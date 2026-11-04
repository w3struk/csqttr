package com.csqtt.client.ui

import com.csqtt.client.PresetApps
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppDialogPolicyTest {

    private data class Row(val pkg: String)

    private val apps = listOf(
        Row("red"),
        Row("orange"),
        Row("server"),
        Row("user"),
    )
    private val preset = PresetApps(
        red = setOf("red"),
        orange = setOf("orange"),
    )

    @Test
    fun `local mode yields a single user section with every app`() {
        val sections = AppDialogPolicy.buildSections(
            apps = apps,
            packageName = { it.pkg },
            ruleActive = false,
            rulePackages = emptySet(),
            preset = preset,
        )

        assertEquals(1, sections.size)
        val section = sections.single()
        assertEquals(AppSectionSource.USER, section.source)
        assertEquals(apps, section.rows)
        assertEquals(4, section.total)
    }

    @Test
    fun `the section order is red, server, orange, user`() {
        val sections = AppDialogPolicy.buildSections(
            apps = apps,
            packageName = { it.pkg },
            ruleActive = true,
            rulePackages = setOf("server"),
            preset = preset,
        )

        val sources = sections.map { it.source }
        assertEquals(
            listOf(
                AppSectionSource.RED,
                AppSectionSource.SERVER,
                AppSectionSource.ORANGE,
                AppSectionSource.USER,
            ),
            sources,
        )
    }

    @Test
    fun `the server section is hidden when the rule has no packages`() {
        val sections = AppDialogPolicy.buildSections(
            apps = apps,
            packageName = { it.pkg },
            ruleActive = true,
            rulePackages = emptySet(),
            preset = preset,
        )

        val sources = sections.map { it.source }
        assertEquals(
            listOf(
                AppSectionSource.RED,
                AppSectionSource.ORANGE,
                AppSectionSource.USER,
            ),
            sources,
        )
    }

    @Test
    fun `an empty preset level produces no section`() {
        val redEmpty = AppDialogPolicy.buildSections(
            apps = apps,
            packageName = { it.pkg },
            ruleActive = true,
            rulePackages = setOf("server"),
            preset = PresetApps(red = emptySet(), orange = setOf("orange")),
        )
        assertEquals(
            listOf(AppSectionSource.SERVER, AppSectionSource.ORANGE, AppSectionSource.USER),
            redEmpty.map { it.source },
        )

        val orangeEmpty = AppDialogPolicy.buildSections(
            apps = apps,
            packageName = { it.pkg },
            ruleActive = true,
            rulePackages = setOf("server"),
            preset = PresetApps(red = setOf("red"), orange = emptySet()),
        )
        assertEquals(
            listOf(AppSectionSource.RED, AppSectionSource.SERVER, AppSectionSource.USER),
            orangeEmpty.map { it.source },
        )
    }

    @Test
    fun `a preset package listed by the operator stays in its preset section`() {
        val orangeInRule = AppDialogPolicy.buildSections(
            apps = apps,
            packageName = { it.pkg },
            ruleActive = true,
            rulePackages = setOf("server", "orange"),
            preset = preset,
        )
        val orangeSection = orangeInRule.first { it.source == AppSectionSource.ORANGE }
        val serverSection1 = orangeInRule.first { it.source == AppSectionSource.SERVER }
        assertEquals(listOf("orange"), orangeSection.rows.map { it.pkg })
        assertEquals(listOf("server"), serverSection1.rows.map { it.pkg })

        val redInRule = AppDialogPolicy.buildSections(
            apps = apps,
            packageName = { it.pkg },
            ruleActive = true,
            rulePackages = setOf("server", "red"),
            preset = preset,
        )
        val redSection = redInRule.first { it.source == AppSectionSource.RED }
        val serverSection2 = redInRule.first { it.source == AppSectionSource.SERVER }
        assertEquals(listOf("red"), redSection.rows.map { it.pkg })
        assertEquals(listOf("server"), serverSection2.rows.map { it.pkg })
    }

    @Test
    fun `a rule package that is not installed yields an empty server section`() {
        val sections = AppDialogPolicy.buildSections(
            apps = apps,
            packageName = { it.pkg },
            ruleActive = true,
            rulePackages = setOf("absent"),
            preset = preset,
        )

        val serverSection = sections.first { it.source == AppSectionSource.SERVER }
        assertEquals(1, serverSection.total)
        assertTrue(serverSection.rows.isEmpty())
    }

    @Test
    fun `user section excludes preset and rule packages`() {
        val sections = AppDialogPolicy.buildSections(
            apps = apps,
            packageName = { it.pkg },
            ruleActive = true,
            rulePackages = setOf("server"),
            preset = preset,
        )

        val userSection = sections.first { it.source == AppSectionSource.USER }
        assertEquals(listOf("user"), userSection.rows.map { it.pkg })
    }

    @Test
    fun `section titles and totals reflect preset and rule configuration`() {
        val sections = AppDialogPolicy.buildSections(
            apps = apps,
            packageName = { it.pkg },
            ruleActive = true,
            rulePackages = setOf("server", "uninstalled_rule_pkg"),
            preset = PresetApps(
                red = setOf("red", "uninstalled_red_pkg"),
                orange = setOf("orange"),
            ),
        )

        val red = sections.first { it.source == AppSectionSource.RED }
        assertEquals("Всегда мимо туннеля", red.title)
        assertEquals(2, red.total)
        assertEquals(listOf("red"), red.rows.map { it.pkg })

        val server = sections.first { it.source == AppSectionSource.SERVER }
        assertEquals("Правило сервера", server.title)
        assertEquals(2, server.total)
        assertEquals(listOf("server"), server.rows.map { it.pkg })

        val orange = sections.first { it.source == AppSectionSource.ORANGE }
        assertEquals("Можно отключить", orange.title)
        assertEquals(1, orange.total)
        assertEquals(listOf("orange"), orange.rows.map { it.pkg })

        val user = sections.first { it.source == AppSectionSource.USER }
        assertEquals("", user.title)
        assertEquals(1, user.total)
        assertEquals(listOf("user"), user.rows.map { it.pkg })
    }

    // --- Подпись диалога о подмене -------------------------------------------

    @Test
    fun `the substitution notice does not read the list the dialog presents`() {
        // Непустой поиск не совпал ни с пакетом правила, ни с локальным списком —
        // диалог получил бы пустой список. Установленность берётся из набора
        // PackageManager, где пакет правила есть, поэтому видимый набор не должен
        // превращаться в «невидимый». У функции намеренно нет входа «список на
        // экране»: подпись не может зависеть от поискового фильтра.
        val filtered = AppListPolicy.filterApps(
            apps = listOf("com.vpn" to "VPN"),
            query = "no-such-app",
            showSystemApps = true,
            activeSelection = emptySet(),
            isSystem = { false },
            packageName = { it.first },
            name = { it.second },
        )
        assertTrue("поиск действительно отфильтровал всё", filtered.isEmpty())

        assertFalse(
            "поиск не превращает видимый набор в невидимый",
            AppDialogPolicy.substitutionApplied(
                serverLocked = true,
                isWhite = true,
                rulePackages = setOf("com.vpn"),
                activeSelection = emptySet(),
                installedPackages = setOf("com.vpn"),
            ),
        )
    }

    @Test
    fun `a local addition is part of the effective set the notice checks`() {
        assertFalse(
            "установленный пакет локального белого списка уважается",
            AppDialogPolicy.substitutionApplied(
                serverLocked = true,
                isWhite = true,
                rulePackages = setOf("com.example.private"),
                activeSelection = setOf("com.vpn"),
                installedPackages = setOf("com.vpn"),
            ),
        )
        assertTrue(
            "непустой эффективный набор без установленных пакетов — подмена",
            AppDialogPolicy.substitutionApplied(
                serverLocked = true,
                isWhite = true,
                rulePackages = setOf("com.example.private"),
                activeSelection = setOf("com.example.also.private"),
                installedPackages = setOf("com.vpn"),
            ),
        )
    }

    @Test
    fun `the substitution notice stays silent until the installed list is loaded`() {
        assertFalse(
            "на первом кадре список приложений ещё пуст — подписи о подмене нет",
            AppDialogPolicy.substitutionApplied(
                serverLocked = true,
                isWhite = true,
                rulePackages = setOf("com.example.private"),
                activeSelection = emptySet(),
                installedPackages = emptySet(),
            ),
        )
        assertFalse(
            "после неудачной загрузки подпись тоже молчит",
            AppDialogPolicy.substitutionApplied(
                serverLocked = true,
                isWhite = true,
                rulePackages = setOf("com.example.private"),
                activeSelection = setOf("com.example.also.private"),
                installedPackages = emptySet(),
            ),
        )
        assertTrue(
            "по загруженному списку подмена снова считается",
            AppDialogPolicy.substitutionApplied(
                serverLocked = true,
                isWhite = true,
                rulePackages = setOf("com.example.private"),
                activeSelection = emptySet(),
                installedPackages = setOf("com.vpn"),
            ),
        )
    }

    @Test
    fun `the substitution notice needs a server rule and a white mode`() {
        assertFalse(
            "пустой эффективный набор — это «никто», подмены нет",
            AppDialogPolicy.substitutionApplied(
                serverLocked = true,
                isWhite = true,
                rulePackages = emptySet(),
                activeSelection = emptySet(),
                installedPackages = setOf("com.vpn"),
            ),
        )
        assertFalse(
            "в локальном режиме подмены нет",
            AppDialogPolicy.substitutionApplied(
                serverLocked = false,
                isWhite = true,
                rulePackages = setOf("com.example.private"),
                activeSelection = emptySet(),
                installedPackages = setOf("com.vpn"),
            ),
        )
        assertFalse(
            "в чёрном режиме подмены нет",
            AppDialogPolicy.substitutionApplied(
                serverLocked = true,
                isWhite = false,
                rulePackages = setOf("com.example.private"),
                activeSelection = emptySet(),
                installedPackages = setOf("com.vpn"),
            ),
        )
    }
}
