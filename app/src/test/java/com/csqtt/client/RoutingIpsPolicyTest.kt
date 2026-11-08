package com.csqtt.client

import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.zip.GZIPOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RoutingIpsPolicyTest {

    private fun gzipBase64(text: String): String {
        val out = ByteArrayOutputStream()
        GZIPOutputStream(out).use { it.write(text.toByteArray(Charsets.UTF_8)) }
        return Base64.getEncoder().encodeToString(out.toByteArray())
    }

    private fun rule(
        ipsSha: String? = null,
        ipsBlob: String? = null,
        ips: List<String> = emptyList(),
    ) = ServerRoutingRule(
        isWhite = false,
        packages = emptyList(),
        domains = emptyList(),
        ipIsWhite = false,
        ips = ips,
        ipsSha = ipsSha,
        ipsBlob = ipsBlob,
    )

    @Test fun `a matching blob is an update with its sha and entry count`() {
        val text = "10.0.0.0/8\n192.168.0.0/16\n"
        val sha = RoutingIpsPolicy.sha256Hex(text.toByteArray())
        val decision = RoutingIpsPolicy.decide(rule(ipsSha = sha, ipsBlob = gzipBase64(text)), null, null)
        assertEquals(RoutingIpsPolicy.Decision.Update(sha, text, 2), decision)
    }

    @Test fun `a sha mismatch is terminal`() {
        val decision = RoutingIpsPolicy.decide(
            rule(ipsSha = "0".repeat(64), ipsBlob = gzipBase64("10.0.0.0/8\n")),
            null,
            null,
        )
        assertTrue(decision is RoutingIpsPolicy.Decision.Terminal)
        assertEquals("routing_ips_bad_blob", (decision as RoutingIpsPolicy.Decision.Terminal).code)
    }

    @Test fun `a broken gzip is terminal`() {
        val broken = Base64.getEncoder().encodeToString("not gzip".toByteArray())
        val decision = RoutingIpsPolicy.decide(rule(ipsSha = "a".repeat(64), ipsBlob = broken), null, null)
        assertTrue(decision is RoutingIpsPolicy.Decision.Terminal)
        assertEquals("routing_ips_bad_blob", (decision as RoutingIpsPolicy.Decision.Terminal).code)
    }

    @Test fun `a broken base64 is terminal`() {
        val decision = RoutingIpsPolicy.decide(rule(ipsSha = "a".repeat(64), ipsBlob = "!!!not-base64"), null, null)
        assertTrue(decision is RoutingIpsPolicy.Decision.Terminal)
        assertEquals("routing_ips_bad_blob", (decision as RoutingIpsPolicy.Decision.Terminal).code)
    }

    @Test fun `no blob with a matching cache works from the cache`() {
        val text = "10.0.0.0/8\n"
        val sha = RoutingIpsPolicy.sha256Hex(text.toByteArray())
        val decision = RoutingIpsPolicy.decide(rule(ipsSha = sha), sha, text)
        assertEquals(RoutingIpsPolicy.Decision.FromCache(sha, text, 1), decision)
    }

    @Test fun `matching cached sha cannot authorize different text`() {
        val sha = RoutingIpsPolicy.sha256Hex("10.0.0.0/8\n".toByteArray(Charsets.UTF_8))
        val decision = RoutingIpsPolicy.decide(rule(ipsSha = sha), sha, "192.168.0.0/16\n")

        assertTrue(decision is RoutingIpsPolicy.Decision.Terminal)
        assertEquals("routing_ips_missing", (decision as RoutingIpsPolicy.Decision.Terminal).code)
    }

    @Test fun `no blob and no cache is terminal routing_ips_missing`() {
        val sha = "b".repeat(64)
        val decision = RoutingIpsPolicy.decide(rule(ipsSha = sha), null, null)
        assertTrue(decision is RoutingIpsPolicy.Decision.Terminal)
        val terminal = decision as RoutingIpsPolicy.Decision.Terminal
        assertEquals("routing_ips_missing", terminal.code)
        assertTrue(terminal.message.contains(sha))
    }

    @Test fun `a stale cache with no blob is terminal routing_ips_missing`() {
        val text = "10.0.0.0/8\n"
        val decision = RoutingIpsPolicy.decide(rule(ipsSha = "c".repeat(64)), "d".repeat(64), text)
        assertTrue(decision is RoutingIpsPolicy.Decision.Terminal)
        assertEquals("routing_ips_missing", (decision as RoutingIpsPolicy.Decision.Terminal).code)
    }

    @Test fun `no sha disables template routing`() {
        assertEquals(
            RoutingIpsPolicy.Decision.Disabled,
            RoutingIpsPolicy.decide(rule(), "a".repeat(64), "10.0.0.0/8\n"),
        )
    }

    @Test fun `a malformed sha rejects the whole rule`() {
        assertNull(parseServerRoutingRule("""{"ips_sha":"xyz"}"""))
    }

    @Test fun `a blob without a sha rejects the whole rule`() {
        assertNull(parseServerRoutingRule("""{"ips_blob":"AAAA"}"""))
    }

    @Test fun `template addresses never enter the explicit ips list`() {
        val rule = requireNotNull(
            parseServerRoutingRule("""{"ips":["1.1.1.1"],"ips_sha":"${"a".repeat(64)}"}"""),
        )
        assertEquals(listOf("1.1.1.1"), rule.ips)
    }

    @Test fun `argv flag is emitted only for a valid sha`() {
        val sha = "a".repeat(64)
        assertEquals(listOf("-routing-ips-sha", sha), RoutingIpsArgvPolicy.flag(sha))
        assertEquals(emptyList<String>(), RoutingIpsArgvPolicy.flag("bad"))
        assertEquals(emptyList<String>(), RoutingIpsArgvPolicy.flag(null))
        assertEquals(emptyList<String>(), RoutingIpsArgvPolicy.flag("A".repeat(64)))
    }
}
