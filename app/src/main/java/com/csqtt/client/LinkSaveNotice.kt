package com.csqtt.client

/**
 * Результат сохранения ссылки CSQTT с точки зрения пользовательского сообщения.
 *
 * Отдельный тип нужен потому, что тост показывает не сам факт записи, а ещё и то,
 * изменилась ли роль использования: на свежей установке профиль пуст, роль уже
 * «Участник» ([UsageRolePolicy.resolveParticipantMode]), и сообщение о включении
 * режима участника было бы ложью. Смена роли несимметрична: переход в участника
 * и переход в владельца — разные сообщения.
 */
internal enum class LinkSaveOutcome {
    /** Ссылка сохранена, роль не изменилась. */
    SAVED,

    /** Ссылка сохранена, роль переключилась в «Участника». */
    ROLE_CHANGED_TO_PARTICIPANT,

    /** Ссылка сохранена, роль переключилась в «Владельца». */
    ROLE_CHANGED_TO_OWNER,

    /** Сохранить не удалось. */
    FAILED,
}

/**
 * Решения о том, что показать после сохранения ссылки, и сами тексты — в одном месте,
 * чтобы юнит-тест на JVM проверял и логику, и формулировку.
 *
 * Тексты ниже — пользовательские строки. Они намеренно объявлены литералами, а не
 * ресурсами: так их можно проверить посимвольно в JVM-тесте. Фраза «Режим участника
 * включён» появляется только при фактической смене роли на участника, «Режим владельца
 * включён» — только при смене на владельца, а не при каждой записи.
 */
internal object LinkSaveNotice {

    /**
     * Ссылка участника (QR-код, deep-link): роль ДО действия и результат записи.
     *
     * Запись ссылки участником всегда фиксирует роль «Участник», поэтому при роли
     * «Владелец» до записи роль действительно меняется.
     */
    fun outcomeForParticipantLink(roleBeforeParticipant: Boolean, saved: Boolean): LinkSaveOutcome =
        when {
            !saved -> LinkSaveOutcome.FAILED
            roleBeforeParticipant -> LinkSaveOutcome.SAVED
            else -> LinkSaveOutcome.ROLE_CHANGED_TO_PARTICIPANT
        }

    /**
     * Импорт конфигурации: роль ДО и ПОСЛЕ импорта (`null` — роль после прочитать не удалось).
     *
     * Если роль после неизвестна, не утверждаем ни смену, ни её отсутствие. Направление
     * смены важно: импорт может переключить и в участника, и обратно в владельца.
     */
    fun outcomeForImport(roleBeforeParticipant: Boolean, roleAfterParticipant: Boolean?): LinkSaveOutcome =
        when {
            roleAfterParticipant == null -> LinkSaveOutcome.SAVED
            roleBeforeParticipant == roleAfterParticipant -> LinkSaveOutcome.SAVED
            !roleBeforeParticipant && roleAfterParticipant -> LinkSaveOutcome.ROLE_CHANGED_TO_PARTICIPANT
            else -> LinkSaveOutcome.ROLE_CHANGED_TO_OWNER
        }

    /** Тост после сохранения ссылки участника (QR-код). */
    fun linkToast(outcome: LinkSaveOutcome): String =
        when (outcome) {
            LinkSaveOutcome.SAVED -> "Ссылка сохранена ✓"
            LinkSaveOutcome.ROLE_CHANGED_TO_PARTICIPANT -> "Ссылка сохранена ✓ Режим участника включён"
            LinkSaveOutcome.ROLE_CHANGED_TO_OWNER -> "Ссылка сохранена ✓ Режим владельца включён"
            LinkSaveOutcome.FAILED -> "Не удалось сохранить ссылку"
        }

    /** Тост после импорта конфигурации по deep-link `csqtt://`. */
    fun configToast(outcome: LinkSaveOutcome): String =
        when (outcome) {
            LinkSaveOutcome.SAVED -> "Конфигурация CSQTT сохранена ✓"
            LinkSaveOutcome.ROLE_CHANGED_TO_PARTICIPANT -> "Конфигурация CSQTT сохранена ✓ Режим участника включён"
            LinkSaveOutcome.ROLE_CHANGED_TO_OWNER -> "Конфигурация CSQTT сохранена ✓ Режим владельца включён"
            LinkSaveOutcome.FAILED -> "Не удалось сохранить конфигурацию CSQTT"
        }

    /** Тост после импорта конфигурации из файла/буфера. */
    fun importToast(outcome: LinkSaveOutcome): String =
        when (outcome) {
            LinkSaveOutcome.SAVED -> "Конфигурация успешно импортирована ✓"
            LinkSaveOutcome.ROLE_CHANGED_TO_PARTICIPANT -> "Конфигурация успешно импортирована ✓ Режим участника включён"
            LinkSaveOutcome.ROLE_CHANGED_TO_OWNER -> "Конфигурация успешно импортирована ✓ Режим владельца включён"
            LinkSaveOutcome.FAILED -> "Не удалось сохранить конфигурацию"
        }
}
