package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TunnelLogPolicyTest {
    @Test
    fun removesStatusStickersFromVisibleLogs() {
        assertEquals(
            "VPN TUN: разрешение Android VPN было отозвано",
            withoutLogStickers("❌ VPN TUN: разрешение Android VPN было отозвано"),
        )
        assertEquals("Поток готов ✓", withoutLogStickers("Поток готов ✓"))
        assertEquals("✗ Ошибка VPN", withoutLogStickers("✗ Ошибка VPN"))
        assertEquals("Сервис запущен", withoutLogStickers("[✅] Сервис запущен"))
        assertEquals("[СЕТЬ] Переподключение", withoutLogStickers("[СЕТЬ] ⚠ Переподключение"))
    }

    @Test
    fun inactiveLoggingKeepsOnlyReadyStatsAndErrors() {
        assertTrue(TunnelLogPolicy.isAllowedWhenInactiveLogging("ready", false, LogLevel.OK))
        assertTrue(TunnelLogPolicy.isAllowedWhenInactiveLogging("stats", false, LogLevel.NET))
        assertTrue(TunnelLogPolicy.isAllowedWhenInactiveLogging("turn_error", true, LogLevel.ERR))
        assertTrue(TunnelLogPolicy.isAllowedWhenInactiveLogging("general_error", true, null))
        assertFalse(TunnelLogPolicy.isAllowedWhenInactiveLogging("turn_refresh_status", false, LogLevel.LOG))
        assertFalse(TunnelLogPolicy.isAllowedWhenInactiveLogging("wrap_status", false, LogLevel.OK))
        assertFalse(TunnelLogPolicy.isAllowedWhenInactiveLogging("vk_js_call_progress", false, LogLevel.OK))
    }

    @Test
    fun hidesEveryGetconfDiagnostic() {
        assertTrue(TunnelLogPolicy.isInternalRecovery("[GETCONF] Sending 72 bytes"))
        assertTrue(TunnelLogPolicy.isInternalRecovery("[ВОРКЕР #8] GETCONF timeout 750ms"))
        assertTrue(TunnelLogPolicy.isInternalRecovery("GETCONF чтение ответа конфига: timeout"))
        assertFalse(
            TunnelLogPolicy.isInternalRecovery(
                "GETCONF: FATAL_AUTH: неверный пароль подключения"
            )
        )
        assertFalse(
            TunnelLogPolicy.isInternalRecovery(
                "GETCONF: FATAL_PROTOCOL: клиент и сервер используют разные версии протокола"
            )
        )
    }

    @Test
    fun hidesTurnRetriesAndInternalRecovery() {
        assertTrue(
            TunnelLogPolicy.isInternalRecovery(
                "[TURN][RETRY] Ошибка обновления permission: timeout"
            )
        )
        assertTrue(
            TunnelLogPolicy.isInternalRecovery(
                "[TURN][RETRY] Ошибка транзакции ChannelBind: timeout"
            )
        )
        assertTrue(
            TunnelLogPolicy.isInternalRecovery(
                "[TURN][RETRY] Квота Allocate у креда #1; STUN error 486"
            )
        )
        assertTrue(
            TunnelLogPolicy.isInternalRecovery(
                "[TURN][RETRY] Allocation mismatch у креда #1; STUN error 437"
            )
        )
        assertFalse(
            TunnelLogPolicy.isInternalRecovery(
                "[TURN][DOWN] Permission истекает, переподнимаем поток"
            )
        )
        assertTrue(
            TunnelLogPolicy.isInternalRecovery(
                "[ВОРКЕР #17] PEER_LIVENESS_TIMEOUT: 8s без валидных пакетов"
            )
        )
        assertTrue(
            TunnelLogPolicy.isInternalRecovery(
                "[ВОРКЕР #2] [TURN][RETRY] Попытка 46: TURN liveness probe failed"
            )
        )
        assertTrue(
            TunnelLogPolicy.isInternalRecovery(
                "[ВОРКЕР #2] [СЕТЬ][RETRY] Временная ошибка сокета"
            )
        )
        assertTrue(
            TunnelLogPolicy.isInternalRecovery(
                "[ВОРКЕР #1] Ошибка (попытка 1): turn allocate: transaction timeout"
            )
        )
    }

    @Test
    fun surfacesOnlyTurnFailuresThatEndAStream() {
        assertTrue(
            TunnelLogPolicy.isTurnStreamFailure(
                "[TURN][DOWN] Allocation истекает, переподнимаем поток"
            )
        )
        assertTrue(
            TunnelLogPolicy.isTurnStreamFailure(
                "[ВОРКЕР #4] [TURN] Ошибка allocation/кредов: socket closed"
            )
        )
        assertFalse(
            TunnelLogPolicy.isTurnStreamFailure(
                "[ГРУППА #1] [TURN] Креды обновлены, TURN urls=3"
            )
        )
    }

    @Test
    fun pendingLogGateFollowsTheProcessGeneration() {
        // identityKnown = false — строка общего журнала, привязки к поколению нет.
        assertTrue(TunnelLogPolicy.acceptsPendingLog(identityKnown = false, identityCurrent = false, terminal = false))
        assertTrue(TunnelLogPolicy.acceptsPendingLog(identityKnown = true, identityCurrent = true, terminal = false))
        // Обычную запись ушедшего поколения выбрасывать надо: иначе причины из
        // мёртвого процесса пополняли бы журнал действующего.
        assertFalse(TunnelLogPolicy.acceptsPendingLog(identityKnown = true, identityCurrent = false, terminal = false))
    }

    /**
     * Регрессия потерянного `[СТОП]`: причина фатальной остановки ставится в
     * pendingLogs, пока поколение ещё текущее, а в журнал попадает на отложенном
     * флаше — уже после `stopLocked`, который инвалидирует identity. Без
     * terminal-исключения строка молча исчезала, и в журнале, который
     * пользователь копирует в отчёт, оставалось только «VPN-интерфейс закрыт».
     * Тот же предикат стоит на гейте постановки, поэтому запись не теряется и
     * когда фатальное событие дошло уже после requestStop/requestRestart.
     */
    @Test
    fun fatalStopReasonSurvivesProcessInvalidation() {
        val stop = TunnelLogPolicy.terminalStopEntry("routing_payload_incomplete")
        assertTrue(
            TunnelLogPolicy.acceptsPendingLog(
                identityKnown = true,
                identityCurrent = false,
                terminal = stop.terminal,
            )
        )
        assertFalse(TunnelLogPolicy.acceptsPendingLog(true, false, terminal = false))
    }

    /**
     * Причина остановки получается только из `terminalStopEntry`, и её
     * terminal-признак — часть записи, а не отдельный флаг, который вызывающий
     * код может забыть передать: без него та же строка была бы выброшена на
     * не-текущем identity.
     */
    @Test
    fun stopRowCarriesItsTerminalFlag() {
        val stop = TunnelLogPolicy.terminalStopEntry("сервер передал битое правило")
        assertEquals("circuit_breaker", stop.key)
        assertEquals(TunnelLogPolicy.TERMINAL_STOP_KEY, stop.key)
        assertTrue(stop.message.startsWith("[СТОП] "))
        assertTrue(stop.message.contains("сервер передал битое правило"))
        assertEquals(-1, stop.priority)
        assertEquals(TunnelLogPolicy.TERMINAL_STOP_PRIORITY, stop.priority)
        assertTrue(stop.isError)
        assertTrue(stop.terminal)
    }

    /**
     * Атрибуцию поколения держит ключ буфера: строки различаются поколением,
     * priority, isError и уровнем, поэтому слияние определено только для
     * полностью совпавшей логической строки.
     */
    @Test
    fun pendingKeyDefinesTheRowAndKeepsGenerationsApart() {
        val stop = TunnelLogPolicy.terminalStopEntry("x")
        val stopKey = TunnelLogPolicy.pendingLogKey(
            generation = 7L,
            key = stop.key,
            priority = stop.priority,
            isError = stop.isError,
            levelName = null,
        )
        assertEquals(stopKey, TunnelLogPolicy.pendingLogKey(7L, stop.key, stop.priority, stop.isError, null))
        // Другое поколение — другая строка: причины двух процессов не сливаются.
        assertNotEquals(stopKey, TunnelLogPolicy.pendingLogKey(8L, stop.key, stop.priority, stop.isError, null))
        // Другой уровень — тоже другая строка.
        assertNotEquals(stopKey, TunnelLogPolicy.pendingLogKey(7L, stop.key, stop.priority, stop.isError, "ERR"))
        // Общий журнал (identity == null) живёт в собственном ведре поколения 0.
        assertNotEquals(stopKey, TunnelLogPolicy.pendingLogKey(null, stop.key, stop.priority, stop.isError, null))
        assertTrue(
            TunnelLogPolicy.pendingLogKey(null, "ready", 5, false, "OK")
                .startsWith("0:ready:5:false:")
        )
    }

    /**
     * Терминальный флаг не липнет к чужой строке: ни одна обычная запись того же
     * поколения не делит ключ с причиной остановки, а sticky-слияние определено
     * только внутри одного ключа.
     */
    @Test
    fun terminalFlagNeverLeaksIntoAnotherPendingRow() {
        data class Row(val key: String, val priority: Int, val isError: Boolean, val levelName: String?)

        val generation = 7L
        val stop = TunnelLogPolicy.terminalStopEntry("routing_payload_incomplete")
        val stopKey = TunnelLogPolicy.pendingLogKey(generation, stop.key, stop.priority, stop.isError, null)
        val ordinaryRows = listOf(
            Row("vpn_config_err", 99, true, null),
            Row("protocol_lines_dropped", 98, true, null),
            Row("event_error_routing_payload_too_large", 99, true, null),
            Row("stats", 25, false, "NET"),
            Row(StartupDiagnosticPolicy.CREDENTIALS_KEY, 98, false, null),
        )
        for (row in ordinaryRows) {
            val ordinaryKey =
                TunnelLogPolicy.pendingLogKey(generation, row.key, row.priority, row.isError, row.levelName)
            assertNotEquals("строка ${row.key} не может слиться с причиной остановки", stopKey, ordinaryKey)
            // Обычная строка сливается сама с собой и terminal-флаг не получает.
            assertFalse(TunnelLogPolicy.mergedTerminal(existingTerminal = false, incomingTerminal = false))
        }
        // Внутри своего ключа флаг sticky: повторная причина обязана пережить
        // инвалидацию так же, как первая.
        assertTrue(TunnelLogPolicy.mergedTerminal(existingTerminal = true, incomingTerminal = false))
        assertTrue(TunnelLogPolicy.mergedTerminal(existingTerminal = false, incomingTerminal = stop.terminal))
        assertTrue(TunnelLogPolicy.mergedTerminal(existingTerminal = true, incomingTerminal = true))
    }

    /**
     * NIT-4: слияние повторяющейся постановки не может понизить `terminal` уже
     * лежащей строки (запись буфера неизменяемая, `PendingLog.copy`) и не может
     * повысить его у обычной строки — проверка идёт до конца, до гейта, чтобы
     * видеть последствия, а не только таблицу предиката.
     */
    @Test
    fun mergedTerminalNeverDemotesAnExistingStopRow() {
        val stop = TunnelLogPolicy.terminalStopEntry("битое правило от сервера")

        val mergedFromStop = TunnelLogPolicy.mergedTerminal(existingTerminal = stop.terminal, incomingTerminal = false)
        assertTrue("терминальная строка не деградирует", mergedFromStop)
        assertTrue(TunnelLogPolicy.acceptsPendingLog(true, identityCurrent = false, terminal = mergedFromStop))

        val mergedFromOrdinary =
            TunnelLogPolicy.mergedTerminal(existingTerminal = false, incomingTerminal = false)
        assertFalse("обычная строка не становится терминальной от своего повтора", mergedFromOrdinary)
        assertFalse(TunnelLogPolicy.acceptsPendingLog(true, identityCurrent = false, terminal = mergedFromOrdinary))
    }

    /**
     * NIT-5: при переполнении pending-буфера жертва — первая НЕ терминальная
     * запись. Сбрасывать причину остановки значит обнулить весь обход гейта.
     * Оговорка реализована честно: если не-терминальных не осталось, сбрасывается
     * первая (лимит буфера важнее), а для пустого буфера жертвы нет.
     */
    @Test
    fun evictionSkipsTerminalRows() {
        val rows = listOf(
            "7:stats:25:false:NET" to false,
            "7:circuit_breaker:-1:true:" to true,
            "7:ready:5:false:OK" to false,
        )
        assertEquals("7:stats:25:false:NET", TunnelLogPolicy.evictionKey(rows))
        // не-терминальная выбирается даже стоя за терминальной
        assertEquals(
            "k2",
            TunnelLogPolicy.evictionKey(listOf("k1" to true, "k2" to false, "k3" to false)),
        )
        // только терминальные — жертва всё равно находится
        assertEquals("x", TunnelLogPolicy.evictionKey(listOf("x" to true, "y" to true)))
        assertEquals("solo", TunnelLogPolicy.evictionKey(listOf("solo" to true)))
        assertNull(TunnelLogPolicy.evictionKey(emptyList()))
    }

    /**
     * MINOR-6: диагностика медленного старта больше не ошибка (`isError = false`
     * в `StartupDiagnosticPolicy.Notice`), и в тихом режиме её держит список
     * ключей политики — иначе она исчезала бы совсем.
     */
    @Test
    fun startupDiagnosticsStayVisibleWhenLoggingIsDisabled() {
        assertTrue(
            TunnelLogPolicy.isAllowedWhenInactiveLogging(StartupDiagnosticPolicy.CREDENTIALS_KEY, false, null)
        )
        assertTrue(TunnelLogPolicy.isAllowedWhenInactiveLogging(StartupDiagnosticPolicy.TURN_KEY, false, null))
        // прежние статусные строки на том же механизме
        assertTrue(TunnelLogPolicy.isAllowedWhenInactiveLogging("ready", false, LogLevel.OK))
        assertTrue(TunnelLogPolicy.isAllowedWhenInactiveLogging("stats", false, LogLevel.NET))
        // ошибки — как и раньше, по своему признаку
        assertTrue(TunnelLogPolicy.isAllowedWhenInactiveLogging("event_error_any", true, null))
        // а обычная не-ошибка без уровня по-прежнему не проходит
        assertFalse(TunnelLogPolicy.isAllowedWhenInactiveLogging("wrap_status", false, null))
        assertFalse(TunnelLogPolicy.isAllowedWhenInactiveLogging("vk_js_call_progress", false, LogLevel.LOG))
    }
}
