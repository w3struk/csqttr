package com.csqtt.client

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Прежняя легаси-миграция (2.5.0/2.5.1) в белом профиле писала в `EXCLUDED_APPS`
 * «все установленные минус старый белый список» и всегда ставила
 * `SPLIT_TUNNEL_WHITELIST_MIGRATED = true`. Новая миграция выходит по этому
 * флагу, поэтому чинит данные отдельный одноразовый проход под собственным
 * ключом.
 *
 * Как и в [SettingsStoreLegacyAppListsTest], само решение проверяется на чистой
 * [LegacyAppListsMigration], а форма вызова — по исходнику [SettingsStore]:
 * DataStore на JVM недоступен.
 */
class SettingsStoreInvertedBlacklistRepairTest {

    private val source: List<String> = listOf(
        File("app/src/main/java/com/csqtt/client/SettingsStore.kt"),
        File("src/main/java/com/csqtt/client/SettingsStore.kt"),
    ).first(File::isFile).readLines()

    private val migrationBody: String
        get() {
            val start = source.indexOfFirst { it.contains("suspend fun repairInvertedLocalBlacklist(") }
            assertTrue("в SettingsStore нет repairInvertedLocalBlacklist", start >= 0)
            val end = (start until source.size).first { source[it] == "    }" }
            return source.subList(start, end).joinToString("\n")
        }

    @Test
    fun `a white profile loses the black branch`() {
        val repaired = LegacyAppListsMigration.repairedBlacklist(
            isWhitelist = true,
            black = "com.android.chrome,org.telegram.messenger",
        )

        assertEquals("синтезированный чёрный список очищается", "", repaired)
    }

    @Test
    fun `a black profile keeps its user-owned black list`() {
        val repaired = LegacyAppListsMigration.repairedBlacklist(
            isWhitelist = false,
            black = "com.android.chrome",
        )

        assertNull("ветка чёрного профиля не трогается", repaired)
    }

    @Test
    fun `a second run changes nothing`() {
        val once = LegacyAppListsMigration.repairedBlacklist(true, "com.android.chrome")
        val twice = LegacyAppListsMigration.repairedBlacklist(true, once)

        assertEquals("первый проход очищает синтезированную ветку", "", once)
        assertNull("повторный проход уже нечего чинить — ветка не трогается", twice)
    }

    @Test
    fun `the repair is gated by its own key and only clears white profiles`() {
        assertTrue(
            "ремонт идёт под отдельным ключом",
            migrationBody.contains("SPLIT_TUNNEL_INVERTED_LIST_REPAIRED"),
        )
        assertFalse(
            "старый ключ миграции не переиспользуется как гейт",
            migrationBody.contains("SPLIT_TUNNEL_WHITELIST_MIGRATED"),
        )
        assertTrue(
            "до данных проход доходит только при белом режиме профиля",
            migrationBody.contains("isWhitelist = prefs[whitelistKey] == true"),
        )
        assertTrue(
            "решение принимает чистая функция",
            migrationBody.contains("LegacyAppListsMigration.repairedBlacklist"),
        )
        assertTrue(
            "повторный запуск закрыт флагом",
            migrationBody.contains("SPLIT_TUNNEL_INVERTED_LIST_REPAIRED] == true) return@edit"),
        )
    }
}
