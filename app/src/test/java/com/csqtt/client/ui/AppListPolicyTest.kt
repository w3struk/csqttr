package com.csqtt.client.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Checks the visibility rules of the app list: system apps are hidden unless
 * the user turns them on or they carry an active rule of the current mode.
 */
class AppListPolicyTest {

    private data class App(val pkg: String, val name: String, val isSystem: Boolean)

    private val usrTelegram = App("org.tg", "Telegram", false)
    private val usrUser = App("com.user", "User App", false)
    private val sysSettings = App("sys.hidden", "Настройки", true)
    private val sysPhone = App("sys.pinned", "Телефон", true)

    private val allApps = listOf(usrTelegram, usrUser, sysSettings, sysPhone)

    private fun filter(
        apps: List<App> = allApps,
        query: String = "",
        showSystemApps: Boolean = false,
        activeSelection: Set<String> = emptySet(),
        keepVisible: Set<String> = emptySet(),
    ): List<String> = AppListPolicy.filterApps(
        apps = apps,
        query = query,
        showSystemApps = showSystemApps,
        activeSelection = activeSelection,
        isSystem = { it.isSystem },
        packageName = { it.pkg },
        name = { it.name },
        keepVisible = keepVisible,
    ).map { it.pkg }

    @Test
    fun systemAppsAreHiddenByDefault() {
        assertEquals(listOf(usrTelegram.pkg, usrUser.pkg), filter())
    }

    @Test
    fun systemAppWithActiveRuleStaysVisible() {
        // A pinned system app is also a selected one, so it leads the list.
        assertEquals(
            listOf(sysPhone.pkg, usrTelegram.pkg, usrUser.pkg),
            filter(activeSelection = setOf(sysPhone.pkg)),
        )
    }

    @Test
    fun showSystemAppsRevealsAllSystemApps() {
        assertEquals(
            listOf(usrTelegram.pkg, usrUser.pkg, sysSettings.pkg, sysPhone.pkg),
            filter(showSystemApps = true),
        )
    }

    @Test
    fun queryMatchesNameCaseInsensitively() {
        assertTrue(AppListPolicy.matchesQuery("Telegram", "org.tg", "tele"))
        assertFalse(AppListPolicy.matchesQuery("Telegram", "org.tg", "whatsapp"))
    }

    @Test
    fun queryMatchesPackageNameCaseInsensitively() {
        assertTrue(AppListPolicy.matchesQuery("X", "Org.Tg.App", "org.tg"))
        assertFalse(AppListPolicy.matchesQuery("X", "org.tg", "com.user"))
    }

    @Test
    fun blankQueryKeepsAllEligibleApps() {
        assertTrue(AppListPolicy.matchesQuery("X", "org.tg", ""))
        assertTrue(AppListPolicy.matchesQuery("X", "org.tg", "   "))
    }

    @Test
    fun queryFiltersVisibleApps() {
        assertEquals(listOf(usrTelegram.pkg), filter(query = "tele"))
    }

    @Test
    fun filteredListKeepsSelectedFirstAlphabeticalOrdering() {
        assertEquals(
            listOf(usrTelegram.pkg, usrUser.pkg, sysSettings.pkg, sysPhone.pkg),
            filter(showSystemApps = true, activeSelection = setOf(usrTelegram.pkg)),
        )
    }

    @Test
    fun pinningFollowsTheCurrentActiveSelection() {
        assertTrue(sysPhone.pkg in filter(activeSelection = setOf(sysPhone.pkg)))
        assertFalse(sysPhone.pkg in filter(activeSelection = emptySet()))
    }

    @Test
    fun keepVisibleHoldsASystemAppThatJustLostItsRule() {
        // The row must survive unchecking its rule, otherwise it disappears
        // under the finger that just tapped it.
        assertEquals(
            listOf(usrTelegram.pkg, usrUser.pkg, sysPhone.pkg),
            filter(keepVisible = setOf(sysPhone.pkg)),
        )
    }

    @Test
    fun keepVisibleDoesNotChangeTheOrdering() {
        // A kept app is not a selected one, so it stays in the alphabetical group.
        assertEquals(
            listOf(usrTelegram.pkg, usrUser.pkg, sysSettings.pkg, sysPhone.pkg),
            filter(showSystemApps = true, activeSelection = setOf(usrTelegram.pkg), keepVisible = setOf(sysPhone.pkg)),
        )
    }
}
