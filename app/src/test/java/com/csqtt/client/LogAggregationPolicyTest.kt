package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Test

class LogAggregationPolicyTest {
    @Test
    fun mergedTimestampIsTheLastIncomingEvent() {
        val merged = LogAggregationPolicy.merge(entry(timestampMillis = 1_000L), entry(timestampMillis = 2_000L))

        assertEquals(2_000L, merged.timestampMillis)
    }

    @Test
    fun mergeTakesIncomingTimestampEvenWhenClockMovedBack() {
        val merged = LogAggregationPolicy.merge(entry(timestampMillis = 3_000L), entry(timestampMillis = 2_000L))

        assertEquals(2_000L, merged.timestampMillis)
    }

    @Test
    fun countersSumUp() {
        val merged = LogAggregationPolicy.merge(entry(count = 2), entry(count = 3))

        assertEquals(5, merged.count)
    }

    @Test
    fun incomingFieldsWin() {
        val merged = LogAggregationPolicy.merge(
            entry(message = "old", priority = 10, isError = false, level = LogLevel.OK),
            entry(message = "new", priority = 5, isError = true, level = LogLevel.ERR),
        )

        assertEquals("new", merged.message)
        assertEquals(5, merged.priority)
        assertEquals(true, merged.isError)
        assertEquals(LogLevel.ERR, merged.level)
    }

    @Test
    fun mergeKeepsIncomingValuesWhenPriorityChanges() {
        val merged = LogAggregationPolicy.merge(
            entry(priority = 7, isError = false, level = LogLevel.OK, timestampMillis = 3_000L),
            entry(priority = 1, isError = true, level = LogLevel.ERR, timestampMillis = 2_000L),
        )

        assertEquals(1, merged.priority)
        assertEquals(true, merged.isError)
        assertEquals(LogLevel.ERR, merged.level)
        assertEquals(2_000L, merged.timestampMillis)
    }

    @Test
    fun keyIsPreservedFromExistingEntry() {
        val merged = LogAggregationPolicy.merge(entry(key = "existing"), entry(key = "incoming"))

        assertEquals("existing", merged.key)
    }

    private fun entry(
        key: String = "log",
        message: String = "message",
        count: Int = 1,
        priority: Int = 99,
        isError: Boolean = false,
        level: LogLevel? = null,
        timestampMillis: Long = 1_000L,
    ) = LogEntry(key, message, count, priority, isError, level, timestampMillis)
}
