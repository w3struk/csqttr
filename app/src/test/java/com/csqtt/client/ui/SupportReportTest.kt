package com.csqtt.client.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Checks the clipboard text built from the support report and the journal.
 *
 * Only [buildReportCopyText] is covered here: [buildSupportReport] reads Android `Build`
 * fields and is exercised through the source contract instead.
 */
class SupportReportTest {

    private val report = "Версия приложения: 2.5.2\nАндроид: 15 (SDK 35)"
    private val lines = listOf("[08:53:12] [СЕТЬ] Подключено (x1)", "[08:53:13] [TURN] Канал готов (x2)")

    @Test
    fun `empty journal yields the bare report`() {
        assertEquals(report, buildReportCopyText(report, emptyList()))
        assertFalse(
            "the bare report must not gain a separator or a trailing newline",
            buildReportCopyText(report, emptyList()).contains("\n\n"),
        )
    }

    @Test
    fun `non-empty journal is appended after one blank line`() {
        assertEquals(
            "$report\n\n${lines[0]}\n${lines[1]}",
            buildReportCopyText(report, lines),
        )
    }

    @Test
    fun `exactly one blank line separates the header from the journal`() {
        val text = buildReportCopyText(report, lines)
        assertFalse("there must be no double blank line", text.contains("\n\n\n"))
        assertEquals(1, Regex("\n\n").findAll(text).count())
    }

    @Test
    fun `journal order is preserved`() {
        val text = buildReportCopyText(report, lines)
        assertEquals(2, text.lines().size - report.lines().size - 1)
        assertEquals(lines[0], text.lines()[report.lines().size + 1])
        assertEquals(lines[1], text.lines()[report.lines().size + 2])
    }

    @Test
    fun `multi-line header is not distorted`() {
        assertEquals("H1\nH2\n\n${lines[0]}\n${lines[1]}", buildReportCopyText("H1\nH2", listOf(lines[0], lines[1])))
    }
}
