package com.csqtt.client

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.Base64
import java.util.zip.GZIPOutputStream

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

    fun readText(): String? = try {
        textFile.readText(Charsets.UTF_8)
    } catch (_: Exception) {
        null
    }

    fun readSha(): String? {
        val text = readText() ?: return null
        val actual = RoutingIpsPolicy.sha256Hex(text.toByteArray(Charsets.UTF_8))
        val stored = try {
            shaFile.readText(Charsets.UTF_8).trim().takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
        if (stored == null) {
            return try {
                writeAtomically(shaFile, actual)
                actual
            } catch (_: IOException) {
                null
            }
        }
        return if (stored == actual) actual else null
    }

    fun write(text: String, sha: String) {
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
        val tmp = File(dir, "${target.name}.tmp")
        tmp.writeText(content, Charsets.UTF_8)
        if (!tmp.renameTo(target)) {
            target.delete()
            if (!tmp.renameTo(target)) {
                tmp.delete()
                throw IOException("cannot replace ${target.name}")
            }
        }
    }

    companion object {
        const val TEXT_NAME = "routing_ips.txt"
        const val SHA_NAME = "routing_ips.sha"
    }
}
