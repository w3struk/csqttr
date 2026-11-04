package com.csqtt.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Объединение серверного правила с локальным списком приложений: режим задаёт
 * оператор, поэтому список противоположного режима не читается.
 */
class MergedRoutingPolicyTest {

    private fun effective(
        ruleIsWhite: Boolean,
        rulePackages: Set<String>,
        localBlack: Set<String> = emptySet(),
        localWhite: Set<String> = emptySet(),
    ): Set<String> = MergedRoutingPolicy.effectivePackages(
        ruleIsWhite = ruleIsWhite,
        rulePackages = rulePackages,
        localBlack = localBlack,
        localWhite = localWhite,
    )

    @Test
    fun `black rule merges the local black list`() {
        assertEquals(
            "чёрное правило читает локальный чёрный список",
            setOf("a", "b"),
            effective(false, setOf("a"), localBlack = setOf("b"), localWhite = setOf("w")),
        )
    }

    @Test
    fun `white rule merges the local white list`() {
        assertEquals(
            "белое правило читает локальный белый список",
            setOf("a", "w"),
            effective(true, setOf("a"), localBlack = setOf("b"), localWhite = setOf("w")),
        )
    }

    @Test
    fun `the local list of the opposite mode is never read`() {
        assertEquals(
            "в чёрном режиме локальный белый список игнорируется",
            setOf("a"),
            effective(false, setOf("a"), localWhite = setOf("w")),
        )
        assertEquals(
            "в белом режиме локальный чёрный список игнорируется",
            setOf("a"),
            effective(true, setOf("a"), localBlack = setOf("b")),
        )
    }

    @Test
    fun `an empty white rule plus a local white list yields the local white list`() {
        assertEquals(
            "пустое правило не игнорирует локальный белый список",
            setOf("w"),
            effective(true, emptySet(), localWhite = setOf("w")),
        )
    }

    @Test
    fun `an empty white rule with no local list stays empty`() {
        assertEquals(
            "пустой белый набор — это «никто», а не «все»",
            emptySet<String>(),
            effective(true, emptySet()),
        )
    }

    @Test
    fun `a package present in both the rule and the local list appears once`() {
        assertEquals(
            "пакет из правила и локального списка не дублируется",
            setOf("a", "b"),
            effective(false, setOf("a"), localBlack = setOf("a", "b")),
        )
    }

    @Test
    fun `an empty black rule plus an empty local list stays empty`() {
        assertEquals(
            "пустое чёрное правило без локального списка — пустой набор",
            emptySet<String>(),
            effective(false, emptySet()),
        )
    }

    // --- Атрибуция карточки -------------------------------------------------

    private val preset = PresetApps(red = setOf("r"), orange = setOf("o"))

    /** `a` — пакет правила, `b` — локальный, `x` — вне списков, `t` — транспорт. */
    private val installed = setOf("a", "b", "r", "o", "x", "t")

    private val transport = setOf("t")

    private fun counts(
        ruleIsWhite: Boolean,
        rulePackages: Set<String>,
        localBlack: Set<String> = emptySet(),
        localWhite: Set<String> = emptySet(),
        userEnabled: Set<String> = emptySet(),
    ): MergedCardCounts = MergedRoutingPolicy.cardCounts(
        ruleIsWhite = ruleIsWhite,
        rulePackages = rulePackages,
        localBlack = localBlack,
        localWhite = localWhite,
        preset = preset,
        userEnabled = userEnabled,
        installedPackages = installed,
        transportPackages = transport,
    )

    private fun planFor(isWhite: Boolean, packages: Set<String>): VpnAppsPlan =
        VpnAppRouting.build(
            hasServerRule = true,
            isWhite = isWhite,
            rulePackages = packages,
            preset = preset,
            userEnabled = emptySet(),
            transportPackages = transport,
            selfPackage = "self",
            isInstalled = { it in installed },
        )

    @Test
    fun `black mode splits the excluded count between server and user`() {
        val counts = counts(false, setOf("a"), localBlack = setOf("b"))

        assertEquals("исключены правило, локальный список и пресет", 4, counts.excluded)
        assertEquals("пакет правила и весь пресет — от сервера", 3, counts.serverAttributed)
        assertEquals("пакет локального списка — ваш", 1, counts.localAttributed)
        assertEquals("в туннеле только приложение вне списков", 1, counts.inTunnel)
        assertEquals("красный установлен", 1, counts.alwaysExcluded)
        assertEquals("оранжевый установлен", 1, counts.optOut)
    }

    @Test
    fun `a returned orange leaves the server attribution`() {
        val counts = counts(false, setOf("a"), localBlack = setOf("b"), userEnabled = setOf("o"))

        assertEquals("возвращённый оранжевый больше не исключён", 3, counts.excluded)
        assertEquals("он уходит и из атрибуции правила", 2, counts.serverAttributed)
        assertEquals("локальный пакет по-прежнему ваш", 1, counts.localAttributed)
        assertEquals("возвращённый оранжевый идёт в туннель", 2, counts.inTunnel)
    }

    @Test
    fun `white mode counts the in-tunnel set and splits it`() {
        val counts = counts(true, setOf("a"), localWhite = setOf("b"))

        assertEquals("в туннель идут правило и локальный список", 2, counts.inTunnel)
        assertEquals("пакет правила — от сервера", 1, counts.serverAttributed)
        assertEquals("пакет локального списка — ваш", 1, counts.localAttributed)
        assertEquals("остальные мимо тоннеля", 3, counts.excluded)
    }

    @Test
    fun `a package in both the rule and the local list is counted once for the server`() {
        val counts = counts(false, setOf("a", "b"), localBlack = setOf("b"))

        assertEquals("пакет не считается дважды", 4, counts.excluded)
        assertEquals("пересечение относится к правилу", 4, counts.serverAttributed)
        assertEquals("своих пакетов не осталось", 0, counts.localAttributed)
    }

    @Test
    fun `a preset package in the local list never becomes a user package`() {
        val counts = counts(false, setOf("a"), localBlack = setOf("r"))

        assertEquals("красный пресета исключён", 3, counts.excluded)
        assertEquals("и относится к серверу, а не к пользователю", 3, counts.serverAttributed)
        assertEquals("в локальном списке пресетных пакетов нет", 0, counts.localAttributed)
    }

    @Test
    fun `the opposite-mode local list does not leak into the counts`() {
        val counts = counts(false, setOf("a"), localWhite = setOf("w"))

        assertEquals("белый список в чёрном режиме не читается", 0, counts.localAttributed)
    }

    @Test
    fun `an empty white rule counts zero in the tunnel`() {
        val counts = counts(true, emptySet())

        assertEquals("пустой белый набор — никто в туннеле", 0, counts.inTunnel)
        assertEquals("и атрибуции от правила нет", 0, counts.serverAttributed)
        assertEquals("и ваших нет", 0, counts.localAttributed)
        assertEquals("мимо тоннеля всё установленное", 5, counts.excluded)
        assertEquals("красный установлен", 1, counts.alwaysExcluded)
        assertEquals("оранжевый установлен", 1, counts.optOut)
    }

    @Test
    fun `an empty white rule with a restored orange counts one in the tunnel`() {
        val counts = counts(true, emptySet(), userEnabled = setOf("o"))

        assertEquals("возвращённый оранжевый — элемент белого списка", 1, counts.inTunnel)
        assertEquals("и по формуле идёт от правила", 1, counts.serverAttributed)
        assertEquals("своих пакетов нет", 0, counts.localAttributed)
        assertEquals("остальные мимо тоннеля", 4, counts.excluded)
        assertEquals("красный установлен", 1, counts.alwaysExcluded)
        assertEquals("оранжевый установлен", 1, counts.optOut)
    }

    @Test
    fun `uninstalled packages never inflate the counts`() {
        val counts = counts(false, setOf("a", "uninstalled"), localBlack = setOf("b"))

        assertEquals("неустановленный пакет правила не считается", 4, counts.excluded)
        assertEquals("и в атрибуцию правила не попадает", 3, counts.serverAttributed)
    }

    @Test
    fun `transport packages and CSQTT never enter the counts even when listed`() {
        val counts = counts(false, setOf("a", "t"), localBlack = setOf("b"))

        assertEquals("транспорт вычитается даже из правила", 4, counts.excluded)
        assertEquals("и не попадает в атрибуцию правила", 3, counts.serverAttributed)
        assertEquals("в туннеле только приложение вне списков", 1, counts.inTunnel)
    }

    @Test
    fun `transport and CSQTT in the installed set never change the counts`() {
        // Полный набор из PackageManager отличается от списка диалога ровно
        // транспортом и самим CSQTT. Оба вычитаются внутри, поэтому числа
        // обязаны совпасть — иначе переход на авторитетный набор «сдвинул» бы
        // карточку.
        val displayPackages = setOf("a", "b", "r", "o", "x")
        val planTransport = setOf("t", "self")
        fun countsWith(installedPackages: Set<String>) = MergedRoutingPolicy.cardCounts(
            ruleIsWhite = false,
            rulePackages = setOf("a"),
            localBlack = setOf("b"),
            localWhite = emptySet(),
            preset = preset,
            userEnabled = emptySet(),
            installedPackages = installedPackages,
            transportPackages = planTransport,
        )

        val displayCounts = countsWith(displayPackages)
        val fullCounts = countsWith(displayPackages + planTransport)

        assertEquals("числа не зависят от транспорта в наборе", displayCounts, fullCounts)
        assertEquals("и остаются прежними", 4, fullCounts.excluded)
    }

    @Test
    fun `a white rule that lists only transport fails like the plan instead of counting device-wide`() {
        // Полный набор установленных, как его отдаёт PackageManager, содержит
        // транспорт. Предикат подмены ложен, план — отказ (allow-набор пуст
        // после вычитания транспорта), и карточка обязана показать отказ, а не
        // device-wide счётчики, которые получались по отфильтрованному списку.
        val fullInstalled = installed + "self"
        val planTransport = transport + "self"
        val plan = VpnAppRouting.build(
            hasServerRule = true,
            isWhite = true,
            rulePackages = setOf("t"),
            preset = preset,
            userEnabled = emptySet(),
            transportPackages = planTransport,
            selfPackage = "self",
            isInstalled = { it in fullInstalled },
        )
        assertTrue("правило из одного транспорта — отказ, а не подмена", plan is VpnAppsPlan.Failure)

        val counts = MergedRoutingPolicy.cardCounts(
            ruleIsWhite = true,
            rulePackages = setOf("t"),
            localBlack = emptySet(),
            localWhite = emptySet(),
            preset = preset,
            userEnabled = emptySet(),
            installedPackages = fullInstalled,
            transportPackages = planTransport,
        )

        assertEquals("в туннель никто не идёт", 0, counts.inTunnel)
        assertEquals("атрибуции от правила нет", 0, counts.serverAttributed)
        assertEquals("мимо тоннеля всё установленное, кроме транспорта", 5, counts.excluded)
    }

    @Test
    fun `the merged set survives into the VPN plan`() {
        val black = effective(false, setOf("a"), localBlack = setOf("b"))
        assertEquals("чёрный режим объединяет набор", setOf("a", "b"), black)
        val blackPlan = planFor(isWhite = false, packages = black)
        assertTrue("чёрный план исключает приложения", blackPlan is VpnAppsPlan.Disallow)
        assertTrue(
            "локальный пакет доходит до плана",
            "b" in (blackPlan as VpnAppsPlan.Disallow).packages,
        )

        val white = effective(true, setOf("a"), localWhite = setOf("b"))
        assertEquals("белый режим объединяет набор", setOf("a", "b"), white)
        val whitePlan = planFor(isWhite = true, packages = white)
        assertTrue("белый план разрешает приложения", whitePlan is VpnAppsPlan.Allow)
        assertEquals(
            "локальный пакет доходит до allow-списка",
            setOf("a", "b"),
            (whitePlan as VpnAppsPlan.Allow).packages.toSet(),
        )

        val localOnly = effective(true, emptySet(), localWhite = setOf("b"))
        assertEquals("пустое правило не теряет локальный белый список", setOf("b"), localOnly)
        val localOnlyPlan = planFor(isWhite = true, packages = localOnly)
        assertEquals(
            "локальный белый список задаёт allow-план",
            listOf("b"),
            (localOnlyPlan as VpnAppsPlan.Allow).packages,
        )
    }

    @Test
    fun `uninstalled preset packages never inflate the preset counters`() {
        val widePreset = PresetApps(
            red = setOf("r", "r.uninstalled"),
            orange = setOf("o", "o.uninstalled"),
        )
        val counts = MergedRoutingPolicy.cardCounts(
            ruleIsWhite = false,
            rulePackages = setOf("a"),
            localBlack = setOf("b"),
            localWhite = emptySet(),
            preset = widePreset,
            userEnabled = emptySet(),
            installedPackages = installed,
            transportPackages = transport,
        )

        assertEquals("неустановленный красный не считается", 1, counts.alwaysExcluded)
        assertEquals("неустановленный оранжевый не считается", 1, counts.optOut)
        assertEquals("и в исключённые не попадает", 4, counts.excluded)
    }

    @Test
    fun `a package in both preset levels never enters the tunnel even when the user restores it`() {
        val overlap = "z"
        val bothPreset = PresetApps(red = setOf("r", overlap), orange = setOf("o", overlap))
        val counts = MergedRoutingPolicy.cardCounts(
            ruleIsWhite = false,
            rulePackages = setOf("a"),
            localBlack = setOf("b"),
            localWhite = emptySet(),
            preset = bothPreset,
            userEnabled = setOf(overlap),
            installedPackages = installed + overlap,
            transportPackages = transport,
        )

        assertEquals("пакет в обоих уровнях остаётся исключённым", 5, counts.excluded)
        assertEquals("в туннеле только приложение вне списков", 1, counts.inTunnel)
        assertEquals("оба пересечения посчитаны красными", 2, counts.alwaysExcluded)
        assertEquals("и оба — оранжевыми", 2, counts.optOut)
    }

    // --- Подмена невидимого белого списка ------------------------------------

    @Test
    fun `substitutedServerWhitelistCountsAsDeviceWide`() {
        val counts = counts(true, setOf("inv1", "inv2"))

        assertEquals("в туннель идёт всё, кроме пресета", 3, counts.inTunnel)
        assertEquals("и это устройство-wide набор", 3, counts.serverAttributed)
        assertEquals("локальный список в подменённый план не входит", 0, counts.localAttributed)
        assertEquals("пресет остаётся мимо", 2, counts.excluded)
        assertEquals("красный установлен", 1, counts.alwaysExcluded)
        assertEquals("оранжевый установлен", 1, counts.optOut)
    }

    @Test
    fun `substitutedCountsKeepTheOrangeTheUserRestored`() {
        val counts = counts(true, setOf("inv1", "inv2"), userEnabled = setOf("o"))

        assertEquals("возвращённый оранжевый идёт в туннель", 4, counts.inTunnel)
        assertEquals("и остаётся в атрибуции правила", 4, counts.serverAttributed)
        assertEquals("локальный список не атрибуируется", 0, counts.localAttributed)
        assertEquals("мимо тоннеля только красный", 1, counts.excluded)
        assertEquals("красный установлен", 1, counts.alwaysExcluded)
        assertEquals("оранжевый установлен", 1, counts.optOut)
    }

    @Test
    fun `substitutedCountsMatchTheActualPlan`() {
        val planTransport = setOf("t", "self")
        val effective = MergedRoutingPolicy.effectivePackages(
            true, setOf("inv1", "inv2"), emptySet(), emptySet(),
        )
        val plan = VpnAppRouting.build(
            hasServerRule = true,
            isWhite = true,
            rulePackages = effective,
            preset = preset,
            userEnabled = emptySet(),
            transportPackages = planTransport,
            selfPackage = "self",
            isInstalled = { it in installed },
        )

        assertTrue("невидимый непустой белый набор — подмена", plan is VpnAppsPlan.Disallow)
        plan as VpnAppsPlan.Disallow
        assertTrue("план device-wide", plan.deviceWide)
        assertTrue("и помечен подменой", plan.substituted)

        val counts = MergedRoutingPolicy.cardCounts(
            ruleIsWhite = true,
            rulePackages = effective,
            localBlack = emptySet(),
            localWhite = emptySet(),
            preset = preset,
            userEnabled = emptySet(),
            installedPackages = installed,
            transportPackages = planTransport,
        )
        val actualInTunnel = installed - planTransport - preset.red - preset.orange

        assertEquals("карточка совпадает с планом", actualInTunnel.size, counts.inTunnel)
        assertEquals("вся атрибуция — от сервера", counts.inTunnel, counts.serverAttributed)
        assertEquals("ваших в подменённом плане нет", 0, counts.localAttributed)
    }

    @Test
    fun `predicateAgreesWithThePlan`() {
        val overlap = "z"
        val matrixPreset = PresetApps(red = setOf("r", overlap), orange = setOf("o", overlap))
        val matrixInstalled = installed + overlap
        val matrixTransport = setOf("t", "self")
        val ruleSets = listOf(
            emptySet(),
            setOf("inv1"),
            setOf("a"),
            setOf("inv1", "b"),
        )
        val localWhiteSets = listOf(emptySet(), setOf("b"), setOf("inv2"))
        val userSets = listOf(emptySet(), setOf("o", overlap))

        for (isWhite in listOf(false, true)) {
            for (rulePackages in ruleSets) {
                for (localWhite in localWhiteSets) {
                    for (userEnabled in userSets) {
                        val effective = MergedRoutingPolicy.effectivePackages(
                            isWhite, rulePackages, emptySet(), localWhite,
                        )
                        val plan = VpnAppRouting.build(
                            hasServerRule = true,
                            isWhite = isWhite,
                            rulePackages = effective,
                            preset = matrixPreset,
                            userEnabled = userEnabled,
                            transportPackages = matrixTransport,
                            selfPackage = "self",
                            isInstalled = { it in matrixInstalled },
                        )
                        val expected = AppRoutingPolicy.isServerWhitelistInvisible(
                            isWhite,
                            effective,
                        ) { it in matrixInstalled }
                        val cell = "isWhite=$isWhite rule=$rulePackages localWhite=$localWhite " +
                            "user=$userEnabled"
                        if (expected) {
                            assertTrue(
                                "подмена предсказана, а план не device-wide: $cell -> $plan",
                                plan is VpnAppsPlan.Disallow && plan.deviceWide && plan.substituted,
                            )
                        } else {
                            assertTrue(
                                "подмены нет, а план device-wide: $cell -> $plan",
                                plan !is VpnAppsPlan.Disallow || !plan.deviceWide,
                            )
                        }
                    }
                }
            }
        }
    }
}
