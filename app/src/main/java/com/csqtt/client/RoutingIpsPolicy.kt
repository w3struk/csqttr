package com.csqtt.client

import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.Base64
import java.util.zip.GZIPInputStream

/**
 * Решение по серверному шаблону адресов до отправки каких-либо команд клиенту.
 *
 * Шаблон приходит либо готовым gzip-блобом (base64), либо только sha — тогда
 * подходит лишь совпадающий кеш. Любая неопределённость терминальна: туннель не
 * должен подниматься без исключений, которые требует правило.
 */
internal object RoutingIpsPolicy {
    /** sha256 в нижнем регистре: ровно 64 hex-символа. */
    val SHA_PATTERN = Regex("^[0-9a-f]{64}$")

    private const val MAX_DECOMPRESSED_BYTES = 1 shl 20

    sealed interface Decision {
        data class Update(val sha: String, val text: String, val count: Int) : Decision
        data class FromCache(val sha: String, val text: String, val count: Int) : Decision
        data class Terminal(val code: String, val message: String) : Decision
        data object Disabled : Decision
    }

    fun decide(rule: ServerRoutingRule, cached: CachedRoutingIps?): Decision =
        decide(rule, cached?.sha, cached?.text)

    fun decide(rule: ServerRoutingRule, cachedSha: String?, cachedText: String?): Decision {
        val expected = rule.ipsSha ?: return Decision.Disabled
        val blob = rule.ipsBlob
        if (blob != null) {
            val decoded = decodeBlob(blob)
                ?: return Decision.Terminal(
                    "routing_ips_bad_blob",
                    "ожидался sha $expected, получен: битый blob",
                )
            val text = String(decoded, Charsets.UTF_8)
            val actual = sha256Hex(decoded)
            if (actual != expected) {
                return Decision.Terminal(
                    "routing_ips_bad_blob",
                    "ожидался sha $expected, получен $actual",
                )
            }
            return Decision.Update(expected, text, countEntries(text))
        }
        if (cachedSha == expected && cachedText != null &&
            sha256Hex(cachedText.toByteArray(Charsets.UTF_8)) == expected
        ) {
            return Decision.FromCache(expected, cachedText, countEntries(cachedText))
        }
        return Decision.Terminal(
            "routing_ips_missing",
            "нужен список с sha $expected, в кеше ${cachedSha ?: "пусто"}",
        )
    }

    /** base64 → gzip → байты; `null` на любом шаге, если блоб битый или больше 1 МиБ. */
    fun decodeBlob(blobBase64: String): ByteArray? = try {
        val raw = Base64.getDecoder().decode(blobBase64)
        GZIPInputStream(raw.inputStream()).use { input ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            var total = 0
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                if (total > MAX_DECOMPRESSED_BYTES) break
                out.write(buffer, 0, read)
            }
            if (total > MAX_DECOMPRESSED_BYTES) null else out.toByteArray()
        }
    } catch (_: Exception) {
        null
    }

    fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    fun countEntries(text: String): Int =
        text.lineSequence().count { it.isNotBlank() }
}

/** argv-флаг кешированного sha: только валидное значение, иначе флаг не передаётся. */
internal object RoutingIpsArgvPolicy {
    fun flag(sha: String?): List<String> =
        if (sha != null && RoutingIpsPolicy.SHA_PATTERN.matches(sha)) {
            listOf("-routing-ips-sha", sha)
        } else {
            emptyList()
        }
}
