package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Проверяет решение, которое `TunVpnService` передаёт в `VpnService.Builder`,
 * без Android: чёрный режим, обычный белый список, отказ при пустом наборе и
 * подмена невидимого белого списка.
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
        userExcluded: Set<String> = emptySet(),
        serverRulePackages: Set<String> = rulePackages,
    ): VpnAppsPlan = VpnAppRouting.build(
        hasServerRule = hasServerRule,
        isWhite = isWhite,
        rulePackages = rulePackages,
        preset = preset,
        userEnabled = orangeEnabled,
        transportPackages = transport,
        selfPackage = self,
        isInstalled = { it in installed },
        userExcluded = userExcluded,
        serverRulePackages = serverRulePackages,
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
    fun blacklistDeduplicatesPackagesSharedByRuleAndTransport() {
        val plan = build(
            isWhite = false,
            rulePackages = setOf("com.vkontakte.android", "com.vpn"),
        ) as VpnAppsPlan.Disallow

        assertEquals(
            "пакет из правила и транспорта попадает в disallow-список один раз",
            1,
            plan.packages.count { it == "com.vkontakte.android" },
        )
        assertEquals(
            "дубликатов в плане нет",
            plan.packages.distinct(),
            plan.packages,
        )
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
    fun `emptyServerWhitelistFailsWithTheRealCause`() {
        val plan = build(isWhite = true, rulePackages = emptySet())

        assertTrue("пустой белый список не поднимает VPN", plan is VpnAppsPlan.Failure)
        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "текст называет режим правила: $message",
            message.contains("правило сервера задано в белом режиме"),
        )
        assertTrue(
            "и отправляет к тому, кто может его поправить: $message",
            message.contains("поправьте правило на сервере"),
        )
        assertFalse(
            "пользователь не может добавить приложение в белый список под правилом: $message",
            message.contains("добавьте приложения"),
        )
    }

    @Test
    fun `a red app in the rule does not hide the user exclusion cause`() {
        val plan = build(
            isWhite = true,
            rulePackages = setOf("com.bank"),
            serverRulePackages = setOf("com.vpn", "com.bank"),
            userExcluded = setOf("com.vpn"),
        )

        assertTrue("allow-набор пуст — отказ", plan is VpnAppsPlan.Failure)
        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "причина исключения пользователя названа: $message",
            message.contains("исключили установленные приложения"),
        )
        assertTrue(
            "и совет снять исключения есть: $message",
            message.contains("Снимите исключения: «Настройки» → «Список приложений»"),
        )
    }

    @Test
    fun `emptyServerWhitelistWithARestoredOrangeCarriesJustThatOrange`() {
        val plan = build(
            isWhite = true,
            rulePackages = emptySet(),
            orangeEnabled = setOf("ru.sberbankmobile"),
        )

        assertEquals(
            "возвращённый оранжевый — элемент белого списка и идёт в туннель один",
            listOf("ru.sberbankmobile"),
            (plan as VpnAppsPlan.Allow).packages,
        )
    }

    @Test
    fun `localWhitelistOfUninstalledPackagesStillFailsWithTheRealCause`() {
        val plan = build(
            isWhite = true,
            rulePackages = setOf("com.example.notinstalled"),
            hasServerRule = false,
        )

        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "текст называет неустановленные приложения: $message",
            message.contains("не установлено"),
        )
        assertFalse("и не врёт про оранжевые", message.contains("оранж"))
    }

    @Test
    fun `serverWhitelistOfInvisiblePackagesFallsBackToAllApps`() {
        val plan = build(isWhite = true, rulePackages = setOf("com.example.notinstalled"))

        assertTrue("подмена — это disallow-план", plan is VpnAppsPlan.Disallow)
        val disallow = plan as VpnAppsPlan.Disallow
        assertTrue("план покрывает всё устройство", disallow.deviceWide)
        assertTrue("и помечен подменой", disallow.substituted)
        assertFalse("себя сервис исключает отдельно", self in disallow.packages)
        assertEquals(
            "мимо туннеля идут транспорт и весь пресет",
            setOf("com.vkontakte.android", "com.bank", "ru.sberbankmobile"),
            disallow.packages.toSet(),
        )
    }

    @Test
    fun `aVisiblePackageInTheMergedSetKeepsTheAllowPlan`() {
        val plan = build(
            isWhite = true,
            rulePackages = setOf("com.example.notinstalled", "org.telegram.messenger"),
        )

        assertEquals(
            "видимый пакет уважается — подмены нет",
            listOf("org.telegram.messenger"),
            (plan as VpnAppsPlan.Allow).packages,
        )
    }

    @Test
    fun `anInvisibleRuleWithARestoredOrangeStillFallsBackToAllApps`() {
        val plan = build(
            isWhite = true,
            rulePackages = setOf("com.example.notinstalled"),
            orangeEnabled = setOf("ru.sberbankmobile"),
        )

        assertTrue("подмена проверяется до ветки Allow", plan is VpnAppsPlan.Disallow)
        val disallow = plan as VpnAppsPlan.Disallow
        assertTrue("план остаётся device-wide", disallow.deviceWide)
        assertTrue("и помечен подменой", disallow.substituted)
        assertEquals(
            "возвращённый оранжевый в туннеле, в disallow-списке его нет",
            setOf("com.vkontakte.android", "com.bank"),
            disallow.packages.toSet(),
        )
    }

    @Test
    fun `blackRuleWithEmptyPackagesTunnelsTheDeviceExceptPresetAndTransport`() {
        val plan = build(isWhite = false, rulePackages = emptySet())

        assertTrue("чёрное пустое правило — disallow-план", plan is VpnAppsPlan.Disallow)
        val disallow = plan as VpnAppsPlan.Disallow
        assertFalse("это не подмена", disallow.deviceWide)
        assertFalse("и не помечено подменой", disallow.substituted)
        assertFalse("себя сервис исключает отдельно", self in disallow.packages)
        assertEquals(
            "мимо туннеля идут транспорт и весь пресет",
            setOf("com.vkontakte.android", "com.bank", "ru.sberbankmobile"),
            disallow.packages.toSet(),
        )
    }

    @Test
    fun `blackRuleWithEmptyPackagesStillReturnsTheOrangeTheUserRestored`() {
        val plan = build(
            isWhite = false,
            rulePackages = emptySet(),
            orangeEnabled = setOf("ru.sberbankmobile"),
        ) as VpnAppsPlan.Disallow

        assertFalse("это по-прежнему чёрный план, не подмена", plan.deviceWide)
        assertEquals(
            "возвращённый оранжевый в туннеле, в disallow-списке его нет",
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
        assertFalse(
            "и режима серверного правила тоже нет: $message",
            message.contains("правило сервера"),
        )
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

    @Test
    fun orangeWithoutUserConsentAdvisesTheUserActionNotTheServerRule() {
        val plan = build(isWhite = true, rulePackages = setOf("ru.sberbankmobile"))

        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "совет называет действие пользователя: $message",
            message.contains("Верните оранжевые приложения в туннель"),
        )
        assertFalse(
            "пользователь не может поправить правило на сервере: $message",
            message.contains("Поправьте правило на сервере"),
        )
    }

    @Test
    fun redAppsStillAdviseFixingTheServerRule() {
        val plan = build(isWhite = true, rulePackages = setOf("com.bank"))

        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "красный уровень чинится правилом сервера: $message",
            message.contains("Поправьте правило на сервере"),
        )
        assertFalse(
            "оранжевых в причине нет, значит и совета про них нет: $message",
            message.contains("Верните оранжевые"),
        )
    }

    @Test
    fun mixedReasonsAdviseBothFixes() {
        val plan = build(
            isWhite = true,
            rulePackages = setOf("com.bank", "ru.sberbankmobile"),
        )

        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "совет по красному уровню — серверный: $message",
            message.contains("Поправьте правило на сервере"),
        )
        assertTrue(
            "совет по оранжевым — пользовательский: $message",
            message.contains("Верните оранжевые приложения в туннель"),
        )
        assertTrue(
            "каждая причина названа: $message",
            message.contains("всегда мимо туннеля") &&
                message.contains("оранжевые приложения не разрешены пользователем"),
        )
    }

    @Test
    fun localWhitelistNeverAdvisesFixingTheServerRule() {
        val plan = build(
            isWhite = true,
            rulePackages = setOf("ru.sberbankmobile"),
            hasServerRule = false,
        )

        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "совет остаётся действием пользователя: $message",
            message.contains("Верните оранжевые приложения в туннель"),
        )
        assertFalse(
            "локальный режим не лечится правкой серверного правила: $message",
            message.contains("Поправьте правило на сервере"),
        )
    }

    // --- Исключения пользователя ---------------------------------------------

    @Test
    fun `substituted whitelist keeps the user exclusions out of the tunnel`() {
        val plan = build(
            isWhite = true,
            rulePackages = setOf("com.example.notinstalled"),
            userExcluded = setOf("com.vpn"),
        ) as VpnAppsPlan.Disallow

        assertTrue("план остаётся device-wide", plan.deviceWide)
        assertTrue("исключение пользователя в disallow-списке", "com.vpn" in plan.packages)
        assertEquals(
            "транспорт и пресет по-прежнему мимо",
            setOf("com.vkontakte.android", "com.bank", "ru.sberbankmobile", "com.vpn"),
            plan.packages.toSet(),
        )
    }

    @Test
    fun `a restored orange wins over the user exclusion in the substituted plan`() {
        val plan = build(
            isWhite = true,
            rulePackages = setOf("com.example.notinstalled"),
            orangeEnabled = setOf("ru.sberbankmobile"),
            userExcluded = setOf("ru.sberbankmobile"),
        ) as VpnAppsPlan.Disallow

        assertEquals(
            "возвращённый оранжевый остался в туннеле",
            setOf("com.vkontakte.android", "com.bank"),
            plan.packages.toSet(),
        )
    }

    @Test
    fun `a visible rule does not become substituted after excluding its installed app`() {
        val plan = build(
            isWhite = true,
            rulePackages = setOf("com.example.notinstalled"),
            serverRulePackages = setOf("com.vpn", "com.example.notinstalled"),
            userExcluded = setOf("com.vpn"),
        )

        assertTrue("подмены нет — это отказ", plan is VpnAppsPlan.Failure)
        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "причина — исключения пользователя: $message",
            message.contains("исключили все установленные"),
        )
        assertFalse(
            "и не советует править белый список: $message",
            message.contains("добавьте приложения"),
        )
    }

    @Test
    fun `a whitelist emptied by the user fails with the user cause`() {
        val plan = build(
            isWhite = true,
            rulePackages = emptySet(),
            serverRulePackages = setOf("com.vpn"),
            userExcluded = setOf("com.vpn"),
        )

        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue("причина названа: $message", message.contains("исключили все установленные"))
        assertTrue("и действие: $message", message.contains("снимите исключения"))
        assertFalse(
            "и не советует править белый список: $message",
            message.contains("добавьте приложения"),
        )
    }

    @Test
    fun `a user-excluded red rule app names the preset cause, not the exclusion`() {
        val plan = build(
            isWhite = true,
            rulePackages = emptySet(),
            serverRulePackages = setOf("com.bank"),
            userExcluded = setOf("com.bank"),
        )

        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue("названа красная причина: $message", message.contains("всегда мимо туннеля"))
        assertTrue(
            "и серверный совет: $message",
            message.contains("Поправьте правило на сервере"),
        )
        assertFalse(
            "снятие исключения не вернёт туннель — вины пользователя нет: $message",
            message.contains("снимите исключения"),
        )
    }

    @Test
    fun `a user-excluded orange rule app asks to restore the orange`() {
        val plan = build(
            isWhite = true,
            rulePackages = emptySet(),
            serverRulePackages = setOf("ru.sberbankmobile"),
            userExcluded = setOf("ru.sberbankmobile"),
        )

        val message = (plan as VpnAppsPlan.Failure).message
        assertTrue(
            "названа оранжевая причина: $message",
            message.contains("оранжевые приложения не разрешены пользователем"),
        )
        assertTrue(
            "и совет вернуть оранжевый: $message",
            message.contains("Верните оранжевые приложения в туннель"),
        )
        assertFalse(
            "снятие исключения не вернёт туннель — вины пользователя нет: $message",
            message.contains("снимите исключения"),
        )
    }

    @Test
    fun `user exclusions never expand VPN coverage`() {
        val rawRule = setOf("com.vpn", "com.example.notinstalled")
        val before = build(
            isWhite = true,
            rulePackages = rawRule,
            serverRulePackages = rawRule,
        )
        val after = build(
            isWhite = true,
            rulePackages = setOf("com.example.notinstalled"),
            serverRulePackages = rawRule,
            userExcluded = setOf("com.vpn"),
        )

        assertTrue("до исключения — обычный allow-план", before is VpnAppsPlan.Allow)
        assertTrue("после — отказ, а не device-wide", after is VpnAppsPlan.Failure)
    }

    @Test
    fun `a restored orange keeps the tunnel when the user emptied the rule`() {
        val plan = build(
            isWhite = true,
            rulePackages = emptySet(),
            serverRulePackages = setOf("com.vpn"),
            userExcluded = setOf("com.vpn"),
            orangeEnabled = setOf("ru.sberbankmobile"),
        ) as VpnAppsPlan.Allow

        assertEquals(
            "оранжевый один держит туннель, отказа нет",
            listOf("ru.sberbankmobile"),
            plan.packages,
        )
    }
}
