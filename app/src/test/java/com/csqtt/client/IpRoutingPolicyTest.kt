package com.csqtt.client

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * IP-роутинг включается тогда и только тогда, когда список IP непуст, и правило
 * сервера меняет маршруты VPN — иначе excludeRoutes остаются прежними до
 * переподключения.
 */
class IpRoutingPolicyTest {

    private fun rule(
        isWhite: Boolean = false,
        packages: List<String> = emptyList(),
        ipIsWhite: Boolean = false,
        ips: List<String> = emptyList(),
    ) = ServerRoutingRule(
        isWhite = isWhite,
        packages = packages,
        domains = emptyList(),
        templateDomains = false,
        ipIsWhite = ipIsWhite,
        ips = ips,
    )

    @Test
    fun `routing is on exactly when the list is not empty`() {
        assertTrue("непустой список включает роутинг", IpRoutingPolicy.isEnabled("10.0.0.1"))
        assertFalse("пустой список выключает роутинг", IpRoutingPolicy.isEnabled(""))
        assertFalse("пробелы — не список", IpRoutingPolicy.isEnabled("   "))
    }

    @Test
    fun `a first rule always needs a rebuild`() {
        assertTrue("первое правило требует пересборки", IpRoutingPolicy.needsVpnRebuild(null, rule()))
    }

    @Test
    fun `a change of the packages or the mode needs a rebuild`() {
        val previous = rule(packages = listOf("com.a"))
        assertTrue(
            "смена пакета требует пересборки",
            IpRoutingPolicy.needsVpnRebuild(previous, rule(packages = listOf("com.b"))),
        )
        assertTrue(
            "смена режима требует пересборки",
            IpRoutingPolicy.needsVpnRebuild(previous, rule(isWhite = true, packages = listOf("com.a"))),
        )
    }

    @Test
    fun `a change of the ip list needs a rebuild in blacklist mode`() {
        val previous = rule(ips = listOf("10.0.0.1"))
        assertTrue(
            "смена списка IP в режиме чёрного списка требует пересборки",
            IpRoutingPolicy.needsVpnRebuild(previous, rule(ips = listOf("10.0.0.2"))),
        )
    }

    @Test
    fun `a change of the ip list in whitelist mode needs no rebuild`() {
        val previous = rule(ipIsWhite = true, ips = listOf("10.0.0.1"))
        assertFalse(
            "в режиме белого списка IP маршрутов не создают — пересборка не нужна",
            IpRoutingPolicy.needsVpnRebuild(previous, rule(ipIsWhite = true, ips = listOf("10.0.0.2"))),
        )
    }

    @Test
    fun `a change of the ip mode needs a rebuild`() {
        val previous = rule(ipIsWhite = true, ips = listOf("10.0.0.1"))
        assertTrue(
            "смена режима списка IP требует пересборки",
            IpRoutingPolicy.needsVpnRebuild(previous, rule(ipIsWhite = false, ips = listOf("10.0.0.1"))),
        )
    }

    @Test
    fun `an unchanged rule needs no rebuild`() {
        val previous = rule(packages = listOf("com.a"), ips = listOf("10.0.0.1"))
        assertFalse(
            "правило без изменений пересборки не требует",
            IpRoutingPolicy.needsVpnRebuild(previous, rule(packages = listOf("com.a"), ips = listOf("10.0.0.1"))),
        )
    }
}
