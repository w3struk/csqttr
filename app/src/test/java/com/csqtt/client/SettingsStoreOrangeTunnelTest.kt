package com.csqtt.client

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Список оранжевых приложений, которым пользователь разрешил идти в туннель, — настройка
 * ГЛОБАЛЬНАЯ: пресет приходит с серверного правила и к профилям отношения не имеет. Ключ,
 * прошедший через `getProfileKey`, получил бы суффикс профиля и «переезжал» бы вместе с ним.
 *
 * Проверка структурная: `SettingsStore` работает с `DataStore` и `Context`, которые на JVM
 * недоступны, поэтому объявления и форма обращений к ключу проверяются по исходнику — так же,
 * как в [SettingsStoreInitOrderTest] и [SettingsStoreExportImportProfileTest].
 */
class SettingsStoreOrangeTunnelTest {

    private val source: List<String> = listOf(
        File("app/src/main/java/com/csqtt/client/SettingsStore.kt"),
        File("src/main/java/com/csqtt/client/SettingsStore.kt"),
    ).first(File::isFile).readLines()

    /** Тело объявления по его первой строке: до закрывающей `}` на том же отступе. */
    private fun bodyOf(declaration: (String) -> Boolean, what: String): String {
        val start = source.indexOfFirst(declaration)
        assertTrue("в SettingsStore нет $what", start >= 0)
        val indent = source[start].takeWhile { it == ' ' }
        val end = (start until source.size).first { source[it] == indent + "}" }
        return source.subList(start, end + 1).joinToString("\n")
    }

    private val getProfileKeyBody: String
        get() = bodyOf({ it.contains("private fun <T> getProfileKey(") }, "функции getProfileKey")
    private val exportBody: String
        get() = bodyOf({ it.contains("suspend fun exportConfigJson(") }, "функции exportConfigJson")
    private val importBody: String
        get() = bodyOf({ it.contains("suspend fun importConfigJson(") }, "функции importConfigJson")

    @Test
    fun `the orange tunnel key is global and stored as a comma string`() {
        assertTrue(
            "в Keys нет глобального ключа orange_tunnel_enabled",
            source.any { it.trim() == """private val ORANGE_TUNNEL_ENABLED = stringPreferencesKey("orange_tunnel_enabled")""" },
        )
        assertFalse(
            "ORANGE_TUNNEL_ENABLED попал в when-список профильных ключей",
            Regex("""ORANGE_TUNNEL_ENABLED""").containsMatchIn(getProfileKeyBody),
        )
        assertFalse(
            "ORANGE_TUNNEL_ENABLED проходит через getProfileKey и получит суффикс профиля",
            Regex("""getProfileKey\(\s*ORANGE_TUNNEL_ENABLED""").containsMatchIn(source.joinToString("\n")),
        )
        assertTrue(
            "нет flow'а orangeTunnelEnabled с пустой строкой по умолчанию",
            source.any { it.trim() == """val orangeTunnelEnabled: Flow<String> = dataStore.data.map { it[ORANGE_TUNNEL_ENABLED] ?: "" }""" },
        )
        assertTrue(
            "нет сохранения списка как строки через запятую",
            Regex(
                """suspend fun saveOrangeTunnelEnabled\(packages: String\) \{[\s\S]*?prefs\[ORANGE_TUNNEL_ENABLED\] = packages"""
            ).containsMatchIn(source.joinToString("\n")),
        )
    }

    @Test
    fun `the orange tunnel flow is cached in init like the other settings`() {
        val init = source.indexOfFirst { it == "    init {" }
        assertTrue("в SettingsStore нет блока init", init >= 0)
        val end = (init until source.size).first { source[it] == "    }" }
        val initBody = source.subList(init, end).joinToString("\n")

        assertTrue(
            "блок init не кэширует orangeTunnelEnabled",
            Regex("""launch \{ orangeTunnelEnabled\.collect \{ cachedOrangeTunnelEnabled = it \} \}""")
                .containsMatchIn(initBody),
        )

        val declaredAt = source.indexOfFirst { it.trim() == "internal var cachedOrangeTunnelEnabled: String? = null" }
        assertTrue("cachedOrangeTunnelEnabled не объявлен", declaredAt >= 0)
        assertTrue(
            "cachedOrangeTunnelEnabled объявлен после блока init, который его собирает (null при сборе)",
            declaredAt < init,
        )
    }

    @Test
    fun `the orange tunnel key is not exported with the profile settings`() {
        assertFalse(
            "экспорт не должен уносить глобальный список оранжевых приложений",
            exportBody.contains("ORANGE_TUNNEL_ENABLED"),
        )
        assertFalse(
            "импорт не должен перезаписывать глобальный список оранжевых приложений",
            importBody.contains("ORANGE_TUNNEL_ENABLED"),
        )
    }
}
