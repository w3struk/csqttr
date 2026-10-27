package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Пресет российских приложений делит пакеты на два уровня с противоположными
 * рисками: красный нельзя пускать в туннель ни при каких настройках оператора, а
 * оранжевый по умолчанию вне туннеля и возвращается в него только явным выбором
 * пользователя.
 *
 * Матрица режим × уровень: чёрный список исключает `P ∪ R ∪ O`, белый держит в
 * туннеле `(P \ R \ O) ∪ (O ∩ U)`.
 */
class AppRoutingPolicyTest {

    private val preset = PresetApps(red = setOf("com.bank"), orange = setOf("ru.sberbankmobile"))

    @Test
    fun forcedExcludedIsExactlyTheRedSet() {
        assertEquals(
            "принудительно исключены только красные",
            setOf("com.bank"),
            AppRoutingPolicy.forcedExcluded(preset),
        )
    }

    @Test
    fun allowedInTunnelRemovesRedEvenIfOperatorListedThem() {
        assertEquals(
            "красный сильнее списка оператора — в туннель не попадает",
            setOf("com.vpn"),
            AppRoutingPolicy.allowedInTunnel(setOf("com.bank", "com.vpn"), preset),
        )
    }

    @Test
    fun allowedInTunnelKeepsNonPresetPackages() {
        assertEquals(
            "пакет вне пресета остаётся в туннеле",
            setOf("org.telegram.messenger"),
            AppRoutingPolicy.allowedInTunnel(setOf("org.telegram.messenger"), preset),
        )
    }

    @Test
    fun allowedInTunnelKeepsOrangeOutEvenWhenOperatorListedIt() {
        assertEquals(
            "оранжевый из списка оператора идёт в туннель только через U",
            emptySet<String>(),
            AppRoutingPolicy.allowedInTunnel(setOf("ru.sberbankmobile"), preset),
        )
    }

    @Test
    fun orangeAllowedByUserIsTheOnlyWayIntoTheWhitelistTunnel() {
        val operatorPackages = setOf("ru.sberbankmobile")

        assertEquals(
            "пока пользователь не разрешил, оранжевый остаётся мимо туннеля",
            emptySet<String>(),
            AppRoutingPolicy.allowedInTunnel(operatorPackages, preset) +
                AppRoutingPolicy.orangeTunnelEnabled(preset, emptySet()),
        )
        assertEquals(
            "разрешённый пользователем оранжевый возвращается в туннель",
            operatorPackages,
            AppRoutingPolicy.allowedInTunnel(operatorPackages, preset) +
                AppRoutingPolicy.orangeTunnelEnabled(preset, operatorPackages),
        )
    }

    @Test
    fun packageInBothLevelsNeverEntersTheTunnel() {
        val overlap = "com.overlap"
        val both = PresetApps(
            red = setOf(overlap, "com.bank"),
            orange = setOf(overlap, "ru.sberbankmobile"),
        )

        assertEquals(
            "красный уровень сильнее оранжевого: в белый список не попадает",
            emptySet<String>(),
            AppRoutingPolicy.allowedInTunnel(setOf(overlap), both),
        )
        assertEquals(
            "и пользовательский список U его тоже не возвращает",
            emptySet<String>(),
            AppRoutingPolicy.orangeTunnelEnabled(both, setOf(overlap)),
        )

        val blackExcluded = AppRoutingPolicy.excludedInTunnel(emptySet(), both) -
            AppRoutingPolicy.orangeTunnelEnabled(both, setOf(overlap))
        assertTrue(
            "в чёрном режиме пакет остаётся исключённым даже при записи в U",
            overlap in blackExcluded,
        )

        val deviceWide = requireNotNull(
            AppRoutingPolicy.serverRuleCounts(
                hasServerRule = true,
                isWhite = true,
                rulePackages = emptySet(),
                preset = both,
                userEnabled = setOf(overlap),
                installedPackages = installed + overlap,
            )
        )
        assertEquals(
            "в белом режиме «на все приложения» пакет тоже мимо туннеля",
            2,
            deviceWide.inTunnel,
        )
        assertEquals("мимо туннеля красный и оранжевый", 3, deviceWide.excluded)
    }

    @Test
    fun excludedInTunnelAddsTheWholePresetToOperatorPackages() {
        assertEquals(
            "чёрный список исключает пакеты правила и весь пресет",
            setOf("com.vpn", "com.bank", "ru.sberbankmobile"),
            AppRoutingPolicy.excludedInTunnel(setOf("com.vpn"), preset),
        )
    }

    @Test
    fun excludedInTunnelOnEmptyOperatorListStillExcludesPreset() {
        assertEquals(
            "пустое правило всё равно исключает весь пресет",
            preset.all,
            AppRoutingPolicy.excludedInTunnel(emptySet(), preset),
        )
    }

    @Test
    fun orangeTunnelEnabledKeepsOnlyPresetOranges() {
        assertEquals(
            "из пользовательского списка остаются только актуальные оранжевые",
            setOf("ru.sberbankmobile"),
            AppRoutingPolicy.orangeTunnelEnabled(
                preset,
                setOf("ru.sberbankmobile", "com.bank", "com.garbage"),
            ),
        )
    }

    @Test
    fun orangeTunnelEnabledIsEmptyByDefault() {
        assertEquals(
            "без выбора пользователя оранжевый в туннель не идёт",
            emptySet<String>(),
            AppRoutingPolicy.orangeTunnelEnabled(preset, emptySet()),
        )
    }

    @Test
    fun toggleOrangeAddsThenRemovesPackage() {
        assertEquals(
            "переключение добавляет пакет",
            setOf("ru.sberbankmobile"),
            AppRoutingPolicy.toggleOrange(emptySet(), "ru.sberbankmobile"),
        )
        assertEquals(
            "повторное переключение убирает пакет",
            emptySet<String>(),
            AppRoutingPolicy.toggleOrange(setOf("ru.sberbankmobile"), "ru.sberbankmobile"),
        )
    }

    @Test
    fun nonOrangeInUserListNeverLeaksIntoEffectiveSet() {
        val userEnabled = AppRoutingPolicy.toggleOrange(emptySet(), "com.vk")

        assertEquals(
            "в пользовательский список пакет попадает",
            setOf("com.vk"),
            userEnabled,
        )
        assertEquals(
            "но в эффективное множество — нет",
            emptySet<String>(),
            AppRoutingPolicy.orangeTunnelEnabled(preset, userEnabled),
        )
    }

    @Test
    fun whitelistFormulaMatchesSpecMatrix() {
        val redOnly = setOf("com.bank")
        assertEquals(
            "красный не попадает в туннель ни при каких настройках",
            emptySet<String>(),
            AppRoutingPolicy.allowedInTunnel(redOnly, preset) +
                AppRoutingPolicy.orangeTunnelEnabled(preset, emptySet()),
        )
        assertEquals(
            "оранжевый, возвращённый пользователем, идёт в туннель",
            setOf("ru.sberbankmobile"),
            AppRoutingPolicy.allowedInTunnel(redOnly, preset) +
                AppRoutingPolicy.orangeTunnelEnabled(preset, setOf("ru.sberbankmobile")),
        )
        assertEquals(
            "обычный пакет правила остаётся в туннеле",
            setOf("com.vpn"),
            AppRoutingPolicy.allowedInTunnel(setOf("com.vpn"), preset) +
                AppRoutingPolicy.orangeTunnelEnabled(preset, emptySet()),
        )
    }

    @Test
    fun blacklistFormulaMatchesSpecMatrix() {
        val packages = setOf("com.vpn")
        assertEquals(
            "без выбора пользователя исключён весь пресет",
            setOf("com.vpn", "com.bank", "ru.sberbankmobile"),
            AppRoutingPolicy.excludedInTunnel(packages, preset) -
                AppRoutingPolicy.orangeTunnelEnabled(preset, emptySet()),
        )
        assertEquals(
            "оранжевый, возвращённый пользователем, уходит из исключённых",
            setOf("com.vpn", "com.bank"),
            AppRoutingPolicy.excludedInTunnel(packages, preset) -
                AppRoutingPolicy.orangeTunnelEnabled(preset, setOf("ru.sberbankmobile")),
        )
    }

    /**
     * Установленные приложения устройства. Транспортные пакеты (CSQTT, VK)
     * сюда не попадают — их отфильтровывает список приложений на экране.
     */
    private val installed = setOf(
        "com.vpn",
        "com.bank",
        "ru.sberbankmobile",
        "org.telegram.messenger",
    )

    private fun countsFor(
        isWhite: Boolean,
        rulePackages: Set<String>,
        userEnabled: Set<String> = emptySet(),
    ): RoutingCardCounts = requireNotNull(
        AppRoutingPolicy.serverRuleCounts(
            hasServerRule = true,
            isWhite = isWhite,
            rulePackages = rulePackages,
            preset = preset,
            userEnabled = userEnabled,
            installedPackages = installed,
        )
    )

    @Test
    fun deviceWideRuleOnlyWhenWhitelistHasNoOperatorPackages() {
        assertTrue(
            "белый список без пакетов — это правило на все приложения",
            AppRoutingPolicy.isDeviceWideRule(isWhite = true, rulePackages = emptySet()),
        )
        assertFalse(
            "белый список с пакетами остаётся обычным белым списком",
            AppRoutingPolicy.isDeviceWideRule(isWhite = true, rulePackages = setOf("com.vpn")),
        )
        assertFalse(
            "чёрный список без пакетов правилом на все приложения не становится",
            AppRoutingPolicy.isDeviceWideRule(isWhite = false, rulePackages = emptySet()),
        )
    }

    @Test
    fun blacklistCountsExcludeTheWholePreset() {
        val counts = countsFor(isWhite = false, rulePackages = setOf("com.vpn"))

        assertEquals("исключены правило, красный и оранжевый", 3, counts.excluded)
        assertEquals("в туннеле только приложение вне пресета", 1, counts.inTunnel)
        assertEquals("красный на устройстве", 1, counts.alwaysExcluded)
        assertEquals("оранжевый на устройстве", 1, counts.optOut)
    }

    @Test
    fun blacklistReturnsTheOrangeTheUserRestored() {
        val counts = countsFor(
            isWhite = false,
            rulePackages = setOf("com.vpn"),
            userEnabled = setOf("ru.sberbankmobile"),
        )

        assertEquals("возвращённый оранжевый больше не исключён", 2, counts.excluded)
        assertEquals("он идёт в туннель вместе с обычными", 2, counts.inTunnel)
    }

    @Test
    fun whitelistCountsOnlyInstalledRulePackages() {
        val counts = countsFor(
            isWhite = true,
            rulePackages = setOf("com.vpn", "com.bank", "com.example.notinstalled"),
        )

        assertEquals("в туннеле обычный пакет правила", 1, counts.inTunnel)
        assertEquals("красный вычтен, неустановленный не считается", 3, counts.excluded)
        assertEquals("красный на устройстве", 1, counts.alwaysExcluded)
        assertEquals("оранжевый на устройстве", 1, counts.optOut)
    }

    @Test
    fun whitelistReturnsTheOrangeTheUserRestored() {
        val counts = countsFor(
            isWhite = true,
            rulePackages = setOf("com.vpn"),
            userEnabled = setOf("ru.sberbankmobile"),
        )

        assertEquals("возвращённый оранжевый в туннеле", 2, counts.inTunnel)
        assertEquals("мимо туннеля остаются красный и приложение вне правила", 2, counts.excluded)
    }

    @Test
    fun whitelistCountsKeepOperatorOrangeOutOfTheTunnel() {
        val counts = countsFor(
            isWhite = true,
            rulePackages = setOf("com.vpn", "ru.sberbankmobile"),
        )

        assertEquals("оранжевый из списка оператора без U в туннель не идёт", 1, counts.inTunnel)
        assertEquals("мимо туннеля красный, оранжевый и приложение вне правила", 3, counts.excluded)
        assertEquals("красный на устройстве", 1, counts.alwaysExcluded)
        assertEquals("оранжевый на устройстве", 1, counts.optOut)

        val restored = countsFor(
            isWhite = true,
            rulePackages = setOf("com.vpn", "ru.sberbankmobile"),
            userEnabled = setOf("ru.sberbankmobile"),
        )

        assertEquals("пользователь вернул оранжевый в туннель", 2, restored.inTunnel)
        assertEquals("мимо туннеля красный и приложение вне правила", 2, restored.excluded)
    }

    @Test
    fun whitelistWithEmptyPackageListTunnelsEverythingButThePreset() {
        val counts = countsFor(isWhite = true, rulePackages = emptySet())

        assertEquals("в туннель идут все, кроме красного и оранжевого", 2, counts.inTunnel)
        assertEquals("мимо туннеля только красный и оранжевый", 2, counts.excluded)
    }

    @Test
    fun whitelistWithEmptyPackageListReturnsTheOrangeTheUserRestored() {
        val counts = countsFor(
            isWhite = true,
            rulePackages = emptySet(),
            userEnabled = setOf("ru.sberbankmobile"),
        )

        assertEquals("возвращённый оранжевый больше не исключается", 3, counts.inTunnel)
        assertEquals("мимо туннеля остаётся только красный", 1, counts.excluded)
    }

    @Test
    fun countsIgnorePresetPackagesThatAreNotInstalled() {
        val counts = requireNotNull(
            AppRoutingPolicy.serverRuleCounts(
                hasServerRule = true,
                isWhite = false,
                rulePackages = setOf("com.vpn"),
                preset = PresetApps(
                    red = setOf("com.bank", "com.bank.notinstalled"),
                    orange = setOf("ru.sberbankmobile", "ru.orange.notinstalled"),
                ),
                userEnabled = emptySet(),
                installedPackages = installed,
            )
        )

        assertEquals("неустановленный красный не считается", 1, counts.alwaysExcluded)
        assertEquals("неустановленный оранжевый не считается", 1, counts.optOut)
        assertEquals("и в исключённые не попадает", 3, counts.excluded)
    }

    @Test
    fun countsAreNullWithoutServerRule() {
        val counts = AppRoutingPolicy.serverRuleCounts(
            hasServerRule = false,
            isWhite = true,
            rulePackages = setOf("com.vpn"),
            preset = preset,
            userEnabled = emptySet(),
            installedPackages = installed,
        )

        assertNull("без серверного правила карточка показывает локальные списки", counts)
    }
}
