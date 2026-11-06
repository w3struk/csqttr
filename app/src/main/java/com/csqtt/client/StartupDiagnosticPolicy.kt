package com.csqtt.client

/**
 * Решение «что показать в журнале, если туннель долго не поднимается».
 *
 * Вынесено из `TunnelManager` по соглашению репозитория (нетривиальная логика —
 * в `internal object *Policy`, чтобы гонять на JVM) и потому, что раньше это был
 * просто текст на 30-й секунде: он обвинял VK в восемь раз раньше, чем клиент сам
 * считает загрузку кредов неудачной, и предлагал проверить «токен и капчу» там,
 * где ни токен, ни капча не участвуют.
 */
internal object StartupDiagnosticPolicy {
    /**
     * Порог, раньше которого писать о медленном старте смысла нет.
     *
     * Обоснование против двух чисел, у которых это решение стоит:
     * - 240 с — собственный бюджет загрузки TURN-кредов клиента
     *   (`CREDENTIAL_FETCH_TIMEOUT` в rust-client/worker.rs). До него клиент ещё
     *   сам пытается, поэтому любое утверждение о проблеме раньше 240 с — гадание,
     *   а не диагноз;
     * - 80–90 с — замеренная на деградировавшем DNS длительность загрузки кредов
     *   (в нормальной сети — ~1.4 с). Порог обязан быть выше этого, иначе
     *   сообщение появляется при заведомо поздней, но успешной загрузке.
     *
     * 120 с — с запасом над наблюдаемыми 90 с и ровно вдвое раньше отказа
     *   клиента: предупреждение успевает показаться, пока попытки ещё идут, и не
     *   выглядит как «не получилось».
     */
    const val NOTICE_AFTER_MS: Long = 120_000L

    /**
     * Бюджет загрузки TURN-кредов клиента — ручная копия `CREDENTIAL_FETCH_TIMEOUT`
     * из `rust-client/worker.rs` (240 с). Связки через код тут нет и быть не может:
     * это правка через границу языков. Меняешь таймаут клиента — пересматривай и
     * этот номер, и `NOTICE_AFTER_MS` (соотношение «порог вдвое меньше бюджета»
     * проверяет `StartupDiagnosticPolicyTest`).
     */
    const val CLIENT_CREDENTIAL_BUDGET_MS: Long = 240_000L

    const val NOTICE_PRIORITY: Int = 98

    /** Ключ строки «ждём креды» в pending-буфере и журнале. */
    const val CREDENTIALS_KEY: String = "startup_waiting_credentials"

    /** Ключ строки «креды есть, соединения нет». */
    const val TURN_KEY: String = "startup_waiting_turn"

    /**
     * Запись в журнале: ключ агрегации, текст, приоритет и признак ошибки.
     *
     * `isError = false` намеренно: текст говорит «клиент продолжает попытки», а
     * `isError = true` поднимал бы `unreadErrorCount` и красил строку как ошибку
     * (см. `LogJournalPolicy.unreadIncrement`, `ui/logs/LogLine.kt`). Видимость
     * при выключенном логировании держится не на этом флаге, а на ключах
     * (`TunnelLogPolicy.isAllowedWhenInactiveLogging`).
     */
    internal data class Notice(
        val key: String,
        val message: String,
        val priority: Int,
        val isError: Boolean,
    )

    /**
     * Что показать, или `null`, если показывать нечего.
     *
     * @param stage на каком слое встал запуск (стадия считается по событиям клиента)
     * @param authMode эффективный режим авторизации — ровно то значение, которое
     *        `TunnelManager` кладёт в argv `-vk-auth-mode`
     * @param waitedMs сколько времени процесс поднимается
     * @param activeWorkers число активных потоков: если они есть, диагностики нет
     */
    fun notice(
        stage: TunnelStartupStage,
        authMode: String?,
        waitedMs: Long,
        activeWorkers: Int,
    ): Notice? {
        if (waitedMs < NOTICE_AFTER_MS) return null
        if (activeWorkers > 0) return null
        return when (stage) {
            TunnelStartupStage.READY -> null
            TunnelStartupStage.WAITING_FOR_TURN_OR_PEER -> Notice(
                key = TURN_KEY,
                message = "[ДИАГНОСТИКА] TURN-креды получены, но ни один TURN-allocation с сервером ещё не " +
                    "завершился — проверяем соединение, клиент продолжает попытки",
                priority = NOTICE_PRIORITY,
                isError = false,
            )
            TunnelStartupStage.WAITING_FOR_CREDENTIALS -> Notice(
                key = CREDENTIALS_KEY,
                message = credentialsMessage(authMode),
                priority = NOTICE_PRIORITY,
                isError = false,
            )
        }
    }

    /**
     * Текст стадии «ждём креды».
     *
     * Пользовательский VK-токен в этой ветке не участвует никогда: креды выдаются
     * анонимным медиаклом, а `auto_js` берёт их из JS-брокера аккаунтов. Капча
     * тоже не первичный путь:
     * - `vkcalls` идёт через getAnonymToken → getCallPreview → getAnonymCallToken
     *   → auth.anonymLogin → joinConversationByLink; капча подключается только
     *   автоматическим fallback'ом после двух неудачных попыток, и просить
     *   человека «проверить капчу» на этой стадии — значит отправлять его чинить
     *   то, чего он не касался (окно капчи приложение само покажет, когда до
     *   него дойдёт);
     * - `legacy` пропускает VK Calls и сразу идёт через ветку с капчей, поэтому
     *   там подтверждение VK действительно возможно и упоминание уместно.
     *
     * Токен не упоминается ни в одном режиме: креды загружаются app-кредами
     * клиента (client_id) и капчей, а не access-токеном пользователя.
     */
    fun credentialsMessage(authMode: String?): String =
        when (authMode) {
            CsqttConstants.VkAuth.MODE_CAPTCHA ->
                "[ДИАГНОСТИКА] Всё ещё ждём TURN-креды от VK: при слабом сигнале это бывает долго, а в режиме " +
                    "с капчей VK может запросить подтверждение — приложение покажет окно капчи. " +
                    "Проверьте соединение; клиент продолжает попытки."
            else ->
                "[ДИАГНОСТИКА] Всё ещё ждём TURN-креды от VK: при слабом сигнале или медленном DNS это бывает " +
                    "долго. Проверьте соединение — клиент продолжает попытки сам."
        }
}
