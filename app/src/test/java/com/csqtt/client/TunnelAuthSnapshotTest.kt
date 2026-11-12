package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TunnelAuthSnapshotTest {
    @Test
    fun `default snapshot is a loading sentinel`() {
        assertFalse(TunnelAuthSnapshot().isLoaded)
    }

    @Test
    fun `profile snapshot is loaded`() {
        assertTrue(TunnelAuthSnapshot(profile = 0).isLoaded)
    }

    @Test
    fun `snapshot keeps the participant link`() {
        val snapshot = TunnelAuthSnapshot(
            profile = 0,
            csqttLink = "csqtt://connect?peer=example.test",
        )

        assertTrue(snapshot.isLoaded)
        assertEquals("csqtt://connect?peer=example.test", snapshot.csqttLink)
    }
}
