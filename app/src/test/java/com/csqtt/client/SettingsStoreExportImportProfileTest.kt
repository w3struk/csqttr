package com.csqtt.client

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Экспорт и импорт настроек работают с АКТИВНЫМ профилем, а не с базовыми ключами
 * (базовые ключи — это профиль 0, какой бы профиль ни был активен), и не выносят
 * учётные данные VK.
 *
 * Проверка структурная: `SettingsStore` работает с `DataStore` и `Context`, которые на JVM
 * недоступны, поэтому порядок и форма обращений к ключам проверяются по исходнику — так же,
 * как в [SettingsStoreInitOrderTest].
 */
class SettingsStoreExportImportProfileTest {

    private val source: List<String> = listOf(
        File("app/src/main/java/com/csqtt/client/SettingsStore.kt"),
        File("src/main/java/com/csqtt/client/SettingsStore.kt"),
    ).first(File::isFile).readLines()

    private fun bodyOf(function: String): String {
        val start = source.indexOfFirst { it.contains("suspend fun $function(") }
        assertTrue("в SettingsStore нет функции $function", start >= 0)
        val end = (start until source.size).first { source[it] == "    }" }
        return source.subList(start, end).joinToString("\n")
    }

    private val exportBody: String get() = bodyOf("exportConfigJson")
    private val importBody: String get() = bodyOf("importConfigJson")

    /** Ключи, которые живут в профиле: базовый ключ — это всегда профиль 0. */
    private val profileKeys = listOf(
        "PEER", "LISTEN_PORT", "MANUAL_PORTS_ENABLED", "SERVER_PEER_PORT", "OBFS_MODE",
        "TURN_TRANSPORT", "SRTP_MODE", "CUSTOM_TURN_IPS", "SNI", "NO_DNS",
        "DEPLOY_IP", "DEPLOY_LOGIN", "DEPLOY_SSH_PORT", "SERVER_WEB_PORT", "DOCKER_INSTALL",
        "SSH_KEYS_MODE", "VK_HASHES", "SECONDARY_VK_HASH", "VK_AUTH_MODE", "VK_HASH_MODE",
        "WORKERS_PER_HASH", "EXTRA_WORKERS", "CSQTT_LINK", "CSQTT_LINK_MODE",
        "EXCLUDED_APPS", "WHITELIST_APPS", "IS_WHITELIST", "DOMAIN_ROUTING_ENABLED",
        "DOMAIN_IS_WHITELIST", "EXCLUDE_RU_ZONES_ENABLED", "TEMPLATE_DOMAINS_ENABLED",
        "DIRECT_DOMAINS_BLACK", "DIRECT_DOMAINS", "DIRECT_DOMAINS_WHITE", "IP_ROUTING_ENABLED",
        "IP_IS_WHITELIST", "DIRECT_IPS_BLACK", "DIRECT_IPS_WHITE",
        "SELECTED_FINGERPRINT", "SELECTED_TURN_SUBNET", "TURN_SUBNET_IP_LIMIT",
        "PARTICIPANT_SHOW_LOGS",
    )

    @Test
    fun `export reads per profile keys through getProfileKey`() {
        assertTrue("экспорт не вычисляет активный профиль", exportBody.contains("val p = prefs[ACTIVE_PROFILE] ?: 0"))
        for (key in profileKeys) {
            assertFalse(
                "экспорт читает базовый ключ $key вместо ключа профиля",
                Regex("""prefs\[$key\]""").containsMatchIn(exportBody),
            )
        }
        assertTrue(
            "экспорт должен брать ключи профиля через getProfileKey",
            exportBody.contains("prefs[getProfileKey(PEER, p)]"),
        )
    }

    @Test
    fun `import writes per profile keys through getProfileKey`() {
        assertTrue("импорт не вычисляет активный профиль", importBody.contains("val p = mutable[ACTIVE_PROFILE] ?: 0"))
        for (key in profileKeys) {
            assertFalse(
                "импорт пишет базовый ключ $key вместо ключа профиля",
                Regex("""mutable\[$key]""").containsMatchIn(importBody),
            )
        }
        assertTrue(
            "импорт должен писать ключи профиля через getProfileKey",
            importBody.contains("mutable[getProfileKey(PEER, p)]"),
        )
    }

    @Test
    fun `global settings stay global`() {
        // тема, логи и пауза по Wi-Fi — общие для всех профилей
        for (key in listOf("THEME_MODE", "IS_DYNAMIC_COLOR", "THEME_PALETTE", "AUTO_PAUSE_ON_WIFI", "LOGGING_ENABLED", "DETAILED_LOGS")) {
            assertTrue(
                "ключ $key должен остаться общим, а не профильным",
                Regex("""(prefs|mutable)\[$key]""").containsMatchIn(exportBody + importBody),
            )
        }
    }

    @Test
    fun `the export does not carry the VK access token`() {
        assertFalse(
            "экспорт не должен уносить токен доступа VK",
            exportBody.contains("""put("vk_access_token""""),
        )
    }

    @Test
    fun `a blank password or token in an import leaves the stored one alone`() {
        assertTrue(
            "пустой пароль не должен затирать сохранённый",
            importBody.contains("if (pw.isNotBlank())"),
        )
        assertTrue(
            "пустой токен не должен затирать сохранённый",
            importBody.contains("""takeIf { it.isNotBlank() }"""),
        )
    }
}
