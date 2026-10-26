package com.csqtt.client

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Счётчики трафика в уведомлении перерисовываются только при включённом экране:
 * с выключенным экраном это публикация уведомления каждые несколько секунд впустую.
 */
class TunnelNotificationPolicyTest {

    @Test
    fun `traffic numbers are redrawn only with the screen on`() {
        assertTrue("при включённом экране текст обновляется", TunnelNotificationPolicy.shouldRefreshTraffic(true))
        assertFalse("при выключенном экране текст не обновляется", TunnelNotificationPolicy.shouldRefreshTraffic(false))
    }
}
