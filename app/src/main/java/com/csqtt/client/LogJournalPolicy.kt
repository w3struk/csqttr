package com.csqtt.client

internal object LogJournalPolicy {
    const val MAX_ENTRIES = 500
    const val SESSION_KEY_PREFIX = "session_"

    fun isSessionMarker(entry: LogEntry): Boolean =
        entry.key.startsWith(SESSION_KEY_PREFIX)

    /**
     * Index of the most recent row with [key] inside the current session, or -1.
     * Rows before the last session marker belong to earlier sessions and stay frozen,
     * so a reconnect never rewrites what happened before it.
     */
    fun mergeIndex(entries: List<LogEntry>, key: String): Int {
        for (index in entries.indices.reversed()) {
            val entry = entries[index]
            if (isSessionMarker(entry)) return -1
            if (entry.key == key) return index
        }
        return -1
    }

    fun unreadIncrement(incoming: LogEntry, merged: Boolean): Int =
        if (!merged && incoming.isError) 1 else 0

    fun excess(size: Int, maxEntries: Int = MAX_ENTRIES): Int =
        (size - maxEntries).coerceAtLeast(0)
}
