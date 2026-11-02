package com.csqtt.client

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Сообщения о сохранении ссылки CSQTT должны быть правдивыми: на свежей установке
 * профиль пуст и роль уже «Участник» ([UsageRolePolicy]), поэтому «Режим участника
 * включён» допустим только при фактической смене роли. Смена несимметрична —
 * «участник → владелец» и «владелец → участник» сообщаются по-разному.
 *
 * Здесь проверяются и решения [LinkSaveNotice], и точные тексты, и то, что экраны
 * больше не печатают собственные безусловные тосты.
 */
class LinkSaveNoticeTest {

    private fun readSource(vararg candidates: String): String =
        candidates.map(::File).first(File::isFile).readText()

    private val floatingToolbarSource: String by lazy {
        readSource(
            "app/src/main/java/com/csqtt/client/ui/FloatingToolbar.kt",
            "src/main/java/com/csqtt/client/ui/FloatingToolbar.kt",
        )
    }

    private val mainActivitySource: String by lazy {
        readSource(
            "app/src/main/java/com/csqtt/client/MainActivity.kt",
            "src/main/java/com/csqtt/client/MainActivity.kt",
        )
    }

    // --- Матрица решений -------------------------------------------------

    @Test
    fun `participant link that failed to save is FAILED regardless of the role before`() {
        assertEquals(LinkSaveOutcome.FAILED, LinkSaveNotice.outcomeForParticipantLink(roleBeforeParticipant = true, saved = false))
        assertEquals(LinkSaveOutcome.FAILED, LinkSaveNotice.outcomeForParticipantLink(roleBeforeParticipant = false, saved = false))
    }

    @Test
    fun `participant link saved while already a participant keeps the role`() {
        assertEquals(LinkSaveOutcome.SAVED, LinkSaveNotice.outcomeForParticipantLink(roleBeforeParticipant = true, saved = true))
    }

    @Test
    fun `participant link saved from owner switches the role to participant`() {
        assertEquals(LinkSaveOutcome.ROLE_CHANGED_TO_PARTICIPANT, LinkSaveNotice.outcomeForParticipantLink(roleBeforeParticipant = false, saved = true))
    }

    @Test
    fun `import without a readable role after import never claims a role change`() {
        assertEquals(LinkSaveOutcome.SAVED, LinkSaveNotice.outcomeForImport(roleBeforeParticipant = true, roleAfterParticipant = null))
        assertEquals(LinkSaveOutcome.SAVED, LinkSaveNotice.outcomeForImport(roleBeforeParticipant = false, roleAfterParticipant = null))
    }

    @Test
    fun `import that keeps the role is SAVED`() {
        assertEquals(LinkSaveOutcome.SAVED, LinkSaveNotice.outcomeForImport(roleBeforeParticipant = true, roleAfterParticipant = true))
        assertEquals(LinkSaveOutcome.SAVED, LinkSaveNotice.outcomeForImport(roleBeforeParticipant = false, roleAfterParticipant = false))
    }

    @Test
    fun `import from owner to participant is ROLE_CHANGED_TO_PARTICIPANT`() {
        assertEquals(LinkSaveOutcome.ROLE_CHANGED_TO_PARTICIPANT, LinkSaveNotice.outcomeForImport(roleBeforeParticipant = false, roleAfterParticipant = true))
    }

    @Test
    fun `import from participant to owner is ROLE_CHANGED_TO_OWNER`() {
        assertEquals(LinkSaveOutcome.ROLE_CHANGED_TO_OWNER, LinkSaveNotice.outcomeForImport(roleBeforeParticipant = true, roleAfterParticipant = false))
    }

    // --- Тексты ----------------------------------------------------------

    @Test
    fun `link toast texts are exact`() {
        assertEquals("Ссылка сохранена ✓", LinkSaveNotice.linkToast(LinkSaveOutcome.SAVED))
        assertEquals("Ссылка сохранена ✓ Режим участника включён", LinkSaveNotice.linkToast(LinkSaveOutcome.ROLE_CHANGED_TO_PARTICIPANT))
        assertEquals("Ссылка сохранена ✓ Режим владельца включён", LinkSaveNotice.linkToast(LinkSaveOutcome.ROLE_CHANGED_TO_OWNER))
        assertEquals("Не удалось сохранить ссылку", LinkSaveNotice.linkToast(LinkSaveOutcome.FAILED))
    }

    @Test
    fun `config toast texts are exact`() {
        assertEquals("Конфигурация CSQTT сохранена ✓", LinkSaveNotice.configToast(LinkSaveOutcome.SAVED))
        assertEquals("Конфигурация CSQTT сохранена ✓ Режим участника включён", LinkSaveNotice.configToast(LinkSaveOutcome.ROLE_CHANGED_TO_PARTICIPANT))
        assertEquals("Конфигурация CSQTT сохранена ✓ Режим владельца включён", LinkSaveNotice.configToast(LinkSaveOutcome.ROLE_CHANGED_TO_OWNER))
        assertEquals("Не удалось сохранить конфигурацию CSQTT", LinkSaveNotice.configToast(LinkSaveOutcome.FAILED))
    }

    @Test
    fun `import toast texts are exact`() {
        assertEquals("Конфигурация успешно импортирована ✓", LinkSaveNotice.importToast(LinkSaveOutcome.SAVED))
        assertEquals("Конфигурация успешно импортирована ✓ Режим участника включён", LinkSaveNotice.importToast(LinkSaveOutcome.ROLE_CHANGED_TO_PARTICIPANT))
        assertEquals("Конфигурация успешно импортирована ✓ Режим владельца включён", LinkSaveNotice.importToast(LinkSaveOutcome.ROLE_CHANGED_TO_OWNER))
        assertEquals("Не удалось сохранить конфигурацию", LinkSaveNotice.importToast(LinkSaveOutcome.FAILED))
    }

    // --- Структурные проверки экранов ------------------------------------

    @Test
    fun `QR branch no longer shows its own unconditional participant toast`() {
        assertFalse(
            "FloatingToolbar всё ещё печатает безусловный тост о включении режима участника",
            floatingToolbarSource.contains("Ссылка подключена из QR-кода"),
        )
        assertTrue(
            "FloatingToolbar не использует LinkSaveNotice",
            floatingToolbarSource.contains("LinkSaveNotice"),
        )
    }

    @Test
    fun `QR branch reads the role from the flow at save time`() {
        assertTrue(
            "FloatingToolbar не читает роль из потока в момент записи",
            floatingToolbarSource.contains("settingsStore.csqttLinkMode.first()"),
        )
    }

    @Test
    fun `deep-link import no longer claims the configuration was connected`() {
        assertFalse(
            "MainActivity всё ещё печатает «Конфигурация CSQTT успешно подключена»",
            mainActivitySource.contains("Конфигурация CSQTT успешно подключена"),
        )
        assertTrue(
            "MainActivity не использует LinkSaveNotice",
            mainActivitySource.contains("LinkSaveNotice"),
        )
    }

    @Test
    fun `deep-link confirmation dialog labels the port as a port`() {
        assertFalse(
            "в диалоге порт по-прежнему подписан как peer",
            mainActivitySource.contains("Peer: \${link.port}"),
        )
        assertTrue(
            "в диалоге нет подписи порта",
            mainActivitySource.contains("Порт: \${link.port}"),
        )
    }
}
