package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RoutingConfigPolicyTest {
    private fun rule(packages: List<String>) = ServerRoutingRule(
        isWhite = true,
        packages = packages,
        domains = emptyList(),
        templateDomains = false,
    )

    @Test
    fun `an embedded rule wins over the active one`() {
        val embedded = rule(listOf("a.b"))
        val active = rule(listOf("c.d"))

        assertEquals(embedded, RoutingConfigPolicy.ruleToApply(embedded, active))
    }

    @Test
    fun `a config without a rule keeps the rule received by the routing event`() {
        val active = rule(listOf("a.b"))

        assertEquals(active, RoutingConfigPolicy.ruleToApply(embedded = null, active = active))
    }

    @Test
    fun `no embedded and no active rule stays empty`() {
        assertNull(RoutingConfigPolicy.ruleToApply(embedded = null, active = null))
    }

    @Test
    fun `tunnel endpoints are read from a tunconf`() {
        assertEquals(
            "10.66.67.4" to "77.88.8.8,77.88.8.1",
            RoutingConfigPolicy.tunnelEndpoints("TUNCONF:10.66.67.4:77.88.8.8,77.88.8.1:0:stream-v1:workers=10"),
        )
    }

    @Test
    fun `tunnel endpoints are empty without a tunconf`() {
        assertEquals("" to "", RoutingConfigPolicy.tunnelEndpoints(null))
        assertEquals("" to "", RoutingConfigPolicy.tunnelEndpoints(""))
        assertEquals("" to "", RoutingConfigPolicy.tunnelEndpoints("NOCONF"))
    }
}
