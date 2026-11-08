package com.csqtt.client

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TunRecoveryPolicyTest {
    @Test
    fun identicalConfigurationReusesLiveInterface() {
        assertTrue(decide())
    }

    @Test
    fun missingInterfaceRequiresRebuild() {
        assertFalse(decide(hasInterface = false))
    }

    @Test
    fun invalidDescriptorRequiresRebuild() {
        assertFalse(decide(descriptorValid = false))
    }

    @Test
    fun destroyedServiceRequiresRebuild() {
        assertFalse(decide(serviceDestroyed = true))
    }

    @Test
    fun forcedReloadRequiresRebuild() {
        assertFalse(decide(forceRebuild = true))
    }

    @Test
    fun changedAddressRequiresRebuild() {
        assertFalse(decide(requestedClientIp = "10.66.66.3"))
    }

    @Test
    fun changedDnsRequiresRebuild() {
        assertFalse(decide(requestedDns = "8.8.8.8"))
    }

    @Test
    fun absentPreviousAddressRequiresRebuild() {
        assertFalse(decide(activeClientIp = null))
    }

    @Test
    fun absentPreviousDnsRequiresRebuild() {
        assertFalse(decide(activeDns = null))
    }

    @Test
    fun incompleteOrUnknownPlansNeverAuthorizeReuse() {
        val plan = plan()
        for ((applied, requested) in listOf(
            null to plan,
            plan to null,
            plan.copy(complete = false) to plan,
            plan to plan.copy(complete = false),
            plan.copy(complete = false) to plan.copy(complete = false),
        )) {
            assertFalse(TunRecoveryPolicy.shouldReuse(true, true, false, false, applied, requested))
        }
    }

    @Test
    fun changedBuilderInputsRequireRebuildEvenWithIdenticalEndpoints() {
        val applied = plan()
        val changed = listOf(
            applied.copy(mtu = 1280),
            applied.copy(apps = TunAppliedApps(TunAppsMode.ALLOW, setOf("com.csqtt.client"))),
            applied.copy(apps = TunAppliedApps(TunAppsMode.DISALLOW, setOf("com.csqtt.client", "com.example.direct"))),
            applied.copy(dnsServers = listOf("1.1.1.1", "9.9.9.9")),
            applied.copy(routes = mapOf("0.0.0.0/0" to TunRouteType.INCLUDE, "1.1.1.1/32" to TunRouteType.EXCLUDE)),
            applied.copy(metered = true),
        )
        for (requested in changed) {
            assertFalse(TunRecoveryPolicy.shouldReuse(true, true, false, false, applied, requested))
        }
    }

    @Test
    fun idleDescriptorRetirementClaimsCleanupOnlyOnce() {
        val lifetime = TunDescriptorLifetimePolicy()
        assertTrue(lifetime.retire())
        assertFalse(lifetime.retire())
        assertFalse(lifetime.beginDelivery())
    }

    @Test
    fun retirementDuringDeliveryDefersCleanupUntilSenderFinallyWithoutAnAck() {
        val lifetime = TunDescriptorLifetimePolicy()
        assertTrue(lifetime.beginDelivery())
        assertFalse(lifetime.retire())
        assertFalse(lifetime.retire())
        assertTrue(lifetime.finishDelivery())
        assertFalse(lifetime.retire())
        assertFalse(lifetime.beginDelivery())
    }

    @Test
    fun cancelledRetryDoesNotRetireTheDescriptorStillOwnedByTheService() {
        val lifetime = TunDescriptorLifetimePolicy()
        assertTrue(lifetime.beginDelivery())
        assertFalse(lifetime.finishDelivery())
        assertTrue(lifetime.beginDelivery())
        assertFalse(lifetime.finishDelivery())
        assertTrue(lifetime.retire())
    }

    @Test
    fun descriptorCannotBeBorrowedByTwoConcurrentSenders() {
        val lifetime = TunDescriptorLifetimePolicy()
        assertTrue(lifetime.beginDelivery())
        assertFalse(lifetime.beginDelivery())
        assertFalse(lifetime.finishDelivery())
        assertTrue(lifetime.beginDelivery())
        assertFalse(lifetime.retire())
        assertTrue(lifetime.finishDelivery())
    }

    @Test
    fun doNotRestoreInterfaceOnRevokeEvenWhenPermissionGranted() {
        assertFalse(
            TunRecoveryPolicy.shouldRestoreInterface(
                permissionGranted = true,
                stopRequested = false,
                serviceDestroyed = false,
                activeClientIp = "10.66.66.2",
                activeDns = "1.1.1.1",
            )
        )
    }

    @Test
    fun doNotRestoreInterfaceWhenStopRequested() {
        assertFalse(
            TunRecoveryPolicy.shouldRestoreInterface(
                permissionGranted = true,
                stopRequested = true,
                serviceDestroyed = false,
                activeClientIp = "10.66.66.2",
                activeDns = "1.1.1.1",
            )
        )
    }

    private fun decide(
        hasInterface: Boolean = true,
        descriptorValid: Boolean = true,
        serviceDestroyed: Boolean = false,
        forceRebuild: Boolean = false,
        activeClientIp: String? = "10.66.66.2",
        activeDns: String? = "1.1.1.1",
        requestedClientIp: String = "10.66.66.2",
        requestedDns: String = "1.1.1.1",
    ): Boolean = TunRecoveryPolicy.shouldReuse(
        hasInterface = hasInterface,
        descriptorValid = descriptorValid,
        serviceDestroyed = serviceDestroyed,
        forceRebuild = forceRebuild,
        appliedPlan = if (activeClientIp != null && activeDns != null) plan(activeClientIp, activeDns) else null,
        requestedPlan = plan(requestedClientIp, requestedDns),
    )

    private fun plan(clientIp: String = "10.66.66.2", dns: String = "1.1.1.1") = TunAppliedPlan(
        clientAddress = "$clientIp/32",
        mtu = 1500,
        apps = TunAppliedApps(TunAppsMode.DISALLOW, setOf("com.csqtt.client")),
        dnsServers = listOf(dns),
        routes = mapOf("0.0.0.0/0" to TunRouteType.INCLUDE, "$dns/32" to TunRouteType.INCLUDE),
        metered = false,
        complete = true,
    )
}
