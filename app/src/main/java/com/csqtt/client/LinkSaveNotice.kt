package com.csqtt.client

/**
 * Результат сохранения ссылки CSQTT с точки зрения пользовательского сообщения.
 *
 * Роли «Владелец» больше нет: приложение всегда участник, поэтому исходов только два —
 * ссылка записалась или нет. Смена роли не существует, и сообщать о ней нечем.
 */
internal enum class LinkSaveOutcome {
    /** Ссылка (или конфигурация) сохранена. */
    SAVED,

    /** Сохранить не удалось. */
    FAILED,
}

/**
 * Решения о том, что показать после сохранения ссылки, и сами тексты — в одном месте,
 * чтобы юнит-тест на JVM проверял и логику, и формулировку.
 *
 * Тексты ниже — пользовательские строки. Они намеренно объявлены литералами, а не
 * ресурсами: так их можно проверить посимвольно в JVM-тесте.
 */
internal object LinkSaveNotice {

    /** Ссылка участника (QR-код, deep-link): результат записи. */
    fun outcomeForParticipantLink(saved: Boolean): LinkSaveOutcome =
        if (saved) LinkSaveOutcome.SAVED else LinkSaveOutcome.FAILED

    /** Тост после сохранения ссылки участника (QR-код). */
    fun linkToast(outcome: LinkSaveOutcome): String =
        when (outcome) {
            LinkSaveOutcome.SAVED -> "Ссылка сохранена ✓"
            LinkSaveOutcome.FAILED -> "Не удалось сохранить ссылку"
        }

    /** Тост после импорта конфигурации по deep-link `csqtt://`. */
    fun configToast(outcome: LinkSaveOutcome): String =
        when (outcome) {
            LinkSaveOutcome.SAVED -> "Конфигурация reCSQTT сохранена ✓"
            LinkSaveOutcome.FAILED -> "Не удалось сохранить конфигурацию reCSQTT"
        }
}
