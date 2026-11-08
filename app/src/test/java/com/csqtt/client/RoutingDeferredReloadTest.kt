package com.csqtt.client

import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RoutingDeferredReloadTest {
    @Test fun `reload is not taken until the VPN is ready`() {
        val pending = RoutingDeferredReload()
        val connection = pending.begin(1)
        val start = requireNotNull(pending.markStarting(connection))
        assertNull(pending.request(connection, "routing_cleared"))
        assertNull(pending.request(connection, "routing_cleared"))
        assertEquals("routing_cleared", pending.markReady(start)?.reloadReason)
    }

    @Test fun `ready VPN takes the last reason once`() {
        val pending = RoutingDeferredReload()
        val connection = pending.begin(1)
        val start = requireNotNull(pending.markStarting(connection))
        pending.request(connection, "routing_changed")
        pending.request(connection, "routing_cleared")
        assertEquals("routing_cleared", pending.markReady(start)?.reloadReason)
        assertNull(pending.markReady(start))
    }

    @Test fun `clear drops a reason from a previous connection`() {
        val pending = RoutingDeferredReload()
        val connection = pending.begin(1)
        val start = requireNotNull(pending.markStarting(connection))
        pending.request(connection, "routing_changed")
        pending.clear()
        assertNull(pending.markReady(start))
        assertNull(pending.currentConnection())
    }

    @Test fun `nothing remembered is a no-op`() {
        val pending = RoutingDeferredReload()
        val start = requireNotNull(pending.markStarting(pending.begin(1)))
        assertEquals(RoutingDeferredReload.Ready(null), pending.markReady(start))
        assertNull(pending.markReady(start))
    }

    @Test fun `ready before the request does not strand the reload`() {
        val pending = RoutingDeferredReload()
        val connection = pending.begin(1)
        val start = requireNotNull(pending.markStarting(connection))
        // The IO callback wins after the caller observed vpnReady=false.
        assertEquals(RoutingDeferredReload.Ready(null), pending.markReady(start))
        assertEquals("routing_changed", pending.request(connection, "routing_changed"))
        assertNull(pending.markReady(start))
    }

    @Test fun `concurrent ready and request produce exactly one reload`() {
        repeat(25) {
            val pending = RoutingDeferredReload()
            val connection = pending.begin(1)
            val start = requireNotNull(pending.markStarting(connection))
            val barrier = CyclicBarrier(2)
            val actions = ConcurrentLinkedQueue<String>()
            val errors = ConcurrentLinkedQueue<Throwable>()
            fun task(action: () -> String?) = Thread {
                try {
                    barrier.await(5, TimeUnit.SECONDS)
                    action()?.let { actions += it }
                } catch (failure: Throwable) {
                    errors += failure
                }
            }
            val ready = task { pending.markReady(start)?.reloadReason }
            val request = task { pending.request(connection, "routing_changed") }
            ready.start()
            request.start()
            ready.join(5_000)
            request.join(5_000)

            assertFalse(ready.isAlive)
            assertFalse(request.isAlive)
            assertTrue(errors.toString(), errors.isEmpty())
            assertEquals(listOf("routing_changed"), actions.toList())
            assertNull(pending.markReady(start))
        }
    }

    @Test fun `old callbacks and requests cannot consume the new connection debt`() {
        val pending = RoutingDeferredReload()
        val oldConnection = pending.begin(1)
        val oldStart = requireNotNull(pending.markStarting(oldConnection))
        pending.request(oldConnection, "old")
        // Even a reused numeric generation gets a fresh identity.
        val connection = pending.begin(1)
        val start = requireNotNull(pending.markStarting(connection))
        pending.request(connection, "new")

        assertNull(pending.markReady(oldStart))
        assertFalse(pending.markStopped(oldStart))
        assertNull(pending.request(oldConnection, "stale"))
        assertEquals("new", pending.markReady(start)?.reloadReason)
        assertNull(pending.markReady(start))
    }

    @Test fun `queued changes are covered by the latest startup snapshot`() {
        val pending = RoutingDeferredReload()
        val connection = pending.begin(1)
        val firstStart = requireNotNull(pending.markStarting(connection))
        pending.markReady(firstStart)
        assertEquals("first", pending.request(connection, "first"))
        assertNull(pending.request(connection, "second"))
        assertNull(pending.request(connection, "latest"))

        val reloadStart = requireNotNull(pending.markStarting(connection))
        assertNull(pending.markReady(firstStart))
        assertEquals(RoutingDeferredReload.Ready(null), pending.markReady(reloadStart))
        assertNull(pending.markReady(reloadStart))
    }

    @Test fun `reused fd retains pre snapshot debt but rebuilding it covers the debt`() {
        val pending = RoutingDeferredReload()
        val connection = pending.begin(1)
        pending.request(connection, "routing_changed")
        val reusedStart = requireNotNull(pending.markStarting(connection))

        assertEquals("routing_changed", pending.markReady(reusedStart, routesRebuilt = false)?.reloadReason)
        assertNull(pending.markReady(reusedStart, routesRebuilt = false))
        val rebuiltStart = requireNotNull(pending.markStarting(connection))
        assertEquals(RoutingDeferredReload.Ready(null), pending.markReady(rebuiltStart))
    }

    @Test fun `latest change after snapshot wins over debt from a reused interface`() {
        val pending = RoutingDeferredReload()
        val connection = pending.begin(1)
        pending.request(connection, "routing_changed")
        val start = requireNotNull(pending.markStarting(connection))
        pending.request(connection, "routing_cleared")

        assertEquals("routing_cleared", pending.markReady(start, routesRebuilt = false)?.reloadReason)
        assertNull(pending.markReady(start, routesRebuilt = false))
    }

    @Test fun `superseding reuse starts before either ack retain the unfulfilled debt`() {
        val pending = RoutingDeferredReload()
        val connection = pending.begin(1)
        pending.request(connection, "routing_changed")
        val firstStart = requireNotNull(pending.markStarting(connection))
        val latestStart = requireNotNull(pending.markStarting(connection))

        assertNull(pending.markReady(firstStart, routesRebuilt = false))
        assertEquals("routing_changed", pending.markReady(latestStart, routesRebuilt = false)?.reloadReason)
        assertNull(pending.markReady(latestStart, routesRebuilt = false))
    }

    @Test fun `superseding rebuild covers inherited debt but not changes after its snapshot`() {
        val pending = RoutingDeferredReload()
        val connection = pending.begin(1)
        pending.request(connection, "before_first")
        val firstStart = requireNotNull(pending.markStarting(connection))
        pending.request(connection, "before_latest")
        val latestStart = requireNotNull(pending.markStarting(connection))
        pending.request(connection, "after_latest")

        assertNull(pending.markReady(firstStart))
        assertEquals("after_latest", pending.markReady(latestStart)?.reloadReason)
    }

    @Test fun `changes during a rebuild need one more reload with the last reason`() {
        val pending = RoutingDeferredReload()
        val connection = pending.begin(1)
        val firstStart = requireNotNull(pending.markStarting(connection))
        pending.markReady(firstStart)
        pending.request(connection, "first")
        val reloadStart = requireNotNull(pending.markStarting(connection))
        pending.request(connection, "routing_changed")
        pending.request(connection, "routing_cleared")

        assertNull(pending.markReady(firstStart))
        assertEquals("routing_cleared", pending.markReady(reloadStart)?.reloadReason)
        assertNull(pending.markReady(reloadStart))
    }

    @Test fun `stopped interface ignores late ready and repeated stop preserves new debt`() {
        val pending = RoutingDeferredReload()
        val connection = pending.begin(1)
        val start = requireNotNull(pending.markStarting(connection))
        pending.request(connection, "old")
        assertTrue(pending.markStopped(start))
        pending.request(connection, "new")
        assertFalse(pending.markStopped(start))
        assertNull(pending.markReady(start))
        val recoveredStart = requireNotNull(pending.markStarting(connection))
        assertEquals(RoutingDeferredReload.Ready(null), pending.markReady(recoveredStart))
    }
}
