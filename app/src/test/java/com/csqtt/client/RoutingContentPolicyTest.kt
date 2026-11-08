package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RoutingContentPolicyTest {
    private val sha = "a".repeat(64)
    private val otherSha = "b".repeat(64)

    private fun rule(
        contentSha: String? = sha,
        contentCached: Boolean = false,
        domains: List<String> = listOf("example.com"),
        packages: List<String> = listOf("com.example.app"),
        presetRed: List<String> = listOf("ru.example.red"),
        presetOrange: List<String> = listOf("ru.example.orange"),
    ) = ServerRoutingRule(
        isWhite = false,
        packages = packages,
        domains = domains,
        presetRed = presetRed,
        presetOrange = presetOrange,
        contentSha = contentSha,
        contentCached = contentCached,
    )

    private fun cached(
        contentSha: String = sha,
        domains: List<String> = listOf("cached.example"),
        packages: List<String> = listOf("com.cached.app"),
        presetRed: List<String> = listOf("ru.cached.red"),
        presetOrange: List<String> = listOf("ru.cached.orange"),
    ) = CachedRoutingContent(contentSha, domains, packages, presetRed, presetOrange)

    @Test fun `full content with a sha is written to the cache`() {
        val decision = RoutingContentPolicy.decide(rule(), null)
        assertTrue(decision is RoutingContentDecision.Updated)
        val updated = decision as RoutingContentDecision.Updated
        assertEquals(sha, updated.content.sha)
        assertEquals(listOf("example.com"), updated.content.domains)
        assertEquals(listOf("com.example.app"), updated.content.packages)
        assertEquals(listOf("ru.example.red"), updated.content.presetRed)
        assertEquals(listOf("ru.example.orange"), updated.content.presetOrange)
    }

    @Test fun `cached delivery is reconstructed from the cache`() {
        val decision = RoutingContentPolicy.decide(rule(contentCached = true), cached())
        assertTrue(decision is RoutingContentDecision.FromCache)
        val restored = (decision as RoutingContentDecision.FromCache).rule
        assertEquals(listOf("cached.example"), restored.domains)
        assertEquals(listOf("com.cached.app"), restored.packages)
        assertEquals(listOf("ru.cached.red"), restored.presetRed)
        assertEquals(listOf("ru.cached.orange"), restored.presetOrange)
        // Режимы приходят с сервера и кешем не подменяются.
        assertEquals(false, restored.isWhite)
        assertEquals(sha, restored.contentSha)
    }

    @Test fun `cached delivery without a cache is terminal`() {
        val decision = RoutingContentPolicy.decide(rule(contentCached = true), null)
        assertTrue(decision is RoutingContentDecision.Terminal)
        assertEquals(
            RoutingContentPolicy.CODE_MISSING,
            (decision as RoutingContentDecision.Terminal).code,
        )
    }

    @Test fun `cached delivery with another sha is terminal`() {
        val decision = RoutingContentPolicy.decide(
            rule(contentCached = true),
            cached(contentSha = otherSha),
        )
        assertTrue(decision is RoutingContentDecision.Terminal)
    }

    @Test fun `cached delivery without a sha in the rule is terminal`() {
        val decision = RoutingContentPolicy.decide(rule(contentSha = null, contentCached = true), cached())
        assertTrue(decision is RoutingContentDecision.Terminal)
    }

    @Test fun `empty cached arrays are a valid rule`() {
        val decision = RoutingContentPolicy.decide(
            rule(contentCached = true),
            cached(domains = emptyList(), packages = emptyList(), presetRed = emptyList(), presetOrange = emptyList()),
        )
        assertTrue(decision is RoutingContentDecision.FromCache)
        val restored = (decision as RoutingContentDecision.FromCache).rule
        assertTrue(restored.domains.isEmpty())
        assertTrue(restored.packages.isEmpty())
    }

    @Test fun `old server without a content sha is used as is`() {
        val original = rule(contentSha = null)
        val decision = RoutingContentPolicy.decide(original, null)
        assertTrue(decision is RoutingContentDecision.Uncached)
        assertEquals(original, (decision as RoutingContentDecision.Uncached).rule)
    }

    @Test fun `argv always points at the live sha file`() {
        val path = "/data/user/0/app/files/routing_content.sha"
        assertEquals(
            listOf("-routing-content-sha-file", path),
            RoutingContentArgvPolicy.flag(path),
        )
        assertEquals(emptyList<String>(), RoutingContentArgvPolicy.flag(""))
    }
}
