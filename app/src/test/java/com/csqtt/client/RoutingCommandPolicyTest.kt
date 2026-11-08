package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RoutingCommandPolicyTest {

    @Test fun `template ips never reach the vpn exclude routes`() {
        val rule = requireNotNull(
            parseServerRoutingRule("""{"ips":["1.1.1.1"],"ips_sha":"${"a".repeat(64)}"}"""),
        )
        assertEquals(listOf("1.1.1.1"), VpnExcludeRoutePolicy.entries(rule))
        assertEquals(emptyList<String>(), VpnExcludeRoutePolicy.entries(rule.copy(ipIsWhite = true)))
        assertEquals(emptyList<String>(), VpnExcludeRoutePolicy.entries(null))
    }

    @Test fun `terminal routing blocks the later config start`() {
        val gate = RoutingTerminalState()
        gate.onResult(RoutingApplyResult.Terminal("routing_ips_missing", "…"))
        assertTrue(gate.terminal)
        // Config приходит следующим кадром: старт VPN обязан быть заблокирован флагом,
        // не полагаясь на то, что handleCriticalError уже успел остановить процесс.
        assertFalse(RoutingVpnStartPolicy.shouldStart(RoutingApplyResult.Applied, gate.terminal))
    }

    @Test fun `an applied rule resets the terminal flag`() {
        val gate = RoutingTerminalState()
        gate.onResult(RoutingApplyResult.Terminal("routing_ips_bad_blob", "…"))
        gate.onResult(RoutingApplyResult.Applied)
        assertFalse(gate.terminal)
        assertTrue(RoutingVpnStartPolicy.shouldStart(RoutingApplyResult.Applied, gate.terminal))
    }

    @Test fun `domain command with the maximum rule stays under the stdin limit`() {
        val domains = (0 until 1024).joinToString(",") { "d$it.example.com" }
        val ips = (0 until 512).joinToString(",") { "10.0.${(it / 256) % 256}.${it % 256}/32" }

        val command = RoutingCommandPolicy.domainRoutingCommand(true, domains, false, false, ips)

        assertTrue("${command.toByteArray().size}", command.toByteArray().size <= 64 * 1024)
    }

    @Test fun `domain command keeps ip_enabled derived from the explicit list`() {
        val enabled = RoutingCommandPolicy.domainRoutingCommand(true, "ok.ru", false, false, "1.1.1.1")
        assertTrue(enabled.contains("ip_enabled=1"))
        assertFalse(enabled.contains("template="))

        val disabled = RoutingCommandPolicy.domainRoutingCommand(false, "", false, false, "")
        assertTrue(disabled.contains("ip_enabled=0"))
        assertTrue(disabled.startsWith("UPDATE_DOMAINS|enabled=0;whitelist=0;domains="))
    }

    @Test fun `update ips command carries the sha and the blob`() {
        assertEquals("UPDATE_IPS|abc|AAA", RoutingCommandPolicy.updateIpsCommand("abc", "AAA"))
        assertEquals("UPDATE_IPS|", RoutingCommandPolicy.clearIpsCommand())
    }
}
