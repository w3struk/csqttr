package com.csqtt.client

/**
 * Решение по «тяжёлой» части правила до отправки каких-либо команд клиенту.
 *
 * Сервер присылает домены и приложения либо полностью (тогда их надо сохранить),
 * либо только `content_sha` (тогда их обязан дать кеш). Любая неопределённость
 * терминальна: туннель не должен подниматься с пустым или чужим правилом.
 */
internal sealed interface RoutingContentDecision {
    /** Сервер прислал полный набор; его нужно записать в кеш. */
    data class Updated(val rule: ServerRoutingRule, val content: CachedRoutingContent) :
        RoutingContentDecision

    /** Сервер не прислал массивы, кеш совпал — правило собрано из кеша. */
    data class FromCache(val rule: ServerRoutingRule, val content: CachedRoutingContent) :
        RoutingContentDecision

    /** Старый сервер без `content_sha`: кэшировать нечего, берём как пришло. */
    data class Uncached(val rule: ServerRoutingRule) : RoutingContentDecision

    data class Terminal(val code: String, val message: String) : RoutingContentDecision
}

internal object RoutingContentPolicy {
    const val CODE_MISSING = "routing_content_missing"

    fun decide(rule: ServerRoutingRule, cached: CachedRoutingContent?): RoutingContentDecision {
        val contentSha = rule.contentSha
        if (!rule.contentCached) {
            val content = contentSha?.let {
                CachedRoutingContent(
                    sha = it,
                    domains = rule.domains,
                    packages = rule.packages,
                    presetRed = rule.presetRed,
                    presetOrange = rule.presetOrange,
                )
            }
            return if (content != null) {
                RoutingContentDecision.Updated(rule, content)
            } else {
                RoutingContentDecision.Uncached(rule)
            }
        }
        if (contentSha == null) {
            return RoutingContentDecision.Terminal(
                CODE_MISSING,
                "сервер не прислал content_sha для кешированного правила",
            )
        }
        if (cached == null) {
            return RoutingContentDecision.Terminal(
                CODE_MISSING,
                "кеш доменов и приложений отсутствует (нужен sha $contentSha)",
            )
        }
        if (cached.sha != contentSha) {
            return RoutingContentDecision.Terminal(
                CODE_MISSING,
                "кеш доменов и приложений не совпадает: ожидался $contentSha, в кеше ${cached.sha}",
            )
        }
        return RoutingContentDecision.FromCache(
            rule.copy(
                domains = cached.domains,
                packages = cached.packages,
                presetRed = cached.presetRed,
                presetOrange = cached.presetOrange,
            ),
            cached,
        )
    }
}

/**
 * argv-флаг файла с sha кеша доменов и приложений.
 *
 * Клиент читает этот файл на каждом GETCONF, поэтому sha не «прибивается» к
 * моменту запуска: после перезаписи кеша в середине сессии следующий запрос
 * унесёт уже новый sha, и сервер не примет его за чужой.
 */
internal object RoutingContentArgvPolicy {
    /**
     * Путь передаётся всегда, даже если кеша ещё нет: Rust читает файл на
     * каждом GETCONF, поэтому кеш, созданный в середине сессии, тоже будет
     * объявлен серверу. Отсутствие/битый файл — это «кеша нет», не ошибка.
     */
    fun flag(shaFilePath: String): List<String> =
        if (shaFilePath.isNotBlank()) {
            listOf("-routing-content-sha-file", shaFilePath)
        } else {
            emptyList()
        }
}
