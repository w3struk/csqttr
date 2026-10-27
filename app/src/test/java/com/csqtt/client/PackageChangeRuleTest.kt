package com.csqtt.client

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Склейка серверного правила в аргументы [PackageChangePolicy.needsVpnRebuild].
 *
 * Тесты держат именно то, что раньше жило в `TunnelService` и не проверялось:
 * инверсию `isWhite`, форму плана и разные источники пакетов. Ошибка здесь
 * либо теряет пересборку (новый UID остаётся не там), либо рвёт TCP на каждом
 * обновлении VK (транспорт в обычном белом списке).
 */
class PackageChangeRuleTest {

    private val self = "com.csqtt.client"
    private val transportPackages = CsqttConstants.General.VK_TRANSPORT_PACKAGES + self
    private val orange = "ru.sberbankmobile"
    private val red = "com.bank"

    private fun rule(
        isWhite: Boolean,
        packages: List<String> = emptyList(),
    ): ServerRoutingRule = ServerRoutingRule(
        isWhite = isWhite,
        packages = packages,
        domains = emptyList(),
        templateDomains = false,
        presetRed = listOf(red),
        presetOrange = listOf(orange),
    )

    private fun needsRebuild(
        rule: ServerRoutingRule,
        packageName: String,
        orangeEnabled: Set<String> = emptySet(),
    ): Boolean = PackageChangePolicy.needsVpnRebuild(rule, packageName, transportPackages, orangeEnabled)

    @Test
    fun `blacklist reacts to rule, preset and transport packages`() {
        val blacklist = rule(isWhite = false, packages = listOf("com.vpn"))

        assertTrue(needsRebuild(blacklist, "com.vpn"))
        assertTrue(needsRebuild(blacklist, red))
        assertTrue(needsRebuild(blacklist, orange))
        assertTrue(needsRebuild(blacklist, CsqttConstants.General.PACKAGE_VK))
        assertTrue(needsRebuild(blacklist, CsqttConstants.General.PACKAGE_VK_CALLS))
        assertTrue(needsRebuild(blacklist, self))
        assertFalse(needsRebuild(blacklist, "org.telegram.messenger"))
    }

    @Test
    fun `a plain whitelist reacts only to the rule list and the oranges returned by the user`() {
        val whitelist = rule(isWhite = true, packages = listOf("com.vpn"))

        assertTrue(needsRebuild(whitelist, "com.vpn"))
        assertTrue(needsRebuild(whitelist, orange, orangeEnabled = setOf(orange)))
        assertFalse("пресет вычтен из allow-набора", needsRebuild(whitelist, red))
        assertFalse("оранжевый без согласия пользователя тоже вычтен", needsRebuild(whitelist, orange))
        assertFalse(
            "транспорт и так мимо allow-набора",
            needsRebuild(whitelist, CsqttConstants.General.PACKAGE_VK),
        )
        assertFalse(needsRebuild(whitelist, self))
    }

    @Test
    fun `a device-wide whitelist reacts to the preset and the transport`() {
        val deviceWide = rule(isWhite = true, packages = emptyList())

        assertTrue(needsRebuild(deviceWide, red))
        assertTrue(needsRebuild(deviceWide, orange))
        assertTrue(needsRebuild(deviceWide, CsqttConstants.General.PACKAGE_VK))
        assertTrue(needsRebuild(deviceWide, self))
        assertFalse(needsRebuild(deviceWide, "org.telegram.messenger"))
    }

    @Test
    fun `the plain whitelist shape is not confused by an empty preset`() {
        val whitelist = ServerRoutingRule(
            isWhite = true,
            packages = listOf("com.vpn"),
            domains = emptyList(),
            templateDomains = false,
        )

        assertTrue(needsRebuild(whitelist, "com.vpn"))
        assertFalse(needsRebuild(whitelist, red))
    }
}
