package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LogJournalPolicyTest {
    @Test
    fun sessionMarkerIsRecognizedByPrefix() {
        assertTrue(LogJournalPolicy.isSessionMarker(entry(key = "session_1")))
        assertTrue(LogJournalPolicy.isSessionMarker(entry(key = "session_42")))
        assertFalse(LogJournalPolicy.isSessionMarker(entry(key = "stats")))
        assertFalse(LogJournalPolicy.isSessionMarker(entry(key = "ready")))
    }

    @Test
    fun mergeFindsMostRecentRowInTheSameSession() {
        val entries = listOf(
            entry(key = "dtls"),
            entry(key = "ready"),
            entry(key = "dtls"),
        )

        assertEquals(2, LogJournalPolicy.mergeIndex(entries, "dtls"))
    }

    @Test
    fun mergeUsesTheLastMatchingRow() {
        val entries = listOf(
            entry(key = "a", id = 1L),
            entry(key = "b", id = 2L),
            entry(key = "a", id = 3L),
        )

        assertEquals(2, LogJournalPolicy.mergeIndex(entries, "a"))
    }

    @Test
    fun mergeIgnoresRowsBeforeTheLastSessionMarker() {
        val entries = listOf(
            entry(key = "dtls"),
            entry(key = "session_1"),
            entry(key = "ready"),
        )

        assertEquals(-1, LogJournalPolicy.mergeIndex(entries, "dtls"))
    }

    @Test
    fun mergeFindsRowsAfterTheLastSessionMarker() {
        val entries = listOf(
            entry(key = "dtls"),
            entry(key = "session_1"),
            entry(key = "dtls"),
            entry(key = "ready"),
        )

        assertEquals(2, LogJournalPolicy.mergeIndex(entries, "dtls"))
    }

    @Test
    fun mergeStopsAtTheMarkerEvenWhenTheKeyAppearsBeforeIt() {
        val entries = listOf(
            entry(key = "stats"),
            entry(key = "session_1"),
            entry(key = "session_2"),
            entry(key = "ready"),
        )

        assertEquals(-1, LogJournalPolicy.mergeIndex(entries, "stats"))
    }

    @Test
    fun mergeReturnsMinusOneWhenKeyIsAbsentOrListIsEmpty() {
        assertEquals(-1, LogJournalPolicy.mergeIndex(emptyList(), "dtls"))
        assertEquals(-1, LogJournalPolicy.mergeIndex(listOf(entry(key = "ready")), "dtls"))
    }

    @Test
    fun mergeNeverMatchesTheMarkerKeyItself() {
        val entries = listOf(entry(key = "session_1"))

        assertEquals(-1, LogJournalPolicy.mergeIndex(entries, "session_1"))
    }

    @Test
    fun newErrorRowIsUnread() {
        assertEquals(1, LogJournalPolicy.unreadIncrement(entry(isError = true), merged = false))
    }

    @Test
    fun mergedErrorRowIsNotUnread() {
        assertEquals(0, LogJournalPolicy.unreadIncrement(entry(isError = true), merged = true))
    }

    @Test
    fun newNonErrorRowIsNotUnread() {
        assertEquals(0, LogJournalPolicy.unreadIncrement(entry(isError = false), merged = false))
    }

    @Test
    fun excessIsZeroAtOrUnderLimit() {
        assertEquals(0, LogJournalPolicy.excess(0))
        assertEquals(0, LogJournalPolicy.excess(LogJournalPolicy.MAX_ENTRIES))
        assertEquals(0, LogJournalPolicy.excess(LogJournalPolicy.MAX_ENTRIES - 1))
    }

    @Test
    fun excessCountsRowsOverLimit() {
        assertEquals(3, LogJournalPolicy.excess(LogJournalPolicy.MAX_ENTRIES + 3))
    }

    @Test
    fun excessHonoursExplicitLimit() {
        assertEquals(2, LogJournalPolicy.excess(size = 7, maxEntries = 5))
    }

    private fun entry(
        key: String = "log",
        message: String = "message",
        count: Int = 1,
        priority: Int = 99,
        isError: Boolean = false,
        level: LogLevel? = null,
        timestampMillis: Long = 1_000L,
        id: Long = 0L,
    ) = LogEntry(key, message, count, priority, isError, level, timestampMillis, id)
}
