package com.csqtt.client

import android.content.Intent
import android.app.NotificationManager
import android.net.LocalSocket
import android.net.VpnService
import android.net.wifi.WifiManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.coroutines.coroutineContext

class TunVpnService : VpnService() {
    private val serviceJob = SupervisorJob()
    private val serviceScope = CoroutineScope(serviceJob + Dispatchers.IO)
    private val vpnMutex = Mutex()
    private val interfaceLock = Any()
    private class VpnInterface(
        val descriptor: ParcelFileDescriptor,
        val appliedPlan: TunAppliedPlan,
        var start: RoutingDeferredReload.VpnStart,
    ) {
        val lifetime = TunDescriptorLifetimePolicy()
        fun retire(): ParcelFileDescriptor? = descriptor.takeIf { lifetime.retire() }
        fun finishDelivery(): ParcelFileDescriptor? = descriptor.takeIf { lifetime.finishDelivery() }
    }
    private class FdDelivery(val owner: VpnInterface, val start: RoutingDeferredReload.VpnStart) {
        lateinit var job: Job
        // Только под interfaceLock; socket.close и ожидание job — снаружи.
        var socket: LocalSocket? = null
        var cancelled = false
    }
    private var vpnInterface: VpnInterface? = null
    @Volatile
    private var activeVpnStart: RoutingDeferredReload.VpnStart? = null
    private var fdDelivery: FdDelivery? = null
    @Volatile
    private var recoveryAttempts = 0
    @Volatile
    private var stopRequested = false
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    @Volatile
    private var serviceDestroyed = false

    companion object {
        private const val TAG = "TunVPN"
        private const val FD_DELIVERY_MAX_ATTEMPTS = 60

        @Volatile
        var instance: TunVpnService? = null
            private set

        @Volatile
        var tunFd: Int = -1
            private set
    }

    // LOW_LATENCY Wi-Fi lock is active only with the screen on, so the deprecated HIGH_PERF mode is kept for the background VPN.
    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        if (wakeLock?.isHeld != true) {
            val pm = getSystemService(PowerManager::class.java)
            wakeLock = pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "csqtt:tun_vpn_service")?.apply {
                setReferenceCounted(false)
                acquire(24 * 60 * 60 * 1000L)
            }
        }
        if (wifiLock?.isHeld != true) {
            val wm = applicationContext.getSystemService(WifiManager::class.java)
            wifiLock = wm?.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "csqtt:tun_vpn_wifi")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        runCatching {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        }
        wakeLock = null
        runCatching {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        }
        wifiLock = null
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        acquireLocks()
        getSystemService(NotificationManager::class.java)
            .deleteNotificationChannel(CsqttConstants.Notifications.VPN_CHANNEL_ID)
        Log.d(TAG, "TunVpnService created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        acquireLocks()
        if (intent == null) {
            if (TunnelManager.running.value && !stopRequested) {
                Log.i(TAG, "TunVpnService restarted by Android with null intent, recovering active VPN")
                val plan = synchronized(interfaceLock) { vpnInterface?.appliedPlan }
                val ip = plan?.clientAddress?.substringBefore('/')
                val dns = plan?.dnsServers?.joinToString(",")
                val connection = activeVpnStart?.connection
                if (ip != null && dns != null && connection != null && TunnelManager.isRoutingConnectionCurrent(connection)) {
                    serviceScope.launch {
                        startVpn(ip, dns, forceRebuild = false, connection = connection, reason = "android_restart", mtu = plan.mtu)
                    }
                } else {
                    TunnelManager.reloadVpn()
                }
                return START_STICKY
            }
            stopSelf()
            return START_NOT_STICKY
        }

        when (intent.action) {
            "START" -> {
                val connection = TunnelManager.routingConnectionFor(
                    intent.getLongExtra(ROUTING_CONNECTION_GENERATION, 0L).takeIf { it > 0L },
                ) ?: return START_NOT_STICKY
                stopRequested = false
                val plan = synchronized(interfaceLock) { vpnInterface?.appliedPlan }
                val clientIp = intent.getStringExtra("client_ip") ?: plan?.clientAddress?.substringBefore('/') ?: return START_NOT_STICKY
                val dns = intent.getStringExtra("dns") ?: plan?.dnsServers?.joinToString(",") ?: return START_NOT_STICKY
                val forceRebuild = intent.getBooleanExtra("force_rebuild", false)
                val isRoutingReload = intent.getBooleanExtra("is_routing_reload", false)
                val reason = intent.getStringExtra("reason") ?: "start"
                val mtu = intent.getIntExtra("mtu", CsqttConstants.Vpn.DEFAULT_MTU)
                if (!forceRebuild) recoveryAttempts = 0
                serviceScope.launch {
                    startVpn(clientIp, dns, forceRebuild, connection, isRoutingReload, reason, mtu)
                }
            }
            "RELOAD_ROUTING" -> {
                val connection = TunnelManager.routingConnectionFor(
                    intent.getLongExtra(ROUTING_CONNECTION_GENERATION, 0L).takeIf { it > 0L },
                ) ?: return START_NOT_STICKY
                val plan = synchronized(interfaceLock) { vpnInterface?.appliedPlan }
                val clientIp = intent.getStringExtra("client_ip") ?: plan?.clientAddress?.substringBefore('/') ?: return START_NOT_STICKY
                val dns = intent.getStringExtra("dns") ?: plan?.dnsServers?.joinToString(",") ?: return START_NOT_STICKY
                val reason = intent.getStringExtra("reason") ?: "routing_reload"
                val mtu = intent.getIntExtra("mtu", CsqttConstants.Vpn.DEFAULT_MTU)
                serviceScope.launch {
                    startVpn(clientIp, dns, forceRebuild = true, connection = connection, isRoutingReload = true, reason = reason, mtu = mtu)
                }
            }
            "STOP" -> {
                stopRequested = true
                serviceScope.launch {
                    vpnMutex.withLock { stopVpn() }
                    releaseLocks()
                    stopSelf()
                }
            }
            "CLOSE_INTERFACE" -> {
                // Интерфейс закрывается, служба остаётся живой: stopSelf/releaseLocks здесь нельзя,
                // иначе следующий START упрётся в фоновые ограничения startService, а туннель уже мёртв.
                serviceScope.launch {
                    vpnMutex.withLock {
                        closeVpnInterface(
                            logKey = "vpn_close_on_tunnel_exit",
                            logMessage = "[TUN] VPN-интерфейс закрыт: туннель остановлен",
                        )
                    }
                }
            }
        }

        return START_STICKY
    }

    private suspend fun startVpn(
        clientIp: String,
        dns: String,
        forceRebuild: Boolean,
        connection: RoutingDeferredReload.Connection,
        isRoutingReload: Boolean = false,
        reason: String = "unknown",
        mtu: Int = CsqttConstants.Vpn.DEFAULT_MTU,
        expectedStart: RoutingDeferredReload.VpnStart? = null,
    ) {
        vpnMutex.withLock {
        if (stopRequested || serviceDestroyed) return
        if (!TunnelManager.isRoutingConnectionCurrent(connection) ||
            (expectedStart != null && !TunnelManager.isVpnStartCurrent(expectedStart))) return
        // Sender не берёт vpnMutex: его recovery запускается отдельной задачей.
        // Поэтому ждём только I/O/finally, не удерживая interfaceLock или epoch.
        cancelFdDelivery()?.join()
        if (stopRequested || serviceDestroyed ||
            (expectedStart != null && !TunnelManager.isVpnStartCurrent(expectedStart))) return
        val snapshot = TunnelManager.routingRuleSnapshot(connection, expectedStart) ?: return
        val start = snapshot.start
        activeVpnStart = start
        try {
            val serverRule = snapshot.rule
            // Под правилом читается только чёрный список: он дополняет чёрное
            // правило и вычитается из белого. Белый ключ нужен лишь локальному
            // режиму профиля и под правилом не читается вовсе.
            val settingsStore = SettingsStore(applicationContext)
            fun localList(raw: String) = raw.split(",").filter { it.isNotEmpty() }.toSet()
            val localBlack = localList(settingsStore.excludedApps.first())
            val localWhite =
                if (serverRule == null) localList(settingsStore.whitelistApps.first()) else emptySet()
            val rawRulePackages = serverRule?.packages
                ?.filter { it.isNotEmpty() }
                ?.toSet()
                .orEmpty()
            val isWhitelist: Boolean
            val userSelected: Set<String>
            if (serverRule != null) {
                isWhitelist = serverRule.isWhite
                // Правило сервера поверх локального списка, а не вместо него:
                // режим задаёт оператор, а чёрный список пользователя дополняет
                // чёрное правило и вычитается из белого. Эффективный набор
                // уходит в VpnAppRouting.build, который не знает о его
                // происхождении; подмену невидимого белого списка build решает
                // по СЫРОМУ правилу тем же предикатом, что карточка и per-UID
                // триггер.
                userSelected = MergedRoutingPolicy.effectivePackages(
                    ruleIsWhite = serverRule.isWhite,
                    rulePackages = rawRulePackages,
                    localBlack = localBlack,
                )
            } else {
                isWhitelist = settingsStore.isWhitelist.first()
                userSelected = if (isWhitelist) localWhite else localBlack
            }
            // Пресет существует только вместе с серверным правилом: в локальном режиме
            // его нет, и поведение остаётся прежним.
            val preset: PresetApps
            val orangeEnabled: Set<String>
            if (serverRule != null) {
                preset = PresetApps(
                    red = serverRule.presetRed.toSet(),
                    orange = serverRule.presetOrange.toSet(),
                )
                orangeEnabled = SettingsStore(applicationContext)
                    .orangeTunnelEnabled.first()
                    .split(",")
                    .filter { it.isNotEmpty() }
                    .toSet()
            } else {
                preset = PresetApps(red = emptySet(), orange = emptySet())
                orangeEnabled = emptySet()
            }
            val selfPackage = applicationContext.packageName
            val transportPackages = CsqttConstants.General.VK_TRANSPORT_PACKAGES + selfPackage
            val appsPlan = VpnAppRouting.build(
                hasServerRule = serverRule != null,
                isWhite = isWhitelist,
                rulePackages = userSelected,
                preset = preset,
                userEnabled = orangeEnabled,
                transportPackages = transportPackages,
                selfPackage = selfPackage,
                isInstalled = ::isPackageInstalled,
                serverRulePackages = rawRulePackages,
                userExcluded = if (serverRule?.isWhite == true) localBlack else emptySet(),
            )
            if (appsPlan is VpnAppsPlan.Failure) {
                failVpn(appsPlan.message, start)
                return
            }

            if (VpnService.prepare(this) != null) {
                failVpn("разрешение Android VPN не выдано", start)
                return
            }

            val address = TunIpv4Policy.parseAddress(clientIp)
                ?: throw IllegalArgumentException("сервер передал некорректный адрес TUN: $clientIp")
            val canonicalClientIp = TunIpv4Policy.address(address)
            // Builder и PM остаются вне мониторов. Даже кандидат на reuse
            // собирается из успешных add*, а не из зеркала желаемого правила.
            val builder = Builder()
                .setSession("reCSQTT")
                .setMtu(mtu)
                .addAddress(canonicalClientIp, 32)
                .addRoute("0.0.0.0", 0)
            val recorder = TunAppliedPlanRecorder(
                address, mtu, if (appsPlan is VpnAppsPlan.Allow) TunAppsMode.ALLOW else TunAppsMode.DISALLOW,
            )
            recorder.route(requireNotNull(TunIpv4Policy.parseAddress("0.0.0.0")), 0, TunRouteType.INCLUDE)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                try {
                    // Единственный источник excludeRoute — явный список оператора.
                    // Шаблонные тысячи CIDR сюда не попадают никогда: они идут
                    // только в direct_relay Rust-клиента.
                    val ipListStr = VpnExcludeRoutePolicy.entries(serverRule).joinToString(",")
                    ipListStr.split(",", " ", "\n", "\t")
                        .map { it.trim() }
                        .filter { it.isNotEmpty() }
                        .forEach { rawIp ->
                            try {
                                val (ipPart, prefixPart) = if (rawIp.contains("/")) {
                                    val split = rawIp.split("/", limit = 2)
                                    split[0] to split[1].toInt()
                                } else {
                                    rawIp to 32
                                }
                                val addr = java.net.InetAddress.getByName(ipPart)
                                if (addr is java.net.Inet4Address) {
                                    builder.excludeRoute(android.net.IpPrefix(addr, prefixPart))
                                    recorder.route(addr, prefixPart, TunRouteType.EXCLUDE)
                                }
                            } catch (e: Exception) {
                                recorder.incomplete()
                                Log.w(TAG, "Failed to exclude route for IP: $rawIp", e)
                            }
                        }
                } catch (e: Exception) {
                    recorder.incomplete()
                    Log.w(TAG, "excludeRoute processing failed: ${e.message}", e)
                }
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
                recorder.metered(false)
            }

            var validDnsServers = 0
            dns.split(",")
                .map { it.trim() }
                .filter { it.isNotEmpty() && !it.contains(":") }
                .forEach { dnsServer ->
                    try {
                        val dnsAddress = TunIpv4Policy.parseAddress(dnsServer)
                            ?: throw IllegalArgumentException("некорректный IPv4 DNS: $dnsServer")
                        val canonicalDns = TunIpv4Policy.address(dnsAddress)
                        builder.addDnsServer(canonicalDns)
                        recorder.dns(dnsAddress)
                        builder.addRoute(canonicalDns, 32)
                        recorder.route(dnsAddress, 32, TunRouteType.INCLUDE)
                        validDnsServers++
                    } catch (e: Exception) {
                        recorder.incomplete()
                        Log.w(TAG, "Invalid DNS server: $dnsServer", e)
                    }
                }
            if (validDnsServers == 0) {
                try {
                    val fallback = requireNotNull(TunIpv4Policy.parseAddress("77.88.8.8"))
                    builder.addDnsServer("77.88.8.8")
                    recorder.dns(fallback)
                    builder.addRoute("77.88.8.8", 32)
                    recorder.route(fallback, 32, TunRouteType.INCLUDE)
                } catch (_: Exception) {
                    failVpn("сервер передал некорректный DNS: $dns", start)
                    return
                }
            }

            when (appsPlan) {
                is VpnAppsPlan.Failure -> {
                    failVpn(appsPlan.message, start)
                    return
                }
                is VpnAppsPlan.Allow -> {
                    var includedCount = 0
                    appsPlan.packages.forEach { pkg ->
                        try {
                            builder.addAllowedApplication(pkg)
                            recorder.application(pkg)
                            includedCount++
                        } catch (error: Exception) {
                            recorder.incomplete()
                            Log.w(TAG, "Unable to include $pkg in VPN", error)
                        }
                    }
                    if (includedCount == 0) {
                        failVpn("Android не разрешил добавить выбранные приложения в whitelist", start)
                        return
                    }
                }
                is VpnAppsPlan.Disallow -> {
                    try {
                        builder.addDisallowedApplication(selfPackage)
                        recorder.application(selfPackage)
                    } catch (e: Exception) {
                        Log.e(TAG, "Unable to exclude CSQTT UID from its VPN", e)
                        failVpn("Android не разрешил исключить reCSQTT из собственного VPN", start)
                        return
                    }
                    if (appsPlan.deviceWide) {
                        Log.i(TAG, "Server rule applies to all applications (no package filter)")
                    }
                    if (appsPlan.substituted) {
                        TunnelManager.updateLog(
                            "vpn_whitelist_fallback",
                            "[TUN] Белый список правила сервера не содержит установленных приложений: " +
                                "правило применено ко всем приложениям, кроме пресета, транспорта " +
                                "и ваших исключений",
                            30,
                        )
                    }
                    appsPlan.packages.forEach { pkg ->
                        try {
                            builder.addDisallowedApplication(pkg)
                            recorder.application(pkg)
                        } catch (_: Exception) {
                            recorder.incomplete()
                        }
                    }
                }
            }

            if (!TunnelManager.isVpnStartCurrent(start) || stopRequested || serviceDestroyed) return
            val plan = recorder.snapshot()
            val existing = synchronized(interfaceLock) {
                vpnInterface?.takeIf {
                    !stopRequested && TunRecoveryPolicy.shouldReuse(
                        hasInterface = true,
                        descriptorValid = it.descriptor.fileDescriptor.valid(),
                        serviceDestroyed = serviceDestroyed,
                        forceRebuild = forceRebuild,
                        appliedPlan = it.appliedPlan,
                        requestedPlan = plan,
                    ) && TunnelManager.commitVpnStartIfCurrent(start) { it.start = start }
                }
            }
            if (existing != null) {
                TunnelManager.updateLog(
                    "vpn_reuse",
                    "[TUN] VPN-интерфейс переиспользован без пересборки (причина вызова: $reason)",
                    24,
                )
                // Совпадение полного фактического плана доказывает применение
                // snapshot даже без нового establish; долг после snapshot остаётся.
                sendTunFd(existing, start, dns = plan.dnsServers.joinToString(","), isRoutingReload = isRoutingReload)
                return
            }

            if (!TunnelManager.isVpnStartCurrent(start) || stopRequested || serviceDestroyed) return
            val pfd = builder.establish()
            if (pfd == null) {
                Log.e(TAG, "VPN permission not granted")
                failVpn("Android не создал VPN-интерфейс; проверьте разрешение VPN и Always-on VPN", start)
                return
            }

            // Успешный establish необратимо деактивировал прежний интерфейс.
            // Даже отказ epoch-commit не позволяет сохранить его как reusable.
            val previous = synchronized(interfaceLock) {
                vpnInterface.also {
                    vpnInterface = null
                    tunFd = -1
                }
            }
            runCatching { previous?.retire()?.close() }
            var accepted = false
            try {
                val fd = pfd.fd
                val established = VpnInterface(pfd, plan, start)
                accepted = synchronized(interfaceLock) {
                    !serviceDestroyed && !stopRequested && TunnelManager.commitVpnStartIfCurrent(start) {
                        vpnInterface = established
                        tunFd = fd
                    }
                }
            } finally {
                if (!accepted) runCatching { pfd.close() }
            }
            if (!accepted) return
            if (!isRoutingReload && Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
                runCatching { setUnderlyingNetworks(null) }
            }
            Log.d(TAG, "VPN interface established: IP=$clientIp DNS=$dns fd=$tunFd (reason: $reason)")

            val owner = synchronized(interfaceLock) { vpnInterface?.takeIf { it.descriptor === pfd && it.start === start } } ?: return
            sendTunFd(owner, start, dns = plan.dnsServers.joinToString(","), isRoutingReload = isRoutingReload, routesRebuilt = plan.complete)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start VPN: ${e.message}", e)
            failVpn(e.message ?: e.javaClass.simpleName, start)
        }
        }
    }

    private fun sendTunFd(
        owner: VpnInterface,
        start: RoutingDeferredReload.VpnStart,
        dns: String? = null,
        isRoutingReload: Boolean = false,
        routesRebuilt: Boolean = true,
    ) {
        val delivery = FdDelivery(owner, start)
        val job = serviceScope.launch(start = CoroutineStart.LAZY) {
            val acquired = synchronized(interfaceLock) {
                isFdDeliveryCurrent(delivery) && owner.lifetime.beginDelivery()
            }
            if (!acquired) return@launch
            var success = false
            var attempt = 1
            try {
                while (
                    isFdDeliveryCurrent(delivery) && VpnLifecyclePolicy.shouldRetryFdDelivery(
                        tunnelRunning = TunnelManager.running.value,
                        attempt = attempt,
                        maxAttempts = FD_DELIVERY_MAX_ATTEMPTS,
                    )
                ) {
                    coroutineContext.ensureActive()
                    attempt++
                    val socket = LocalSocket()
                    try {
                        val registered = synchronized(interfaceLock) {
                            if (!isFdDeliveryCurrent(delivery)) false else {
                                delivery.socket = socket
                                true
                            }
                        }
                        if (!registered) return@launch
                        socket.connect(android.net.LocalSocketAddress("csqtt_tun_uds", android.net.LocalSocketAddress.Namespace.ABSTRACT))
                        val output = socket.outputStream
                        socket.setFileDescriptorsForSend(arrayOf(owner.descriptor.fileDescriptor))
                        // SCM_RIGHTS отправляется write, не setter'ом. После всех
                        // синхронных подготовительных вызовов проверяем владельца
                        // и token ещё раз; I/O не выполняется под state-мониторами.
                        coroutineContext.ensureActive()
                        if (!isFdDeliveryCurrent(delivery)) return@launch
                        output.write(1)
                        output.flush()
                        socket.soTimeout = 3_000
                        if (socket.inputStream.read() != 1) {
                            throw IllegalStateException("Rust-клиент не подтвердил TUN-интерфейс")
                        }
                        coroutineContext.ensureActive()
                        val acknowledged = synchronized(interfaceLock) {
                            isFdDeliveryCurrent(delivery) && TunnelManager.commitVpnStartIfCurrent(start) {
                                recoveryAttempts = 0
                            }
                        }
                        if (!acknowledged) return@launch
                        success = true
                        Log.d(TAG, "Sent TUN fd to Rust client successfully")
                        if (isRoutingReload) TunnelManager.onRoutingUpdated(start, routesRebuilt)
                        else TunnelManager.onVpnInterfaceReady(start, dns, routesRebuilt)
                        break
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        coroutineContext.ensureActive()
                        Log.d(TAG, "Failed to connect to Rust client UDS, retrying: ${e.message}")
                    } finally {
                        synchronized(interfaceLock) {
                            if (delivery.socket === socket) delivery.socket = null
                        }
                        runCatching { socket.close() }
                    }
                    delay(500)
                }
            } finally {
                // Retired FD закрывается и при отмене/retry/устаревшем token.
                // Его cleanup принадлежит owner, а не ветке успешного ACK.
                val retired = owner.finishDelivery()
                runCatching { retired?.close() }
            }
            if (!success && isFdDeliveryCurrent(delivery)) {
                // Sibling, не child sender'а: cancel/join никогда не ждёт задачу,
                // которой для cleanup/recovery понадобится vpnMutex.
                serviceScope.launch { handleFdDeliveryFailure(owner, start, dns) }
            }
        }
        delivery.job = job
        val accepted = synchronized(interfaceLock) {
            !stopRequested && !serviceDestroyed && vpnInterface === owner && owner.start === start && fdDelivery == null &&
                TunnelManager.commitVpnStartIfCurrent(start) { fdDelivery = delivery }
        }
        job.invokeOnCompletion {
            synchronized(interfaceLock) { if (fdDelivery === delivery) fdDelivery = null }
        }
        if (accepted) job.start() else job.cancel()
    }

    private fun isFdDeliveryCurrent(delivery: FdDelivery): Boolean = synchronized(interfaceLock) {
        fdDelivery === delivery && !delivery.cancelled && vpnInterface === delivery.owner && delivery.owner.start === delivery.start &&
            !stopRequested && !serviceDestroyed && TunnelManager.isVpnStartCurrent(delivery.start)
    }

    /** Отмена не равна завершению I/O: сохраняем job до его completion, чтобы START мог join. */
    private fun cancelFdDelivery(): Job? {
        val cancelled = synchronized(interfaceLock) {
            fdDelivery?.let {
                it.cancelled = true
                it.job to it.socket
            }
        } ?: return null
        cancelled.first.cancel()
        runCatching { cancelled.second?.close() }
        return cancelled.first
    }

    private fun ownsInterface(owner: VpnInterface, start: RoutingDeferredReload.VpnStart): Boolean = synchronized(interfaceLock) {
        vpnInterface === owner && owner.start === start && !stopRequested && !serviceDestroyed && TunnelManager.isVpnStartCurrent(start)
    }

    private suspend fun handleFdDeliveryFailure(owner: VpnInterface, start: RoutingDeferredReload.VpnStart, dns: String?) {
        if (!ownsInterface(owner, start)) return
        if (!VpnLifecyclePolicy.shouldReestablishVpn(TunnelManager.running.value)) {
            vpnMutex.withLock {
                if (!ownsInterface(owner, start)) return
                Log.e(TAG, "Could not send TUN fd to Rust client: tunnel is not running, closing interface")
                closeVpnInterface(
                    logKey = "vpn_fd_delivery_tunnel_dead",
                    logMessage = "[TUN] VPN-интерфейс закрыт: туннель остановлен, Rust-клиент не принял TUN fd",
                )
            }
            return
        }
        Log.e(TAG, "Could not send TUN fd to Rust client after $FD_DELIVERY_MAX_ATTEMPTS retries")
        if (!dns.isNullOrBlank()) {
            TunnelManager.updateLog(
                "vpn_dns_delivery_error_$dns",
                "[SERVER] DNS не применён: ${dnsProfileName(dns)} — Rust-клиент не принял TUN-интерфейс",
                99,
                true,
            )
        }
        recoverAfterFdFailure(owner, start)
    }

    private suspend fun recoverAfterFdFailure(owner: VpnInterface, start: RoutingDeferredReload.VpnStart) {
        var rateLimited = false
        var backoffMs = 0L
        val stopped = vpnMutex.withLock {
            synchronized(interfaceLock) {
                if (!ownsInterface(owner, start)) null else {
                    if (TunnelManager.commitVpnStartIfCurrent(start) {
                        vpnInterface = null
                        tunFd = -1
                        rateLimited = recoveryAttempts >= 3
                        if (rateLimited) backoffMs = 2000L else {
                            recoveryAttempts++
                            backoffMs = 500L * recoveryAttempts
                        }
                    }) owner else null
                }
            }
        } ?: return
        runCatching { stopped.retire()?.close() }
        val plan = stopped.appliedPlan
        TunnelManager.onVpnInterfaceStopped(start)
        if (!VpnLifecyclePolicy.shouldReestablishVpn(TunnelManager.running.value)) {
            TunnelManager.updateLog(
                "vpn_interface_closed_tunnel_dead",
                "[TUN] VPN-интерфейс закрыт: туннель не запущен, восстанавливать нечего",
                98,
                true,
            )
            return
        }
        if (rateLimited) {
            TunnelManager.onVpnRecoverableFailure(
                start,
                "не удалось передать TUN fd Rust-клиенту после повторных попыток",
                VpnFailureKind.TunFdDeliveryFailed,
            )
        }
        delay(backoffMs)
        if (rateLimited) synchronized(interfaceLock) {
            if (!stopRequested && !serviceDestroyed) TunnelManager.commitVpnStartIfCurrent(start) { recoveryAttempts = 0 }
        }
        if (!stopRequested && !serviceDestroyed && TunnelManager.isVpnStartCurrent(start)) {
            startVpn(
                plan.clientAddress.substringBefore('/'), plan.dnsServers.joinToString(","),
                forceRebuild = true, connection = start.connection, reason = "fd_delivery_failed", mtu = plan.mtu, expectedStart = start,
            )
        }
    }

    private fun failVpn(message: String, start: RoutingDeferredReload.VpnStart) {
        if (!TunnelManager.isVpnStartCurrent(start)) return
        stopRequested = true
        stopVpn()
        releaseLocks()
        TunnelManager.onVpnTerminalFailure(start, message, VpnFailureKind.TunEstablishFailed)
    }

    private fun stopVpn() {
        closeVpnInterface(
            logKey = "vpn_stop",
            logMessage = "[TUN] VPN-интерфейс закрыт вызовом stopVpn()",
        )
    }

    /** Снимает owner сразу; закрывает FD после выхода отменённого синхронного sender. */
    private fun closeVpnInterface(logKey: String, logMessage: String) {
        cancelFdDelivery()
        val stopped = synchronized(interfaceLock) {
            vpnInterface.also {
                vpnInterface = null
                tunFd = -1
            }
        }
        try {
            stopped?.retire()?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing VPN interface: ${e.message}")
        }
        stopped?.let { TunnelManager.onVpnInterfaceStopped(it.start) }
        TunnelManager.updateLog(logKey, logMessage, 22)
        Log.d(TAG, "VPN interface closed")
    }

    private fun isPackageInstalled(packageName: String): Boolean {
        return try {
            packageManager.getPackageInfo(packageName, 0)
            true
        } catch (_: Exception) {
            false
        }
    }

    fun refreshUnderlyingNetworks() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
            runCatching { setUnderlyingNetworks(null) }
        }
    }

    override fun onDestroy() {
        val unexpected = !stopRequested && TunnelManager.running.value
        val start = activeVpnStart
        serviceDestroyed = true
        serviceJob.cancel()
        stopVpn()
        releaseLocks()
        instance = null
        if (unexpected && start != null) {
            TunnelManager.onVpnRecoverableFailure(
                start,
                "VPN-служба была остановлена Android",
                VpnFailureKind.ServiceDestroyed,
            )
        }
        super.onDestroy()
    }

    override fun onRevoke() {
        if (serviceDestroyed) return
        stopRequested = true
        serviceDestroyed = true
        serviceJob.cancel()
        stopVpn()
        releaseLocks()
        instance = null
        TunnelManager.onVpnTerminalFailure(
            "разрешение Android VPN было отозвано",
            VpnFailureKind.PermissionRevoked,
        )
        stopSelf()
    }
}
