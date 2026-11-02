package com.csqtt.client

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Явный выбор роли фиксируется в момент действия пользователя и не пересчитывается заново:
 * ввод ссылки участником пишет «Участника», сохранение собственных настроек — «Владельца».
 *
 * Проверка структурная: `SettingsStore` и `SettingsTab` работают с `DataStore` и `Context`,
 * которые на JVM недоступны, поэтому наличие ключей проверяется по исходникам — так же,
 * как в [SettingsStoreInitOrderTest] и [SettingsStoreExportImportProfileTest].
 */
class UsageRolePinningTest {

    private val storeSource: List<String> = readSource(
        "app/src/main/java/com/csqtt/client/SettingsStore.kt",
        "src/main/java/com/csqtt/client/SettingsStore.kt",
    )
    private val tabSource: List<String> = readSource(
        "app/src/main/java/com/csqtt/client/ui/SettingsTab.kt",
        "src/main/java/com/csqtt/client/ui/SettingsTab.kt",
    )

    private fun readSource(vararg candidates: String): List<String> =
        candidates.map(::File).first(File::isFile).readLines()

    /** Тела suspend-функций верхнего уровня класса (методы объявлены с отступом в 4 пробела). */
    private fun suspendFunctionBodies(source: List<String>): List<String> {
        val bodies = mutableListOf<String>()
        var index = 0
        while (index < source.size) {
            if (source[index].startsWith("    suspend fun ")) {
                val end = (index until source.size).first { source[it] == "    }" }
                bodies += source.subList(index, end + 1).joinToString("\n")
                index = end + 1
            } else {
                index++
            }
        }
        return bodies
    }

    @Test
    fun `link-only save is gone and participant link pins the role`() {
        assertFalse(
            "метод, пишущий ссылку без признака роли, не должен существовать",
            storeSource.any { it.contains("suspend fun saveCsqttLink(") },
        )

        val linkWriters = suspendFunctionBodies(storeSource).filter {
            it.contains("prefs[getProfileKey(CSQTT_LINK, profile)] =")
        }
        assertTrue("в SettingsStore не осталось ни одной записи CSQTT_LINK", linkWriters.isNotEmpty())
        for (body in linkWriters) {
            assertTrue(
                "функция пишет CSQTT_LINK, но не фиксирует CSQTT_LINK_MODE",
                body.contains("prefs[getProfileKey(CSQTT_LINK_MODE, profile)] ="),
            )
        }

        val participant = suspendFunctionBodies(storeSource)
            .firstOrNull { it.contains("suspend fun saveCsqttParticipantLink(") }
        assertTrue("нет функции saveCsqttParticipantLink", participant != null)
        val participantBody = participant ?: return
        assertTrue(
            "сохранение ссылки участником должно писать CSQTT_LINK",
            participantBody.contains("prefs[getProfileKey(CSQTT_LINK, profile)] = link"),
        )
        assertTrue(
            "сохранение ссылки участником должно фиксировать режим участника",
            participantBody.contains("prefs[getProfileKey(CSQTT_LINK_MODE, profile)] = true"),
        )
    }

    @Test
    fun `link editor saves as participant link`() {
        val body = tabSource.joinToString("\n")
        assertTrue(
            "редактор ссылки должен вызывать saveCsqttParticipantLink",
            body.contains("settingsStore.saveCsqttParticipantLink(linkText)"),
        )
        assertFalse(
            "редактор ссылки не должен вызывать saveCsqttLink",
            body.contains("settingsStore.saveCsqttLink("),
        )
    }

    @Test
    fun `owner save pins the owner role`() {
        val save = suspendFunctionBodies(storeSource)
            .firstOrNull { it.contains("suspend fun save(") }
        assertTrue("в SettingsStore нет функции save(", save != null)
        val body = save ?: return
        assertTrue(
            "сохранение собственных настроек должно фиксировать роль владельца",
            body.contains("prefs[getProfileKey(CSQTT_LINK_MODE, profile)] = false"),
        )
    }
}
