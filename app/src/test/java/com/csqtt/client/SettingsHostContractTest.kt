package com.csqtt.client

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Source contract for consolidating the settings UI.
 *
 * The paths are resolved relative to the Gradle module directory first and to the
 * repository root second, matching the convention of [DeployRemovalContractTest].
 */
class SettingsHostContractTest {
    private fun readModuleSource(relativePath: String): String =
        listOf(
            File("app/$relativePath"),
            File(relativePath),
        ).first(File::isFile).readText()

    private fun moduleFileExists(relativePath: String): Boolean =
        listOf(
            File("app/$relativePath"),
            File(relativePath),
        ).any(File::isFile)

    private fun assertAbsent(fileName: String, source: String, vararg forbidden: String) {
        forbidden.forEach { token ->
            assertFalse("$fileName must not contain `$token`", source.contains(token))
        }
    }

    // --- B1/B2: общие настройки вынесены из модалки на вкладку ------------

    @Test
    fun `general settings content owns the former dialog controls`() {
        assertTrue(
            "GeneralSettingsContent.kt отсутствует",
            moduleFileExists("src/main/java/com/csqtt/client/ui/GeneralSettingsContent.kt"),
        )
        val content = readModuleSource("src/main/java/com/csqtt/client/ui/GeneralSettingsContent.kt")
        listOf(
            "Основные параметры",
            "CompactDropdownSetting",
            "Показывать логи",
            "Выбор TURN-подсетей",
        ).forEach { token ->
            assertTrue("GeneralSettingsContent.kt must contain `$token`", content.contains(token))
        }
        assertAbsent("GeneralSettingsContent.kt", content, "CsqttActionsCard")
    }

    @Test
    fun `settings tab hosts the general settings content`() {
        val tab = readModuleSource("src/main/java/com/csqtt/client/ui/GeneralSettingsTab.kt")
        assertTrue(
            "GeneralSettingsTab.kt не вызывает GeneralSettingsContent",
            tab.contains("GeneralSettingsContent("),
        )
    }

    @Test
    fun `settings tab renders the actions footer after the routing card`() {
        val tab = readModuleSource("src/main/java/com/csqtt/client/ui/GeneralSettingsTab.kt")
        val general = tab.indexOf("GeneralSettingsContent(")
        val routing = tab.indexOf("AppRoutingSection(")
        val actions = tab.indexOf("CsqttActionsCard(")
        assertTrue("GeneralSettingsTab.kt не вызывает GeneralSettingsContent", general >= 0)
        assertTrue("GeneralSettingsTab.kt не вызывает AppRoutingSection", routing >= 0)
        assertTrue("GeneralSettingsTab.kt не рендерит CsqttActionsCard", actions >= 0)
        assertTrue(
            "CsqttActionsCard должен идти после AppRoutingSection (general=$general, routing=$routing, actions=$actions)",
            general < routing && routing < actions,
        )
    }

    @Test
    fun `settings tab does not carry a title that shifts the header`() {
        val tab = readModuleSource("src/main/java/com/csqtt/client/ui/GeneralSettingsTab.kt")
        assertAbsent("GeneralSettingsTab.kt", tab, "CsqttScreen(title")
    }

    @Test
    fun `turn subnets button matches the app list button styling`() {
        val content = readModuleSource("src/main/java/com/csqtt/client/ui/GeneralSettingsContent.kt")
        listOf(
            "Icons.Outlined.AltRoute",
            "material.icons.outlined.AltRoute",
            "MaterialTheme.colorScheme.outline.copy(alpha = 0.5f)",
            "Modifier.size(18.dp)",
            "Spacer(Modifier.width(8.dp))",
            "padding(top = 4.dp, bottom = 4.dp)",
        ).forEach { token ->
            assertTrue("кнопка TURN не содержит `$token`", content.contains(token))
        }
    }

    @Test
    fun `profile dialog uses a labelled close and a neutral clear action`() {
        val tab = readModuleSource("src/main/java/com/csqtt/client/ui/GeneralSettingsTab.kt")
        assertTrue(
            "крестик диалога не занимает минимальную touch-цель",
            tab.contains("Modifier.size(CsqttSizes.MinimumTouchTarget)"),
        )
        assertTrue("крестик диалога без подписи «Закрыть»", tab.contains("contentDescription = \"Закрыть\""))
        assertAbsent("GeneralSettingsTab.kt", tab, "Icons.Default.Delete", "colorScheme.error")
    }

    @Test
    fun `main activity wires the settings tab instead of the routing tab`() {
        val activity = readModuleSource("src/main/java/com/csqtt/client/MainActivity.kt")
        assertTrue("MainActivity не подписывает вкладку 3 как «Настройки»",
            activity.contains("R.string.nav_settings"))
        assertTrue("MainActivity не вызывает GeneralSettingsTab",
            activity.contains("GeneralSettingsTab"))
        assertAbsent("MainActivity.kt", activity, "R.string.nav_exceptions", "ExceptionsTab")
    }

    @Test
    fun `header toolbar is reduced to the qr action`() {
        val toolbar = readModuleSource("src/main/java/com/csqtt/client/ui/FloatingToolbar.kt")
        assertAbsent(
            "FloatingToolbar.kt",
            toolbar,
            "ic_settings_gear",
            "quick_settings",
            "CompactDropdownSetting",
            "CsqttActionsCard",
            "editingProfileIndex",
            "WifiAutoPauseInfoDialog",
            "TurnSubnetsDialog",
            "isDarkTheme",
            "settingsIconTint",
            "luminance()",
        )
        listOf("QrScannerDialog", "LinkSaveNotice").forEach { token ->
            assertTrue("FloatingToolbar.kt must still contain `$token`", toolbar.contains(token))
        }
        assertTrue(
            "QR-кнопка не занимает минимальную touch-цель",
            toolbar.contains(".size(CsqttSizes.MinimumTouchTarget)"),
        )
        assertTrue(
            "иконка QR не использует нейтральный тинт темы",
            toolbar.contains("tint = MaterialTheme.colorScheme.onSurface"),
        )
    }

    @Test
    fun `settings dialogs moved to the settings tab`() {
        val tab = readModuleSource("src/main/java/com/csqtt/client/ui/GeneralSettingsTab.kt")
        listOf(
            "WifiAutoPauseInfoDialog",
            "TurnSubnetsDialog",
            "saveProfileName",
        ).forEach { token ->
            assertTrue("GeneralSettingsTab.kt must contain `$token`", tab.contains(token))
        }
    }

    @Test
    fun `navigation strings call tab three settings`() {
        val strings = readModuleSource("src/main/res/values/strings.xml")
        assertTrue(
            "strings.xml must contain nav_settings=Настройки",
            strings.contains("name=\"nav_settings\">Настройки<"),
        )
    }

    // --- B3: маршрутизация приложений внутри вкладки -----------------------

    @Test
    fun `exceptions tab file is gone`() {
        assertFalse(
            "ExceptionsTab.kt всё ещё существует",
            moduleFileExists("src/main/java/com/csqtt/client/ui/ExceptionsTab.kt"),
        )
    }

    @Test
    fun `settings tab hosts the app routing section`() {
        val tab = readModuleSource("src/main/java/com/csqtt/client/ui/GeneralSettingsTab.kt")
        listOf("AppRoutingSection(", "serverRoutingActive").forEach { token ->
            assertTrue("GeneralSettingsTab.kt must contain `$token`", tab.contains(token))
        }
    }

    @Test
    fun `app routing section keeps the dialog and persistence invariants`() {
        val section = readModuleSource("src/main/java/com/csqtt/client/ui/AppRoutingSection.kt")
        listOf(
            "Маршрутизация приложений",
            "Список приложений",
            "AppListDialog",
            "DisposableEffect",
            "appPersistenceScope",
            "orangeToggleMutex",
            "TunnelManager.reloadVpn",
        ).forEach { token ->
            assertTrue("AppRoutingSection.kt must contain `$token`", section.contains(token))
        }
    }

    // --- B4: тексты указывают на «Настройки» ------------------------------

    @Test
    fun `routing advice points at the settings tab`() {
        val policy = readModuleSource("src/main/java/com/csqtt/client/AppRoutingPolicy.kt")
        assertFalse("AppRoutingPolicy.kt всё ещё ссылается на «Маршрут»", policy.contains("«Маршрут»"))
        assertTrue("AppRoutingPolicy.kt не ссылается на «Настройки»", policy.contains("«Настройки»"))
        assertTrue(
            "совет по исключениям не ведёт в «Список приложений»",
            policy.contains("Снимите исключения: «Настройки» → «Список приложений»"),
        )
    }

    @Test
    fun `logs toggle receives its state instead of collecting the flow`() {
        val content = readModuleSource("src/main/java/com/csqtt/client/ui/GeneralSettingsContent.kt")
        assertFalse(
            "переключатель логов снова собирает flow и мигает при открытии вкладки",
            content.contains("settingsStore.participantShowLogs"),
        )
        assertTrue(
            "переключатель логов должен получать состояние параметром",
            content.contains("participantShowLogs: Boolean"),
        )
    }

    @Test
    fun `strings for the removed header dialog are gone`() {
        val strings = readModuleSource("src/main/res/values/strings.xml")
        assertAbsent("strings.xml", strings, "quick_settings", "action_close", "nav_exceptions")
        assertTrue(
            "strings.xml must contain nav_settings=Настройки",
            strings.contains("name=\"nav_settings\">Настройки<"),
        )
    }
}
