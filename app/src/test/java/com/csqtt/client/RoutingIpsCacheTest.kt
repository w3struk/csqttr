package com.csqtt.client

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.mockito.Mockito

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
        assertEquals(CachedRoutingIps(sha, text), cache.readSnapshot())
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
        assertNull(cache.readSnapshot())
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

    @Test fun `concurrent writers keep text and sha consistent`() {
        val first = RoutingIpsCache(dir)
        val second = RoutingIpsCache(dir)
        val textA = "10.0.0.0/8\n"
        val textB = "192.168.0.0/16\n"
        val shaA = RoutingIpsPolicy.sha256Hex(textA.toByteArray())
        val shaB = RoutingIpsPolicy.sha256Hex(textB.toByteArray())
        val barrier = java.util.concurrent.CyclicBarrier(2)
        val errors = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()
        fun writer(cache: RoutingIpsCache, text: String, sha: String) = Thread {
            try {
                barrier.await()
                repeat(50) { cache.write(text, sha) }
            } catch (error: Throwable) {
                errors += error
            }
        }
        val a = writer(first, textA, shaA)
        val b = writer(second, textB, shaB)
        a.start()
        b.start()
        a.join()
        b.join()

        assertTrue(errors.isEmpty())
        val text = requireNotNull(first.readText())
        val expected = RoutingIpsPolicy.sha256Hex(text.toByteArray())
        assertEquals(expected, first.readSha())
        assertTrue(dir.listFiles().orEmpty().none { it.name.endsWith(".tmp") })
    }

    @Test fun `writer between cache read and policy use never mixes sha and text`() {
        val readerCache = RoutingIpsCache(dir)
        val writerCache = RoutingIpsCache(dir)
        val textA = "10.0.0.0/8\n"
        val textB = "192.168.0.0/16\n"
        val shaA = RoutingIpsPolicy.sha256Hex(textA.toByteArray(Charsets.UTF_8))
        val shaB = RoutingIpsPolicy.sha256Hex(textB.toByteArray(Charsets.UTF_8))
        readerCache.write(textA, shaA)
        val readComplete = CountDownLatch(1)
        val published = CountDownLatch(1)
        val error = AtomicReference<Throwable?>()
        val writer = Thread {
            try {
                check(readComplete.await(5, TimeUnit.SECONDS))
                writerCache.write(textB, shaB)
            } catch (failure: Throwable) {
                error.set(failure)
            } finally {
                published.countDown()
            }
        }
        writer.start()
        val cached = readerCache.readSnapshot()
        readComplete.countDown()
        try {
            assertTrue(published.await(5, TimeUnit.SECONDS))
            val rule = ServerRoutingRule(false, emptyList(), emptyList(), false, emptyList(), ipsSha = shaA)
            val decision = RoutingIpsPolicy.decide(rule, cached)
            assertEquals(RoutingIpsPolicy.Decision.FromCache(shaA, textA, 1), decision)
        } finally {
            writer.join(5_000)
        }
        assertNull(error.get())
    }

    @Test fun `snapshot waits for the writer to finish publishing both files`() {
        val textA = "10.0.0.0/8\n"
        val textB = "192.168.0.0/16\n"
        val shaA = RoutingIpsPolicy.sha256Hex(textA.toByteArray(Charsets.UTF_8))
        val shaB = RoutingIpsPolicy.sha256Hex(textB.toByteArray(Charsets.UTF_8))
        RoutingIpsCache(dir).write(textA, shaA)
        val partialWrite = CountDownLatch(1)
        val finishWrite = CountDownLatch(1)
        val readerEntered = CountDownLatch(1)
        val result = AtomicReference<CachedRoutingIps?>()
        val errors = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()
        val writer = Thread {
            try {
                synchronized(routingCacheWriteLock) {
                    File(dir, RoutingIpsCache.TEXT_NAME).writeText(textB, Charsets.UTF_8)
                    partialWrite.countDown()
                    check(finishWrite.await(5, TimeUnit.SECONDS))
                    File(dir, RoutingIpsCache.SHA_NAME).writeText(shaB, Charsets.UTF_8)
                }
            } catch (failure: Throwable) {
                errors += failure
            }
        }
        val reader = Thread {
            try {
                readerEntered.countDown()
                result.set(RoutingIpsCache(dir).readSnapshot())
            } catch (failure: Throwable) {
                errors += failure
            }
        }
        writer.start()
        try {
            assertTrue(partialWrite.await(5, TimeUnit.SECONDS))
            reader.start()
            assertTrue(readerEntered.await(5, TimeUnit.SECONDS))
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
            while (reader.state != Thread.State.BLOCKED && reader.isAlive && System.nanoTime() < deadline) {
                Thread.yield()
            }
            assertEquals(Thread.State.BLOCKED, reader.state)
        } finally {
            finishWrite.countDown()
            writer.join(5_000)
            reader.join(5_000)
        }
        assertFalse(writer.isAlive)
        assertFalse(reader.isAlive)
        assertTrue(errors.toString(), errors.isEmpty())
        assertEquals(CachedRoutingIps(shaB, textB), result.get())
    }

    @Test fun `concurrent cache instances expose only validated snapshots`() {
        val textA = "10.0.0.0/8\n"
        val textB = "192.168.0.0/16\n"
        val shaA = RoutingIpsPolicy.sha256Hex(textA.toByteArray(Charsets.UTF_8))
        val shaB = RoutingIpsPolicy.sha256Hex(textB.toByteArray(Charsets.UTF_8))
        RoutingIpsCache(dir).write(textA, shaA)
        val barrier = java.util.concurrent.CyclicBarrier(3)
        val errors = java.util.concurrent.ConcurrentLinkedQueue<Throwable>()
        fun task(block: () -> Unit) = Thread {
            try {
                barrier.await(5, TimeUnit.SECONDS)
                block()
            } catch (failure: Throwable) {
                errors += failure
            }
        }
        val first = RoutingIpsCache(dir)
        val second = RoutingIpsCache(dir)
        val reader = RoutingIpsCache(dir)
        val threads = listOf(
            task { repeat(50) { first.write(textA, shaA) } },
            task { repeat(50) { second.write(textB, shaB) } },
            task {
                repeat(100) {
                    val snapshot = requireNotNull(reader.readSnapshot())
                    assertTrue(snapshot == CachedRoutingIps(shaA, textA) || snapshot == CachedRoutingIps(shaB, textB))
                    assertEquals(snapshot.sha, RoutingIpsPolicy.sha256Hex(snapshot.text.toByteArray(Charsets.UTF_8)))
                }
            },
        )
        threads.forEach { it.start() }
        threads.forEach { it.join(10_000) }
        assertTrue(threads.none { it.isAlive })
        assertTrue(errors.toString(), errors.isEmpty())
        assertTrue(dir.listFiles().orEmpty().none { it.name.endsWith(".tmp") })
    }

    @Test fun `failed text replacement preserves the prior published target`() {
        val cache = RoutingIpsCache(dir)
        val text = "10.0.0.0/8\n"
        val sha = RoutingIpsPolicy.sha256Hex(text.toByteArray(Charsets.UTF_8))
        cache.write(text, sha)
        val target = File(dir, RoutingIpsCache.TEXT_NAME).toPath()

        Mockito.mockStatic(Files::class.java, Mockito.CALLS_REAL_METHODS).use { files ->
            files.`when`<Path> {
                Files.move(Mockito.any(Path::class.java), Mockito.eq(target), Mockito.eq(StandardCopyOption.REPLACE_EXISTING))
            }.thenThrow(IOException("forced replacement failure"))
            assertThrows(IOException::class.java) { cache.write("192.168.0.0/16\n", "f".repeat(64)) }
        }

        assertEquals(CachedRoutingIps(sha, text), cache.readSnapshot())
        assertTrue(dir.listFiles().orEmpty().none { it.name.endsWith(".tmp") })
    }

    @Test fun `failed sha replacement preserves its target and the torn pair is a miss`() {
        val cache = RoutingIpsCache(dir)
        val textA = "10.0.0.0/8\n"
        val textB = "192.168.0.0/16\n"
        val shaA = RoutingIpsPolicy.sha256Hex(textA.toByteArray(Charsets.UTF_8))
        val shaB = RoutingIpsPolicy.sha256Hex(textB.toByteArray(Charsets.UTF_8))
        cache.write(textA, shaA)
        val target = File(dir, RoutingIpsCache.SHA_NAME).toPath()

        Mockito.mockStatic(Files::class.java, Mockito.CALLS_REAL_METHODS).use { files ->
            files.`when`<Path> {
                Files.move(Mockito.any(Path::class.java), Mockito.eq(target), Mockito.eq(StandardCopyOption.REPLACE_EXISTING))
            }.thenThrow(IOException("forced replacement failure"))
            assertThrows(IOException::class.java) { cache.write(textB, shaB) }
        }

        assertEquals(shaA, File(dir, RoutingIpsCache.SHA_NAME).readText(Charsets.UTF_8))
        assertNull(cache.readSnapshot())
        assertTrue(dir.listFiles().orEmpty().none { it.name.endsWith(".tmp") })
    }

    @Test fun `base64Gzip produces a decodable blob`() {
        val cache = RoutingIpsCache(dir)
        val text = "10.0.0.0/8\n192.168.0.0/16\n"

        val blob = cache.base64Gzip(text)

        assertEquals(text, String(requireNotNull(RoutingIpsPolicy.decodeBlob(blob)), Charsets.UTF_8))
    }
}
