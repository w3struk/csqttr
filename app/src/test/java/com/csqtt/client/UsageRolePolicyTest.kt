package com.csqtt.client

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UsageRolePolicyTest {

    @Test
    fun explicitParticipantWinsOverConfiguredProfile() {
        assertTrue(
            UsageRolePolicy.resolveParticipantMode(
                storedMode = true,
                peer = "server.example.org",
                link = "csqtt://server.example.org",
            ),
        )
    }

    @Test
    fun explicitOwnerWinsOverEmptyProfile() {
        assertFalse(
            UsageRolePolicy.resolveParticipantMode(
                storedMode = false,
                peer = "",
                link = "",
            ),
        )
    }

    @Test
    fun emptyProfileWithoutChoiceResolvesToParticipant() {
        assertTrue(
            UsageRolePolicy.resolveParticipantMode(
                storedMode = null,
                peer = "",
                link = "",
            ),
        )
    }

    @Test
    fun configuredPeerWithoutChoiceResolvesToOwner() {
        assertFalse(
            UsageRolePolicy.resolveParticipantMode(
                storedMode = null,
                peer = "server.example.org",
                link = "",
            ),
        )
    }

    @Test
    fun configuredLinkWithoutChoiceResolvesToOwner() {
        assertFalse(
            UsageRolePolicy.resolveParticipantMode(
                storedMode = null,
                peer = "",
                link = "csqtt://server.example.org",
            ),
        )
    }

    @Test
    fun blankPeerAndLinkCountAsEmptyProfile() {
        assertTrue(UsageRolePolicy.isProfileEmpty(peer = "   ", link = "\t\n"))
        assertFalse(UsageRolePolicy.isProfileEmpty(peer = " server ", link = ""))
        assertFalse(UsageRolePolicy.isProfileEmpty(peer = "", link = " link "))
    }
}
