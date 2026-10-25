package com.csqtt.client

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

internal object LogTimestampPolicy {
    private val formatter = DateTimeFormatter.ofPattern("HH:mm:ss", Locale.ROOT)

    fun format(timestampMillis: Long, zoneId: ZoneId = ZoneId.systemDefault()): String =
        Instant.ofEpochMilli(timestampMillis).atZone(zoneId).format(formatter)

    fun copyLine(entry: LogEntry, zoneId: ZoneId = ZoneId.systemDefault()): String =
        "[${format(entry.timestampMillis, zoneId)}] ${entry.message} (x${entry.count})"
}
