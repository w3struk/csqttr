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

    /**
     * Тело функции по её сигнатуре: до первой строки, ровно равной `    }`.
     *
     * Ограничение парсера: `    }` — это не только закрывающая скобка функции, но и любая
     * валидная конструкция с таким же отступом внутри тела (например `run { … }`, закрытый с
     * четырьмя пробелами). Такая скобка перед проверяемым кодом молча усекает тело, и все
     * негативные ассерты проходят вакуумом — поэтому тело дополнительно удостоверяется
     * стражем [assertBodiesAreComplete].
     */
    private fun bodyOf(function: String): String {
        val start = source.indexOfFirst { it.contains("suspend fun $function(") }
        assertTrue("в SettingsStore нет функции $function", start >= 0)
        val end = (start until source.size).first { source[it] == "    }" }
        return source.subList(start, end).joinToString("\n")
    }

    /**
     * Страж полноты тела: если парсер дочитал функцию до конца, её последние характерные
     * строки обязаны остаться в теле. Не даёт негативным проверкам «проходиться по пустоте».
     */
    private fun assertBodiesAreComplete() {
        assertTrue(
            "тело exportConfigJson усечено парсером — негативные проверки бессмысленны",
            exportBody.contains("return root.toString(2)"),
        )
        assertTrue(
            "тело importConfigJson усечено парсером — негативные проверки бессмысленны",
            importBody.contains("}.getOrDefault(false)"),
        )
    }

    private val exportBody: String get() = bodyOf("exportConfigJson")
    private val importBody: String get() = bodyOf("importConfigJson")

    /** Ключи профиля, которые экспорт и импорт реально переносят: базовый ключ — это всегда профиль 0. */
    private val profileKeys = listOf(
        "PEER", "LISTEN_PORT", "MANUAL_PORTS_ENABLED", "SERVER_PEER_PORT", "OBFS_MODE",
        "TURN_TRANSPORT", "SRTP_MODE", "CUSTOM_TURN_IPS", "SNI", "NO_DNS",
        "DEPLOY_IP", "DEPLOY_LOGIN", "DEPLOY_SSH_PORT", "SERVER_WEB_PORT", "DOCKER_INSTALL",
        "SSH_KEYS_MODE", "VK_HASHES", "SECONDARY_VK_HASH", "VK_AUTH_MODE", "VK_HASH_MODE",
        "WORKERS_PER_HASH", "EXTRA_WORKERS", "CSQTT_LINK", "CSQTT_LINK_MODE",
        "SELECTED_FINGERPRINT", "SELECTED_TURN_SUBNET", "TURN_SUBNET_IP_LIMIT",
        "PARTICIPANT_SHOW_LOGS",
    )

    @Test
    fun `export reads per profile keys through getProfileKey`() {
        assertBodiesAreComplete()
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
        assertBodiesAreComplete()
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
        assertBodiesAreComplete()
        assertFalse(
            "экспорт не должен уносить токен доступа VK",
            exportBody.contains("""put("vk_access_token""""),
        )
    }

    @Test
    fun `the export and import no longer carry domain or IP settings`() {
        assertBodiesAreComplete()
        val removed = listOf(
            "DOMAIN_ROUTING_ENABLED", "DOMAIN_IS_WHITELIST", "TEMPLATE_DOMAINS_ENABLED",
            "DIRECT_DOMAINS", "DIRECT_DOMAINS_BLACK", "DIRECT_DOMAINS_WHITE",
            "IP_ROUTING_ENABLED", "IP_IS_WHITELIST", "DIRECT_IPS_BLACK", "DIRECT_IPS_WHITE",
        )
        for (key in removed) {
            assertFalse("экспорт всё ещё переносит $key", exportBody.contains(key))
            assertFalse("импорт всё ещё переносит $key", importBody.contains(key))
        }
        for (jsonName in listOf(
            "domain_routing_enabled", "domain_is_whitelist", "template_domains_enabled",
            "direct_domains", "direct_ips",
            "ip_routing_enabled", "ip_is_whitelist", "direct_ips_black", "direct_ips_white",
        )) {
            assertFalse("экспорт всё ещё пишет $jsonName", exportBody.contains("\"$jsonName\""))
            assertFalse("импорт всё ещё читает $jsonName", importBody.contains("\"$jsonName\""))
        }
    }

    @Test
    fun `the export and import no longer carry the app lists`() {
        assertBodiesAreComplete()
        // Списки приложений резервируются отдельно — карточка «Импорт и экспорт правил» со своим
        // форматом version:2. Пункт «Маршрут» из карточки «Импорт и Экспорт» убран вместе с
        // переносом маршрутизации на сервер.
        for (key in listOf("EXCLUDED_APPS", "WHITELIST_APPS", "IS_WHITELIST")) {
            assertFalse("экспорт всё ещё переносит $key", exportBody.contains(key))
            assertFalse("импорт всё ещё переносит $key", importBody.contains(key))
        }
        for (jsonName in listOf("exceptions", "excluded_apps", "whitelist_apps", "is_whitelist")) {
            assertFalse("экспорт всё ещё пишет $jsonName", exportBody.contains("\"$jsonName\""))
            assertFalse("импорт всё ещё читает $jsonName", importBody.contains("\"$jsonName\""))
        }
        assertFalse(
            "экспорт всё ещё принимает параметр includeExceptions",
            exportBody.contains("includeExceptions"),
        )
        assertFalse(
            "импорт всё ещё принимает параметр includeExceptions",
            importBody.contains("includeExceptions"),
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
