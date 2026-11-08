package com.csqtt.client

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.Base64
import java.util.zip.GZIPOutputStream

/**
 * Один монитор на все файловые кеши маршрутизации.
 *
 * Экземпляры кеша создаются на каждый вызов, а writer'ы могут работать из
 * разных потоков. Общий `.tmp` и `renameTo` без сериализации позволяли второму
 * writer'у удалить уже опубликованный файл.
 */
internal val routingCacheWriteLock = Any()

internal data class CachedRoutingIps(val sha: String, val text: String)

/**
 * Диск-кеш серверного шаблона адресов: нормализованный текст и его sha256.
 *
 * Запись атомарна (temp + rename), причём текст пишется раньше sha: обрыв между
 * ними оставляет валидный текст, и `readSha` пересчитает sha по нему. Любая
 * ошибка чтения — это «кеша нет», а не исключение: вызывающий обязан выбрать
 * fail-closed, а не упасть.
 */
internal class RoutingIpsCache(private val dir: File) {
    private val textFile = File(dir, TEXT_NAME)
    private val shaFile = File(dir, SHA_NAME)

    fun readText(): String? = synchronized(routingCacheWriteLock) {
        try {
            textFile.readText(Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }

    fun readSha(): String? = readSnapshot()?.sha

    /** SHA и текст проверяются и возвращаются одним снимком, без окна writer'у. */
    fun readSnapshot(): CachedRoutingIps? = synchronized(routingCacheWriteLock) {
        // Без текста sha не отдаём: клиент запросит blob заново и не поднимется
        // с неполным списком. Это самоисцеление, а не fail-open — терминальная
        // ветка `RoutingIpsPolicy` остаётся на случай «hit без blob».
        val text = readText() ?: return@synchronized null
        val actual = RoutingIpsPolicy.sha256Hex(text.toByteArray(Charsets.UTF_8))
        val stored = try {
            shaFile.readText(Charsets.UTF_8).trim().takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
        if (stored == null) {
            return@synchronized try {
                writeAtomically(shaFile, actual)
                CachedRoutingIps(actual, text)
            } catch (_: IOException) {
                null
            }
        }
        if (stored == actual) CachedRoutingIps(actual, text) else null
    }

    fun write(text: String, sha: String) = synchronized(routingCacheWriteLock) {
        writeAtomically(textFile, text)
        writeAtomically(shaFile, sha)
    }

    fun base64Gzip(text: String): String {
        val out = ByteArrayOutputStream()
        GZIPOutputStream(out).use { gzip ->
            gzip.write(text.toByteArray(Charsets.UTF_8))
        }
        return Base64.getEncoder().encodeToString(out.toByteArray())
    }

    private fun writeAtomically(target: File, content: String) {
        val tmp = File(dir, "${target.name}.${System.nanoTime()}.tmp")
        try {
            tmp.writeText(content, Charsets.UTF_8)
            Files.move(
                tmp.toPath(),
                target.toPath(),
                StandardCopyOption.REPLACE_EXISTING,
            )
        } catch (error: IOException) {
            tmp.delete()
            throw error
        }
    }

    companion object {
        const val TEXT_NAME = "routing_ips.txt"
        const val SHA_NAME = "routing_ips.sha"
    }
}
