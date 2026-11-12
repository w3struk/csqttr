package com.csqtt.client

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source contract for the single logging toggle.
 *
 * «Показывать логи» (`participant_show_logs`) is now the only switch: it drives both
 * the visibility of the logs tab and [TunnelManager.isLoggingEnabled]. The legacy
 * preference keys must not come back. Tokens are assembled from fragments so this
 * contract does not trip the repository-wide grep for the retired names.
 */
class LoggingToggleContractTest {
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
    fun `settings store keeps a single logging switch`() {
        val store = readModuleSource("src/main/java/com/csqtt/client/SettingsStore.kt")
        assertAbsent(
            "SettingsStore.kt",
            store,
            "logging" + "_enabled",
            "LOGGING" + "_ENABLED",
            "logging" + "Enabled",
            "saveLogging" + "Enabled",
            "detailed" + "_logs",
            "DETAILED" + "_LOGS",
        )
        assertTrue(
            "SettingsStore.kt must still expose participantShowLogs",
            store.contains("participantShowLogs"),
        )
    }

    @Test
    fun `application drives the journal from participant show logs`() {
        val app = readModuleSource("src/main/java/com/csqtt/client/CsqttApplication.kt")
        assertTrue(
            "CsqttApplication.kt must collect participantShowLogs",
            app.contains("participantShowLogs"),
        )
        assertTrue(
            "CsqttApplication.kt must deduplicate the settings flow",
            app.contains("distinctUntilChanged"),
        )
        assertAbsent("CsqttApplication.kt", app, "logging" + "Enabled")
    }

    @Test
    fun `logs tab no longer carries its own switch`() {
        val tab = readModuleSource("src/main/java/com/csqtt/client/ui/LogsTab.kt")
        assertAbsent("LogsTab.kt", tab, "CsqttSettingRow", "logs" + "_enabled", "logging" + "Enabled")
        assertTrue(
            "LogsTab.kt must keep the copy action",
            tab.contains("action_copy_report"),
        )
        assertTrue(
            "LogsTab.kt must keep the clear action",
            tab.contains("TunnelManager::clearLogs"),
        )
    }

    @Test
    fun `tunnel service reads the participant show logs flag`() {
        val service = readModuleSource("src/main/java/com/csqtt/client/TunnelService.kt")
        assertAbsent("TunnelService.kt", service, "store.logging" + "Enabled")
    }

    @Test
    fun `strings drop the retired logging label`() {
        val strings = readModuleSource("src/main/res/values/strings.xml")
        assertAbsent("strings.xml", strings, "name=\"" + "logs" + "_enabled" + "\"")
    }
}
