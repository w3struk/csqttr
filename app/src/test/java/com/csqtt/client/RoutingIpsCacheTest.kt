package com.csqtt.client

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RoutingIpsCacheTest {

    private val dir: File = Files.createTempDirectory("routing-ips-cache").toFile()

    @After fun tearDown() {
        dir.deleteRecursively()
    }

    @Test fun `cache write and read round-trip leaves no temporary file`() {
        val cache = RoutingIpsCache(dir)
        val text = "10.0.0.0/8\n192.168.0.0/16\n"
        val sha = RoutingIpsPolicy.sha256Hex(text.toByteArray())

        cache.write(text, sha)

        assertEquals(text, cache.readText())
        assertEquals(sha, cache.readSha())
        assertTrue(dir.listFiles().orEmpty().none { it.name.endsWith(".tmp") })
    }

    @Test fun `readSha recomputes the sha when only the text exists`() {
        val cache = RoutingIpsCache(dir)
        val text = "10.0.0.0/8\n"
        File(dir, RoutingIpsCache.TEXT_NAME).writeText(text, Charsets.UTF_8)

        val expected = RoutingIpsPolicy.sha256Hex(text.toByteArray())
        assertEquals(expected, cache.readSha())
        assertEquals(expected, File(dir, RoutingIpsCache.SHA_NAME).readText(Charsets.UTF_8).trim())
    }

    @Test fun `a sha that does not match the cached text is a cache miss`() {
        val cache = RoutingIpsCache(dir)
        File(dir, RoutingIpsCache.TEXT_NAME).writeText("10.0.0.0/8\n", Charsets.UTF_8)
        File(dir, RoutingIpsCache.SHA_NAME).writeText("f".repeat(64), Charsets.UTF_8)

        assertNull(cache.readSha())
    }

    @Test fun `missing text is a cache miss`() {
        val cache = RoutingIpsCache(dir)
        assertNull(cache.readText())
        assertNull(cache.readSha())
    }

    @Test fun `unreadable cache files are a cache miss and never throw`() {
        File(dir, RoutingIpsCache.TEXT_NAME).mkdirs()
        val cache = RoutingIpsCache(dir)

        assertNull(cache.readText())
        assertNull(cache.readSha())
    }

    @Test fun `a broken sha file is never fatal`() {
        val cache = RoutingIpsCache(dir)
        File(dir, RoutingIpsCache.TEXT_NAME).writeText("10.0.0.0/8\n", Charsets.UTF_8)
        File(dir, RoutingIpsCache.SHA_NAME).mkdirs()
        File(File(dir, RoutingIpsCache.SHA_NAME), "child").writeText("x")

        assertNull(cache.readSha())
    }

    @Test fun `base64Gzip produces a decodable blob`() {
        val cache = RoutingIpsCache(dir)
        val text = "10.0.0.0/8\n192.168.0.0/16\n"

        val blob = cache.base64Gzip(text)

        assertEquals(text, String(requireNotNull(RoutingIpsPolicy.decodeBlob(blob)), Charsets.UTF_8))
    }
}
