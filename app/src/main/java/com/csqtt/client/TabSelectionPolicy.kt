package com.csqtt.client

// A saved tab can belong to a mode the user no longer has; fall back to the
// connection tab instead of leaving the content pane empty.
internal fun resolveSelectedTab(current: Int, allowedIds: List<Int>): Int =
    current.takeIf { it in allowedIds } ?: 0
