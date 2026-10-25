package com.csqtt.client

import java.time.Instant
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LogTimestampPolicyTest {
    @Test
    fun midnightFormatsWithLeadingZeros() {
        val timestampMillis = Instant.parse("2026-10-25T00:00:00Z").toEpochMilli()

        assertEquals("00:00:00", LogTimestampPolicy.format(timestampMillis, ZoneId.of("UTC")))
    }

    @Test
    fun lastSecondOfDayFormatsCorrectly() {
        val timestampMillis = Instant.parse("2026-10-25T23:59:59Z").toEpochMilli()

        assertEquals("23:59:59", LogTimestampPolicy.format(timestampMillis, ZoneId.of("UTC")))
    }

    @Test
    fun ordinaryTimeKeepsLeadingZeros() {
        val timestampMillis = Instant.parse("2026-10-25T09:07:03Z").toEpochMilli()

        assertEquals("09:07:03", LogTimestampPolicy.format(timestampMillis, ZoneId.of("UTC")))
    }

    @Test
    fun sameInstantDiffersAcrossZones() {
        val timestampMillis = Instant.parse("2026-10-25T14:23:05Z").toEpochMilli()

        assertEquals("14:23:05", LogTimestampPolicy.format(timestampMillis, ZoneId.of("UTC")))
        assertEquals(
            "19:23:05",
            LogTimestampPolicy.format(timestampMillis, ZoneId.of("Asia/Yekaterinburg")),
        )
    }

    @Test
    fun zeroEpochFormatsAsMidnightInUtc() {
        assertEquals("00:00:00", LogTimestampPolicy.format(0L, ZoneId.of("UTC")))
    }

    @Test
    fun formatIsAsciiAndExactlyEightChars() {
        val timestampMillis = Instant.parse("2026-10-25T09:07:03Z").toEpochMilli()
        val zones = listOf("UTC", "Asia/Yekaterinburg", "America/New_York")

        zones.forEach { zone ->
            val formatted = LogTimestampPolicy.format(timestampMillis, ZoneId.of(zone))
            assertTrue("Unexpected timestamp format in $zone: $formatted", formatted.matches(Regex("^[0-9]{2}:[0-9]{2}:[0-9]{2}$")))
        }
    }

    @Test
    fun copyLineStartsWithBracketedTimestamp() {
        val entry = LogEntry(
            key = "copy-line",
            message = "[TURN] Сессия готова",
            count = 3,
            level = LogLevel.TURN,
            timestampMillis = Instant.parse("2026-10-25T14:23:05Z").toEpochMilli(),
        )

        assertEquals(
            "[14:23:05] [TURN] Сессия готова (x3)",
            LogTimestampPolicy.copyLine(entry, ZoneId.of("UTC")),
        )
    }

    @Test
    fun copyLinePreservesBodyAndCounter() {
        val timestampMillis = Instant.parse("2026-10-25T14:23:05Z").toEpochMilli()
        val message = "Текст записи"

        listOf(2, 7).forEach { count ->
            val entry = LogEntry(
                key = "copy-line-$count",
                message = message,
                count = count,
                timestampMillis = timestampMillis,
            )

            assertEquals(
                "[14:23:05] $message (x$count)",
                LogTimestampPolicy.copyLine(entry, ZoneId.of("UTC")),
            )
        }
    }

    @Test
    fun singleEventCopyHasExactlyOneTimestampPrefix() {
        val entry = LogEntry(
            key = "single-copy-line",
            message = "Сообщение",
            count = 1,
            timestampMillis = Instant.parse("2026-10-25T14:23:05Z").toEpochMilli(),
        )
        val copiedLine = LogTimestampPolicy.copyLine(entry, ZoneId.of("UTC"))

        assertEquals("[14:23:05] Сообщение (x1)", copiedLine)
        assertFalse(copiedLine.contains("] ["))
    }

    @Test
    fun copyLineUsesTheSameFormatterAsFormat() {
        val entry = LogEntry(
            key = "formatter-copy-line",
            message = "[DBG] Проверка",
            count = 4,
            timestampMillis = Instant.parse("2026-10-25T14:23:05Z").toEpochMilli(),
        )
        val zoneId = ZoneId.of("UTC")

        assertEquals(
            "[${LogTimestampPolicy.format(entry.timestampMillis, zoneId)}] ${entry.message} (x${entry.count})",
            LogTimestampPolicy.copyLine(entry, zoneId),
        )
    }
}
