// SPDX-FileCopyrightText: 2026 amurcanov
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

package com.csqtt.client

/** Which pipe of the Rust child process a line came from. */
internal enum class RustLogStream {
    /** stdout: protocol records and `__CSQTT_EVENT__|...` events. */
    PROTOCOL,

    /** stderr: everything written through `log_error!` / `log_info!`. */
    DIAGNOSTIC,
}

internal enum class RustLogSeverity {
    DEBUG,
    INFO,
    ERROR,
}

/**
 * Pure mapping between a Rust child-process line and its logcat representation.
 *
 * Debug builds mirror both pipes into logcat so the whole Rust stream can be read
 * with a tag filter, next to the Kotlin logs. Release builds never call this.
 */
internal object RustLogSinkPolicy {
    const val PROTOCOL_TAG = "CSQTT/Protocol"
    const val DIAGNOSTIC_TAG = "CSQTT/Diagnostic"

    /**
     * logcat drops everything past ~4068 bytes of payload. The budget is measured
     * in UTF-8 *bytes*, not characters: a Russian line costs two bytes per character,
     * so a character-based limit still produced records twice as long as logcat
     * accepts. 4000 leaves room for the longest tag plus logd's own framing.
     */
    const val MAX_CHUNK_BYTES = 4000

    private val ERROR_MARKERS = listOf(
        "ошибка",
        "error",
        "fail",
        "fatal",
        "panic",
        "refused",
        "timeout",
    )

    fun tag(stream: RustLogStream): String = when (stream) {
        RustLogStream.PROTOCOL -> PROTOCOL_TAG
        RustLogStream.DIAGNOSTIC -> DIAGNOSTIC_TAG
    }

    /**
     * Severity is a heuristic, not a contract: the Rust side uses `log_error!` for
     * informational lines as well, so only the line content can hint at an error.
     * The tag, not the severity, is what separates the two streams.
     */
    fun severity(stream: RustLogStream, line: String): RustLogSeverity {
        val lowered = line.lowercase()
        if (ERROR_MARKERS.any { lowered.contains(it) }) return RustLogSeverity.ERROR
        return when (stream) {
            RustLogStream.PROTOCOL -> RustLogSeverity.DEBUG
            RustLogStream.DIAGNOSTIC -> RustLogSeverity.INFO
        }
    }

    private fun utf8Length(codePoint: Int): Int = when {
        codePoint < 0x80 -> 1
        codePoint < 0x800 -> 2
        codePoint < 0x10000 -> 3
        else -> 4
    }

    /**
     * Splits [line] so that every chunk fits into [limitBytes] UTF-8 bytes and the
     * concatenation is unchanged. Chunks always end on a code point boundary, so a
     * surrogate pair (an emoji in a log line) is never cut in half.
     */
    fun chunks(line: String, limitBytes: Int = MAX_CHUNK_BYTES): List<String> {
        // 4 bytes is the largest UTF-8 code point, so a smaller budget could not be
        // honoured without breaking a character in half.
        require(limitBytes >= 4) { "chunk limit must be at least 4 bytes" }
        if (line.isEmpty()) return emptyList()

        val chunks = ArrayList<String>()
        val current = StringBuilder()
        var currentBytes = 0
        var index = 0

        while (index < line.length) {
            val codePoint = line.codePointAt(index)
            val chars = Character.charCount(codePoint)
            val bytes = utf8Length(codePoint)
            if (currentBytes + bytes > limitBytes && current.isNotEmpty()) {
                chunks += current.toString()
                current.setLength(0)
                currentBytes = 0
            }
            current.append(line, index, index + chars)
            currentBytes += bytes
            index += chars
        }
        if (current.isNotEmpty()) chunks += current.toString()
        return chunks
    }
}
