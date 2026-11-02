package com.csqtt.client

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Импорт конфигурации из файла/буфера раньше печатал безусловное «Конфигурация успешно
 * импортирована ✓», хотя в JSON может прийти `csqtt_link_mode=true` — импорт переключает
 * роль на «Участника» и прячет вкладку «Деплой». Пользователь должен узнать об этом из тоста.
 *
 * Сами решения и тексты проверяет [LinkSaveNoticeTest]; здесь — только то, что диалог
 * действительно делегирует сообщение политике и читает роль до и после импорта.
 */
class LinkImportNoticeTest {

    private fun readSource(vararg candidates: String): String =
        candidates.map(::File).first(File::isFile).readText()

    private val importExportDialogSource: String by lazy {
        readSource(
            "app/src/main/java/com/csqtt/client/ui/dialogs/ImportExportDialog.kt",
            "src/main/java/com/csqtt/client/ui/dialogs/ImportExportDialog.kt",
        )
    }

    @Test
    fun `import dialog delegates the message to LinkSaveNotice`() {
        assertTrue(
            "ImportExportDialog не использует LinkSaveNotice",
            importExportDialogSource.contains("LinkSaveNotice"),
        )
        assertTrue(
            "ImportExportDialog не считает исход импорта через outcomeForImport",
            importExportDialogSource.contains("outcomeForImport"),
        )
    }

    @Test
    fun `import dialog no longer prints its own unconditional success toast`() {
        assertFalse(
            "ImportExportDialog всё ещё печатает безусловный тост об успешном импорте",
            importExportDialogSource.contains("Конфигурация успешно импортирована ✓"),
        )
    }

    @Test
    fun `import dialog reads the role both before and after the import`() {
        assertEquals(
            "роль должна читаться до и после импорта (csqttLinkMode.first())",
            2,
            Regex("""csqttLinkMode\.first\(\)""").findAll(importExportDialogSource).count(),
        )
    }
}
