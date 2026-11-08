package com.csqtt.client

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Пункт «Маршрут» убран из карточки «Импорт и Экспорт» вместе с переносом маршрутизации на
 * сервер: списки приложений резервирует отдельная карточка «Импорт и экспорт правил».
 *
 * Возврат ряда с таким чекбоксом в диалог раньше ничем не проверялся: правка собиралась (у
 * `exportConfigJson`/`importConfigJson` параметра для списков больше нет, так что ряд висел бы
 * на локальной переменной), юнит-тесты оставались зелёными, а пользователь видел пункт, который
 * ничего не делает. Поэтому проверка структурная — по исходнику диалога, как в
 * [LinkImportNoticeTest]. Проверяются только заголовки опций и форма обращений, не вёрстка:
 * перестановка строк местами или изменение отступов тест не ломают.
 */
class ImportExportDialogScopeTest {

    private fun readSource(vararg candidates: String): String =
        candidates.map(::File).first(File::isFile).readText()

    private val dialogSource: String by lazy {
        readSource(
            "app/src/main/java/com/csqtt/client/ui/dialogs/ImportExportDialog.kt",
            "src/main/java/com/csqtt/client/ui/dialogs/ImportExportDialog.kt",
        )
    }

    /** Заголовки строк выбора: вызовы `ConfigOptionRow` с их первым аргументом. */
    private val optionTitles: List<String>
        get() = Regex("""ConfigOptionRow\(\s*title = "([^"]+)"""")
            .findAll(dialogSource)
            .map { it.groupValues[1] }
            .toList()

    @Test
    fun `the dialog no longer offers the routing option`() {
        assertFalse(
            "диалог всё ещё хранит выбор по списку приложений",
            dialogSource.contains("includeExceptions"),
        )
        assertFalse(
            "диалог всё ещё рисует пункт «Маршрут»",
            dialogSource.contains("""title = "Маршрут""""),
        )
        assertFalse(
            "в диалоге остался ключ секции исключений",
            dialogSource.contains("\"exceptions\""),
        )
    }

    @Test
    fun `the dialog offers exactly the three remaining options`() {
        assertEquals(
            "в карточке должны остаться только три пункта выбора",
            setOf("Туннель", "Деплой", "Настройки"),
            optionTitles.toSet(),
        )
        // страховка от вакуума: регулярка обязана найти ровно три вызова, а не ноль
        assertEquals("число строк выбора в диалоге", 3, optionTitles.size)
    }

    @Test
    fun `every action button shares one selection guard`() {
        assertTrue(
            "выбор разделов должен считаться один раз в hasSelection",
            dialogSource.contains("val hasSelection = includeTunnel || includeDeploy || includeSettings"),
        )
        val all = Regex("""enabled = """).findAll(dialogSource).count()
        val shared = Regex("""enabled = !isProcessing && hasSelection""").findAll(dialogSource).count()
        // страховка от вакуума: иначе отсутствие предикатов читалось бы как успех
        assertTrue("в диалоге должно быть не меньше четырёх кнопок с предикатом enabled, найдено $all", all >= 4)
        assertEquals(
            "каждая кнопка обязана опираться на общий hasSelection, а не повторять выбор в четырёх местах",
            all,
            shared,
        )
    }
}
