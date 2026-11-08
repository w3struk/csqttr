package com.csqtt.client

import java.io.File
import java.io.IOException
import org.json.JSONArray
import org.json.JSONObject

/**
 * Домены и приложения серверного правила, сохранённые одним файлом вместе с
 * серверным `content_sha`.
 *
 * Один файл, а не «контент + .sha»: серверный sha нельзя пересчитать на клиенте
 * (канонизация — серверная), поэтому разъехавшиеся файлы нечем сверить. Один
 * атомарный rename оставляет либо старую пару, либо новую.
 */
internal data class CachedRoutingContent(
    val sha: String,
    val domains: List<String>,
    val packages: List<String>,
    val presetRed: List<String>,
    val presetOrange: List<String>,
)

internal class RoutingContentCache(private val dir: File) {
    private val file = File(dir, FILE_NAME)
    private val shaFile = File(dir, SHA_NAME)

    fun read(): CachedRoutingContent? = try {
        parseCachedRoutingContent(file.readText(Charsets.UTF_8))
    } catch (_: Exception) {
        null
    }

    /** Sha для политики: только при полностью валидном кеше. */
    fun readSha(): String? = read()?.sha

    /**
     * Синхронизировать отдельный `.sha`-файл с валидным JSON перед запуском
     * клиента и вернуть sha для argv. Rust читает этот файл на каждом GETCONF,
     * поэтому sha остаётся актуальным и после перезаписи кеша в середине сессии.
     * Невалидный кеш удаляет `.sha`, чтобы клиент не сослался на него.
     */
    fun reconcileForSpawn(): String? {
        val content = read()
        if (content == null) {
            shaFile.delete()
            return null
        }
        return try {
            writeAtomically(shaFile, content.sha)
            content.sha
        } catch (_: IOException) {
            shaFile.delete()
            null
        }
    }

    fun write(content: CachedRoutingContent) {
        val json = JSONObject().apply {
            put("version", VERSION)
            put("sha", content.sha)
            put("domains", JSONArray(content.domains))
            put("packages", JSONArray(content.packages))
            put("preset_red", JSONArray(content.presetRed))
            put("preset_orange", JSONArray(content.presetOrange))
        }
        writeAtomically(file, json.toString())
        // Сначала JSON, потом подсказка Rust: при обрыве между ними клиент
        // прочтёт старый sha и получит полную доставку — это безопасно.
        writeAtomically(shaFile, content.sha)
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
        const val FILE_NAME = "routing_content.json"
        const val SHA_NAME = "routing_content.sha"
        private const val VERSION = 1
    }
}

internal fun parseCachedRoutingContent(raw: String): CachedRoutingContent? = runCatching {
    val json = JSONObject(raw)
    require(json.optInt("version", 0) == 1) { "unsupported routing cache version" }
    val sha = json.getString("sha")
    require(RoutingIpsPolicy.SHA_PATTERN.matches(sha)) { "invalid cached content sha" }
    fun strings(key: String): List<String> {
        val array = json.getJSONArray(key)
        require(array.length() <= 4096) { "routing cache list too large" }
        return (0 until array.length()).map { index ->
            val value = array.get(index)
            require(value is String) { "routing cache entry must be a string" }
            value.trim()
        }.filter(String::isNotEmpty).distinct()
    }

    val packages = strings("packages")
    require(packages.all(::isRoutingPackageName)) { "invalid cached package name" }
    val presetRed = strings("preset_red")
    require(presetRed.all(::isRoutingPackageName)) { "invalid cached preset name" }
    val presetOrange = strings("preset_orange")
    require(presetOrange.all(::isRoutingPackageName)) { "invalid cached preset name" }
    CachedRoutingContent(
        sha = sha,
        domains = strings("domains"),
        packages = packages,
        presetRed = presetRed,
        presetOrange = presetOrange,
    )
}.getOrNull()
