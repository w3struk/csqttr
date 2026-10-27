package com.csqtt.client.ui

import android.content.Context
import android.content.pm.PackageManager
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import android.widget.Toast
import com.csqtt.client.showRaisedToast
import org.json.JSONArray
import org.json.JSONObject
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.graphics.drawable.toBitmap
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.csqtt.client.AppRoutingPolicy
import com.csqtt.client.PresetApps
import com.csqtt.client.R
import com.csqtt.client.SettingsStore
import com.csqtt.client.TunnelManager
import com.csqtt.client.ui.components.CsqttScreen
import com.csqtt.client.ui.components.CsqttSegmentedControl
import com.csqtt.client.ui.components.CsqttSettingRow
import com.csqtt.client.ui.design.CsqttShapes
import com.csqtt.client.ui.design.CsqttSizes
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

private object AppCache {
    @Volatile
    var cachedList: List<AppItem>? = null
}

/**
 * Reads the installed applications from the package manager.
 *
 * The CSQTT package itself and the VK packages are filtered out — they are
 * never routed through the tunnel.
 */
private suspend fun loadInstalledApps(context: Context): List<AppItem> {
    val packageManager = context.packageManager
    return packageManager
        .getInstalledApplications(PackageManager.GET_META_DATA)
        .asSequence()
        .filter { app ->
            app.packageName != context.packageName &&
                !app.packageName.contains("vkontakte") &&
                !app.packageName.contains("vk.calls")
        }
        .map { app ->
            AppItem(
                name = runCatching { app.loadLabel(packageManager).toString() }
                    .getOrDefault(app.packageName),
                packageName = app.packageName,
                icon = runCatching { app.loadIcon(packageManager).toBitmap().asImageBitmap() }.getOrNull(),
                isSystem = (app.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0,
            )
        }
        .sortedWith(compareBy<AppItem> { it.isSystem }.thenBy { it.name.lowercase() })
        .toList()
}

private enum class RoutingMode { ExcludeSelected, IncludeSelected }

@Composable
fun ExceptionsTab(
    settingsStore: SettingsStore,
    savedExcluded: String,
    savedWhitelist: String,
    showSystemApps: Boolean,
    isWhitelist: Boolean,
    serverRoutingActive: Boolean = TunnelManager.serverRoutingActive.value,
) {
    val context = LocalContext.current.applicationContext
    val scope = rememberCoroutineScope()
    val tunnelRunning by TunnelManager.running.collectAsStateWithLifecycle()
    val serverRoutingActiveLive by TunnelManager.serverRoutingActive.collectAsStateWithLifecycle(
        initialValue = serverRoutingActive
    )
    val isServerRouting = serverRoutingActive || serverRoutingActiveLive
    val activeServerRule by TunnelManager.activeServerRoutingRule.collectAsStateWithLifecycle()

    @Suppress("DEPRECATION")
    val clipboardManager = LocalClipboardManager.current
    val domainRoutingEnabled by settingsStore.domainRoutingEnabled.collectAsStateWithLifecycle(
        initialValue = SettingsStore.cachedDomainRoutingEnabled ?: false
    )
    val templateDomainsEnabled by settingsStore.templateDomainsEnabled.collectAsStateWithLifecycle(
        initialValue = SettingsStore.cachedTemplateDomainsEnabled ?: false
    )
    val domainIsWhitelist by settingsStore.domainIsWhitelist.collectAsStateWithLifecycle(
        initialValue = false
    )
    val directDomainsBlackStr by settingsStore.directDomainsBlack.collectAsStateWithLifecycle(
        initialValue = SettingsStore.cachedDirectDomains ?: ""
    )
    val directDomainsWhiteStr by settingsStore.directDomainsWhite.collectAsStateWithLifecycle(
        initialValue = ""
    )

    val ipRoutingEnabled by settingsStore.ipRoutingEnabled.collectAsStateWithLifecycle(
        initialValue = false
    )
    val ipIsWhitelist by settingsStore.ipIsWhitelist.collectAsStateWithLifecycle(
        initialValue = false
    )
    val directIpsBlackStr by settingsStore.directIpsBlack.collectAsStateWithLifecycle(
        initialValue = ""
    )
    val directIpsWhiteStr by settingsStore.directIpsWhite.collectAsStateWithLifecycle(
        initialValue = ""
    )

    fun cleanDomain(raw: String): String {
        return raw.trim()
            .lowercase()
            .removePrefix("https://")
            .removePrefix("http://")
            .removePrefix("www.")
            .substringBefore('/')
            .substringBefore(':')
            .substringBefore('?')
            .substringBefore('#')
            .trim(',', ';', ' ', '\t', '\n', '\r', '.', '(', ')', '[', ']', '"', '\'')
    }

    val domainPattern = remember {
        Regex("^[a-z0-9\u0400-\u04ff]([a-z0-9\u0400-\u04ff\\-]{0,61}[a-z0-9\u0400-\u04ff])?\$")
    }

    fun isValidDomain(domain: String): Boolean {
        if (domain.length < 3 || domain.length > 253) return false
        val parts = domain.split('.')
        if (parts.size < 2) return false
        val tld = parts.last()
        if (tld.length < 2 || !tld.any { it.isLetter() }) return false
        return parts.all { it.matches(domainPattern) }
    }

    fun parseDomainsFromText(text: String): List<String> {
        return text
            .split(Regex("[,;\\s\\n\\r]+"))
            .map { cleanDomain(it) }
            .filter { isValidDomain(it) }
            .distinct()
            .take(1024)
    }

    fun isValidIpv4(ip: String): Boolean {
        val parts = ip.split('.')
        if (parts.size != 4) return false
        return parts.all { part ->
            val num = part.toIntOrNull() ?: return@all false
            num in 0..255 && (part == "0" || !part.startsWith("0"))
        }
    }

    fun isValidIpRule(raw: String): Boolean {
        val item = raw.trim()
        if (item.isEmpty()) return false
        if (item.contains('/')) {
            val parts = item.split('/')
            if (parts.size != 2) return false
            val prefix = parts[1].toIntOrNull() ?: return false
            return prefix in 0..32 && isValidIpv4(parts[0].trim())
        }
        if (item.contains('-')) {
            val parts = item.split('-')
            if (parts.size != 2) return false
            return isValidIpv4(parts[0].trim()) && isValidIpv4(parts[1].trim())
        }
        return isValidIpv4(item)
    }

    fun cleanIpRule(raw: String): String {
        val item = raw.trim()
        if (item.contains('-')) {
            val parts = item.split('-')
            if (parts.size == 2) {
                return "${parts[0].trim()}-${parts[1].trim()}"
            }
        }
        return item
    }

    fun parseIpsFromText(text: String): List<String> {
        return text
            .split(Regex("[,;\\s\\n\\r]+"))
            .map { cleanIpRule(it) }
            .filter { isValidIpRule(it) }
            .distinct()
            .take(1024)
    }

    val packagePattern = remember {
        Regex("^[a-zA-Z][a-zA-Z0-9_]*(\\.[a-zA-Z0-9_]+)+$")
    }

    fun isValidPackage(pkg: String): Boolean {
        if (pkg.length < 3 || pkg.length > 255) return false
        val parts = pkg.split('.')
        if (parts.size < 2) return false
        return pkg.matches(packagePattern)
    }

    fun parseAppExportFromText(text: String): Pair<Set<String>, Set<String>>? {
        val lines = text.lines()
        var currentSection: String? = null
        val black = mutableSetOf<String>()
        val white = mutableSetOf<String>()
        var headerFound = false

        fun extractPkgs(s: String): List<String> {
            return s.split(Regex("[,;\\s\\t]+"))
                .map { it.trim().trim(',', ';', '"', '\'') }
                .filter { isValidPackage(it) }
        }

        for (line in lines) {
            val trimmed = line.trim()
            if (trimmed.isEmpty()) continue
            val lower = trimmed.lowercase()

            when {
                lower.startsWith("чёрный-список:") || lower.startsWith("черный-список:") ||
                lower.startsWith("чёрный список:") || lower.startsWith("черный список:") ||
                lower.startsWith("blacklist:") || lower.startsWith("black:") -> {
                    headerFound = true
                    currentSection = "black"
                    val remainder = trimmed.substringAfter(':')
                    black.addAll(extractPkgs(remainder))
                }
                lower.startsWith("белый-список:") || lower.startsWith("белый список:") ||
                lower.startsWith("whitelist:") || lower.startsWith("white:") -> {
                    headerFound = true
                    currentSection = "white"
                    val remainder = trimmed.substringAfter(':')
                    white.addAll(extractPkgs(remainder))
                }
                else -> {
                    if (currentSection == "black") {
                        black.addAll(extractPkgs(trimmed))
                    } else if (currentSection == "white") {
                        white.addAll(extractPkgs(trimmed))
                    }
                }
            }
        }

        if (!headerFound) return null
        return Pair(black, white)
    }

    val templateDomains = remember {
        val text = runCatching {
            context.assets.open("domains.txt").bufferedReader().use { it.readText() }
        }.getOrNull().orEmpty()
        parseDomainsFromText(text)
    }

    val directDomainsStr = if (domainIsWhitelist) directDomainsWhiteStr else directDomainsBlackStr
    val directDomainsList = remember(directDomainsStr) {
        parseDomainsFromText(directDomainsStr)
    }

    val directIpsStr = if (ipIsWhitelist) directIpsWhiteStr else directIpsBlackStr
    val directIpsList = remember(directIpsStr) {
        parseIpsFromText(directIpsStr)
    }

    val persistedBlacklist = remember(savedExcluded) {
        savedExcluded.split(',').filter(String::isNotBlank).toSet()
    }
    val persistedWhitelist = remember(savedWhitelist) {
        savedWhitelist.split(',').filter(String::isNotBlank).toSet()
    }

    var blacklistSelection by remember { mutableStateOf(persistedBlacklist) }
    var whitelistSelection by remember { mutableStateOf(persistedWhitelist) }
    var lastSavedBlacklist by remember { mutableStateOf(persistedBlacklist) }
    var lastSavedWhitelist by remember { mutableStateOf(persistedWhitelist) }
    // These short DataStore writes must survive navigation away from this screen.
    val appPersistenceScope = remember(settingsStore) {
        CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    }

    LaunchedEffect(persistedBlacklist) {
        if (blacklistSelection == lastSavedBlacklist) {
            blacklistSelection = persistedBlacklist
        }
        lastSavedBlacklist = persistedBlacklist
    }

    LaunchedEffect(persistedWhitelist) {
        if (whitelistSelection == lastSavedWhitelist) {
            whitelistSelection = persistedWhitelist
        }
        lastSavedWhitelist = persistedWhitelist
    }

    var appsList by remember { mutableStateOf(AppCache.cachedList.orEmpty()) }
    var isAppsLoading by remember { mutableStateOf(AppCache.cachedList == null) }
    var isRefreshing by remember { mutableStateOf(false) }
    var refreshFailed by remember { mutableStateOf(false) }
    var isMigrationReady by rememberSaveable { mutableStateOf(false) }

    var showAppsDialog by rememberSaveable { mutableStateOf(false) }
    var showDomainsDialog by rememberSaveable { mutableStateOf(false) }
    var showIpsDialog by rememberSaveable { mutableStateOf(false) }
    var showRoutingModeInfoDialog by rememberSaveable { mutableStateOf(false) }
    var showRulesTransferDialog by rememberSaveable { mutableStateOf(false) }

    var dialogSnapshotBlacklist by remember { mutableStateOf<Set<String>?>(null) }
    var dialogSnapshotWhitelist by remember { mutableStateOf<Set<String>?>(null) }
    var dialogSnapshotIsWhitelist by remember { mutableStateOf<Boolean?>(null) }

    val openAppsDialog = {
        dialogSnapshotBlacklist = blacklistSelection
        dialogSnapshotWhitelist = whitelistSelection
        dialogSnapshotIsWhitelist = isWhitelist
        showAppsDialog = true
    }

    val closeAppsDialog = {
        showAppsDialog = false
        val currentBlack = blacklistSelection
        val currentWhite = whitelistSelection
        val currentIsWhite = isWhitelist
        val blackChanged = dialogSnapshotBlacklist != null && dialogSnapshotBlacklist != currentBlack
        val whiteChanged = dialogSnapshotWhitelist != null && dialogSnapshotWhitelist != currentWhite
        val modeChanged = dialogSnapshotIsWhitelist != null && dialogSnapshotIsWhitelist != currentIsWhite
        if (blackChanged || whiteChanged || modeChanged) {
            appPersistenceScope.launch {
                settingsStore.saveAppRoutingLists(
                    currentBlack.sorted().joinToString(","),
                    currentWhite.sorted().joinToString(","),
                )
                TunnelManager.reloadVpn()
            }
        }
    }

    var appSearchQuery by rememberSaveable { mutableStateOf("") }
    var showSystemAppsState by remember(showSystemApps) { mutableStateOf(showSystemApps) }

    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) { settingsStore.migrateLegacyWhitelistMode() }
        isMigrationReady = true

        AppCache.cachedList?.let {
            appsList = it
            isAppsLoading = false
            return@LaunchedEffect
        }

        isAppsLoading = true
        try {
            val loadedApps = withContext(Dispatchers.IO) { loadInstalledApps(context) }
            AppCache.cachedList = loadedApps
            appsList = loadedApps
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (throwable: Throwable) {
            // A single broken package must not take the whole list down.
            appsList = emptyList()
        } finally {
            isAppsLoading = false
        }
    }

    /**
     * Re-reads the package manager without touching the current rules, the
     * search query or the list that is currently on screen. A failed refresh
     * keeps the old list and only raises the error banner.
     */
    fun refreshApps() {
        if (isRefreshing) return
        AppCache.cachedList = null
        isRefreshing = true
        scope.launch {
            try {
                val loadedApps = withContext(Dispatchers.IO) { loadInstalledApps(context) }
                appsList = loadedApps
                AppCache.cachedList = loadedApps
                refreshFailed = false
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (throwable: Throwable) {
                refreshFailed = true
            } finally {
                isRefreshing = false
            }
        }
    }

    val routingMode = if (isWhitelist) RoutingMode.IncludeSelected else RoutingMode.ExcludeSelected
    val activeAppSelection = if (isWhitelist) whitelistSelection else blacklistSelection

    // Values the server rule actually applies. They are shown read-only: the
    // local lists stay on disk but do not take part while the rule is active.
    val serverRule = activeServerRule
    // The one flag the whole screen reads: card status, locks and the dialog mode
    // all use it. The `serverRoutingActive` flag is set in the same place as the
    // rule itself (TunnelManager.applyServerRoutingRule), so there is nothing to
    // show while it is on but the rule has not arrived.
    val serverRuleActive = isServerRouting && serverRule != null

    // The domain and IP cards are edited by dialogs that make no sense under a
    // server rule: close them when the rule appears.
    LaunchedEffect(serverRuleActive) {
        if (serverRuleActive) {
            showDomainsDialog = false
            showIpsDialog = false
            showRulesTransferDialog = false
        }
    }

    val preset = PresetApps(
        red = serverRule?.presetRed?.toSet() ?: emptySet(),
        orange = serverRule?.presetOrange?.toSet() ?: emptySet(),
    )
    // Collected unconditionally: a conditional subscription would be torn down
    // and rebuilt every time the server rule appears or disappears.
    val orangeTunnelEnabledRaw by settingsStore.orangeTunnelEnabled.collectAsStateWithLifecycle(
        initialValue = SettingsStore.cachedOrangeTunnelEnabled ?: ""
    )
    val orangeTunnelEnabled = orangeTunnelEnabledRaw.split(",").filter { it.isNotEmpty() }.toSet()
    val installedPackages = appsList.map { it.packageName }.toSet()
    val rulePackages = serverRule?.packages?.toSet() ?: emptySet()
    // The mode that actually applies: the server rule wins while it is active,
    // the local setting is only a fallback without one. One value feeds both
    // the card status and the dialog highlight.
    val serverIsWhite = serverRule?.isWhite == true

    // The system apps that carried a rule when the dialog opened for the
    // current mode stay visible for the whole session: unchecking a rule must
    // not make the row disappear under the finger that just tapped it.
    val pinnedForSession = remember(showAppsDialog, isWhitelist) {
        if (showAppsDialog) activeAppSelection else emptySet()
    }

    val filteredApps = remember(
        appsList,
        appSearchQuery,
        activeAppSelection,
        showSystemAppsState,
        pinnedForSession,
    ) {
        AppListPolicy.filterApps(
            apps = appsList,
            query = appSearchQuery,
            showSystemApps = showSystemAppsState,
            activeSelection = activeAppSelection,
            isSystem = { it.isSystem },
            packageName = { it.packageName },
            name = { it.name },
            keepVisible = pinnedForSession,
        )
    }

    fun persistAppSelections(black: Set<String>?, white: Set<String>?, mode: Boolean? = null) {
        val nextBlack = black ?: blacklistSelection
        val nextWhite = white ?: whitelistSelection
        appPersistenceScope.launch {
            settingsStore.saveAppRoutingLists(
                nextBlack.sorted().joinToString(","),
                nextWhite.sorted().joinToString(","),
                mode,
            )
            if (mode != null) TunnelManager.reloadVpn()
        }
    }

    fun persistAppSelection(selection: Set<String>, forWhitelist: Boolean) {
        if (forWhitelist) {
            persistAppSelections(black = null, white = selection)
        } else {
            persistAppSelections(black = selection, white = null)
        }
    }

    // Rapid taps arrive faster than DataStore emits, so the toggle is computed
    // from the saved list inside the coroutine, one write at a time. Basing it on
    // the composition's `orangeTunnelEnabled` would make the second tap read the
    // value from before the first write and lose one toggle.
    val orangeToggleMutex = remember(settingsStore) { Mutex() }

    fun toggleOrangePackage(packageName: String) {
        appPersistenceScope.launch {
            orangeToggleMutex.withLock {
                val current = settingsStore.orangeTunnelEnabled.first()
                    .split(",")
                    .filter { it.isNotEmpty() }
                    .toSet()
                val next = AppRoutingPolicy.toggleOrange(current, packageName)
                settingsStore.saveOrangeTunnelEnabled(next.sorted().joinToString(","))
                // The server rule itself does not change here, so nothing else
                // rebuilds the tunnel. The restart goes after the write: the
                // service reads the saved key, and an earlier restart could pick
                // up the old list.
                TunnelManager.reloadVpn()
            }
        }
    }

    DisposableEffect(Unit) {
        onDispose {
            val pendingBlacklist = blacklistSelection
            val pendingWhitelist = whitelistSelection
            val blacklistChanged = pendingBlacklist != lastSavedBlacklist
            val whitelistChanged = pendingWhitelist != lastSavedWhitelist
            if (!blacklistChanged && !whitelistChanged) return@onDispose
            lastSavedBlacklist = pendingBlacklist
            lastSavedWhitelist = pendingWhitelist
            appPersistenceScope.launch {
                settingsStore.saveAppRoutingLists(
                    pendingBlacklist.sorted().joinToString(","),
                    pendingWhitelist.sorted().joinToString(","),
                )
            }
        }
    }

    CsqttScreen {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            AppSectionCard(
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = "Маршрутизация приложений",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Ellipsis,
                    )
                    val serverCounts = AppRoutingPolicy.serverRuleCounts(
                        hasServerRule = serverRuleActive,
                        isWhite = serverIsWhite,
                        rulePackages = rulePackages,
                        preset = preset,
                        userEnabled = orangeTunnelEnabled,
                        installedPackages = installedPackages,
                    )
                    // Числа имеют смысл только по загруженному списку: пустой список
                    // бывает и на первом кадре, и после неудачной загрузки.
                    val appStatusText = when {
                        serverCounts == null && isWhitelist ->
                            "Белый список: ${whitelistSelection.size} в туннеле"
                        serverCounts == null ->
                            "Чёрный список: ${blacklistSelection.size} исключено"
                        installedPackages.isEmpty() && isAppsLoading ->
                            "Правило сервера: список приложений загружается…"
                        installedPackages.isEmpty() ->
                            "Правило сервера: список приложений недоступен"
                        serverIsWhite ->
                            "Правило сервера: белый список, ${serverCounts.inTunnel} в туннеле " +
                                "(${serverCounts.alwaysExcluded} всегда мимо туннеля, " +
                                "${serverCounts.optOut} можно отключить)"
                        else ->
                            "Правило сервера: чёрный список, ${serverCounts.excluded} исключено " +
                                "(${serverCounts.alwaysExcluded} всегда мимо туннеля, " +
                                "${serverCounts.optOut} можно отключить)"
                    }
                    Text(
                        text = appStatusText,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = if (serverRuleActive) Int.MAX_VALUE else 1,
                        softWrap = serverRuleActive,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (serverRuleActive) {
                        Text(
                            text = "Локальные списки не применяются, пока действует правило сервера. " +
                                "Оранжевые приложения можно вернуть в туннель",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }

                OutlinedButton(
                    onClick = openAppsDialog,
                    enabled = true,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(CsqttSizes.ControlHeight),
                    shape = CsqttShapes.Pill,
                    colors = ButtonDefaults.outlinedButtonColors(
                        containerColor = Color.Transparent,
                        contentColor = MaterialTheme.colorScheme.onSurface,
                    ),
                    border = BorderStroke(
                        1.dp,
                        MaterialTheme.colorScheme.outline.copy(alpha = 0.5f),
                    ),
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Apps,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                        tint = MaterialTheme.colorScheme.onSurface,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = "Список приложений",
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            AppSectionCard(
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = "Маршрутизация доменов",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Ellipsis,
                    )
                    val domainsStatusText = if (serverRule != null) {
                        when {
                            serverRule.domainsIsWhite ->
                                "Правило сервера: белый список, ${serverRule.domains.size} доменов в туннеле"
                            serverRule.templateDomains && serverRule.domains.isNotEmpty() ->
                                "Правило сервера: чёрный список, ${templateDomains.size} готовых + " +
                                    "${serverRule.domains.size} своих исключено"
                            serverRule.templateDomains ->
                                "Правило сервера: чёрный список, ${templateDomains.size} исключено " +
                                    "(Готовый список RU)"
                            serverRule.domains.isEmpty() ->
                                "Правило сервера: чёрный список, 0 доменов исключено"
                            else ->
                                "Правило сервера: чёрный список, ${serverRule.domains.size} исключено"
                        }
                    } else if (domainIsWhitelist) {
                        "Белый список: ${directDomainsList.size} в туннеле"
                    } else {
                        when {
                            directDomainsList.isEmpty() -> "Чёрный список: 0 доменов исключено"
                            templateDomainsEnabled -> {
                                val customCount = directDomainsList.count { !templateDomains.contains(it) }
                                if (customCount > 0) {
                                    "Исключено: ${templateDomains.size} готовых + $customCount своих"
                                } else {
                                    "Исключено: ${directDomainsList.size} (Готовый список RU)"
                                }
                            }
                            else -> "Чёрный список: ${directDomainsList.size} исключено"
                        }
                    }
                    Text(
                        text = domainsStatusText,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = if (serverRuleActive) Int.MAX_VALUE else 1,
                        softWrap = serverRuleActive,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                OutlinedButton(
                    onClick = { showDomainsDialog = true },
                    enabled = !serverRuleActive,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(CsqttSizes.ControlHeight),
                    shape = CsqttShapes.Pill,
                    colors = ButtonDefaults.outlinedButtonColors(
                        containerColor = Color.Transparent,
                        contentColor = MaterialTheme.colorScheme.onSurface,
                    ),
                    border = BorderStroke(
                        1.dp,
                        MaterialTheme.colorScheme.outline.copy(alpha = 0.5f),
                    ),
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Language,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                        tint = MaterialTheme.colorScheme.onSurface,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = "Список доменов",
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (serverRuleActive) {
                    Text(
                        text = "Задано правилом сервера",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            AppSectionCard(
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(
                        text = "Маршрутизация адресов",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Ellipsis,
                    )
                    val ipsStatusText = if (serverRule != null) {
                        if (serverRule.ipIsWhite) {
                            "Правило сервера: белый список, ${serverRule.ips.size} в туннеле"
                        } else {
                            "Правило сервера: чёрный список, ${serverRule.ips.size} исключено"
                        }
                    } else if (ipIsWhitelist) {
                        "Белый список: ${directIpsList.size} в туннеле"
                    } else {
                        "Чёрный список: ${directIpsList.size} исключено"
                    }
                    Text(
                        text = ipsStatusText,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = if (serverRuleActive) Int.MAX_VALUE else 1,
                        softWrap = serverRuleActive,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                OutlinedButton(
                    onClick = { showIpsDialog = true },
                    enabled = !serverRuleActive,
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(CsqttSizes.ControlHeight),
                    shape = CsqttShapes.Pill,
                    colors = ButtonDefaults.outlinedButtonColors(
                        containerColor = Color.Transparent,
                        contentColor = MaterialTheme.colorScheme.onSurface,
                    ),
                    border = BorderStroke(
                        1.dp,
                        MaterialTheme.colorScheme.outline.copy(alpha = 0.5f),
                    ),
                ) {
                    Icon(
                        painter = painterResource(R.drawable.ic_ip),
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                        tint = MaterialTheme.colorScheme.onSurface,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = "Список адресов",
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (serverRuleActive) {
                    Text(
                        text = "Задано правилом сервера",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            if (!serverRuleActive) {
                AppSectionCard(
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(
                            text = "Импорт и экспорт правил",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            text = "Резервное копирование и перенос настроек",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }

                    OutlinedButton(
                        onClick = { showRulesTransferDialog = true },
                        enabled = true,
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(CsqttSizes.ControlHeight),
                        shape = CsqttShapes.Pill,
                        colors = ButtonDefaults.outlinedButtonColors(
                            containerColor = Color.Transparent,
                            contentColor = MaterialTheme.colorScheme.onSurface,
                        ),
                        border = BorderStroke(
                            1.dp,
                            MaterialTheme.colorScheme.outline.copy(alpha = 0.5f),
                        ),
                    ) {
                        Icon(
                            imageVector = Icons.Default.SwapVert,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp),
                            tint = MaterialTheme.colorScheme.onSurface,
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = "Импорт и экспорт правил",
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }

        if (showAppsDialog) {
            AppListDialog(
                appsList = filteredApps,
                isAppsLoading = isAppsLoading,
                isMigrationReady = isMigrationReady,
                isRefreshing = isRefreshing,
                refreshFailed = refreshFailed,
                searchQuery = appSearchQuery,
                onSearchQueryChange = { appSearchQuery = it },
                activeSelection = if (serverRuleActive) rulePackages else activeAppSelection,
                isWhitelist = if (serverRuleActive) serverIsWhite else isWhitelist,
                showSystemApps = showSystemAppsState,
                onShowSystemAppsChange = { value ->
                    showSystemAppsState = value
                    appPersistenceScope.launch { settingsStore.saveShowSystemApps(value) }
                },
                onToggleApp = { packageName ->
                    val newSelection = if (packageName in activeAppSelection) {
                        activeAppSelection - packageName
                    } else {
                        activeAppSelection + packageName
                    }
                    if (isWhitelist) {
                        whitelistSelection = newSelection
                        persistAppSelection(newSelection, forWhitelist = true)
                    } else {
                        blacklistSelection = newSelection
                        persistAppSelection(newSelection, forWhitelist = false)
                    }
                },
                onRefresh = { refreshApps() },
                onSwitchMode = { toWhitelist ->
                    scope.launch { settingsStore.saveIsWhitelist(toWhitelist) }
                },
                onClose = closeAppsDialog,
                serverLocked = serverRuleActive,
                lockedPackages = rulePackages,
                preset = preset,
                orangeTunnelEnabled = orangeTunnelEnabled,
                onToggleOrange = ::toggleOrangePackage,
            )
        }

        if (showRoutingModeInfoDialog) {
            Dialog(
                onDismissRequest = { showRoutingModeInfoDialog = false },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Surface(
                    shape = CsqttShapes.Dialog,
                    color = appSectionCardColor(),
                    contentColor = MaterialTheme.colorScheme.onSurface,
                    border = BorderStroke(1.dp, appSectionCardBorderColor()),
                    tonalElevation = 0.dp,
                    modifier = Modifier.fillMaxWidth(0.92f),
                ) {
                    Column(
                        modifier = Modifier
                            .padding(horizontal = 20.dp, vertical = 18.dp)
                            .verticalScroll(rememberScrollState()),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "Режим исключения",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                maxLines = 1,
                                softWrap = false,
                                overflow = TextOverflow.Ellipsis,
                            )
                            IconButton(
                                onClick = { showRoutingModeInfoDialog = false },
                                modifier = Modifier.size(36.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Close,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }
                        Text(
                            text = "• В режиме чёрного списка отмеченные приложения не идут в туннель CSQTT.\n\n• В режиме белого списка только отмеченные приложения идут в туннель CSQTT (и ни одного другого).",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                    }
                }
            }
        }

        if (showDomainsDialog) {
            var domainIsWhiteMode by rememberSaveable(showDomainsDialog) { mutableStateOf(domainIsWhitelist) }
            var domainInputTextBlack by rememberSaveable(showDomainsDialog) {
                mutableStateOf(
                    if (directDomainsBlackStr.isBlank()) {
                        if (templateDomainsEnabled && templateDomains.isNotEmpty()) {
                            templateDomains.joinToString("\n")
                        } else {
                            ""
                        }
                    } else {
                        parseDomainsFromText(directDomainsBlackStr).joinToString("\n")
                    }
                )
            }
            var domainInputTextWhite by rememberSaveable(showDomainsDialog) {
                mutableStateOf(
                    parseDomainsFromText(directDomainsWhiteStr).joinToString("\n")
                )
            }

            val currentDomainText = if (domainIsWhiteMode) domainInputTextWhite else domainInputTextBlack
            val parsedDomains = remember(currentDomainText) {
                parseDomainsFromText(currentDomainText)
            }

            val saveAndCloseDomains = {
                val formattedBlack = parseDomainsFromText(domainInputTextBlack).joinToString(",")
                val formattedWhite = parseDomainsFromText(domainInputTextWhite).joinToString(",")
                scope.launch {
                    settingsStore.saveDomainIsWhitelist(domainIsWhiteMode)
                    settingsStore.saveDirectDomainsBlack(formattedBlack)
                    settingsStore.saveDirectDomainsWhite(formattedWhite)
                    TunnelManager.pushLocalRouting(context)
                }
                showDomainsDialog = false
            }

            Dialog(
                onDismissRequest = saveAndCloseDomains,
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Surface(
                    shape = CsqttShapes.Dialog,
                    color = appSectionCardColor(),
                    contentColor = MaterialTheme.colorScheme.onSurface,
                    border = BorderStroke(1.dp, appSectionCardBorderColor()),
                    tonalElevation = 0.dp,
                    modifier = Modifier
                        .fillMaxWidth(0.95f)
                        .fillMaxHeight(0.92f),
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Language,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(22.dp),
                                )
                                Text(
                                    text = "Маршрутизация доменов",
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.Bold,
                                    maxLines = 1,
                                    softWrap = false,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            IconButton(
                                onClick = saveAndCloseDomains,
                                modifier = Modifier.size(36.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Close,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onSurface,
                                )
                            }
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            if (!domainIsWhiteMode) {
                                Button(
                                    onClick = {},
                                    modifier = Modifier
                                        .weight(1f)
                                        .height(CsqttSizes.ControlHeight),
                                    shape = CsqttShapes.Pill,
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = Color(0xFF1475FD),
                                        contentColor = Color.White,
                                    ),
                                ) {
                                    Text(
                                        text = "Чёрный список",
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            } else {
                                OutlinedButton(
                                    onClick = { domainIsWhiteMode = false },
                                    modifier = Modifier
                                        .weight(1f)
                                        .height(CsqttSizes.ControlHeight),
                                    shape = CsqttShapes.Pill,
                                    colors = ButtonDefaults.outlinedButtonColors(
                                        containerColor = Color.Transparent,
                                        contentColor = MaterialTheme.colorScheme.onSurface,
                                    ),
                                    border = BorderStroke(
                                        1.dp,
                                        MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                                    ),
                                ) {
                                    Text(
                                        text = "Чёрный список",
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }

                            if (domainIsWhiteMode) {
                                Button(
                                    onClick = {},
                                    modifier = Modifier
                                        .weight(1f)
                                        .height(CsqttSizes.ControlHeight),
                                    shape = CsqttShapes.Pill,
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = Color(0xFF1475FD),
                                        contentColor = Color.White,
                                    ),
                                ) {
                                    Text(
                                        text = "Белый список",
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            } else {
                                OutlinedButton(
                                    onClick = { domainIsWhiteMode = true },
                                    modifier = Modifier
                                        .weight(1f)
                                        .height(CsqttSizes.ControlHeight),
                                    shape = CsqttShapes.Pill,
                                    colors = ButtonDefaults.outlinedButtonColors(
                                        containerColor = Color.Transparent,
                                        contentColor = MaterialTheme.colorScheme.onSurface,
                                    ),
                                    border = BorderStroke(
                                        1.dp,
                                        MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                                    ),
                                ) {
                                    Text(
                                        text = "Белый список",
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        }

                        if (!domainIsWhiteMode) {
                            Surface(
                                shape = CsqttShapes.Control,
                                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                                border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f)),
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                CsqttSettingRow(
                                    title = "Готовый список RU доменов",
                                    description = "503 важных доменных имён",
                                    checked = templateDomainsEnabled,
                                    onCheckedChange = { enabled ->
                                        if (enabled) {
                                            val current = parseDomainsFromText(domainInputTextBlack)
                                            val merged = (current + templateDomains).distinct()
                                            domainInputTextBlack = merged.joinToString("\n")
                                            val formatted = merged.joinToString(",")
                                            scope.launch {
                                                settingsStore.saveTemplateDomainsEnabled(true)
                                                settingsStore.saveDirectDomainsBlack(formatted)
                                            }
                                        } else {
                                            val current = parseDomainsFromText(domainInputTextBlack)
                                            val templateSet = templateDomains.toSet()
                                            val remaining = current.filter { !templateSet.contains(it) }
                                            domainInputTextBlack = remaining.joinToString("\n")
                                            val formatted = remaining.joinToString(",")
                                            scope.launch {
                                                settingsStore.saveTemplateDomainsEnabled(false)
                                                settingsStore.saveDirectDomainsBlack(formatted)
                                            }
                                        }
                                    },
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                                )
                            }
                        }

                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.35f))

                        OutlinedTextField(
                            value = if (domainIsWhiteMode) domainInputTextWhite else domainInputTextBlack,
                            onValueChange = { newText ->
                                if (domainIsWhiteMode) {
                                    domainInputTextWhite = newText
                                } else {
                                    domainInputTextBlack = newText
                                }
                            },
                            label = {
                                Text(
                                    "Список доменов",
                                    maxLines = 1,
                                    softWrap = false,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            },
                            placeholder = {
                                Text("Введите домены списком, через запятую или пробел:\nyandex.ru, mail.ru\nkinopoisk.ru")
                            },
                            shape = RoundedCornerShape(8.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f),
                        )

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "Распознано: ${parsedDomains.size}",
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                softWrap = false,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                if (currentDomainText.isNotBlank()) {
                                    OutlinedButton(
                                        onClick = {
                                            if (domainIsWhiteMode) {
                                                domainInputTextWhite = ""
                                                scope.launch { settingsStore.saveDirectDomainsWhite("") }
                                            } else {
                                                domainInputTextBlack = ""
                                                scope.launch {
                                                    settingsStore.saveTemplateDomainsEnabled(false)
                                                    settingsStore.saveDirectDomainsBlack("")
                                                }
                                            }
                                        },
                                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                                        modifier = Modifier.height(32.dp),
                                        shape = CsqttShapes.Pill,
                                    ) {
                                        Text(
                                            text = "Очистить",
                                            style = MaterialTheme.typography.labelSmall,
                                            maxLines = 1,
                                            softWrap = false,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                }
                                Button(
                                    onClick = saveAndCloseDomains,
                                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 4.dp),
                                    modifier = Modifier.height(32.dp),
                                    shape = CsqttShapes.Pill,
                                ) {
                                    Text(
                                        text = "Готово",
                                        style = MaterialTheme.typography.labelSmall,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        if (showIpsDialog) {
            var ipIsWhiteMode by rememberSaveable(showIpsDialog) { mutableStateOf(ipIsWhitelist) }
            var ipInputTextBlack by rememberSaveable(showIpsDialog) {
                mutableStateOf(parseIpsFromText(directIpsBlackStr).joinToString("\n"))
            }
            var ipInputTextWhite by rememberSaveable(showIpsDialog) {
                mutableStateOf(parseIpsFromText(directIpsWhiteStr).joinToString("\n"))
            }

            val currentIpText = if (ipIsWhiteMode) ipInputTextWhite else ipInputTextBlack
            val parsedIps = remember(currentIpText) {
                parseIpsFromText(currentIpText)
            }

            val saveAndCloseIps = {
                val formattedBlack = parseIpsFromText(ipInputTextBlack).joinToString(",")
                val formattedWhite = parseIpsFromText(ipInputTextWhite).joinToString(",")
                scope.launch {
                    settingsStore.saveIpIsWhitelist(ipIsWhiteMode)
                    settingsStore.saveIpRoutingEnabled(true)
                    settingsStore.saveDirectIpsBlack(formattedBlack)
                    settingsStore.saveDirectIpsWhite(formattedWhite)
                    TunnelManager.pushLocalRouting(context)
                }
                showIpsDialog = false
            }

            Dialog(
                onDismissRequest = saveAndCloseIps,
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Surface(
                    shape = CsqttShapes.Dialog,
                    color = appSectionCardColor(),
                    contentColor = MaterialTheme.colorScheme.onSurface,
                    border = BorderStroke(1.dp, appSectionCardBorderColor()),
                    tonalElevation = 0.dp,
                    modifier = Modifier
                        .fillMaxWidth(0.95f)
                        .fillMaxHeight(0.92f),
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Icon(
                                    painter = painterResource(R.drawable.ic_ip),
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.primary,
                                    modifier = Modifier.size(22.dp),
                                )
                                Text(
                                    text = "Маршрутизация адресов",
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.Bold,
                                    maxLines = 1,
                                    softWrap = false,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            IconButton(
                                onClick = saveAndCloseIps,
                                modifier = Modifier.size(36.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Close,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onSurface,
                                )
                            }
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            if (!ipIsWhiteMode) {
                                Button(
                                    onClick = {},
                                    modifier = Modifier
                                        .weight(1f)
                                        .height(CsqttSizes.ControlHeight),
                                    shape = CsqttShapes.Pill,
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = Color(0xFF1475FD),
                                        contentColor = Color.White,
                                    ),
                                ) {
                                    Text(
                                        text = "Чёрный список",
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            } else {
                                OutlinedButton(
                                    onClick = { ipIsWhiteMode = false },
                                    modifier = Modifier
                                        .weight(1f)
                                        .height(CsqttSizes.ControlHeight),
                                    shape = CsqttShapes.Pill,
                                    colors = ButtonDefaults.outlinedButtonColors(
                                        containerColor = Color.Transparent,
                                        contentColor = MaterialTheme.colorScheme.onSurface,
                                    ),
                                    border = BorderStroke(
                                        1.dp,
                                        MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                                    ),
                                ) {
                                    Text(
                                        text = "Чёрный список",
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }

                            if (ipIsWhiteMode) {
                                Button(
                                    onClick = {},
                                    modifier = Modifier
                                        .weight(1f)
                                        .height(CsqttSizes.ControlHeight),
                                    shape = CsqttShapes.Pill,
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = Color(0xFF1475FD),
                                        contentColor = Color.White,
                                    ),
                                ) {
                                    Text(
                                        text = "Белый список",
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            } else {
                                OutlinedButton(
                                    onClick = { ipIsWhiteMode = true },
                                    modifier = Modifier
                                        .weight(1f)
                                        .height(CsqttSizes.ControlHeight),
                                    shape = CsqttShapes.Pill,
                                    colors = ButtonDefaults.outlinedButtonColors(
                                        containerColor = Color.Transparent,
                                        contentColor = MaterialTheme.colorScheme.onSurface,
                                    ),
                                    border = BorderStroke(
                                        1.dp,
                                        MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                                    ),
                                ) {
                                    Text(
                                        text = "Белый список",
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        }

                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.35f))

                        OutlinedTextField(
                            value = if (ipIsWhiteMode) ipInputTextWhite else ipInputTextBlack,
                            onValueChange = { newText ->
                                if (ipIsWhiteMode) {
                                    ipInputTextWhite = newText
                                } else {
                                    ipInputTextBlack = newText
                                }
                            },
                            label = {
                                Text(
                                    "Список адресов",
                                    maxLines = 1,
                                    softWrap = false,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            },
                            placeholder = {
                                Text("1.2.3.4/32\n1.2.3.4\n1.2.3.4-1.2.3.255")
                            },
                            shape = RoundedCornerShape(8.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f),
                        )

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "Распознано: ${parsedIps.size}",
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                softWrap = false,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                if (currentIpText.isNotBlank()) {
                                    OutlinedButton(
                                        onClick = {
                                            if (ipIsWhiteMode) {
                                                ipInputTextWhite = ""
                                                scope.launch { settingsStore.saveDirectIpsWhite("") }
                                            } else {
                                                ipInputTextBlack = ""
                                                scope.launch { settingsStore.saveDirectIpsBlack("") }
                                            }
                                        },
                                        contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                                        modifier = Modifier.height(32.dp),
                                        shape = CsqttShapes.Pill,
                                    ) {
                                        Text(
                                            text = "Очистить",
                                            style = MaterialTheme.typography.labelSmall,
                                            maxLines = 1,
                                            softWrap = false,
                                            overflow = TextOverflow.Ellipsis,
                                        )
                                    }
                                }
                                Button(
                                    onClick = saveAndCloseIps,
                                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 4.dp),
                                    modifier = Modifier.height(32.dp),
                                    shape = CsqttShapes.Pill,
                                ) {
                                    Text(
                                        text = "Готово",
                                        style = MaterialTheme.typography.labelSmall,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        if (showRulesTransferDialog) {
            var transferAppsSelected by rememberSaveable { mutableStateOf(true) }
            var transferDomainsSelected by rememberSaveable { mutableStateOf(true) }
            var transferIpsSelected by rememberSaveable { mutableStateOf(true) }

            Dialog(
                onDismissRequest = { showRulesTransferDialog = false },
                properties = DialogProperties(usePlatformDefaultWidth = false),
            ) {
                Surface(
                    shape = CsqttShapes.Dialog,
                    color = appSectionCardColor(),
                    contentColor = MaterialTheme.colorScheme.onSurface,
                    border = BorderStroke(1.dp, appSectionCardBorderColor()),
                    tonalElevation = 0.dp,
                    modifier = Modifier.fillMaxWidth(0.92f),
                ) {
                    Column(
                        modifier = Modifier
                            .padding(horizontal = 20.dp, vertical = 18.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "Импорт и экспорт правил",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                maxLines = 1,
                                softWrap = false,
                                overflow = TextOverflow.Ellipsis,
                            )
                            IconButton(
                                onClick = { showRulesTransferDialog = false },
                                modifier = Modifier.size(36.dp),
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Close,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }

                        Surface(
                            shape = CsqttShapes.Control,
                            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f)),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { transferAppsSelected = !transferAppsSelected }
                                    .padding(horizontal = 14.dp, vertical = 8.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = "Приложения",
                                    style = MaterialTheme.typography.bodyLarge,
                                    fontWeight = FontWeight.Medium,
                                    maxLines = 1,
                                    softWrap = false,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Checkbox(
                                    checked = transferAppsSelected,
                                    onCheckedChange = { transferAppsSelected = it },
                                    colors = CheckboxDefaults.colors(
                                        checkedColor = MaterialTheme.colorScheme.primary,
                                        checkmarkColor = MaterialTheme.colorScheme.onPrimary,
                                    ),
                                )
                            }
                        }

                        Surface(
                            shape = CsqttShapes.Control,
                            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f)),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { transferDomainsSelected = !transferDomainsSelected }
                                    .padding(horizontal = 14.dp, vertical = 8.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = "Домены",
                                    style = MaterialTheme.typography.bodyLarge,
                                    fontWeight = FontWeight.Medium,
                                    maxLines = 1,
                                    softWrap = false,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Checkbox(
                                    checked = transferDomainsSelected,
                                    onCheckedChange = { transferDomainsSelected = it },
                                    colors = CheckboxDefaults.colors(
                                        checkedColor = MaterialTheme.colorScheme.primary,
                                        checkmarkColor = MaterialTheme.colorScheme.onPrimary,
                                    ),
                                )
                            }
                        }

                        Surface(
                            shape = CsqttShapes.Control,
                            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                            border = BorderStroke(1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.3f)),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { transferIpsSelected = !transferIpsSelected }
                                    .padding(horizontal = 14.dp, vertical = 8.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    text = "IP адреса",
                                    style = MaterialTheme.typography.bodyLarge,
                                    fontWeight = FontWeight.Medium,
                                    maxLines = 1,
                                    softWrap = false,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Checkbox(
                                    checked = transferIpsSelected,
                                    onCheckedChange = { transferIpsSelected = it },
                                    colors = CheckboxDefaults.colors(
                                        checkedColor = MaterialTheme.colorScheme.primary,
                                        checkmarkColor = MaterialTheme.colorScheme.onPrimary,
                                    ),
                                )
                            }
                        }

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Button(
                                onClick = {
                                    if (!transferAppsSelected && !transferDomainsSelected && !transferIpsSelected) {
                                        context.showRaisedToast("Выберите хотя бы один пункт", Toast.LENGTH_SHORT)
                                        return@Button
                                    }
                                    val root = JSONObject()
                                    root.put("version", 2)
                                    if (transferAppsSelected) {
                                        val appsObj = JSONObject()
                                        appsObj.put("is_whitelist", isWhitelist)
                                        appsObj.put("active_mode", if (isWhitelist) "whitelist" else "blacklist")
                                        val blackArr = JSONArray()
                                        blacklistSelection.sorted().forEach { blackArr.put(it) }
                                        appsObj.put("blacklist", blackArr)
                                        val whiteArr = JSONArray()
                                        whitelistSelection.sorted().forEach { whiteArr.put(it) }
                                        appsObj.put("whitelist", whiteArr)
                                        root.put("apps", appsObj)
                                    }
                                    if (transferDomainsSelected) {
                                        val domainsObj = JSONObject()
                                        domainsObj.put("is_whitelist", domainIsWhitelist)
                                        domainsObj.put("active_mode", if (domainIsWhitelist) "whitelist" else "blacklist")
                                        domainsObj.put("template_domains", templateDomainsEnabled)
                                        val blackArr = JSONArray()
                                        val templateSet = templateDomains.toSet()
                                        val blackList = parseDomainsFromText(directDomainsBlackStr)
                                        val customOnly = if (templateDomainsEnabled) {
                                            blackList.filter { !templateSet.contains(it) }
                                        } else {
                                            blackList
                                        }
                                        customOnly.forEach { blackArr.put(it) }
                                        domainsObj.put("blacklist", blackArr)
                                        val whiteArr = JSONArray()
                                        parseDomainsFromText(directDomainsWhiteStr).forEach { whiteArr.put(it) }
                                        domainsObj.put("whitelist", whiteArr)
                                        domainsObj.put("direct_domains", if (domainIsWhitelist) whiteArr else blackArr)
                                        root.put("domains", domainsObj)
                                    }
                                    if (transferIpsSelected) {
                                        val ipsObj = JSONObject()
                                        ipsObj.put("is_whitelist", ipIsWhitelist)
                                        ipsObj.put("active_mode", if (ipIsWhitelist) "whitelist" else "blacklist")
                                        val blackArr = JSONArray()
                                        parseIpsFromText(directIpsBlackStr).forEach { blackArr.put(it) }
                                        ipsObj.put("blacklist", blackArr)
                                        val whiteArr = JSONArray()
                                        parseIpsFromText(directIpsWhiteStr).forEach { whiteArr.put(it) }
                                        ipsObj.put("whitelist", whiteArr)
                                        ipsObj.put("direct_ips", if (ipIsWhitelist) whiteArr else blackArr)
                                        root.put("ips", ipsObj)
                                    }
                                    clipboardManager.setText(AnnotatedString(root.toString(2)))
                                    context.showRaisedToast("Правила экспортированы в буфер обмена", Toast.LENGTH_SHORT)
                                },
                                modifier = Modifier
                                    .weight(1f)
                                    .defaultMinSize(minHeight = CsqttSizes.MinimumTouchTarget),
                                shape = CsqttShapes.Control,
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = MaterialTheme.colorScheme.primary,
                                    contentColor = MaterialTheme.colorScheme.onPrimary,
                                ),
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                            ) {
                                Row(
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Icon(
                                        painter = painterResource(R.drawable.ic_export),
                                        contentDescription = null,
                                        modifier = Modifier.size(18.dp),
                                    )
                                    Text(
                                        text = "Экспорт",
                                        style = MaterialTheme.typography.labelLarge,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }

                            Button(
                                onClick = {
                                    if (!transferAppsSelected && !transferDomainsSelected && !transferIpsSelected) {
                                        context.showRaisedToast("Выберите хотя бы один пункт", Toast.LENGTH_SHORT)
                                        return@Button
                                    }
                                    val clipText = clipboardManager.getText()?.text.orEmpty().trim()
                                    if (clipText.isBlank()) {
                                        context.showRaisedToast("Буфер обмена пуст", Toast.LENGTH_SHORT)
                                        return@Button
                                    }
                                    var importedAny = false
                                    val rootJson = runCatching { JSONObject(clipText) }.getOrNull()
                                    if (rootJson != null) {
                                        if (transferAppsSelected && rootJson.has("apps")) {
                                            val appsObj = rootJson.getJSONObject("apps")
                                            val isWhite = if (appsObj.has("active_mode")) {
                                                appsObj.optString("active_mode") == "whitelist"
                                            } else {
                                                appsObj.optBoolean("is_whitelist", isWhitelist)
                                            }
                                            val newBlack = mutableSetOf<String>()
                                            val blackArr = appsObj.optJSONArray("blacklist")
                                            if (blackArr != null) {
                                                for (i in 0 until blackArr.length()) {
                                                    val pkg = blackArr.optString(i)
                                                    if (isValidPackage(pkg)) newBlack.add(pkg)
                                                }
                                            }
                                            val newWhite = mutableSetOf<String>()
                                            val whiteArr = appsObj.optJSONArray("whitelist")
                                            if (whiteArr != null) {
                                                for (i in 0 until whiteArr.length()) {
                                                    val pkg = whiteArr.optString(i)
                                                    if (isValidPackage(pkg)) newWhite.add(pkg)
                                                }
                                            }
                                            blacklistSelection = newBlack
                                            whitelistSelection = newWhite
                                            persistAppSelections(black = newBlack, white = newWhite, mode = isWhite)
                                            importedAny = true
                                        }
                                        if (transferDomainsSelected && rootJson.has("domains")) {
                                            val domainsObj = rootJson.getJSONObject("domains")
                                            val isWhite = if (domainsObj.has("active_mode")) {
                                                domainsObj.optString("active_mode") == "whitelist"
                                            } else {
                                                domainsObj.optBoolean("is_whitelist", domainIsWhitelist)
                                            }
                                            val isTemplate = domainsObj.optBoolean("template_domains", false)
                                            val impBlack = mutableListOf<String>()
                                            val blackArr = domainsObj.optJSONArray("blacklist")
                                            if (blackArr != null) {
                                                for (i in 0 until blackArr.length()) {
                                                    val d = cleanDomain(blackArr.optString(i))
                                                    if (isValidDomain(d)) impBlack.add(d)
                                                }
                                            }
                                            val impWhite = mutableListOf<String>()
                                            val whiteArr = domainsObj.optJSONArray("whitelist")
                                            if (whiteArr != null) {
                                                for (i in 0 until whiteArr.length()) {
                                                    val d = cleanDomain(whiteArr.optString(i))
                                                    if (isValidDomain(d)) impWhite.add(d)
                                                }
                                            }
                                            val flatArr = domainsObj.optJSONArray("direct_domains")
                                            if (flatArr != null && impBlack.isEmpty() && impWhite.isEmpty()) {
                                                for (i in 0 until flatArr.length()) {
                                                    val d = cleanDomain(flatArr.optString(i))
                                                    if (isValidDomain(d)) {
                                                        if (isWhite) impWhite.add(d) else impBlack.add(d)
                                                    }
                                                }
                                            }
                                            val formattedBlack = impBlack.distinct().take(1024).joinToString(",")
                                            val formattedWhite = impWhite.distinct().take(1024).joinToString(",")
                                            scope.launch {
                                                settingsStore.saveDomainIsWhitelist(isWhite)
                                                settingsStore.saveTemplateDomainsEnabled(isTemplate)
                                                if (impBlack.isNotEmpty() || !isWhite) settingsStore.saveDirectDomainsBlack(formattedBlack)
                                                if (impWhite.isNotEmpty() || isWhite) settingsStore.saveDirectDomainsWhite(formattedWhite)
                                                TunnelManager.pushLocalRouting(context)
                                            }
                                            importedAny = true
                                        }
                                        if (transferIpsSelected && rootJson.has("ips")) {
                                            val ipsObj = rootJson.getJSONObject("ips")
                                            val isWhite = if (ipsObj.has("active_mode")) {
                                                ipsObj.optString("active_mode") == "whitelist"
                                            } else {
                                                ipsObj.optBoolean("is_whitelist", ipIsWhitelist)
                                            }
                                            val impBlack = mutableListOf<String>()
                                            val blackArr = ipsObj.optJSONArray("blacklist")
                                            if (blackArr != null) {
                                                for (i in 0 until blackArr.length()) {
                                                    val r = cleanIpRule(blackArr.optString(i))
                                                    if (isValidIpRule(r)) impBlack.add(r)
                                                }
                                            }
                                            val impWhite = mutableListOf<String>()
                                            val whiteArr = ipsObj.optJSONArray("whitelist")
                                            if (whiteArr != null) {
                                                for (i in 0 until whiteArr.length()) {
                                                    val r = cleanIpRule(whiteArr.optString(i))
                                                    if (isValidIpRule(r)) impWhite.add(r)
                                                }
                                            }
                                            val flatArr = ipsObj.optJSONArray("direct_ips")
                                            if (flatArr != null && impBlack.isEmpty() && impWhite.isEmpty()) {
                                                for (i in 0 until flatArr.length()) {
                                                    val r = cleanIpRule(flatArr.optString(i))
                                                    if (isValidIpRule(r)) {
                                                        if (isWhite) impWhite.add(r) else impBlack.add(r)
                                                    }
                                                }
                                            }
                                            val formattedBlack = impBlack.distinct().take(1024).joinToString(",")
                                            val formattedWhite = impWhite.distinct().take(1024).joinToString(",")
                                            scope.launch {
                                                settingsStore.saveIpIsWhitelist(isWhite)
                                                settingsStore.saveIpRoutingEnabled(true)
                                                if (impBlack.isNotEmpty() || !isWhite) settingsStore.saveDirectIpsBlack(formattedBlack)
                                                if (impWhite.isNotEmpty() || isWhite) settingsStore.saveDirectIpsWhite(formattedWhite)
                                                TunnelManager.pushLocalRouting(context)
                                            }
                                            importedAny = true
                                        }
                                    } else {
                                        if (transferAppsSelected) {
                                            val parsed = parseAppExportFromText(clipText)
                                            if (parsed != null) {
                                                val (impBlack, impWhite) = parsed
                                                val nBlack = if (impBlack.isNotEmpty()) blacklistSelection + impBlack else null
                                                val nWhite = if (impWhite.isNotEmpty()) whitelistSelection + impWhite else null
                                                if (nBlack != null || nWhite != null) {
                                                    nBlack?.let { blacklistSelection = it }
                                                    nWhite?.let { whitelistSelection = it }
                                                    persistAppSelections(black = nBlack, white = nWhite)
                                                    importedAny = true
                                                }
                                            }
                                        }
                                        if (transferDomainsSelected) {
                                            val importedDomains = parseDomainsFromText(clipText)
                                            if (importedDomains.isNotEmpty()) {
                                                val currentList = if (domainIsWhitelist) parseDomainsFromText(directDomainsWhiteStr) else parseDomainsFromText(directDomainsBlackStr)
                                                val combined = (currentList + importedDomains).distinct().take(1024).joinToString(",")
                                                scope.launch {
                                                    if (domainIsWhitelist) {
                                                        settingsStore.saveDirectDomainsWhite(combined)
                                                    } else {
                                                        settingsStore.saveDirectDomainsBlack(combined)
                                                    }
                                                    TunnelManager.pushLocalRouting(context)
                                                }
                                                importedAny = true
                                            }
                                        }
                                        if (transferIpsSelected) {
                                            val importedIps = parseIpsFromText(clipText)
                                            if (importedIps.isNotEmpty()) {
                                                val currentList = if (ipIsWhitelist) parseIpsFromText(directIpsWhiteStr) else parseIpsFromText(directIpsBlackStr)
                                                val combined = (currentList + importedIps).distinct().take(1024).joinToString(",")
                                                scope.launch {
                                                    settingsStore.saveIpRoutingEnabled(true)
                                                    if (ipIsWhitelist) {
                                                        settingsStore.saveDirectIpsWhite(combined)
                                                    } else {
                                                        settingsStore.saveDirectIpsBlack(combined)
                                                    }
                                                    TunnelManager.pushLocalRouting(context)
                                                }
                                                importedAny = true
                                            }
                                        }
                                    }
                                    if (importedAny) {
                                        if (transferAppsSelected) {
                                            TunnelManager.reloadVpn()
                                        }
                                        context.showRaisedToast("Правила успешно импортированы", Toast.LENGTH_SHORT)
                                        showRulesTransferDialog = false
                                    } else {
                                        context.showRaisedToast("В буфере обмена нет подходящих данных", Toast.LENGTH_SHORT)
                                    }
                                },
                                modifier = Modifier
                                    .weight(1f)
                                    .defaultMinSize(minHeight = CsqttSizes.MinimumTouchTarget),
                                shape = CsqttShapes.Control,
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = MaterialTheme.colorScheme.primary,
                                    contentColor = MaterialTheme.colorScheme.onPrimary,
                                ),
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                            ) {
                                Row(
                                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Icon(
                                        painter = painterResource(R.drawable.ic_import),
                                        contentDescription = null,
                                        modifier = Modifier.size(18.dp),
                                    )
                                    Text(
                                        text = "Импорт",
                                        style = MaterialTheme.typography.labelLarge,
                                        maxLines = 1,
                                        softWrap = false,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
