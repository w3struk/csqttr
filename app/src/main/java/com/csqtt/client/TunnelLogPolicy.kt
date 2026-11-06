package com.csqtt.client

object TunnelLogPolicy {
    /** Ключ строки-причины терминальной остановки в журнале. */
    const val TERMINAL_STOP_KEY: String = "circuit_breaker"

    /**
     * Приоритет строки причины (прежний `-1`, семантику не менял). На видимость
     * он не влияет: `LogLine` берёт уровень по `isError = true` → `LogLevel.ERR`,
     * а лестница приоритетов (`priority <= 2/4/6`) играет роль только когда
     * `level == null` и запись не ошибка.
     */
    const val TERMINAL_STOP_PRIORITY: Int = -1

    /**
     * Строки, которые остаются в журнале и при выключенном логировании
     * (`TunnelManager.isLoggingEnabled = false`). Ошибки и `LogLevel.ERR`
     * пропускаются по своему признаку; здесь — статусные строки, которые
     * пользователь ждёт и без подробного лога: готовность, трафик и обе
     * стадии диагностики медленного старта. Последнее важно именно теперь:
     * `[ДИАГНОСТИКА]` больше не ошибка (`isError = false` в
     * `StartupDiagnosticPolicy.Notice`), поэтому без этого списка она молча
     * исчезала бы в тихом режиме.
     */
    private val QUIET_MODE_VISIBLE_KEYS: Set<String> = setOf(
        "ready",
        "stats",
        StartupDiagnosticPolicy.CREDENTIALS_KEY,
        StartupDiagnosticPolicy.TURN_KEY,
    )

    fun isAllowedWhenInactiveLogging(key: String, isError: Boolean, level: LogLevel?): Boolean {
        return isError || level == LogLevel.ERR || key in QUIET_MODE_VISIBLE_KEYS
    }

    /**
     * Единый предикат обоих гейтов pending-буфера — постановки
     * (`updateLogForProcess`) и флаша (`applyPendingLog`).
     *
     * Фактическое положение дел, из которого вырос предикат: причина фатальной
     * остановки ставится в `pendingLogs`, пока `ProcessIdentity` ещё текущий, а
     * применяется позже — отложенным на `LOG_UI_FLUSH_MS` флашем или флашем
     * следующего `start()`. К этому моменту `stopLocked` →
     * `terminateProcessLocked` уже обнулил `process`/`processIdentity`, и
     * `isCurrent` (тот же объект процесса + тот же `process` + то же
     * `processGeneration` + принятый тикет) даёт false. Без исключения для
     * terminal-записи строка `[СТОП] …` из in-app журнала, который пользователь
     * копирует в отчёт, пропадала.
     *
     * Что реально защищает атрибуцию и порядок — и чем именно (этим предикатом
     * это НЕ защищается):
     * - принадлежность поколению держит ключ буфера (`pendingLogKey`): в него
     *   входит `generation`, поэтому записи разных поколений физически не могут
     *   слиться в одну pending-строку;
     * - порядок строк держат маркер сессии (`session_*`, на нём останавливается
     *   `LogJournalPolicy.mergeIndex`) и инвалидация тикета: `start()` без
     *   `isSwitching` ставит маркер ПОСЛЕ принудительного флаша, поэтому записи
     *   прошлой сессии оказываются выше маркера. У путей transport- и crash-restart
     *   маркера нет, и они обязаны сбросить буфер до `startProcessLocked` — иначе
     *   `[СТОП] <прошлой причины>` станет ниже строк нового процесса;
     * - сам предикат решает ровно одно: выбрасывать ли запись с не-текущим
     *   identity или дотянуть её до журнала.
     *
     * @param identityKnown запись привязана к поколению процесса (`false` —
     *        строка общего журнала, `identity == null`)
     * @param identityCurrent это поколение всё ещё действующее; значимо только
     *        при `identityKnown = true`
     * @param terminal запись — причина терминальной остановки туннеля
     */
    fun acceptsPendingLog(identityKnown: Boolean, identityCurrent: Boolean, terminal: Boolean): Boolean =
        !identityKnown || terminal || identityCurrent

    /**
     * Ключ pending-буфера: поколение плюс смысловые поля записи. Две постановки
     * с одинаковым ключом — одна логическая строка (обновляются текст, время и
     * счётчик); всё, что отличается хотя бы одним полем, живёт в отдельной
     * записи, поэтому терминальный флаг не может перетечь в чужую строку.
     */
    fun pendingLogKey(
        generation: Long?,
        key: String,
        priority: Int,
        isError: Boolean,
        levelName: String?,
    ): String = "${generation ?: 0L}:$key:$priority:$isError:${levelName.orEmpty()}"

    /**
     * terminal слитой записи — sticky строго внутри одного `pendingLogKey`.
     * Правило двустороннее и проверяется тестами: терминальная строка не может
     * стать не-терминальной (`existing = true` всегда даёт `true`), а обычная
     * строка не становится терминальной сама по себе — `true` приходит только из
     * `terminalStopEntry`, чей ключ (`pendingLogKey`) не совпадает ни с одной
     * обычной строкой, так что `existing = false, incoming = true` для чужой
     * строки не возникает.
     */
    fun mergedTerminal(existingTerminal: Boolean, incomingTerminal: Boolean): Boolean =
        existingTerminal || incomingTerminal

    /**
     * Жертва при переполнении pending-буфера: первая НЕ терминальная запись в
     * порядке постановки. Терминальные причины — последние: сбросить их значит
     * обнулить весь смысл обхода гейта. Честная оговорка: если в буфере не
     * осталось ничего, кроме причин остановки, возвращаем первую (`null` только
     * для пустого буфера) — лимит `MAX_PENDING_LOGS` важнее, чем гипотетические
     * 128 причин остановки за одно окно флаша.
     */
    fun evictionKey(rows: List<Pair<String, Boolean>>): String? {
        val victim = rows.firstOrNull { !it.second } ?: rows.firstOrNull()
        return victim?.first
    }

    /**
     * Строка причины фатальной остановки — единственная точка, где рождаются её
     * ключ, текст, приоритет и признак `terminal`. `TunnelManager.updateLog` и
     * `updateProcessLog` жёстко ставят `terminal = false`, поэтому обычный
     * эмитент не может породить ни строку `[СТОП]`/`circuit_breaker`, ни
     * терминальное обходное исключение: для этого есть только
     * `updateTerminalStopLog(terminalStopEntry(...))`.
     */
    fun terminalStopEntry(reason: String): TerminalStopEntry = TerminalStopEntry(
        key = TERMINAL_STOP_KEY,
        message = "[СТОП] $reason",
        priority = TERMINAL_STOP_PRIORITY,
        isError = true,
        terminal = true,
    )

    /** Набор полей постановки причины остановки (см. `terminalStopEntry`). */
    data class TerminalStopEntry(
        val key: String,
        val message: String,
        val priority: Int,
        val isError: Boolean,
        val terminal: Boolean,
    )

    fun isInternalRecovery(line: String): Boolean {
        if (line.contains("FATAL_", ignoreCase = true)) return false
        return line.contains("GETCONF", ignoreCase = true) ||
            line.contains("[СЕТЬ][RETRY]", ignoreCase = true) ||
            line.contains("[TURN][RETRY]", ignoreCase = true) ||
            line.contains("[HANDSHAKE][RETRY]", ignoreCase = true) ||
            line.contains("PEER_LIVENESS_TIMEOUT", ignoreCase = true) ||
            line.contains("486", ignoreCase = true) ||
            line.contains("437", ignoreCase = true) ||
            (line.contains("turn", ignoreCase = true) && line.contains("timeout", ignoreCase = true)) ||
            (line.contains("allocation", ignoreCase = true) && line.contains("quota", ignoreCase = true)) ||
            (line.contains("allocation", ignoreCase = true) && line.contains("mismatch", ignoreCase = true)) ||
            (line.contains("[КРЕД", ignoreCase = true) && line.contains("Повторяем через", ignoreCase = true))
    }

    fun isTurnStreamFailure(line: String): Boolean {
        if (isInternalRecovery(line)) return false
        return line.contains("[TURN][DOWN]", ignoreCase = true) ||
            (
                line.contains("[ВОРКЕР", ignoreCase = true) &&
                    line.contains("[TURN]", ignoreCase = true) &&
                    (
                        line.contains("ошибка", ignoreCase = true) ||
                            line.contains("failed", ignoreCase = true) ||
                            line.contains("exhausted", ignoreCase = true)
                        )
                )
    }
}
