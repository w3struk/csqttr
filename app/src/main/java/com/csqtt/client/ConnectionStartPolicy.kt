package com.csqtt.client

internal enum class ConnectionStartBlocker(val message: String) {
    Link("нужна корректная ссылка CSQTT"),
    Hashes("нет действующих VK хешей или VK токена"),
}

internal object ConnectionStartPolicy {
    fun hasReadyVkCredentials(
        linkHashCount: Int,
        linkTokenPresent: Boolean,
        autoHashMode: Boolean,
        storedTokenPresent: Boolean,
        manualHashCount: Int,
    ): Boolean = linkHashCount > 0 || linkTokenPresent || manualHashCount > 0 ||
        (autoHashMode && storedTokenPresent)

    fun blocker(
        linkValid: Boolean,
        hashesReady: Boolean,
    ): ConnectionStartBlocker? {
        // Ссылка — первая причина: без неё сообщение про хеши сбивало бы с толку,
        // ведь хеши берутся в том числе из ссылки.
        if (!linkValid) return ConnectionStartBlocker.Link
        return if (hashesReady) null else ConnectionStartBlocker.Hashes
    }
}
