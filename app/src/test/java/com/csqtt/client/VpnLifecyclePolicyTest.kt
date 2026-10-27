package com.csqtt.client

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VpnLifecyclePolicyTest {
    @Test
    fun keepsInterfaceWhenRestartScheduled() {
        assertFalse(
            VpnLifecyclePolicy.shouldCloseVpnOnProcessExit(
                restartScheduled = true,
                tunnelRunning = true,
            )
        )
    }

    @Test
    fun keepsInterfaceWhenAnotherProcessTookOver() {
        assertFalse(
            VpnLifecyclePolicy.shouldCloseVpnOnProcessExit(
                restartScheduled = false,
                tunnelRunning = true,
            )
        )
    }

    @Test
    fun closesInterfaceWhenProcessExitedWithoutRestart() {
        assertTrue(
            VpnLifecyclePolicy.shouldCloseVpnOnProcessExit(
                restartScheduled = false,
                tunnelRunning = false,
            )
        )
    }

    @Test
    fun stopsFdDeliveryWhenTunnelIsGone() {
        assertFalse(
            VpnLifecyclePolicy.shouldRetryFdDelivery(
                tunnelRunning = false,
                attempt = 1,
                maxAttempts = 60,
            )
        )
    }

    @Test
    fun keepsRetryingWhileTunnelIsAlive() {
        assertTrue(
            VpnLifecyclePolicy.shouldRetryFdDelivery(
                tunnelRunning = true,
                attempt = 1,
                maxAttempts = 60,
            )
        )
        assertTrue(
            VpnLifecyclePolicy.shouldRetryFdDelivery(
                tunnelRunning = true,
                attempt = 60,
                maxAttempts = 60,
            )
        )
    }

    @Test
    fun stopsFdDeliveryWhenAttemptsExhausted() {
        assertFalse(
            VpnLifecyclePolicy.shouldRetryFdDelivery(
                tunnelRunning = true,
                attempt = 61,
                maxAttempts = 60,
            )
        )
    }

    @Test
    fun doesNotReestablishVpnWithoutTunnel() {
        assertFalse(VpnLifecyclePolicy.shouldReestablishVpn(tunnelRunning = false))
    }

    @Test
    fun reestablishesVpnWhileTunnelIsAlive() {
        assertTrue(VpnLifecyclePolicy.shouldReestablishVpn(tunnelRunning = true))
    }

    @Test
    fun clearsPersistedRunStateOnRealStop() {
        assertTrue(VpnLifecyclePolicy.shouldClearPersistedRunState(preserveWifiAutoPause = false))
    }

    @Test
    fun keepsPersistedRunStateDuringWifiAutoPause() {
        // The resume intent is saved before the pause, so clearing it here would
        // leave the tunnel dead until the user reconnects by hand.
        assertFalse(VpnLifecyclePolicy.shouldClearPersistedRunState(preserveWifiAutoPause = true))
    }
}
