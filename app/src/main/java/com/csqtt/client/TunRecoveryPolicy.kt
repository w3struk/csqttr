package com.csqtt.client

import java.net.Inet4Address
import java.net.InetAddress

internal enum class TunAppsMode { ALLOW, DISALLOW }
internal enum class TunRouteType { INCLUDE, EXCLUDE }

internal data class TunAppliedApps(val mode: TunAppsMode, val packages: Set<String>)

/**
 * Только успешно переданные Builder входы, а не правило или настройки профиля.
 * complete не означает атомарный снимок UID: пакетные изменения по-прежнему
 * требуют forceRebuild через существующий PackageChangePolicy/reloadVpn.
 */
internal data class TunAppliedPlan(
    val clientAddress: String,
    val mtu: Int,
    val apps: TunAppliedApps,
    val dnsServers: List<String>,
    val routes: Map<String, TunRouteType>,
    val metered: Boolean?,
    val complete: Boolean,
)

internal object TunIpv4Policy {
    fun parseAddress(raw: String): Inet4Address? {
        val parts = raw.trim().split('.')
        if (parts.size != 4) return null
        val bytes = ByteArray(4)
        for ((index, part) in parts.withIndex()) {
            if (part.isEmpty() || part.any { !it.isDigit() }) return null
            val octet = part.toIntOrNull()?.takeIf { it in 0..255 } ?: return null
            bytes[index] = octet.toByte()
        }
        return InetAddress.getByAddress(bytes) as? Inet4Address
    }

    fun address(address: Inet4Address): String =
        address.address.joinToString(".") { (it.toInt() and 0xff).toString() }

    fun prefix(address: Inet4Address, length: Int): String {
        require(length in 0..32)
        val bits = address.address.fold(0L) { value, byte -> (value shl 8) or (byte.toLong() and 0xff) }
        val mask = if (length == 0) 0L else (0xffff_ffffL shl (32 - length)) and 0xffff_ffffL
        val network = bits and mask
        return listOf(24, 16, 8, 0).joinToString(".") { ((network ushr it) and 0xff).toString() } + "/$length"
    }
}

/** Каждый add* записывается после успеха; любой сбой запрещает reuse этого FD. */
internal class TunAppliedPlanRecorder(
    private val clientAddress: Inet4Address,
    private val mtu: Int,
    private val appsMode: TunAppsMode,
) {
    private val packages = linkedSetOf<String>()
    private val dnsServers = linkedSetOf<String>()
    private val routes = linkedMapOf<String, TunRouteType>()
    private var metered: Boolean? = null
    private var complete = true

    fun incomplete() { complete = false }
    fun metered(value: Boolean) { metered = value }
    fun application(packageName: String) { packages += packageName }
    fun dns(address: Inet4Address) { dnsServers += TunIpv4Policy.address(address) }

    fun route(address: Inet4Address, prefix: Int, type: TunRouteType) {
        // На API 33 DNS /32, добавленный после excludeRoute того же префикса,
        // заменяет его тип. Разные префиксы остаются независимыми маршрутами.
        routes[TunIpv4Policy.prefix(address, prefix)] = type
    }

    fun snapshot(): TunAppliedPlan = TunAppliedPlan(
        clientAddress = TunIpv4Policy.prefix(clientAddress, 32),
        mtu = mtu,
        apps = TunAppliedApps(appsMode, packages.toSet()),
        dnsServers = dnsServers.toList(),
        routes = routes.toMap(),
        metered = metered,
        complete = complete,
    )
}

/** FD принадлежит интерфейсу: retire закрывает его после выхода sender, не после ACK. */
internal class TunDescriptorLifetimePolicy {
    private var inDelivery = false
    private var retired = false
    private var closeClaimed = false

    @Synchronized
    fun beginDelivery(): Boolean {
        if (retired || inDelivery) return false
        inDelivery = true
        return true
    }

    @Synchronized
    fun finishDelivery(): Boolean {
        check(inDelivery)
        inDelivery = false
        return claimClose()
    }

    @Synchronized
    fun retire(): Boolean {
        retired = true
        return claimClose()
    }

    private fun claimClose(): Boolean {
        if (!retired || inDelivery || closeClaimed) return false
        closeClaimed = true
        return true
    }
}

internal object TunRecoveryPolicy {
    fun shouldReuse(
        hasInterface: Boolean,
        descriptorValid: Boolean,
        serviceDestroyed: Boolean,
        forceRebuild: Boolean,
        appliedPlan: TunAppliedPlan?,
        requestedPlan: TunAppliedPlan?,
    ): Boolean =
        hasInterface &&
            descriptorValid &&
            !serviceDestroyed &&
            !forceRebuild &&
            appliedPlan?.complete == true &&
            requestedPlan?.complete == true &&
            appliedPlan == requestedPlan

    fun shouldRestoreInterface(
        permissionGranted: Boolean,
        stopRequested: Boolean,
        serviceDestroyed: Boolean,
        activeClientIp: String?,
        activeDns: String?,
    ): Boolean = false
}
