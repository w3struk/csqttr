package com.csqtt.client

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Блок `init` в [SettingsStore] поднимает сборщики кэша на `Dispatchers.Default`, и они читают
 * flow'и, объявленные свойствами класса. Kotlin присваивает свойства сверху вниз, поэтому блок
 * обязан идти после всех свойств: выше он успевал прочитать `null` и вызвать `collect` на `null` —
 * приложение падало при запуске и при рестарте сервиса (аппарат Redmi Note 15 / Redmi A5).
 *
 * Тест структурный: гонка в рантайме не воспроизводится надёжно, а порядок объявлений — это и есть
 * средство защиты.
 */
class SettingsStoreInitOrderTest {

    private val source: List<String> = listOf(
        File("app/src/main/java/com/csqtt/client/SettingsStore.kt"),
        File("src/main/java/com/csqtt/client/SettingsStore.kt"),
    ).first(File::isFile).readLines()

    @Test
    fun `the init block that starts the cache collectors comes after every property it reads`() {
        val property = Regex("""^    (private |internal )?(val|var) (\w+)""")
        val properties = source.withIndex()
            .mapNotNull { (i, line) -> property.find(line)?.let { it.groupValues[3] to i } }
            .toMap()

        val init = source.indexOfFirst { it == "    init {" }
        assertTrue("в SettingsStore нет блока init", init >= 0)
        val end = (init until source.size).first { source[it] == "    }" }

        val collected = Regex("""launch \{ (\w+)\.collect""")
            .findAll(source.subList(init, end).joinToString("\n"))
            .map { it.groupValues[1] }
            .toList()
        assertTrue("блок init больше не поднимает сборщики кэша", collected.size >= 20)

        for (name in collected) {
            val at = properties[name]
            assertTrue("$name не является свойством SettingsStore", at != null)
            assertTrue(
                "$name объявлен после блока init, который его собирает (null при сборе)",
                at!! < init,
            )
        }
    }

    @Test
    fun `no property is declared after the init block`() {
        val property = Regex("""^    (private |internal )?(val|var) (\w+)""")
        val init = source.indexOfFirst { it == "    init {" }
        assertTrue("в SettingsStore нет блока init", init >= 0)

        val after = source.withIndex()
            .filter { (i, line) -> i > init && property.containsMatchIn(line) }
            .map { (i, line) -> property.find(line)!!.groupValues[3] }
        assertTrue("свойства объявлены после блока init: $after", after.isEmpty())
    }
}
