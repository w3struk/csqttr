package com.csqtt.client

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Пересборка VPN после смены пакетов нужна только там, где меняется план
 * маршрутизации: пакеты правила, оранжевые, возвращённые пользователем, и — в
 * зависимости от формы плана — транспорт и пресет. Пакет вне их по-прежнему
 * покрыт диапазоном UID, и пересборка только порвала бы ему TCP.
 */
class PackageChangePolicyTest {

    private val preset = PresetApps(
        red = setOf("ru.sberbankmobile", "ru.fns.lkfl"),
        orange = setOf("ru.vk.store", "com.wildberries.ru"),
    )
    private val rulePackages = setOf("com.example.allowed", "ru.ozon.app.android")
    private val transportPackages = setOf(
        "com.csqtt.client",
        CsqttConstants.General.PACKAGE_VK,
        CsqttConstants.General.PACKAGE_VK_CALLS,
    )

    private fun needsRebuild(
        packageName: String,
        orangeEnabled: Set<String> = emptySet(),
        planExcludesPackages: Boolean = true,
    ): Boolean = PackageChangePolicy.needsVpnRebuild(
        packageName = packageName,
        preset = preset,
        rulePackages = rulePackages,
        transportPackages = transportPackages,
        orangeEnabled = orangeEnabled,
        planExcludesPackages = planExcludesPackages,
    )

    @Test
    fun `a package from the red preset needs a rebuild`() {
        assertTrue(needsRebuild("ru.sberbankmobile"))
    }

    @Test
    fun `a package from the orange preset needs a rebuild`() {
        assertTrue(needsRebuild("com.wildberries.ru"))
    }

    @Test
    fun `a package from the rule list needs a rebuild in any plan shape`() {
        assertTrue(needsRebuild("com.example.allowed", planExcludesPackages = true))
        assertTrue(needsRebuild("com.example.allowed", planExcludesPackages = false))
    }

    @Test
    fun `a transport package needs a rebuild only when the plan excludes packages`() {
        assertTrue(needsRebuild(CsqttConstants.General.PACKAGE_VK, planExcludesPackages = true))
        assertTrue(needsRebuild(CsqttConstants.General.PACKAGE_VK_CALLS, planExcludesPackages = true))
        assertTrue(needsRebuild("com.csqtt.client", planExcludesPackages = true))

        assertFalse(needsRebuild(CsqttConstants.General.PACKAGE_VK, planExcludesPackages = false))
        assertFalse(needsRebuild("com.csqtt.client", planExcludesPackages = false))
    }

    @Test
    fun `an orange returned by the user needs a rebuild in any plan shape`() {
        assertTrue(needsRebuild("com.wildberries.ru", orangeEnabled = setOf("com.wildberries.ru")))
        assertTrue(
            needsRebuild(
                "com.wildberries.ru",
                orangeEnabled = setOf("com.wildberries.ru"),
                planExcludesPackages = false,
            )
        )
    }

    @Test
    fun `a preset package needs no rebuild in a plain allow plan unless the user returned it`() {
        assertFalse(needsRebuild("ru.sberbankmobile", planExcludesPackages = false))
        assertFalse(needsRebuild("com.wildberries.ru", planExcludesPackages = false))
        assertFalse(
            needsRebuild(
                "ru.sberbankmobile",
                orangeEnabled = setOf("com.wildberries.ru"),
                planExcludesPackages = false,
            )
        )
    }

    @Test
    fun `a package outside the preset, the rule, the transport and the user list needs no rebuild`() {
        assertFalse(needsRebuild("com.example.unrelated"))
        assertFalse(needsRebuild("com.example.unrelated", planExcludesPackages = false))
    }

    @Test
    fun `an empty preset and rule never needs a rebuild`() {
        assertFalse(
            PackageChangePolicy.needsVpnRebuild(
                packageName = "com.example.unrelated",
                preset = PresetApps(red = emptySet(), orange = emptySet()),
                rulePackages = emptySet(),
                transportPackages = transportPackages,
                orangeEnabled = emptySet(),
                planExcludesPackages = true,
            )
        )
    }

    @Test
    fun `an empty package name needs no rebuild`() {
        assertFalse(needsRebuild(""))
    }
}
