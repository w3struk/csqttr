package com.csqtt.client

/**
 * Итог применения серверного правила маршрутизации.
 *
 * `Terminal` означает, что туннель поднимать нельзя: список, который требует
 * правило, не удалось ни получить, ни проверить. Решение принимается до отправки
 * любых команд клиенту.
 */
sealed interface RoutingApplyResult {
    data object Applied : RoutingApplyResult
    data class Terminal(val code: String, val message: String) : RoutingApplyResult
}

/**
 * JVM-тестируемое зеркало `@Volatile`-флага `TunnelManager.routingTerminal`.
 * Флаг важнее факта остановки: `handleCriticalError` только запускает корутину,
 * а следующий кадр `Config` приходит раньше, чем она выполнится.
 */
internal class RoutingTerminalState {
    var terminal: Boolean = false
        private set

    fun onResult(result: RoutingApplyResult) {
        terminal = result is RoutingApplyResult.Terminal
    }
}

internal object RoutingVpnStartPolicy {
    fun shouldStart(result: RoutingApplyResult, terminal: Boolean): Boolean =
        result is RoutingApplyResult.Applied && !terminal
}

internal object RoutingCommandPolicy {
    fun domainRoutingCommand(
        enabled: Boolean,
        directDomains: String,
        isWhitelist: Boolean,
        ipIsWhitelist: Boolean,
        directIps: String,
    ): String = buildString {
        append("UPDATE_DOMAINS|enabled=").append(if (enabled) 1 else 0)
        append(";whitelist=").append(if (isWhitelist) 1 else 0)
        append(";domains=").append(directDomains)
        append(";ip_enabled=").append(if (directIps.isNotBlank()) 1 else 0)
        append(";ip_whitelist=").append(if (ipIsWhitelist) 1 else 0)
        append(";ips=").append(directIps)
    }

    fun updateIpsCommand(sha: String, blobGzipBase64: String): String =
        "UPDATE_IPS|$sha|$blobGzipBase64"

    fun clearIpsCommand(): String = "UPDATE_IPS|"
}

/**
 * Единственный источник `VpnService.Builder.excludeRoute`.
 *
 * Шаблонные адреса (тысячи CIDR) сюда не попадают никогда: это ломает
 * `LinkProperties`/netd и не работает на API < 33. Явный список оператора
 * исключается только в чёрном режиме, как и раньше.
 */
internal object VpnExcludeRoutePolicy {
    fun entries(rule: ServerRoutingRule?): List<String> {
        if (rule == null || rule.ipIsWhite) return emptyList()
        return rule.ips
    }
}
