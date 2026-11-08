package com.csqtt.client

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.LocalSocket
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.FileDescriptor
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.mockito.Mockito
import sun.misc.Unsafe

@OptIn(ExperimentalCoroutinesApi::class)
class RoutingManagerRegressionTest {
    private val dir = Files.createTempDirectory("routing-manager-regression").toFile()
    private val originalFields = linkedMapOf<String, Any?>()
    private lateinit var originalScope: CoroutineScope
    private var originalRule: ServerRoutingRule? = null
    private var originalReady = false
    private var originalRoutingActive = false
    private var originalConfig: String? = null
    private var originalStats = ""
    private var originalWorkers = 0
    private var originalAssignedWorkers: Int? = null
    private var originalRunning = false
    private val originalRecoveryFields = linkedMapOf<String, Any?>()
    private val mainDispatcher = StandardTestDispatcher()
    private var originalLogs = emptyList<LogEntry>()
    private var originalUnreadErrors = 0
    private var originalDiagnostic = ""

    private fun field(name: String) = TunnelManager::class.java.getDeclaredField(name).apply {
        isAccessible = true
    }

    private fun invoke(name: String, vararg args: Any?): Any? = TunnelManager::class.java
        .declaredMethods.single { it.name == name && it.parameterCount == args.size }
        .apply { isAccessible = true }
        .invoke(TunnelManager, *args)

    private fun pending() = field("pendingRoutingReload").get(null) as RoutingDeferredReload

    @Before fun setUp() {
        Dispatchers.setMain(mainDispatcher)
        for (name in listOf("process", "processIdentity", "processGeneration", "nativeProcessPid", "strongAppContext", "lastContext", "routingTerminal", "isLoggingEnabled", "lastTunLossMs", "lastVpnStartAttemptMs", "wrapAuthTimeoutCount", "lastReportedDroppedProtocol", "workerRecoveryJob")) {
            originalFields[name] = field(name).get(null)
        }
        val recovery = field("workerRecoveryPolicy").get(null) as WorkerRecoveryPolicy
        for (name in listOf("peak", "armedTarget")) {
            originalRecoveryFields[name] = recovery.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(recovery)
        }
        recovery.reset()
        field("workerRecoveryJob").set(null, null)
        originalScope = TunnelManager.activeScope
        originalRule = TunnelManager.activeServerRoutingRule.value
        originalReady = TunnelManager.vpnReady.value
        originalRoutingActive = TunnelManager.serverRoutingActive.value
        originalConfig = TunnelManager.config.value
        originalStats = TunnelManager.stats.value
        originalWorkers = TunnelManager.activeWorkers.value
        originalAssignedWorkers = TunnelManager.serverAssignedWorkers.value
        originalRunning = TunnelManager.running.value
        originalLogs = TunnelManager.logs.toList()
        originalUnreadErrors = TunnelManager.unreadErrorCount.value
        originalDiagnostic = TunnelManager.lastTunnelDiagnostic.value
        TunnelManager.activeScope = CoroutineScope(Job().apply { cancel() })
        field("isLoggingEnabled").setBoolean(null, false)
        field("strongAppContext").set(null, null)
        field("lastContext").set(null, null)
        field("lastTunLossMs").setLong(null, 0L)
        field("lastVpnStartAttemptMs").setLong(null, 0L)
        pending().clear()
    }

    @After fun tearDown() {
        mainDispatcher.scheduler.advanceUntilIdle()
        pending().clear()
        (field("lifecycleState").get(null) as TunnelLifecycleState).requestStop()
        originalFields.forEach { (name, value) -> field(name).set(null, value) }
        val recovery = field("workerRecoveryPolicy").get(null)
        originalRecoveryFields.forEach { (name, value) ->
            recovery.javaClass.getDeclaredField(name).apply { isAccessible = true }.set(recovery, value)
        }
        TunnelManager.activeScope = originalScope
        TunnelManager.activeServerRoutingRule.value = originalRule
        TunnelManager.vpnReady.value = originalReady
        TunnelManager.serverRoutingActive.value = originalRoutingActive
        TunnelManager.config.value = originalConfig
        TunnelManager.stats.value = originalStats
        TunnelManager.activeWorkers.value = originalWorkers
        TunnelManager.serverAssignedWorkers.value = originalAssignedWorkers
        TunnelManager.running.value = originalRunning
        TunnelManager.logs.clear()
        TunnelManager.logs.addAll(originalLogs)
        TunnelManager.unreadErrorCount.value = originalUnreadErrors
        TunnelManager.lastTunnelDiagnostic.value = originalDiagnostic
        Dispatchers.resetMain()
        dir.deleteRecursively()
    }

    private fun attachProcess(output: OutputStream = ByteArrayOutputStream()): Any {
        val lifecycle = field("lifecycleState").get(null) as TunnelLifecycleState
        val process = Mockito.mock(Process::class.java)
        Mockito.`when`(process.isAlive).thenReturn(true)
        Mockito.`when`(process.outputStream).thenReturn(output)
        return synchronized(pending()) {
            val epoch = lifecycle.requestStart()
            val ticket = requireNotNull(lifecycle.reserveProcess(epoch, processIsNull = true))
            // The same publication transition used by startProcessLocked, not a mirror.
            requireNotNull(invoke("attachProcessIdentity", process, ticket))
        }
    }

    private fun startSnapshot() = requireNotNull(
        TunnelManager.routingRuleSnapshot(requireNotNull(TunnelManager.routingConnectionFor())),
    )

    private fun rule(packageName: String) = ServerRoutingRule(
        isWhite = false,
        packages = listOf(packageName),
        domains = emptyList(),
        ipIsWhite = false,
        ips = emptyList(),
    )

    @Test fun `old ready callback cannot consume a new connection reload`() {
        attachProcess()
        val oldStart = startSnapshot().start
        val oldCallback = { TunnelManager.onVpnInterfaceReady(oldStart) }
        attachProcess()
        val start = startSnapshot().start
        pending().request(start.connection, "routing_changed")

        oldCallback()

        assertFalse(TunnelManager.vpnReady.value)
        assertEquals("routing_changed", pending().markReady(start)?.reloadReason)
    }

    @Test fun `old stopped callback cannot erase a new connection reload`() {
        attachProcess()
        val oldStart = startSnapshot().start
        val oldCallback = { TunnelManager.onVpnInterfaceStopped(oldStart) }
        attachProcess()
        val start = startSnapshot().start
        pending().request(start.connection, "routing_changed")

        oldCallback()

        assertEquals("routing_changed", pending().markReady(start)?.reloadReason)
    }

    @Test fun `old failure callbacks cannot clear the new connection debt`() {
        attachProcess()
        val oldStart = startSnapshot().start
        attachProcess()
        val start = startSnapshot().start
        pending().request(start.connection, "routing_changed")

        TunnelManager.onVpnRecoverableFailure(oldStart, "stale service", VpnFailureKind.ServiceDestroyed)
        TunnelManager.onVpnTerminalFailure(oldStart, "stale establish", VpnFailureKind.TunEstablishFailed)

        assertFalse(field("routingTerminal").getBoolean(null))
        assertFalse(TunnelManager.vpnReady.value)
        assertEquals("routing_changed", pending().markReady(start)?.reloadReason)
    }

    @Test fun `old fd callback cannot consume debt from a newer rebuild of the same connection`() {
        attachProcess()
        val oldStart = startSnapshot().start
        TunnelManager.onVpnInterfaceReady(oldStart)
        val start = startSnapshot().start
        pending().request(start.connection, "routing_cleared")

        TunnelManager.onVpnInterfaceReady(oldStart)
        TunnelManager.onVpnInterfaceStopped(oldStart)

        assertFalse(TunnelManager.vpnReady.value)
        assertEquals("routing_cleared", pending().markReady(start)?.reloadReason)
    }

    @Test fun `process detach clears the actual helper and rejects late ready`() {
        attachProcess()
        val start = startSnapshot().start
        pending().request(start.connection, "routing_changed")
        invoke("detachProcessIdentity")

        TunnelManager.onVpnInterfaceReady(start)

        assertNull(pending().currentConnection())
        assertNull(pending().currentStart())
        assertFalse(TunnelManager.vpnReady.value)
        attachProcess()
        val nextStart = startSnapshot().start
        assertEquals(RoutingDeferredReload.Ready(null), pending().markReady(nextStart))
    }

    /// Забитый stdin старого процесса не имеет права удерживать общий монитор:
    /// иначе stopLocked не успевает снять VPN, а новые процессы и обработка
    /// логов ждут остановившуюся запись.
    @Test fun `blocked stdin of an old process cannot hold the routing monitor`() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val blocked = object : OutputStream() {
            private fun hold() {
                entered.countDown()
                release.await(15, TimeUnit.SECONDS)
            }

            override fun write(b: Int) = hold()
            override fun write(b: ByteArray, off: Int, len: Int) = hold()
        }
        val failures = AtomicReference<Throwable?>(null)
        val oldIdentity = attachProcess(blocked)
        val oldApply = Thread {
            try {
                invoke(
                    "applyServerRoutingRule",
                    rule("com.example.blocked"),
                    "10.0.0.2",
                    "1.1.1.1",
                    oldIdentity,
                )
            } catch (error: Throwable) {
                failures.set(error)
            }
        }
        oldApply.start()
        assertTrue("apply обязан упереться в stdin", entered.await(5, TimeUnit.SECONDS))

        val detach = Thread { invoke("detachProcessIdentity") }
        detach.start()
        detach.join(2_000)
        assertFalse("detach не должен ждать забитый stdin", detach.isAlive)

        val newIdentity = attachProcess()
        val newApply = Thread {
            try {
                invoke(
                    "applyServerRoutingRule",
                    rule("com.example.new"),
                    "10.0.0.2",
                    "1.1.1.1",
                    newIdentity,
                )
            } catch (error: Throwable) {
                failures.set(error)
            }
        }
        newApply.start()
        newApply.join(2_000)
        assertFalse("новый процесс не должен ждать I/O старого", newApply.isAlive)

        release.countDown()
        oldApply.join(5_000)
        assertFalse(oldApply.isAlive)
        assertNull(failures.get())
    }

    @Test fun `startup rule changes reload the latest rule exactly once through the actual manager`() {
        attachProcess()
        val context = Mockito.mock(Context::class.java)
        Mockito.`when`(context.filesDir).thenReturn(dir)
        field("strongAppContext").set(null, context)
        TunnelManager.config.value = "TUNCONF:10.0.0.2:1.1.1.1"
        TunnelManager.activeServerRoutingRule.value = rule("com.example.initial")
        val snapshot = startSnapshot()

        Mockito.mockConstruction(Intent::class.java).use { intents ->
            val identity = field("processIdentity").get(null)
            assertEquals(RoutingApplyResult.Applied, invoke("applyServerRoutingRule", null, "10.0.0.2", "1.1.1.1", identity))
            assertEquals(RoutingApplyResult.Applied, invoke("applyServerRoutingRule", rule("com.example.changed"), "10.0.0.2", "1.1.1.1", identity))
            assertEquals(RoutingApplyResult.Applied, invoke("applyServerRoutingRule", null, "10.0.0.2", "1.1.1.1", identity))
            assertTrue(intents.constructed().isEmpty())

            TunnelManager.onVpnInterfaceReady(snapshot.start)
            TunnelManager.onVpnInterfaceReady(snapshot.start)
            TunnelManager.onRoutingUpdated(snapshot.start)

            assertEquals(1, intents.constructed().size)
            val intent = intents.constructed().single()
            Mockito.verify(intent).setAction("RELOAD_ROUTING")
            Mockito.verify(intent).putExtra("reason", "routing_cleared")
            Mockito.verify(intent).putExtra(ROUTING_CONNECTION_GENERATION, snapshot.start.connection.generation)
            val reloadSnapshot = startSnapshot()
            assertNull(reloadSnapshot.rule)
            TunnelManager.onRoutingUpdated(reloadSnapshot.start)
            Mockito.verify(context, Mockito.times(1)).startService(Mockito.any(Intent::class.java))
            assertTrue(TunnelManager.vpnReady.value)
        }
    }

    @Test fun `ready before rule changes sends once and queued changes use the latest snapshot`() {
        attachProcess()
        val context = Mockito.mock(Context::class.java)
        Mockito.`when`(context.filesDir).thenReturn(dir)
        field("strongAppContext").set(null, context)
        TunnelManager.config.value = "TUNCONF:10.0.0.2:1.1.1.1"
        TunnelManager.activeServerRoutingRule.value = rule("com.example.initial")
        val snapshot = startSnapshot()
        TunnelManager.onVpnInterfaceReady(snapshot.start)

        Mockito.mockConstruction(Intent::class.java).use { intents ->
            val identity = field("processIdentity").get(null)
            invoke("applyServerRoutingRule", rule("com.example.second"), "10.0.0.2", "1.1.1.1", identity)
            val latestRule = rule("com.example.latest")
            invoke("applyServerRoutingRule", latestRule, "10.0.0.2", "1.1.1.1", identity)

            assertEquals(1, intents.constructed().size)
            val reloadSnapshot = startSnapshot()
            assertEquals(latestRule, reloadSnapshot.rule)
            TunnelManager.onVpnInterfaceReady(snapshot.start)
            assertFalse(TunnelManager.vpnReady.value)
            TunnelManager.onRoutingUpdated(reloadSnapshot.start)
            Mockito.verify(context, Mockito.times(1)).startService(Mockito.any(Intent::class.java))
            assertTrue(TunnelManager.vpnReady.value)
        }
    }

    @Test fun `retained interface reuse does not forget a pre startup routing change`() {
        attachProcess()
        val context = Mockito.mock(Context::class.java)
        Mockito.`when`(context.filesDir).thenReturn(dir)
        field("strongAppContext").set(null, context)
        TunnelManager.config.value = "TUNCONF:10.0.0.2:1.1.1.1"
        TunnelManager.activeServerRoutingRule.value = rule("com.example.retained")
        val identity = field("processIdentity").get(null)
        invoke("applyServerRoutingRule", rule("com.example.latest"), "10.0.0.2", "1.1.1.1", identity)
        val snapshot = startSnapshot()
        // A snapshot alone does not apply the rule when the service reuses an old FD.
        // The service now verifies AppliedPlan; this also protects compatibility
        // callbacks that cannot prove the snapshot was applied (routesRebuilt=false).

        Mockito.mockConstruction(Intent::class.java).use { intents ->
            TunnelManager.onVpnInterfaceReady(snapshot.start, routesRebuilt = false)
            assertEquals(1, intents.constructed().size)
            Mockito.verify(intents.constructed().single()).putExtra("reason", "routing_changed")
            TunnelManager.onVpnInterfaceReady(snapshot.start, routesRebuilt = false)
            val rebuiltSnapshot = startSnapshot()
            TunnelManager.onRoutingUpdated(rebuiltSnapshot.start)
            assertEquals(1, intents.constructed().size)
        }
    }

    @Test fun `two retained fd starts before ack cannot lose the manager routing debt`() {
        attachProcess()
        val context = Mockito.mock(Context::class.java)
        Mockito.`when`(context.filesDir).thenReturn(dir)
        field("strongAppContext").set(null, context)
        TunnelManager.config.value = "TUNCONF:10.0.0.2:1.1.1.1"
        TunnelManager.activeServerRoutingRule.value = rule("com.example.retained")
        startSnapshot() // The descriptor was built for this earlier snapshot.
        val identity = field("processIdentity").get(null)
        assertEquals(RoutingApplyResult.Applied, invoke("applyServerRoutingRule", rule("com.example.latest"), "10.0.0.2", "1.1.1.1", identity))
        val firstStart = startSnapshot().start
        val latestStart = startSnapshot().start

        Mockito.mockConstruction(Intent::class.java).use { intents ->
            TunnelManager.onVpnInterfaceReady(firstStart, routesRebuilt = false)
            assertFalse(TunnelManager.vpnReady.value)
            TunnelManager.onVpnInterfaceReady(latestStart, routesRebuilt = false)
            TunnelManager.onVpnInterfaceReady(firstStart, routesRebuilt = false)
            TunnelManager.onVpnInterfaceReady(latestStart, routesRebuilt = false)

            assertEquals(1, intents.constructed().size)
            Mockito.verify(intents.constructed().single()).setAction("RELOAD_ROUTING")
            Mockito.verify(intents.constructed().single()).putExtra("reason", "routing_changed")
        }
    }

    @Test fun `reconnect rebuilds the retained descriptor when desired apps changed before detach`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.retained")
        TunnelManager.config.value = "TUNCONF:10.0.0.2:1.1.1.1"
        withVpnBoundary { vpn ->
            vpn.start()
            val retained = vpn.descriptor()
            val oldStart = requireNotNull(pending().currentStart())
            val latestRule = rule("com.example.latest")
            assertEquals(RoutingApplyResult.Applied, invoke("applyServerRoutingRule", latestRule, "10.0.0.2", "1.1.1.1", field("processIdentity").get(null)))
            invoke("detachProcessIdentity")
            attachProcess()
            // Desired B survived detach, but the actual Android descriptor still applies A.
            assertEquals(RoutingApplyResult.Applied, invoke("applyServerRoutingRule", latestRule, "10.0.0.2", "1.1.1.1", field("processIdentity").get(null)))

            vpn.start()

            assertNotSame("connection debt is not proof of descriptor compatibility", retained, vpn.descriptor())
            Mockito.verify(vpn.builders.last()).addDisallowedApplication("com.example.latest")
            TunnelManager.onVpnInterfaceReady(oldStart)
            assertFalse(TunnelManager.vpnReady.value)
            mainDispatcher.scheduler.runCurrent() // ACK from the actual service delivery path.
            assertTrue(TunnelManager.vpnReady.value)
            assertEquals(latestRule, TunnelManager.activeServerRoutingRule.value)
        }
    }

    @Test fun `superseding service starts reuse only the descriptor built for the latest apps`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.retained")
        withVpnBoundary { vpn ->
            vpn.start()
            val retained = vpn.descriptor()
            invoke("applyServerRoutingRule", rule("com.example.latest"), "10.0.0.2", "1.1.1.1", field("processIdentity").get(null))
            vpn.start()
            val rebuilt = vpn.descriptor()
            val firstStart = requireNotNull(pending().currentStart())
            vpn.start()

            assertNotSame(retained, rebuilt)
            assertSame(rebuilt, vpn.descriptor())
            assertEquals(2, vpn.establishedDescriptors.size)
            TunnelManager.onVpnInterfaceReady(firstStart)
            assertFalse(TunnelManager.vpnReady.value)
            mainDispatcher.scheduler.runCurrent()
            assertTrue(TunnelManager.vpnReady.value)
        }
    }

    @Test fun `retained descriptor cannot ignore changed local app additions under the same rule`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        withVpnBoundary { vpn ->
            vpn.start()
            val retained = vpn.descriptor()
            vpn.localBlack = "com.example.local"

            vpn.start()

            assertNotSame(retained, vpn.descriptor())
            Mockito.verify(vpn.builders.last()).addDisallowedApplication("com.example.local")
        }
    }

    @Test fun `retained descriptor cannot ignore changed manual Android exclude routes`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server").copy(ips = listOf("192.0.2.0/24"))
        withVpnBoundary { vpn ->
            vpn.start()
            Mockito.verify(vpn.builders.single()).excludeRoute(Mockito.any(IpPrefix::class.java))
            val retained = vpn.descriptor()
            TunnelManager.activeServerRoutingRule.value = rule("com.example.server").copy(ips = listOf("198.51.100.0/24"))

            vpn.start()

            assertNotSame(retained, vpn.descriptor())
        }
    }

    @Test fun `retained descriptor cannot ignore a changed mtu`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        withVpnBoundary { vpn ->
            vpn.start(mtu = 1280)
            val retained = vpn.descriptor()

            vpn.start(mtu = 1400)

            assertNotSame(retained, vpn.descriptor())
            Mockito.verify(vpn.builders.last()).setMtu(1400)
        }
    }

    @Test fun `domain only rule changes reuse the unchanged descriptor Android plan`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server").copy(domains = listOf("old.example"))
        withVpnBoundary { vpn ->
            vpn.start()
            val retained = vpn.descriptor()
            invoke("applyServerRoutingRule", rule("com.example.server").copy(domains = listOf("new.example")), "10.0.0.2", "1.1.1.1", field("processIdentity").get(null))

            vpn.start()

            assertSame(retained, vpn.descriptor())
            assertEquals(1, vpn.establishedDescriptors.size)
            assertEquals(listOf("new.example"), TunnelManager.activeServerRoutingRule.value?.domains)
        }
    }

    @Test fun `changing app filter mode rebuilds even with the same packages and endpoints`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server").copy(isWhite = true)
        withVpnBoundary { vpn ->
            vpn.start()
            val retained = vpn.descriptor()
            Mockito.verify(vpn.builders.single()).addAllowedApplication("com.example.server")
            TunnelManager.activeServerRoutingRule.value = rule("com.example.server")

            vpn.start()

            assertNotSame(retained, vpn.descriptor())
            Mockito.verify(vpn.builders.last()).addDisallowedApplication("com.example.server")
            Mockito.verify(vpn.builders.last()).addDisallowedApplication("com.csqtt.client")
        }
    }

    @Test fun `changed orange selection rebuilds the descriptor actual app filter`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server").copy(presetOrange = listOf("com.example.orange"))
        withVpnBoundary { vpn ->
            vpn.start()
            val retained = vpn.descriptor()
            Mockito.verify(vpn.builders.single()).addDisallowedApplication("com.example.orange")
            vpn.orangeEnabled = "com.example.orange"

            vpn.start()

            assertNotSame(retained, vpn.descriptor())
            Mockito.verify(vpn.builders.last(), Mockito.never()).addDisallowedApplication("com.example.orange")
        }
    }

    @Test fun `installing the invisible whitelist package rebuilds the substituted descriptor`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server").copy(isWhite = true)
        withVpnBoundary { vpn ->
            vpn.uninstalled = setOf("com.example.server")
            vpn.start()
            val retained = vpn.descriptor()
            Mockito.verify(vpn.builders.single()).addDisallowedApplication("com.csqtt.client")
            vpn.uninstalled = emptySet()

            vpn.start()

            assertNotSame(retained, vpn.descriptor())
            Mockito.verify(vpn.builders.last()).addAllowedApplication("com.example.server")
        }
    }

    @Test fun `canonical ordered dns avoids rebuild for whitespace and duplicates`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        withVpnBoundary { vpn ->
            vpn.start(dns = " 1.1.1.1 ,9.9.9.9,1.1.1.1")
            val retained = vpn.descriptor()

            vpn.start(dns = "1.1.1.1,9.9.9.9")

            assertSame(retained, vpn.descriptor())
            assertEquals(1, vpn.establishedDescriptors.size)
        }
    }

    @Test fun `dns order remains part of descriptor compatibility`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        withVpnBoundary { vpn ->
            vpn.start(dns = "1.1.1.1,9.9.9.9")
            val retained = vpn.descriptor()

            vpn.start(dns = "9.9.9.9,1.1.1.1")

            assertNotSame(retained, vpn.descriptor())
        }
    }

    @Test fun `fallback dns and explicit equivalent dns share the same Android plan`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        withVpnBoundary { vpn ->
            vpn.start(dns = "")
            val retained = vpn.descriptor()
            Mockito.verify(vpn.builders.single()).addDnsServer("77.88.8.8")

            vpn.start(dns = "77.88.8.8")

            assertSame(retained, vpn.descriptor())
            assertEquals(1, vpn.establishedDescriptors.size)
        }
    }

    @Test fun `dns host route overriding an exclude does not leave false rebuild debt`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.config.value = "TUNCONF:10.0.0.2:1.1.1.1"
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server").copy(ips = listOf("1.1.1.1/32"))
        withVpnBoundary { vpn ->
            vpn.start()
            val retained = vpn.descriptor()
            Mockito.verify(vpn.builders.single()).excludeRoute(Mockito.any(IpPrefix::class.java))
            Mockito.verify(vpn.builders.single()).addRoute("1.1.1.1", 32)
            Mockito.mockConstruction(Intent::class.java).use { intents ->
                invoke("applyServerRoutingRule", rule("com.example.server"), "10.0.0.2", "1.1.1.1", field("processIdentity").get(null))

                vpn.start()
                mainDispatcher.scheduler.runCurrent()

                assertSame(retained, vpn.descriptor())
                assertTrue("the final Android route map was unchanged", intents.constructed().isEmpty())
                assertTrue(TunnelManager.vpnReady.value)
            }
        }
    }

    @Test fun `canonical excluded prefix ignores host bits without leaving false rebuild debt`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.config.value = "TUNCONF:10.0.0.2:1.1.1.1"
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server").copy(ips = listOf("192.0.2.7/24"))
        withVpnBoundary { vpn ->
            vpn.start()
            val retained = vpn.descriptor()
            Mockito.mockConstruction(Intent::class.java).use { intents ->
                invoke("applyServerRoutingRule", rule("com.example.server").copy(ips = listOf("192.0.2.0/24")), "10.0.0.2", "1.1.1.1", field("processIdentity").get(null))

                vpn.start()
                mainDispatcher.scheduler.runCurrent()

                assertSame(retained, vpn.descriptor())
                assertTrue(intents.constructed().isEmpty())
            }
        }
    }

    @Test fun `dns host route does not erase a wider excluded network`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server").copy(ips = listOf("1.1.1.0/24"))
        withVpnBoundary { vpn ->
            vpn.start()
            val retained = vpn.descriptor()
            TunnelManager.activeServerRoutingRule.value = rule("com.example.server")

            vpn.start()

            assertNotSame(retained, vpn.descriptor())
        }
    }

    @Test fun `failed allow addition leaves an incomplete descriptor that cannot be reused`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server").copy(isWhite = true, packages = listOf("com.example.server", "com.example.extra"))
        withVpnBoundary { vpn ->
            vpn.failAllowed = setOf("com.example.extra")
            vpn.start()
            val retained = vpn.descriptor()
            vpn.failAllowed = emptySet()

            vpn.start()

            assertNotSame(retained, vpn.descriptor())
            Mockito.verify(vpn.builders.last()).addAllowedApplication("com.example.extra")
        }
    }

    @Test fun `repeated failed disallow additions never prove descriptor compatibility`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        withVpnBoundary { vpn ->
            vpn.failDisallowed = setOf("com.example.server")
            vpn.start()
            val retained = vpn.descriptor()

            vpn.start()

            assertNotSame(retained, vpn.descriptor())
        }
    }

    @Test fun `failed dns route after successful dns addition forbids descriptor reuse`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        withVpnBoundary { vpn ->
            vpn.failDnsRoute = setOf("1.1.1.1")
            vpn.start(dns = "1.1.1.1,9.9.9.9")
            val retained = vpn.descriptor()
            vpn.failDnsRoute = emptySet()

            vpn.start(dns = "1.1.1.1,9.9.9.9")

            assertNotSame(retained, vpn.descriptor())
        }
    }

    @Test fun `failed exclude call forbids reuse even when dns would overwrite that prefix`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server").copy(ips = listOf("1.1.1.1/32"))
        withVpnBoundary { vpn ->
            vpn.failExcludeRoutes = true
            vpn.start()
            val retained = vpn.descriptor()

            vpn.start()

            assertNotSame(retained, vpn.descriptor())
        }
    }

    @Test fun `stale successful establish invalidates the old descriptor despite its valid fd`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        withVpnBoundary { vpn ->
            vpn.start()
            val retained = vpn.descriptor()
            vpn.onEstablish = {
                invoke("detachProcessIdentity")
                attachProcess()
                vpn.onEstablish = null
            }

            vpn.start(forceRebuild = true)

            assertTrue(retained.fileDescriptor.valid())
            assertNull("a newer establish deactivated the old interface", vpn.descriptorOrNull())
            vpn.start()
            assertNotSame(retained, vpn.descriptor())
            assertEquals(3, vpn.establishedDescriptors.size)
        }
    }

    @Test fun `superseding a rebuild delivery cannot orphan the deactivated previous descriptor`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        withVpnBoundary { vpn ->
            vpn.start()
            val previous = vpn.descriptor()
            vpn.start(forceRebuild = true)
            val current = vpn.descriptor()

            vpn.start()
            mainDispatcher.scheduler.runCurrent()

            assertSame(current, vpn.descriptor())
            Mockito.verify(previous, Mockito.times(1)).close()
            Mockito.verify(current, Mockito.never()).close()
            assertTrue(TunnelManager.vpnReady.value)
        }
    }

    @Test fun `blocked pre rights sender cannot deliver a stale descriptor after a superseding start`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        val sender = ControlledFdSender(FdBlock.BEFORE_RIGHTS)
        withVpnBoundary(sender) { vpn ->
            vpn.start()
            val previous = vpn.descriptor()
            val worker = sender.startBlockedPump()
            try {
                assertTrue("old sender reached the SCM_RIGHTS boundary", sender.blocked.await(5, TimeUnit.SECONDS))
                val replacement = launch { vpn.start(forceRebuild = true) }
                mainDispatcher.scheduler.runCurrent()
                sender.releaseAndJoin(worker)
                mainDispatcher.scheduler.runCurrent()
                assertTrue(replacement.isCompleted)
                sender.runCurrent()

                val current = vpn.descriptor()
                assertNotSame(previous, current)
                assertEquals("only the current descriptor may cross SCM_RIGHTS", listOf(current.fileDescriptor), sender.sentDescriptors.toList())
                Mockito.verify(previous, Mockito.times(1)).close()
                assertTrue(TunnelManager.vpnReady.value)
            } finally {
                sender.releaseAndJoin(worker)
            }
        }
    }

    @Test fun `superseding start awaits a blocked cancelled ack before establishing another descriptor`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        val sender = ControlledFdSender(FdBlock.ACK)
        withVpnBoundary(sender) { vpn ->
            vpn.start()
            val previous = vpn.descriptor()
            val worker = sender.startBlockedPump()
            try {
                assertTrue("old sender is blocked reading ACK", sender.blocked.await(5, TimeUnit.SECONDS))
                val replacement = launch { vpn.start(forceRebuild = true) }
                mainDispatcher.scheduler.runCurrent()

                assertFalse("cancel is not completion of synchronous socket I/O", replacement.isCompleted)
                assertEquals(1, vpn.establishedDescriptors.size)
                assertTrue("cancel closes the in-flight socket", sender.firstSocketClosed)
                Mockito.verify(previous, Mockito.never()).close()

                sender.releaseAndJoin(worker)
                mainDispatcher.scheduler.runCurrent()
                assertTrue(replacement.isCompleted)
                sender.runCurrent()
                Mockito.verify(previous, Mockito.times(1)).close()
                assertEquals(2, vpn.establishedDescriptors.size)
                assertTrue(TunnelManager.vpnReady.value)
            } finally {
                sender.releaseAndJoin(worker)
            }
        }
    }

    @Test fun `connection superseded at the pre rights boundary cannot send any stale descriptor`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        val sender = ControlledFdSender(FdBlock.BEFORE_RIGHTS)
        withVpnBoundary(sender) { vpn ->
            vpn.start()
            val worker = sender.startBlockedPump()
            try {
                assertTrue(sender.blocked.await(5, TimeUnit.SECONDS))
                invoke("detachProcessIdentity")
                attachProcess()
                sender.releaseAndJoin(worker)

                assertTrue("the obsolete token was rechecked immediately before SCM_RIGHTS", sender.sentDescriptors.isEmpty())
                assertFalse(TunnelManager.vpnReady.value)
                vpn.start()
                sender.runCurrent()
                assertEquals(listOf(vpn.descriptor().fileDescriptor), sender.sentDescriptors.toList())
                assertTrue(TunnelManager.vpnReady.value)
            } finally {
                sender.releaseAndJoin(worker)
            }
        }
    }

    @Test fun `cancelled rebuild retry cannot orphan retired fd when the next start reuses its owner`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        val sender = ControlledFdSender()
        withVpnBoundary(sender) { vpn ->
            vpn.start()
            sender.runCurrent()
            val previous = vpn.descriptor()
            sender.failedConnects.set(1)
            vpn.start(forceRebuild = true)
            val current = vpn.descriptor()
            sender.runCurrent() // Rebuilt owner's delivery is now in the retry delay.
            assertFalse(TunnelManager.vpnReady.value)

            val reuse = launch { vpn.start() }
            mainDispatcher.scheduler.runCurrent()
            sender.runCurrent() // Finish cancellation, including the sender's finally.
            mainDispatcher.scheduler.runCurrent()
            assertTrue(reuse.isCompleted)
            sender.runCurrent()

            assertSame(current, vpn.descriptor())
            assertEquals(2, vpn.establishedDescriptors.size)
            Mockito.verify(previous, Mockito.times(1)).close()
            Mockito.verify(current, Mockito.never()).close()
            assertTrue(TunnelManager.vpnReady.value)
        }
    }

    @Test fun `stopping a blocked sender retires its descriptor until synchronous delivery exits`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        val sender = ControlledFdSender(FdBlock.ACK)
        withVpnBoundary(sender) { vpn ->
            vpn.start()
            val descriptor = vpn.descriptor()
            val worker = sender.startBlockedPump()
            try {
                assertTrue(sender.blocked.await(5, TimeUnit.SECONDS))
                TunVpnService::class.java.declaredMethods.single { it.name == "stopVpn" }
                    .apply { isAccessible = true }.invoke(vpn.service)

                assertNull(vpn.descriptorOrNull())
                assertTrue("stop aborts blocked socket I/O", sender.firstSocketClosed)
                Mockito.verify(descriptor, Mockito.never()).close()
                sender.releaseAndJoin(worker)
                Mockito.verify(descriptor, Mockito.times(1)).close()
                assertFalse(TunnelManager.vpnReady.value)
            } finally {
                sender.releaseAndJoin(worker)
            }
        }
    }

    @Test fun `cancelling a waiting start cannot let the next start overtake the blocked sender`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        val sender = ControlledFdSender(FdBlock.ACK)
        withVpnBoundary(sender) { vpn ->
            vpn.start()
            val worker = sender.startBlockedPump()
            try {
                assertTrue(sender.blocked.await(5, TimeUnit.SECONDS))
                val abandoned = launch { vpn.start(forceRebuild = true) }
                mainDispatcher.scheduler.runCurrent()
                assertFalse(abandoned.isCompleted)
                abandoned.cancel()
                mainDispatcher.scheduler.runCurrent()
                val replacement = launch { vpn.start(forceRebuild = true) }
                mainDispatcher.scheduler.runCurrent()

                assertFalse("the cancelled sender remains joinable until I/O really exits", replacement.isCompleted)
                assertEquals(1, vpn.establishedDescriptors.size)
                sender.releaseAndJoin(worker)
                mainDispatcher.scheduler.runCurrent()
                assertTrue(replacement.isCompleted)
                sender.runCurrent()
                assertEquals(2, vpn.establishedDescriptors.size)
                assertTrue(TunnelManager.vpnReady.value)
            } finally {
                sender.releaseAndJoin(worker)
            }
        }
    }

    @Test fun `exhausted fd delivery reestablishes outside sender completion and preserves mtu`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        val sender = ControlledFdSender()
        sender.failedConnects.set(60)
        withVpnBoundary(sender) { vpn ->
            vpn.start(mtu = 1400)
            val failed = vpn.descriptor()

            sender.advanceUntilIdle()

            assertNotSame(failed, vpn.descriptor())
            assertEquals(2, vpn.establishedDescriptors.size)
            vpn.builders.forEach { Mockito.verify(it).setMtu(1400) }
            Mockito.verify(failed, Mockito.times(1)).close()
            assertEquals(listOf(vpn.descriptor().fileDescriptor), sender.sentDescriptors.toList())
            assertTrue(TunnelManager.vpnReady.value)
        }
    }

    @Test fun `fd recovery delayed past a newer start cannot rebuild or close that start owner`() = runTest(mainDispatcher) {
        attachProcess()
        TunnelManager.activeServerRoutingRule.value = rule("com.example.server")
        val sender = ControlledFdSender()
        sender.failedConnects.set(60)
        withVpnBoundary(sender) { vpn ->
            vpn.start()
            val failed = vpn.descriptor()
            sender.advanceBy(30_000)
            sender.runCurrent() // Exhaustion retired the failed owner; recovery is delayed.
            assertNull(vpn.descriptorOrNull())
            vpn.start(mtu = 1280)
            val current = vpn.descriptor()

            sender.advanceUntilIdle()

            assertSame(current, vpn.descriptor())
            assertEquals(2, vpn.establishedDescriptors.size)
            Mockito.verify(failed, Mockito.times(1)).close()
            Mockito.verify(current, Mockito.never()).close()
            assertTrue(TunnelManager.vpnReady.value)
        }
    }

    @Test fun `recovery snapshot from a superseded start cannot replace the current start token`() {
        attachProcess()
        val old = startSnapshot().start
        val current = startSnapshot().start

        assertNull(TunnelManager.routingRuleSnapshot(current.connection, expectedStart = old))

        assertTrue(TunnelManager.isVpnStartCurrent(current))
        assertSame(current, pending().currentStart())
    }

    private enum class FdBlock { NONE, BEFORE_RIGHTS, ACK }

    /** Only the Android socket is controlled; ownership, starts and ACK commits stay real. */
    private class ControlledFdSender(private val blockAt: FdBlock = FdBlock.NONE) {
        val dispatcher = StandardTestDispatcher(TestCoroutineScheduler())
        val blocked = CountDownLatch(1)
        private val resume = CountDownLatch(1)
        private val pauseNext = AtomicBoolean(true)
        private val workerFailure = AtomicReference<Throwable?>()
        private val closedSockets = CopyOnWriteArrayList<AtomicBoolean>()
        val sentDescriptors = CopyOnWriteArrayList<FileDescriptor>()
        val failedConnects = AtomicInteger()
        val firstSocketClosed: Boolean get() = closedSockets.first().get()

        private fun pause(point: FdBlock) {
            if (blockAt == point && pauseNext.compareAndSet(true, false)) {
                blocked.countDown()
                check(resume.await(5, TimeUnit.SECONDS)) { "controllable sender was not released" }
            }
        }

        fun runCurrent() = drive { dispatcher.scheduler.runCurrent() }
        fun advanceUntilIdle() = drive { dispatcher.scheduler.advanceUntilIdle() }
        fun advanceBy(millis: Long) = drive { dispatcher.scheduler.advanceTimeBy(millis) }

        private fun drive(pump: () -> Unit) {
            Mockito.mockConstruction(LocalSocket::class.java) { socket, _ ->
                val closed = AtomicBoolean()
                val descriptor = AtomicReference<FileDescriptor?>()
                closedSockets += closed
                Mockito.doAnswer { closed.set(true); null }.`when`(socket).close()
                Mockito.doAnswer { call ->
                    val descriptors = call.getArgument<Array<FileDescriptor>>(0)
                    check(descriptors.size == 1)
                    descriptor.set(descriptors.single())
                    null
                }.`when`(socket).setFileDescriptorsForSend(Mockito.any<Array<FileDescriptor>>())
                Mockito.doAnswer {
                    if (failedConnects.getAndUpdate { if (it > 0) it - 1 else 0 } > 0) throw IOException("injected UDS retry")
                    null
                }.`when`(socket).connect(Mockito.any(android.net.LocalSocketAddress::class.java))
                val output = object : OutputStream() {
                    override fun write(value: Int) {
                        if (closed.get()) throw IOException("cancelled socket")
                        check(value == 1)
                        sentDescriptors += requireNotNull(descriptor.get())
                    }
                }
                Mockito.`when`(socket.outputStream).thenAnswer { pause(FdBlock.BEFORE_RIGHTS); output }
                Mockito.`when`(socket.inputStream).thenReturn(object : InputStream() {
                    override fun read(): Int {
                        pause(FdBlock.ACK)
                        if (closed.get()) throw IOException("cancelled socket")
                        return 1
                    }
                })
            }.use { pump() }
        }

        fun startBlockedPump(): Thread = Thread {
            try {
                Mockito.mockStatic(Log::class.java).use { runCurrent() }
            } catch (failure: Throwable) {
                workerFailure.set(failure)
            }
        }.apply { start() }

        fun releaseAndJoin(worker: Thread) {
            resume.countDown()
            worker.join(5_000)
            assertFalse("sender exited without holding a start/state lock", worker.isAlive)
            assertNull(workerFailure.get())
        }
    }

    private class VpnBoundary(val service: TunVpnService) {
        var localBlack = ""
        var localWhite = ""
        var isWhitelist = false
        var orangeEnabled = ""
        var uninstalled = emptySet<String>()
        var failAllowed = emptySet<String>()
        var failDisallowed = emptySet<String>()
        var failDnsRoute = emptySet<String>()
        var failExcludeRoutes = false
        var onEstablish: (() -> Unit)? = null
        val builders = mutableListOf<VpnService.Builder>()
        val establishedDescriptors = mutableListOf<ParcelFileDescriptor>()

        fun descriptorOrNull(): ParcelFileDescriptor? {
            val value = TunVpnService::class.java.getDeclaredField("vpnInterface").apply { isAccessible = true }.get(service) ?: return null
            return if (value is ParcelFileDescriptor) value else {
                value.javaClass.getDeclaredField("descriptor").apply { isAccessible = true }.get(value) as ParcelFileDescriptor
            }
        }

        fun descriptor(): ParcelFileDescriptor = requireNotNull(descriptorOrNull())

        suspend fun start(mtu: Int = CsqttConstants.Vpn.DEFAULT_MTU, dns: String = "1.1.1.1", forceRebuild: Boolean = false) {
            suspendCoroutineUninterceptedOrReturn<Unit> { continuation ->
                val result = TunVpnService::class.java.declaredMethods.single { it.name == "startVpn" }
                    .apply { isAccessible = true }
                    .invoke(service, "10.0.0.2", dns, forceRebuild, requireNotNull(TunnelManager.routingConnectionFor()), false, "regression", mtu, null, continuation)
                if (result === COROUTINE_SUSPENDED) result else Unit
            }
        }
    }

    private suspend fun withVpnBoundary(sender: ControlledFdSender? = null, block: suspend (VpnBoundary) -> Unit) {
        val context = Mockito.mock(Context::class.java)
        Mockito.`when`(context.filesDir).thenReturn(dir)
        Mockito.`when`(context.packageName).thenReturn("com.csqtt.client")
        field("strongAppContext").set(null, context)
        TunnelManager.running.value = true
        val packageManager = Mockito.mock(PackageManager::class.java)
        // Only the Android service shell is doubled; startVpn, its production
        // reuse policy, Builder argument generation and FD delivery remain real.
        val service = Mockito.mock(TunVpnService::class.java, Mockito.CALLS_REAL_METHODS)
        Mockito.doReturn(context).`when`(service).applicationContext
        Mockito.doReturn(packageManager).`when`(service).packageManager
        val scopeJob = Job()
        for ((name, value) in mapOf("interfaceLock" to Any(), "vpnMutex" to Mutex(), "serviceScope" to CoroutineScope(scopeJob + (sender?.dispatcher ?: mainDispatcher)))) {
            TunVpnService::class.java.getDeclaredField(name).apply { isAccessible = true }.set(service, value)
        }
        val vpn = VpnBoundary(service)
        Mockito.`when`(packageManager.getPackageInfo(Mockito.anyString(), Mockito.eq(0))).thenAnswer { call ->
            val packageName = call.getArgument<String>(0)
            if (packageName in vpn.uninstalled) throw Mockito.mock(PackageManager.NameNotFoundException::class.java)
            Mockito.mock(PackageInfo::class.java).apply { this.packageName = packageName }
        }
        val previousTunFd = TunVpnService.tunFd
        val sdk = Build.VERSION::class.java.getDeclaredField("SDK_INT").apply { isAccessible = true }
        val previousSdk = sdk.getInt(null)
        // The mockable android.jar exposes SDK_INT as final. This only selects
        // our Builder branch in the test JVM; no framework behavior is emulated.
        val unsafe = Unsafe::class.java.getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null) as Unsafe
        val sdkBase = unsafe.staticFieldBase(sdk)
        val sdkOffset = unsafe.staticFieldOffset(sdk)
        unsafe.putIntVolatile(sdkBase, sdkOffset, 33)
        try {
            Mockito.mockStatic(Log::class.java).use {
                Mockito.mockStatic(VpnService::class.java).use {
                    Mockito.mockConstruction(SettingsStore::class.java) { settings, _ ->
                        Mockito.`when`(settings.excludedApps).thenReturn(flow { emit(vpn.localBlack) })
                        Mockito.`when`(settings.whitelistApps).thenReturn(flow { emit(vpn.localWhite) })
                        Mockito.`when`(settings.isWhitelist).thenReturn(flow { emit(vpn.isWhitelist) })
                        Mockito.`when`(settings.orangeTunnelEnabled).thenReturn(flow { emit(vpn.orangeEnabled) })
                    }.use {
                        Mockito.mockConstruction(VpnService.Builder::class.java, Mockito.withSettings().defaultAnswer(Mockito.RETURNS_SELF)) { builder, _ ->
                            vpn.builders += builder
                            val pfd = Mockito.mock(ParcelFileDescriptor::class.java)
                            val fd = Mockito.mock(FileDescriptor::class.java)
                            Mockito.`when`(fd.valid()).thenReturn(true)
                            Mockito.`when`(pfd.fileDescriptor).thenReturn(fd)
                            Mockito.`when`(pfd.fd).thenReturn(100 + vpn.builders.size)
                            Mockito.`when`(builder.addAllowedApplication(Mockito.anyString())).thenAnswer { call ->
                                if (call.getArgument<String>(0) in vpn.failAllowed) throw IllegalArgumentException("injected allow failure")
                                builder
                            }
                            Mockito.`when`(builder.addDisallowedApplication(Mockito.anyString())).thenAnswer { call ->
                                if (call.getArgument<String>(0) in vpn.failDisallowed) throw IllegalArgumentException("injected disallow failure")
                                builder
                            }
                            Mockito.`when`(builder.addRoute(Mockito.anyString(), Mockito.eq(32))).thenAnswer { call ->
                                if (call.getArgument<String>(0) in vpn.failDnsRoute) throw IllegalArgumentException("injected DNS route failure")
                                builder
                            }
                            Mockito.`when`(builder.excludeRoute(Mockito.any(IpPrefix::class.java))).thenAnswer {
                                if (vpn.failExcludeRoutes) throw IllegalArgumentException("injected exclude failure")
                                builder
                            }
                            Mockito.`when`(builder.establish()).thenAnswer {
                                vpn.establishedDescriptors += pfd
                                vpn.onEstablish?.invoke()
                                pfd
                            }
                        }.use {
                            val socketMocks = if (sender != null) null else Mockito.mockConstruction(LocalSocket::class.java) { socket, _ ->
                                Mockito.`when`(socket.outputStream).thenReturn(ByteArrayOutputStream())
                                Mockito.`when`(socket.inputStream).thenReturn(ByteArrayInputStream(byteArrayOf(1)))
                            }
                            try {
                                Mockito.mockConstruction(IpPrefix::class.java) { prefix, construction ->
                                    Mockito.`when`(prefix.address).thenReturn(construction.arguments()[0] as java.net.InetAddress)
                                    Mockito.`when`(prefix.prefixLength).thenReturn(construction.arguments()[1] as Int)
                                }.use {
                                    try {
                                        block(vpn)
                                    } finally {
                                        scopeJob.cancel()
                                        if (sender == null) mainDispatcher.scheduler.runCurrent() else sender.runCurrent()
                                        TunVpnService::class.java.declaredMethods.single { it.name == "closeVpnInterface" }
                                            .apply { isAccessible = true }.invoke(service, "test_cleanup", "test cleanup")
                                    }
                                }
                            } finally {
                                socketMocks?.close()
                            }
                        }
                    }
                }
            }
        } finally {
            unsafe.putIntVolatile(sdkBase, sdkOffset, previousSdk)
            TunVpnService::class.java.getDeclaredField("tunFd").apply { isAccessible = true }.setInt(null, previousTunFd)
        }
    }

    @Test fun `old critical error cannot terminalize the new connection`() {
        val oldIdentity = attachProcess()
        attachProcess()
        val currentRule = rule("com.example.current")
        TunnelManager.activeServerRoutingRule.value = currentRule
        TunnelManager.serverRoutingActive.value = true

        invoke("handleCriticalError", "stale routing failure", oldIdentity)

        assertFalse(field("routingTerminal").getBoolean(null))
        assertEquals(currentRule, TunnelManager.activeServerRoutingRule.value)
        assertTrue(TunnelManager.serverRoutingActive.value)
    }

    @Test fun `stats routing validation crossing a restart cannot clear the new rule`() {
        assertStaleValidationCannotMutateNewRule(
            rule("com.example.old").copy(contentSha = "a".repeat(64), contentCached = true),
            TunnelEventParser.Event.Stats(1, 0, 0),
        )
    }

    @Test fun `tun lost routing validation crossing a restart cannot clear the new rule`() {
        assertStaleValidationCannotMutateNewRule(
            rule("com.example.old").copy(ipsSha = "b".repeat(64)),
            TunnelEventParser.Event.TunLost,
        )
    }

    @Test fun `config crossing a restart before publication preserves the current endpoints`() {
        val barrier = RestartBarrier()
        val event = Mockito.spy(TunnelEventParser.Event.Config("TUNCONF:10.0.0.2:1.1.1.1"))
        Mockito.doAnswer { barrier.pause(); "TUNCONF:10.0.0.2:1.1.1.1" }.`when`(event).config
        assertEventCrossingRestartPreservesCurrentState(event, barrier)
    }

    @Test fun `stats crossing a restart before worker publication preserves all current state`() {
        val barrier = RestartBarrier()
        val event = Mockito.spy(TunnelEventParser.Event.Stats(12, 1_048_576L, 0L, 99L))
        Mockito.doAnswer { barrier.pause(); 12 }.`when`(event).active
        assertEventCrossingRestartPreservesCurrentState(event, barrier)
    }

    @Test fun `process pid crossing a restart before publication cannot replace the current pid`() {
        val barrier = RestartBarrier()
        val event = Mockito.spy(TunnelEventParser.Event.Process(1001))
        Mockito.doAnswer { barrier.pause(); 1001 }.`when`(event).pid
        assertEventCrossingRestartPreservesCurrentState(event, barrier)
    }

    @Test fun `workers crossing a restart before dispatch cannot replace the current assignment`() {
        val barrier = RestartBarrier()
        val event = Mockito.spy(TunnelEventParser.Event.Workers(3))
        Mockito.doAnswer { barrier.pause(); 3 }.`when`(event).workers
        assertEventCrossingRestartPreservesCurrentState(event, barrier)
    }

    @Test fun `tun lost crossing a restart while reading the clock preserves current recovery state`() {
        assertEventCrossingRestartPreservesCurrentState(TunnelEventParser.Event.TunLost, RestartBarrier(), pauseClock = true)
    }

    @Test fun `old active zero continuation cannot arm recovery for the replacement process`() {
        val oldIdentity = attachProcess()
        invoke("detachProcessIdentity")
        attachProcess()
        val recovery = field("workerRecoveryPolicy").get(null) as WorkerRecoveryPolicy
        recovery.observe(10)

        invoke("scheduleWorkerZeroRecovery", oldIdentity)

        assertFalse(recovery.shouldRecover(0, 10))
        assertNull(field("workerRecoveryJob").get(null))
    }

    @Test fun `worker recovery crossing a restart at the service boundary cannot restart the new process`() {
        val oldIdentity = attachProcess()
        val context = Mockito.mock(Context::class.java)
        Mockito.`when`(context.applicationContext).thenAnswer {
            invoke("detachProcessIdentity")
            attachProcess()
            publishCurrentEventState()
            context
        }
        field("strongAppContext").set(null, context)
        TunnelManager.running.value = true
        val scopeJob = Job()
        TunnelManager.activeScope = CoroutineScope(scopeJob + mainDispatcher)
        (field("workerRecoveryPolicy").get(null) as WorkerRecoveryPolicy).observe(10)
        try {
            Mockito.mockConstruction(Intent::class.java).use { intents ->
                invoke("handleTunnelEvent", TunnelEventParser.Event.ActiveZero(), oldIdentity)
                mainDispatcher.scheduler.advanceUntilIdle()

                assertEquals("TUNCONF:10.0.0.3:9.9.9.9", TunnelManager.config.value)
                assertTrue("an obsolete recovery must not dispatch a restart", intents.constructed().isEmpty())
                Mockito.verify(context, Mockito.never()).startService(Mockito.any(Intent::class.java))
            }
        } finally {
            scopeJob.cancel()
        }
    }

    private class RestartBarrier {
        val entered = CountDownLatch(1)
        val resume = CountDownLatch(1)
        private val first = AtomicBoolean(true)

        fun pause() {
            if (first.compareAndSet(true, false)) {
                entered.countDown()
                check(resume.await(5, TimeUnit.SECONDS))
            }
        }
    }

    private fun publishCurrentEventState() {
        TunnelManager.config.value = "TUNCONF:10.0.0.3:9.9.9.9"
        TunnelManager.stats.value = "current connection stats"
        TunnelManager.activeWorkers.value = 7
        TunnelManager.serverAssignedWorkers.value = 9
        field("nativeProcessPid").set(null, 2002)
        field("wrapAuthTimeoutCount").setInt(null, 3)
        field("lastReportedDroppedProtocol").setLong(null, 20L)
        field("lastTunLossMs").setLong(null, 600_000L)
        field("lastVpnStartAttemptMs").setLong(null, 500_000L)
        TunnelManager.activeServerRoutingRule.value = rule("com.example.current")
        TunnelManager.serverRoutingActive.value = true
    }

    private fun assertCurrentEventState() {
        assertEquals("TUNCONF:10.0.0.3:9.9.9.9", TunnelManager.config.value)
        assertEquals("current connection stats", TunnelManager.stats.value)
        assertEquals(7, TunnelManager.activeWorkers.value)
        assertEquals(9, TunnelManager.serverAssignedWorkers.value)
        assertEquals(2002, field("nativeProcessPid").get(null))
        assertEquals(3, field("wrapAuthTimeoutCount").getInt(null))
        assertEquals(20L, field("lastReportedDroppedProtocol").getLong(null))
        assertEquals(600_000L, field("lastTunLossMs").getLong(null))
        assertEquals(500_000L, field("lastVpnStartAttemptMs").getLong(null))
        assertFalse(field("routingTerminal").getBoolean(null))
        assertEquals(rule("com.example.current"), TunnelManager.activeServerRoutingRule.value)
        assertTrue(TunnelManager.serverRoutingActive.value)
        assertFalse(TunnelManager.vpnReady.value)
    }

    private fun assertEventCrossingRestartPreservesCurrentState(
        event: TunnelEventParser.Event,
        barrier: RestartBarrier,
        pauseClock: Boolean = false,
    ) {
        val oldIdentity = attachProcess()
        TunnelManager.config.value = "TUNCONF:10.0.0.2:1.1.1.1"
        val error = AtomicReference<Throwable?>()
        val background = Thread {
            try {
                Mockito.mockStatic(SystemClock::class.java).use { clock ->
                    clock.`when`<Long> { SystemClock.elapsedRealtime() }.thenAnswer {
                        if (pauseClock) barrier.pause()
                        100_000L
                    }
                    invoke("handleTunnelEvent", event, oldIdentity)
                }
            } catch (failure: Throwable) {
                error.set(failure.cause ?: failure)
            }
        }
        val currentRecoveryJob = Job()
        background.start()
        try {
            assertTrue("old event reached the pre-commit boundary", barrier.entered.await(5, TimeUnit.SECONDS))
            invoke("detachProcessIdentity")
            attachProcess()
            val currentStart = startSnapshot().start
            pending().request(currentStart.connection, "current_debt")
            publishCurrentEventState()
            val recovery = field("workerRecoveryPolicy").get(null) as WorkerRecoveryPolicy
            recovery.observe(10)
            assertEquals(10, recovery.armAtZero())
            field("workerRecoveryJob").set(null, currentRecoveryJob)
            barrier.resume.countDown()
            background.join(5_000)

            assertFalse("background event completed", background.isAlive)
            assertNull(error.get())
            assertCurrentEventState()
            assertTrue("current recovery must not be cancelled by an old event", currentRecoveryJob.isActive)
            assertTrue(recovery.shouldRecover(0, 10))
            assertEquals("current_debt", pending().markReady(currentStart)?.reloadReason)
        } finally {
            barrier.resume.countDown()
            background.join(5_000)
            currentRecoveryJob.cancel()
        }
    }

    private fun assertStaleValidationCannotMutateNewRule(oldRule: ServerRoutingRule, event: TunnelEventParser.Event) {
        val oldIdentity = attachProcess()
        TunnelManager.config.value = "TUNCONF:10.0.0.2:1.1.1.1"
        TunnelManager.activeServerRoutingRule.value = oldRule
        val enteredCache = CountDownLatch(1)
        val continueCache = CountDownLatch(1)
        val firstRead = AtomicBoolean(true)
        val context = Mockito.mock(Context::class.java)
        Mockito.`when`(context.filesDir).thenAnswer {
            if (firstRead.compareAndSet(true, false)) {
                enteredCache.countDown()
                check(continueCache.await(5, TimeUnit.SECONDS))
            }
            dir
        }
        field("strongAppContext").set(null, context)
        val error = AtomicReference<Throwable?>()
        val background = Thread {
            try {
                Mockito.mockStatic(SystemClock::class.java).use { clock ->
                    clock.`when`<Long> { SystemClock.elapsedRealtime() }.thenReturn(100_000L)
                    invoke("handleTunnelEvent", event, oldIdentity)
                }
            } catch (failure: Throwable) {
                error.set(failure.cause ?: failure)
            }
        }
        background.start()
        try {
            assertTrue("old event reached cache validation", enteredCache.await(5, TimeUnit.SECONDS))
            invoke("detachProcessIdentity")
            attachProcess()
            val currentStart = startSnapshot().start
            pending().request(currentStart.connection, "current_debt")
            publishCurrentEventState()
            continueCache.countDown()
            background.join(5_000)

            assertFalse("background event completed", background.isAlive)
            assertNull(error.get())
            assertCurrentEventState()
            assertEquals("current_debt", pending().markReady(currentStart)?.reloadReason)
        } finally {
            continueCache.countDown()
            background.join(5_000)
        }
    }
}
