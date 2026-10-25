package com.csqtt.client

internal object LogAggregationPolicy {
    fun merge(existing: LogEntry, incoming: LogEntry): LogEntry = existing.copy(
        count = existing.count + incoming.count,
        message = incoming.message,
        priority = incoming.priority,
        isError = incoming.isError,
        level = incoming.level,
        timestampMillis = incoming.timestampMillis,
    )
}
