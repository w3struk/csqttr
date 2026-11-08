package com.csqtt.client

internal const val ROUTING_CONNECTION_GENERATION = "routing_connection_generation"

/**
 * Один монитор для подключения, готовности VPN и отложенного RELOAD_ROUTING.
 *
 * TunnelManager публикует identity/поколение и snapshot правила под этим же
 * монитором. Callback несёт токен конкретного старта: прежний процесс или
 * прежняя выдача FD не могут снять долг нового старта.
 */
internal class RoutingDeferredReload {
    class Connection internal constructor(val generation: Long)
    class VpnStart internal constructor(val connection: Connection, internal val reasonBeforeSnapshot: String?)
    data class Ready(val reloadReason: String?)

    private var connection: Connection? = null
    private var vpnStart: VpnStart? = null
    private var ready = false
    private var stopped = false
    private var reloadScheduled = false
    private var reason: String? = null

    @Synchronized
    fun begin(generation: Long): Connection {
        clear()
        return Connection(generation).also { connection = it }
    }

    @Synchronized
    fun currentConnection(generation: Long? = null): Connection? =
        connection?.takeIf { generation == null || it.generation == generation }

    @Synchronized
    fun currentStart(): VpnStart? = vpnStart

    @Synchronized
    fun isCurrent(value: Connection): Boolean = connection === value

    @Synchronized
    fun isCurrent(value: VpnStart): Boolean = vpnStart === value && isCurrent(value.connection)

    /** Долг до snapshot покрыт пересборкой или доказанным совпадением AppliedPlan. */
    @Synchronized
    fun markStarting(value: Connection): VpnStart? {
        if (!isCurrent(value)) return null
        // Предыдущая выдача FD могла ещё ждать ACK. Её snapshot не означает,
        // что интерфейс пересобран: следующий START наследует невыполненный долг.
        val pending = reason ?: vpnStart?.reasonBeforeSnapshot.takeIf { !ready && !stopped }
        ready = false
        stopped = false
        reloadScheduled = false
        reason = null
        return VpnStart(value, pending).also { vpnStart = it }
    }

    /** Решение «отправить сейчас или запомнить» атомарно с ready и identity. */
    @Synchronized
    fun request(connection: Connection, value: String): String? {
        if (!isCurrent(connection)) return null
        if (ready && !reloadScheduled) {
            reloadScheduled = true
            return value
        }
        reason = value
        return null
    }

    @Synchronized
    fun markReady(value: VpnStart, routesRebuilt: Boolean = true): Ready? {
        if (!isCurrent(value) || stopped || ready) return null
        ready = true
        val pending = reason ?: value.reasonBeforeSnapshot.takeUnless { routesRebuilt }
        reason = null
        reloadScheduled = pending != null
        return Ready(pending)
    }

    @Synchronized
    fun markStopped(value: VpnStart): Boolean {
        if (!isCurrent(value) || stopped) return false
        stopped = true
        ready = false
        reloadScheduled = false
        reason = null
        return true
    }

    @Synchronized
    fun clear() {
        connection = null
        vpnStart = null
        ready = false
        stopped = false
        reloadScheduled = false
        reason = null
    }
}
