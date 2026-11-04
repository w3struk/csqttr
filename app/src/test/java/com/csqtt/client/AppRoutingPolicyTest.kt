package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    @Test
    fun invisibleWhitelistPredicateFiresOnlyForANonEmptyUninstalledSet() {
        val installed = setOf("com.vpn")

        assertTrue(
            "непустой набор без установленных пакетов — подмена",
            AppRoutingPolicy.isServerWhitelistInvisible(
                isWhite = true,
                rulePackages = setOf("com.example.notinstalled"),
            ) { it in installed },
        )
        assertFalse(
            "пустой набор — это «никто», подмены нет",
            AppRoutingPolicy.isServerWhitelistInvisible(
                isWhite = true,
                rulePackages = emptySet(),
            ) { it in installed },
        )
        assertFalse(
            "установленный пакет в наборе уважается",
            AppRoutingPolicy.isServerWhitelistInvisible(
                isWhite = true,
                rulePackages = setOf("com.vpn"),
            ) { it in installed },
        )
        assertFalse(
            "чёрный режим подмены не имеет",
            AppRoutingPolicy.isServerWhitelistInvisible(
                isWhite = false,
                rulePackages = setOf("com.example.notinstalled"),
            ) { it in installed },
        )
    }
}
