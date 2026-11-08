package com.csqtt.client

import org.json.JSONObject

data class ServerRoutingRule(
    val isWhite: Boolean,
    val packages: List<String>,
    val domains: List<String>,
    val ipIsWhite: Boolean = false,
    val ips: List<String> = emptyList(),
    val domainsIsWhite: Boolean = isWhite,
    val presetRed: List<String> = emptyList(),
    val presetOrange: List<String> = emptyList(),
    val ipsSha: String? = null,
    val ipsBlob: String? = null,
    /** Sha серверной «тяжёлой» части: домены и приложения. */
    val contentSha: String? = null,
    /** Сервер не прислал домены/приложения: их нужно взять из кеша по [contentSha]. */
    val contentCached: Boolean = false,
) {
    val templateIps: Boolean get() = ipsSha != null
}

internal fun isRoutingPackageName(value: String): Boolean =
    value.length in 1..255 &&
        value.split('.').all { part ->
            part.isNotEmpty() && (part[0] in 'A'..'Z' || part[0] in 'a'..'z' || part[0] == '_') &&
                part.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '_' }
        }

internal fun lenientPresetPackages(json: JSONObject, key: String): List<String> {
    val array = json.optJSONArray(key) ?: return emptyList()
    val entries = mutableListOf<String>()
    for (index in 0 until minOf(array.length(), 4096)) {
        val entry = array.opt(index)
        if (entry !is String) {
            System.err.println("[ServerRoutingRule] отброшена запись пресета $key: не строка ($entry)")
            continue
        }
        val trimmed = entry.trim()
        if (trimmed.isEmpty()) continue
        if (!isRoutingPackageName(trimmed)) {
            System.err.println("[ServerRoutingRule] отброшена запись пресета $key: $entry")
            continue
        }
        entries += trimmed
    }
    return entries.distinct()
}

internal fun parseServerRoutingRule(value: String): ServerRoutingRule? = runCatching {
    val json = JSONObject(value)
    fun strings(key: String): List<String> {
        if (!json.has(key)) return emptyList()
        val array = json.getJSONArray(key)
        require(array.length() <= 4096) { "routing list too large" }
        return (0 until array.length()).map { index ->
            require(array.get(index) is String) { "routing entry must be a string" }
            array.getString(index).trim()
        }.filter(String::isNotEmpty).distinct()
    }
    val appsWhite = json.optBoolean("is_whitelist", json.optString("mode", "blacklist") == "whitelist")
    val domainsWhite = json.optBoolean(
        "domains_is_whitelist",
        json.optString("domains_mode", if (appsWhite) "whitelist" else "blacklist") == "whitelist",
    )
    val packages = strings("packages")
    require(packages.all(::isRoutingPackageName)) { "invalid routing package name" }
    val presetRed = lenientPresetPackages(json, "preset_red")
    val presetOrange = lenientPresetPackages(json, "preset_orange")
    val ipsSha = if (json.has("ips_sha") && !json.isNull("ips_sha")) {
        val raw = json.get("ips_sha")
        require(raw is String) { "ips_sha must be a string" }
        require(RoutingIpsPolicy.SHA_PATTERN.matches(raw)) { "invalid ips_sha" }
        raw
    } else {
        null
    }
    val ipsBlob = if (json.has("ips_blob") && !json.isNull("ips_blob")) {
        val raw = json.get("ips_blob")
        require(raw is String) { "ips_blob must be a string" }
        require(ipsSha != null) { "ips_blob requires ips_sha" }
        raw.takeIf { it.isNotEmpty() }
    } else {
        null
    }
    val contentSha = if (json.has("content_sha") && !json.isNull("content_sha")) {
        val raw = json.get("content_sha")
        require(raw is String && RoutingIpsPolicy.SHA_PATTERN.matches(raw)) { "invalid content_sha" }
        raw
    } else {
        null
    }
    val contentCached = json.optBoolean("content_cached", false)
    require(!contentCached || contentSha != null) { "content_cached requires content_sha" }
    ServerRoutingRule(
        isWhite = appsWhite,
        packages = packages,
        domains = strings("domains"),
        ipIsWhite = json.optBoolean("ip_is_whitelist", json.optString("ip_mode", "blacklist") == "whitelist"),
        ips = strings("ips"),
        domainsIsWhite = domainsWhite,
        presetRed = presetRed,
        presetOrange = presetOrange,
        ipsSha = ipsSha,
        ipsBlob = ipsBlob,
        contentSha = contentSha,
        contentCached = contentCached,
    )
}.getOrNull()
