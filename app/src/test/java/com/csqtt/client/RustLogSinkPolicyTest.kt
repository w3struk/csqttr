// SPDX-FileCopyrightText: 2026 amurcanov
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RustLogSinkPolicyTest {

    @Test
    fun `streams map to distinct tags`() {
        assertEquals("CSQTT/Protocol", RustLogSinkPolicy.tag(RustLogStream.PROTOCOL))
        assertEquals("CSQTT/Diagnostic", RustLogSinkPolicy.tag(RustLogStream.DIAGNOSTIC))
        assertTrue(
            RustLogSinkPolicy.tag(RustLogStream.PROTOCOL) !=
                RustLogSinkPolicy.tag(RustLogStream.DIAGNOSTIC),
        )
    }

    @Test
    fun `plain protocol line is debug and plain diagnostic line is info`() {
        assertEquals(
            RustLogSeverity.DEBUG,
            RustLogSinkPolicy.severity(RustLogStream.PROTOCOL, "[TURN] Сессия готова к передаче данных"),
        )
        assertEquals(
            RustLogSeverity.INFO,
            RustLogSinkPolicy.severity(RustLogStream.DIAGNOSTIC, "[TURN] ChannelBind активен: канал 0x4001"),
        )
    }

    @Test
    fun `error markers win over the stream default`() {
        val errorLines = listOf(
            "Ошибка подключения",
            "connect error: refused",
            "TLS handshake FAILED",
            "FATAL_PROTOCOL",
            "panicked at src/main.rs:1",
            "connection refused",
            "read timeout",
        )
        for (line in errorLines) {
            for (stream in RustLogStream.entries) {
                assertEquals(
                    "expected ERROR for: $line ($stream)",
                    RustLogSeverity.ERROR,
                    RustLogSinkPolicy.severity(stream, line),
                )
            }
        }
    }

    @Test
    fun `short lines are a single chunk`() {
        assertEquals(listOf("abc"), RustLogSinkPolicy.chunks("abc"))
        assertEquals(emptyList<String>(), RustLogSinkPolicy.chunks(""))
    }

    @Test
    fun `line that already fits in bytes is not split`() {
        val line = "я".repeat(RustLogSinkPolicy.MAX_CHUNK_BYTES / 2)
        assertEquals(line.toByteArray(Charsets.UTF_8).size, RustLogSinkPolicy.MAX_CHUNK_BYTES)
        assertEquals(listOf(line), RustLogSinkPolicy.chunks(line))
    }

    @Test
    fun `chunks respect the byte budget for multibyte text`() {
        // 8000 Cyrillic characters would be 16000 bytes: character-based chunking
        // would hand logcat records twice its payload limit.
        val line = "ошибка подключения ".repeat(600)
        val chunks = RustLogSinkPolicy.chunks(line)
        assertTrue("expected several chunks", chunks.size > 1)
        for (chunk in chunks) {
            assertTrue(
                "chunk of ${chunk.toByteArray(Charsets.UTF_8).size} bytes exceeds the budget",
                chunk.toByteArray(Charsets.UTF_8).size <= RustLogSinkPolicy.MAX_CHUNK_BYTES,
            )
        }
        assertEquals(line, chunks.joinToString(""))
    }

    @Test
    fun `surrogate pairs are never split across chunks`() {
        val line = "🔒" + "a".repeat(RustLogSinkPolicy.MAX_CHUNK_BYTES + 10)
        val chunks = RustLogSinkPolicy.chunks(line)
        for (chunk in chunks) {
            assertTrue("no chunk may contain a lone surrogate", !chunk.hasLoneSurrogate())
            assertTrue(chunk.toByteArray(Charsets.UTF_8).size <= RustLogSinkPolicy.MAX_CHUNK_BYTES)
        }
        assertEquals(line, chunks.joinToString(""))
    }

    @Test
    fun `chunks of emoji-heavy text stay within the budget`() {
        val line = "🔒".repeat(2000)
        val chunks = RustLogSinkPolicy.chunks(line)
        for (chunk in chunks) {
            assertTrue(!chunk.hasLoneSurrogate())
            assertTrue(chunk.toByteArray(Charsets.UTF_8).size <= RustLogSinkPolicy.MAX_CHUNK_BYTES)
        }
        assertEquals(line, chunks.joinToString(""))
    }

    @Test(expected = IllegalArgumentException::class)
    fun `zero chunk limit is rejected`() {
        RustLogSinkPolicy.chunks("abc", limitBytes = 0)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `budget below one code point is rejected`() {
        // A single emoji costs four UTF-8 bytes, so a smaller budget could not be
        // honoured without splitting a character.
        RustLogSinkPolicy.chunks("🔒", limitBytes = 3)
    }

    @Test
    fun `a line that fits is logged as is`() {
        assertEquals(listOf("abc"), RustLogSinkPolicy.chunksForLogcat("abc"))
    }

    @Test
    fun `a split line is marked so it cannot be read as a cut payload`() {
        val line = "ошибка подключения ".repeat(600)
        val chunks = RustLogSinkPolicy.chunksForLogcat(line)
        assertTrue("expected several chunks", chunks.size > 1)
        val total = chunks.size
        chunks.forEachIndexed { index, chunk ->
            assertTrue(
                "chunk $index must carry its part marker: $chunk",
                chunk.endsWith("[часть ${index + 1}/$total]"),
            )
            assertTrue(
                "chunk of ${chunk.toByteArray(Charsets.UTF_8).size} bytes exceeds the logcat limit",
                chunk.toByteArray(Charsets.UTF_8).size <= RustLogSinkPolicy.LOG_MESSAGE_LIMIT_BYTES,
            )
        }
    }

    @Test
    fun `the marker survives even when a caller asks for the full log budget`() {
        val line = "я".repeat(6000)
        val chunks = RustLogSinkPolicy.chunksForLogcat(line, limitBytes = RustLogSinkPolicy.LOG_MESSAGE_LIMIT_BYTES)
        assertTrue("expected several chunks", chunks.size > 1)
        for (chunk in chunks) {
            assertTrue(
                "chunk of ${chunk.toByteArray(Charsets.UTF_8).size} bytes exceeds the logcat limit",
                chunk.toByteArray(Charsets.UTF_8).size <= RustLogSinkPolicy.LOG_MESSAGE_LIMIT_BYTES,
            )
        }
    }

    private fun String.hasLoneSurrogate(): Boolean {
        var i = 0
        while (i < length) {
            val c = this[i]
            if (Character.isHighSurrogate(c)) {
                if (i + 1 >= length || !Character.isLowSurrogate(this[i + 1])) return true
                i += 2
            } else {
                if (Character.isLowSurrogate(c)) return true
                i++
            }
        }
        return false
    }
}