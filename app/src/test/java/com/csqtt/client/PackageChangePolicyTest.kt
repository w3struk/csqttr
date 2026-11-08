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
        localPackages: Set<String> = emptySet(),
    ): Boolean = PackageChangePolicy.needsVpnRebuild(
        packageName = packageName,
        preset = preset,
        rulePackages = rulePackages,
        transportPackages = transportPackages,
        orangeEnabled = orangeEnabled,
        planExcludesPackages = planExcludesPackages,
        localPackages = localPackages,
    )

    private fun rule(
        isWhite: Boolean,
        packages: List<String> = emptyList(),
    ): ServerRoutingRule = ServerRoutingRule(
        isWhite = isWhite,
        packages = packages,
        domains = emptyList(),
        presetRed = preset.red.toList(),
        presetOrange = preset.orange.toList(),
    )

    private fun localModeNeedsRebuild(
        isWhitelist: Boolean,
        localPackages: Set<String>,
        packageName: String,
    ): Boolean = PackageChangePolicy.needsVpnRebuild(
        isWhitelist = isWhitelist,
        localPackages = localPackages,
        packageName = packageName,
        transportPackages = transportPackages,
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

    @Test
    fun `a package from the local list needs a rebuild in any plan shape`() {
        val localPackages = setOf("com.example.local")
        assertTrue(
            needsRebuild("com.example.local", planExcludesPackages = true, localPackages = localPackages)
        )
        assertTrue(
            needsRebuild("com.example.local", planExcludesPackages = false, localPackages = localPackages)
        )
    }

    @Test
    fun `a local package needs a rebuild even under an empty white rule`() {
        assertTrue(
            PackageChangePolicy.needsVpnRebuild(
                rule = rule(isWhite = true),
                packageName = "com.example.local",
                transportPackages = transportPackages,
                orangeEnabled = emptySet(),
                localPackages = setOf("com.example.local"),
            )
        )
    }

    @Test
    fun `the local mode form rebuilds for the active list in both modes`() {
        val localPackages = setOf("com.example.local")
        assertTrue(
            localModeNeedsRebuild(
                isWhitelist = false,
                localPackages = localPackages,
                packageName = "com.example.local",
            )
        )
        assertTrue(
            localModeNeedsRebuild(
                isWhitelist = true,
                localPackages = localPackages,
                packageName = "com.example.local",
            )
        )
        assertFalse(
            localModeNeedsRebuild(
                isWhitelist = false,
                localPackages = localPackages,
                packageName = "com.example.unrelated",
            )
        )
        assertFalse(
            localModeNeedsRebuild(
                isWhitelist = true,
                localPackages = localPackages,
                packageName = "com.example.unrelated",
            )
        )
    }

    @Test
    fun `the local mode form still rebuilds transport only when excluding`() {
        assertTrue(
            localModeNeedsRebuild(
                isWhitelist = false,
                localPackages = emptySet(),
                packageName = CsqttConstants.General.PACKAGE_VK,
            )
        )
        assertFalse(
            localModeNeedsRebuild(
                isWhitelist = true,
                localPackages = emptySet(),
                packageName = CsqttConstants.General.PACKAGE_VK,
            )
        )
    }

    @Test
    fun `a substituted white rule rebuilds for preset and transport packages`() {
        val invisible = rule(isWhite = true, packages = listOf("com.example.invisible"))

        listOf("ru.sberbankmobile", "com.wildberries.ru", CsqttConstants.General.PACKAGE_VK)
            .forEach { pkg ->
                assertTrue(
                    "под подменой $pkg меняет покрытие",
                    PackageChangePolicy.needsVpnRebuild(
                        rule = invisible,
                        packageName = pkg,
                        transportPackages = transportPackages,
                        orangeEnabled = emptySet(),
                        localPackages = emptySet(),
                        planSubstituted = true,
                    ),
                )
            }

        listOf("ru.sberbankmobile", "com.wildberries.ru", CsqttConstants.General.PACKAGE_VK)
            .forEach { pkg ->
                assertFalse(
                    "обычный белый список всё так же не реагирует на $pkg",
                    PackageChangePolicy.needsVpnRebuild(
                        rule = invisible,
                        packageName = pkg,
                        transportPackages = transportPackages,
                        orangeEnabled = emptySet(),
                        localPackages = emptySet(),
                        planSubstituted = false,
                    ),
                )
            }
    }

    @Test
    fun `a substituted white rule rebuilds when a local package disappears`() {
        val invisible = rule(isWhite = true, packages = listOf("com.example.invisible"))
        val localPackages = setOf("com.example.local")

        assertTrue(
            "удаление локального пакета — переход «в подмену»",
            PackageChangePolicy.needsVpnRebuild(
                rule = invisible,
                packageName = "com.example.local",
                transportPackages = transportPackages,
                orangeEnabled = emptySet(),
                localPackages = localPackages,
                planSubstituted = true,
            ),
        )
        assertTrue(
            "переход «из подмены» ловится пакетом правила",
            PackageChangePolicy.needsVpnRebuild(
                rule = invisible,
                packageName = "com.example.invisible",
                transportPackages = transportPackages,
                orangeEnabled = emptySet(),
                localPackages = localPackages,
                planSubstituted = true,
            ),
        )
        assertFalse(
            "посторонний пакет пересборку не запускает",
            PackageChangePolicy.needsVpnRebuild(
                rule = invisible,
                packageName = "com.example.unrelated",
                transportPackages = transportPackages,
                orangeEnabled = emptySet(),
                localPackages = localPackages,
                planSubstituted = true,
            ),
        )
    }
}
