package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Проверяет решение, которое `TunVpnService` передаёт в `VpnService.Builder`,
 * без Android: чёрный режим, обычный белый список, белый список «на все
 * приложения» и отказ поднять VPN.
 */
class VpnAppRoutingTest {

    private val self = "com.csqtt.client"
    private val transport = setOf(self, "com.vkontakte.android")
    private val preset = PresetApps(red = setOf("com.bank"), orange = setOf("ru.sberbankmobile"))
    private val installed = setOf(
        self,
        "com.vkontakte.android",
        "com.vpn",
        "com.bank",
        "ru.sberbankmobile",
        "org.telegram.messenger",
    )

    private fun build(
        isWhite: Boolean,
        rulePackages: Set<String> = emptySet(),
        orangeEnabled: Set<String> = emptySet(),
        hasServerRule: Boolean = true,
    ): VpnAppsPlan = VpnAppRouting.build(
        hasServerRule = hasServerRule,
        isWhite = isWhite,
        rulePackages = rulePackages,
        preset = preset,
        userEnabled = orangeEnabled,
        transportPackages = transport,
        selfPackage = self,
        isInstalled = { it in installed },
    )

    @Test
    fun blacklistExcludesRulePresetAndTransportButNeverItself() {
        val plan = build(isWhite = false, rulePackages = setOf("com.vpn"))

        assertTrue("чёрный режим не использует allow-список", plan is VpnAppsPlan.Disallow)
        val disallow = plan as VpnAppsPlan.Disallow
        assertFalse("CSQTT добавляет исключение сам, первым вызовом", self in disallow.packages)
        assertEquals(
            "исключены правило, весь пресет и транспортный пакет",
            setOf("com.vpn", "com.bank", "ru.sberbankmobile", "com.vkontakte.android"),
            disallow.packages.toSet(),
        )
        assertFalse("это не правило на все приложения", disallow.deviceWide)
    }

    @Test
    fun blacklistReturnsTheOrangeTheUserRestored() {
        val plan = build(
            isWhite = false,
            rulePackages = setOf("com.vpn"),
            orangeEnabled = setOf("ru.sberbankmobile"),
        ) as VpnAppsPlan.Disallow

        assertEquals(
            "возвращённый оранжевый идёт в туннель",
            setOf("com.vpn", "com.bank", "com.vkontakte.android"),
            plan.packages.toSet(),
        )
    }

    @Test
    fun localBlacklistExcludesOnlyTheSavedPackages() {
        val plan = build(
            isWhite = false,
            rulePackages = setOf("com.vpn"),
            hasServerRule = false,
        ) as VpnAppsPlan.Disallow

        assertEquals(
            "без серверного правила пресета нет",
            setOf("com.vpn", "com.vkontakte.android"),
            plan.packages.toSet(),
        )
    }

    @Test
    fun whitelistAllowsOnlyRulePackagesOutsideThePreset() {
        val plan = build(
            isWhite = true,
            rulePackages = setOf("com.vpn", "com.bank", "ru.sberbankmobile", "com.example.notinstalled"),
        )

        assertEquals(
            "красный вычтен, оранжевый без разрешения тоже, неустановленный отброшен",
            listOf("com.vpn"),
            (plan as VpnAppsPlan.Allow).packages,
        )
    }

    @Test
    fun whitelistAllowsTheOrangeTheUserRestored() {
        val plan = build(
            isWhite = true,
            rulePackages = setOf("com.vpn"),
            orangeEnabled = setOf("ru.sberbankmobile"),
        ) as VpnAppsPlan.Allow

        assertEquals(
            "разрешённый пользователем оранжевый добавлен к правилу",
            setOf("com.vpn", "ru.sberbankmobile"),
            plan.packages.toSet(),
        )
    }

    @Test
    fun whitelistWithoutServerRuleAllowsTheSavedPackages() {
        val plan = build(
            isWhite = true,
            rulePackages = setOf("com.vpn", "org.telegram.messenger"),
            hasServerRule = false,
        ) as VpnAppsPlan.Allow

        assertEquals(
            "локальный белый список работает как раньше",
            setOf("com.vpn", "org.telegram.messenger"),
            plan.packages.toSet(),
        )
    }

    @Test
    fun emptyServerWhitelistExcludesThePresetFromAllApps() {
        val plan = build(isWhite = true, rulePackages = emptySet())

        assertTrue("правило на все приложения — это disallow-список", plan is VpnAppsPlan.Disallow)
        val disallow = plan as VpnAppsPlan.Disallow
        assertTrue("ветка «на все приложения»", disallow.deviceWide)
        assertFalse("себя сервис исключает отдельно", self in disallow.packages)
        assertEquals(
            "мимо туннеля идут транспорт и весь пресет",
            setOf("com.vkontakte.android", "com.bank", "ru.sberbankmobile"),
            disallow.packages.toSet(),
        )
    }

    @Test
    fun deviceWideRuleStillReturnsAnOrangeTheUserRestored() {
        val plan = build(
            isWhite = true,
            rulePackages = emptySet(),
            orangeEnabled = setOf("ru.sberbankmobile"),
        ) as VpnAppsPlan.Disallow

        assertEquals(
            "возвращённый оранжевый не исключается",
            setOf("com.vkontakte.android", "com.bank"),
            plan.packages.toSet(),
        )
    }

    @Test
    fun emptyLocalWhitelistFailsWithTheRealCause() {
        val plan = build(isWhite = true, rulePackages = emptySet(), hasServerRule = false)

        assertTrue("пустой белый список не поднимает VPN", plan is VpnAppsPlan.Failure)
        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "текст просит выбрать приложения, а не вернуть оранжевые",
            message.contains("выберите приложения"),
        )
        assertFalse("в локальном режиме оранжевых нет", message.contains("оранж"))
    }

    @Test
    fun whitelistOfDisabledAppsFailsWithTheRealCause() {
        val plan = build(isWhite = true, rulePackages = setOf("com.example.notinstalled"))

        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "текст называет неустановленные приложения: $message",
            message.contains("не установлено"),
        )
        assertFalse("и не врёт про оранжевые", message.contains("верните оранжевые"))
    }

    @Test
    fun whitelistOfRedAppsFailsWithTheRealCause() {
        val plan = build(isWhite = true, rulePackages = setOf("com.bank"))

        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "текст называет красный уровень: $message",
            message.contains("всегда мимо туннеля"),
        )
        assertFalse("и не врёт про оранжевые", message.contains("верните оранжевые"))
    }

    @Test
    fun whitelistOfOrangeWithoutUserConsentFailsWithTheRealCause() {
        val plan = build(isWhite = true, rulePackages = setOf("ru.sberbankmobile"))

        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "текст называет отсутствие разрешения пользователя: $message",
            message.contains("оранжевые приложения не разрешены"),
        )
    }

    @Test
    fun whitelistOfTransportPackagesFailsWithTheRealCause() {
        val plan = build(
            isWhite = true,
            rulePackages = setOf("com.vkontakte.android"),
            hasServerRule = false,
        )

        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "текст называет транспортные пакеты: $message",
            message.contains("транспортные пакеты"),
        )
    }
}
