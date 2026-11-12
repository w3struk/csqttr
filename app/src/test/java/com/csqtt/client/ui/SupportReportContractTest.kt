package com.csqtt.client.ui

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source contract for the support report living in its own file.
 *
 * The report builder moved out of `CsqttActionsCard.kt` into `SupportReport.kt` so the
 * settings card no longer owns it, and the report row is gone from the actions card: the
 * logs tab copy button now emits the report together with the journal. Paths resolve to the
 * Gradle module directory first and to the repository root second, matching
 * [DeployRemovalContractTest]. Tokens are assembled from fragments so this contract does not
 * trip the repository-wide grep for the retired names.
 */
class SupportReportContractTest {
    private fun readModuleSource(relativePath: String): String =
        listOf(
            File("app/$relativePath"),
            File(relativePath),
        ).first(File::isFile).readText()

    private fun assertAbsent(fileName: String, source: String, vararg forbidden: String) {
        forbidden.forEach { token ->
            assertFalse("$fileName must not contain `$token`", source.contains(token))
        }
    }

    @Test
    fun `actions card no longer builds or copies the report`() {
        assertAbsent(
            "CsqttActionsCard.kt",
            readModuleSource("src/main/java/com/csqtt/client/ui/CsqttActionsCard.kt"),
            "Собрать " + "отчёт",
            "buildSupport" + "Report",
            "Clipboard" + "Manager",
            "Clip" + "Data",
        )
    }

    @Test
    fun `report builder lives in its own file`() {
        val source = readModuleSource("src/main/java/com/csqtt/client/ui/SupportReport.kt")
        assertTrue(
            "SupportReport.kt must define buildSupportReport",
            source.contains("fun buildSupport" + "Report("),
        )
        assertTrue(
            "SupportReport.kt must define buildReportCopyText",
            source.contains("fun buildReport" + "CopyText("),
        )
    }

    @Test
    fun `logs tab copies the report together with the journal`() {
        val tab = readModuleSource("src/main/java/com/csqtt/client/ui/LogsTab.kt")
        assertTrue(
            "LogsTab.kt must use the report copy builder",
            tab.contains("buildReport" + "CopyText("),
        )
        assertTrue(
            "LogsTab.kt must append the support report",
            tab.contains("buildSupport" + "Report()"),
        )
        assertTrue(
            "LogsTab.kt must keep the copy action label",
            tab.contains("action" + "_copy_report"),
        )
        assertTrue(
            "LogsTab.kt must size the copy button to a full touch target",
            tab.contains("CsqttSizes." + "MinimumTouchTarget"),
        )
        val copyBlock = tab.substring(
            tab.indexOf("buildReport" + "CopyText("),
            tab.indexOf("Icons.Outlined." + "ContentCopy"),
        )
        assertFalse(
            "LogsTab.kt must keep the copy button enabled on an empty journal",
            copyBlock.contains("enabled ="),
        )
        assertTrue(
            "LogsTab.kt must disable the clear button on an empty journal",
            tab.contains("enabled = currentLogs" + ".isNotEmpty()"),
        )
    }

    @Test
    fun `strings replace the retired copy labels`() {
        val strings = readModuleSource("src/main/res/values/strings.xml")
        assertAbsent(
            "strings.xml",
            strings,
            "name=\"" + "action" + "_copy" + "\"",
            "name=\"" + "logs" + "_copied" + "\"",
        )
        listOf(
            "action" + "_copy_report",
            "logs_report" + "_copied",
            "report" + "_copied",
        ).forEach { name ->
            assertTrue(
                "strings.xml must declare `$name`",
                strings.contains("name=\"$name\""),
            )
        }
    }
}
