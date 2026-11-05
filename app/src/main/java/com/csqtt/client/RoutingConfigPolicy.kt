package com.csqtt.client

/**
 * Какое правило маршрутизации применять при разборе `TUNCONF`.
 *
 * Правило приходит отдельным событием `ROUTING` и к моменту `TUNCONF` уже может
 * быть в памяти. В самом `TUNCONF` правило бывает только устаревшим встроенным
 * полем; `null` там означает «в конфиге правила нет», а не «правило снято».
 * Поэтому отсутствие встроенного правила не должно затирать уже полученное.
 */
internal object RoutingConfigPolicy {
    fun ruleToApply(
        embedded: ServerRoutingRule?,
        active: ServerRoutingRule?,
    ): ServerRoutingRule? = embedded ?: active

    /**
     * Адрес туннеля и DNS из строки `TUNCONF`, нужные `applyServerRoutingRule`
     * для перезапуска VPN. Вынесено сюда, чтобы оба обработчика маршрутизации
     * (правило и его отсутствие) разбирали конфиг одинаково.
     */
    fun tunnelEndpoints(config: String?): Pair<String, String> {
        if (config == null || !config.startsWith("TUNCONF:")) return "" to ""
        val parts = config.removePrefix("TUNCONF:").split(":")
        return parts.getOrNull(0)?.trim().orEmpty() to parts.getOrNull(1)?.trim().orEmpty()
    }
}
