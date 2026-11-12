package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ConnectionStartPolicyTest {
    @Test
    fun tokenFromParticipantLinkIsReadyWithoutStoredToken() {
        assertEquals(
            true,
            ConnectionStartPolicy.hasReadyVkCredentials(
                linkHashCount = 0,
                linkTokenPresent = true,
                autoHashMode = true,
                storedTokenPresent = false,
                manualHashCount = 0,
            ),
        )
    }

    @Test
    fun participantLinkUsesExplicitlyEnteredHashesWhenLinkHasNoVkCredentials() {
        assertEquals(
            true,
            ConnectionStartPolicy.hasReadyVkCredentials(
                linkHashCount = 0,
                linkTokenPresent = false,
                autoHashMode = false,
                storedTokenPresent = false,
                manualHashCount = 1,
            ),
        )
    }

    @Test
    fun participantLinkWithoutCredentialsIsBlockedUntilUserEntersThem() {
        assertEquals(
            false,
            ConnectionStartPolicy.hasReadyVkCredentials(
                linkHashCount = 0,
                linkTokenPresent = false,
                autoHashMode = false,
                storedTokenPresent = false,
                manualHashCount = 0,
            ),
        )
    }

    @Test
    fun `valid link with ready hashes has no blocker`() {
        assertNull(
            ConnectionStartPolicy.blocker(
                linkValid = true,
                hashesReady = true,
            ),
        )
    }

    @Test
    fun `missing hashes is reported after the link`() {
        assertEquals(
            ConnectionStartBlocker.Hashes,
            ConnectionStartPolicy.blocker(
                linkValid = true,
                hashesReady = false,
            ),
        )
    }

    @Test
    fun `invalid link is the only remaining configuration blocker`() {
        assertEquals(
            ConnectionStartBlocker.Link,
            ConnectionStartPolicy.blocker(
                linkValid = false,
                hashesReady = true,
            ),
        )
    }

    @Test
    fun `the link is checked before the hashes`() {
        // Хеши приходят в том числе из ссылки: без ссылки сообщение про хеши
        // отправляло бы пользователя не туда.
        assertEquals(
            ConnectionStartBlocker.Link,
            ConnectionStartPolicy.blocker(
                linkValid = false,
                hashesReady = false,
            ),
        )
    }
}
