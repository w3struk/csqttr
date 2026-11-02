package com.csqtt.client

internal object UsageRolePolicy {
    /** Профиль пуст: нет адреса сервера и нет ссылки CSQTT. */
    fun isProfileEmpty(peer: String, link: String): Boolean =
        peer.isBlank() && link.isBlank()

    /** Явный выбор важнее расчёта; без выбора — участник только на пустом профиле. */
    fun resolveParticipantMode(storedMode: Boolean?, peer: String, link: String): Boolean =
        storedMode ?: isProfileEmpty(peer, link)
}
