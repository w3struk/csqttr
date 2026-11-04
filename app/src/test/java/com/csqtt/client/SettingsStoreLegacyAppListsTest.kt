package com.csqtt.client

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Легаси-настройка хранила один список приложений в `EXCLUDED_APPS`
 * независимо от режима: в белом режиме там был белый список. Новая настройка
 * читает только список того режима, который задаёт правило, поэтому миграция
 * обязана оставить старый список в его ветке, а противоположную — пустой:
 * синтез «всё установленное минус старый список» под чёрным правилом
 * прочитался бы как настоящий чёрный список.
 *
 * Поведение проверяется на чистой [LegacyAppListsMigration], которую вызывает
 * [SettingsStore]; сама миграция работает с DataStore и на JVM недоступна,
 * поэтому форма её вызова проверяется по исходнику — как в
 * [SettingsStoreInitOrderTest].
 */
class SettingsStoreLegacyAppListsTest {

    private val source: List<String> = listOf(
        File("app/src/main/java/com/csqtt/client/SettingsStore.kt"),
        File("src/main/java/com/csqtt/client/SettingsStore.kt"),
    ).first(File::isFile).readLines()

    private val migrationBody: String
        get() {
            val start = source.indexOfFirst { it.contains("suspend fun migrateLegacyWhitelistMode(") }
            assertTrue("в SettingsStore нет migrateLegacyWhitelistMode", start >= 0)
            val end = (start until source.size).first { source[it] == "    }" }
            return source.subList(start, end).joinToString("\n")
        }

    @Test
    fun `a legacy white list moves to the white branch and leaves the black branch empty`() {
        val migrated = LegacyAppListsMigration.fromLegacyWhiteList("com.vpn,org.telegram.messenger")

        assertEquals("противоположная ветка пуста", "", migrated.black)
        assertEquals(
            "старый список остаётся в ветке своего режима",
            "com.vpn,org.telegram.messenger",
            migrated.white,
        )
    }

    @Test
    fun `an empty legacy list yields two empty branches`() {
        val migrated = LegacyAppListsMigration.fromLegacyWhiteList(null)

        assertEquals("чёрная ветка пуста", "", migrated.black)
        assertEquals("белая ветка пуста", "", migrated.white)
    }

    @Test
    fun `the migration never synthesizes the opposite list from installed apps`() {
        assertFalse(
            "миграция снова перечисляет установленные приложения",
            migrationBody.contains("PackageManager") ||
                migrationBody.contains("getInstalledApplications") ||
                migrationBody.contains("installedSplitTunnelPackages"),
        )
        assertTrue(
            "старый список переносится в белую ветку",
            migrationBody.contains("LegacyAppListsMigration.fromLegacyWhiteList"),
        )
        assertTrue(
            "чёрная ветка получает пустое значение из переноса",
            migrationBody.contains("prefs[appsKey] = migrated.black"),
        )
        assertTrue(
            "уже заполненная белая ветка не перезаписывается",
            migrationBody.contains("prefs[whitelistAppsKey] == null"),
        )
    }
}
