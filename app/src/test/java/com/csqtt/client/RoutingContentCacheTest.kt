package com.csqtt.client

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RoutingContentCacheTest {
    private val dir: File = Files.createTempDirectory("routing-content-cache").toFile()
    private val sha = "c".repeat(64)

    @After fun tearDown() {
        dir.deleteRecursively()
    }

    private fun content(sha: String = this.sha) = CachedRoutingContent(
        sha = sha,
        domains = listOf("example.com", "vk.com"),
        packages = listOf("com.example.app"),
        presetRed = listOf("ru.example.red"),
        presetOrange = listOf("ru.example.orange"),
    )

    @Test fun `write and read round-trip leaves no temporary file`() {
        val cache = RoutingContentCache(dir)
        cache.write(content())

        assertEquals(content(), cache.read())
        assertEquals(sha, cache.readSha())
        assertEquals(
            sha,
            File(dir, RoutingContentCache.SHA_NAME).readText(Charsets.UTF_8).trim(),
        )
        assertTrue(dir.listFiles().orEmpty().none { it.name.endsWith(".tmp") })
    }

    @Test fun `reconcileForSpawn refreshes the live sha file`() {
        val cache = RoutingContentCache(dir)
        cache.write(content(sha = "e".repeat(64)))
        // Подсказка для Rust могла отстать от JSON (обрыв между записями).
        File(dir, RoutingContentCache.SHA_NAME).writeText("f".repeat(64), Charsets.UTF_8)

        assertEquals("e".repeat(64), cache.reconcileForSpawn())
        assertEquals(
            "e".repeat(64),
            File(dir, RoutingContentCache.SHA_NAME).readText(Charsets.UTF_8).trim(),
        )
    }

    @Test fun `reconcileForSpawn removes a stale sha when the json is broken`() {
        val cache = RoutingContentCache(dir)
        File(dir, RoutingContentCache.SHA_NAME).writeText(sha, Charsets.UTF_8)
        File(dir, RoutingContentCache.FILE_NAME).writeText("{not-json", Charsets.UTF_8)

        assertNull(cache.reconcileForSpawn())
        assertTrue(!File(dir, RoutingContentCache.SHA_NAME).exists())
    }

    @Test fun `missing file is a cache miss`() {
        val cache = RoutingContentCache(dir)
        assertNull(cache.read())
        assertNull(cache.readSha())
    }

    @Test fun `broken json is a cache miss and never throws`() {
        val cache = RoutingContentCache(dir)
        File(dir, RoutingContentCache.FILE_NAME).writeText("{not-json", Charsets.UTF_8)
        assertNull(cache.read())
        assertNull(cache.readSha())
    }

    @Test fun `the server sha is stored verbatim and not recomputed`() {
        val cache = RoutingContentCache(dir)
        val serverSha = "d".repeat(64)
        cache.write(content(sha = serverSha))
        assertEquals(serverSha, cache.readSha())
    }

    @Test fun `an invalid package name invalidates the cache`() {
        val cache = RoutingContentCache(dir)
        cache.write(content().copy(packages = listOf("bad package")))
        assertNull(cache.read())
        assertNull(cache.readSha())
    }

    @Test fun `an invalid sha invalidates the cache`() {
        val cache = RoutingContentCache(dir)
        cache.write(content(sha = "xyz"))
        assertNull(cache.read())
    }

    @Test fun `overwriting replaces the whole pair atomically`() {
        val cache = RoutingContentCache(dir)
        cache.write(content(sha = "e".repeat(64)))
        cache.write(content(sha = "f".repeat(64)))

        assertEquals("f".repeat(64), cache.readSha())
        assertEquals(content(sha = "f".repeat(64)), cache.read())
        assertTrue(dir.listFiles().orEmpty().none { it.name.endsWith(".tmp") })
    }

    @Test fun `an unsupported cache version is a miss`() {
        val cache = RoutingContentCache(dir)
        File(dir, RoutingContentCache.FILE_NAME).writeText(
            """{"version":2,"sha":"$sha","domains":[],"packages":[],"preset_red":[],"preset_orange":[]}""",
            Charsets.UTF_8,
        )
        assertNull(cache.read())
    }
}
