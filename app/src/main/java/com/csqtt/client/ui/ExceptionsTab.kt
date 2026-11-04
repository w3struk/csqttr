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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import android.widget.Toast
import com.csqtt.client.showRaisedToast
import org.json.JSONArray
import org.json.JSONObject
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import com.csqtt.client.CsqttConstants
import com.csqtt.client.MergedRoutingPolicy
import com.csqtt.client.PresetApps
import com.csqtt.client.R
import com.csqtt.client.SettingsStore
import com.csqtt.client.TunnelManager
import com.csqtt.client.ui.components.CsqttScreen
import com.csqtt.client.ui.components.CsqttSegmentedControl
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

/**
 * Установленные приложения в двух видах, которые расходятся осознанно:
 * [displayList] — строки диалога без CSQTT и VK-транспорта (их не выбирают),
 * [allPackages] — сырой ответ `PackageManager`, включая транспорт и сам CSQTT.
 *
 * [allPackages] — единственный авторитетный ответ на вопрос «установлен ли
 * пакет». По нему считают предикат подмены и счётчики карточки, и его же
 * спрашивают `TunVpnService.isPackageInstalled` и `TunnelService.onPackageChanged`
 * (через `getPackageInfo`). Выводить установленность из [displayList] нельзя:
 * он неполон, и правило, перечислившее только транспорт, выглядело бы
 * «невидимым» — карточка показала бы device-wide счётчики, а план вернул бы
 * отказ.
 */
private data class InstalledApps(
    val displayList: List<AppItem>,
    val allPackages: Set<String>,
)

private object AppCache {
    @Volatile
    var cached: InstalledApps? = null
}

/**
 * Reads the installed applications from the package manager.
 *
 * The display list has the CSQTT package itself and the VK packages filtered
 * out — they are never routed through the tunnel. The VK filter matches exact
 * package names from [CsqttConstants.General.VK_TRANSPORT_PACKAGES] — the same
 * set the routing policy subtracts — so the shown rows and the card counts
 * agree on look-alike names such as `com.vkontakte.android.beta`. The full
 * package set keeps them: it is the same answer `PackageManager` gives the plan.
 */
private suspend fun loadInstalledApps(context: Context): InstalledApps {
    val packageManager = context.packageManager
    val installed = packageManager.getInstalledApplications(PackageManager.GET_META_DATA)
    val displayList = installed
        .asSequence()
        .filter { app ->
            app.packageName != context.packageName &&
                app.packageName !in CsqttConstants.General.VK_TRANSPORT_PACKAGES
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
    return InstalledApps(
        displayList = displayList,
        allPackages = installed.asSequence().map { it.packageName }.toSet(),
    )
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

    var appsList by remember { mutableStateOf(AppCache.cached?.displayList.orEmpty()) }
    // Сырой набор имён из PackageManager: авторитетный ответ «установлен ли
    // пакет» для предиката подмены и счётчиков карточки. Не выводится из
    // appsList — тот отфильтрован для показа.
    var installedPackages by remember { mutableStateOf(AppCache.cached?.allPackages.orEmpty()) }
    var isAppsLoading by remember { mutableStateOf(AppCache.cached == null) }
    var isRefreshing by remember { mutableStateOf(false) }
    var refreshFailed by remember { mutableStateOf(false) }
    var isMigrationReady by rememberSaveable { mutableStateOf(false) }

    var showAppsDialog by rememberSaveable { mutableStateOf(false) }
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

        AppCache.cached?.let {
            appsList = it.displayList
            installedPackages = it.allPackages
            isAppsLoading = false
            return@LaunchedEffect
        }

        isAppsLoading = true
        try {
            val loadedApps = withContext(Dispatchers.IO) { loadInstalledApps(context) }
            AppCache.cached = loadedApps
            appsList = loadedApps.displayList
            installedPackages = loadedApps.allPackages
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (throwable: Throwable) {
            // A single broken package must not take the whole list down.
            appsList = emptyList()
            installedPackages = emptySet()
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
        AppCache.cached = null
        isRefreshing = true
        scope.launch {
            try {
                val loadedApps = withContext(Dispatchers.IO) { loadInstalledApps(context) }
                appsList = loadedApps.displayList
                installedPackages = loadedApps.allPackages
                AppCache.cached = loadedApps
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
    val rulePackages = serverRule?.packages?.toSet() ?: emptySet()
    // The mode that actually applies: the server rule wins while it is active,
    // the local setting is only a fallback without one. One value feeds both
    // the card status and the dialog highlight.
    val serverIsWhite = serverRule?.isWhite == true

    // Пользовательский слой, который диалог редактирует и который карточка
    // атрибуирует «ваши»: под правилом — список режима правила, без него — режима профиля.
    val effectiveIsWhite = if (serverRuleActive) serverIsWhite else isWhitelist
    val userEditableSelection = when {
        serverRuleActive && serverIsWhite -> whitelistSelection
        serverRuleActive -> blacklistSelection
        else -> activeAppSelection
    }

    // Подмена «правило на все приложения» для подписи диалога считается один раз
    // здесь — по нефильтрованному набору установленных. Диалог получает список,
    // уже суженный поиском, поэтому выводить из него установленность нельзя.
    val substitutionApplied = AppDialogPolicy.substitutionApplied(
        serverLocked = serverRuleActive,
        isWhite = effectiveIsWhite,
        rulePackages = rulePackages,
        activeSelection = userEditableSelection,
        installedPackages = installedPackages,
    )

    // The system apps that carried a rule when the dialog opened for the
    // current mode stay visible for the whole session: unchecking a rule must
    // not make the row disappear under the finger that just tapped it.
    val pinnedForSession = remember(showAppsDialog, isWhitelist) {
        if (showAppsDialog) activeAppSelection else emptySet()
    }

    val filteredApps = remember(
        appsList,
        appSearchQuery,
        userEditableSelection,
        rulePackages,
        showSystemAppsState,
        pinnedForSession,
    ) {
        AppListPolicy.filterApps(
            apps = appsList,
            query = appSearchQuery,
            showSystemApps = showSystemAppsState,
            activeSelection = userEditableSelection,
            isSystem = { it.isSystem },
            packageName = { it.packageName },
            name = { it.name },
            keepVisible = pinnedForSession + rulePackages + userEditableSelection,
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
                    val mergedCounts = if (serverRuleActive) {
                        MergedRoutingPolicy.cardCounts(
                            ruleIsWhite = serverIsWhite,
                            rulePackages = rulePackages,
                            localBlack = blacklistSelection,
                            localWhite = whitelistSelection,
                            preset = preset,
                            userEnabled = orangeTunnelEnabled,
                            installedPackages = installedPackages,
                            transportPackages = CsqttConstants.General.VK_TRANSPORT_PACKAGES +
                                context.packageName,
                        )
                    } else {
                        null
                    }
                    // Числа имеют смысл только по загруженному списку: пустой список
                    // бывает и на первом кадре, и после неудачной загрузки.
                    val appStatusText = when {
                        !serverRuleActive && isWhitelist ->
                            "Белый список: ${whitelistSelection.size} в туннеле"
                        !serverRuleActive ->
                            "Чёрный список: ${blacklistSelection.size} исключено"
                        installedPackages.isEmpty() && isAppsLoading ->
                            "Правило сервера: список приложений загружается…"
                        installedPackages.isEmpty() ->
                            "Правило сервера: список приложений недоступен"
                        serverIsWhite -> with(requireNotNull(mergedCounts)) {
                            "Белый список: $inTunnel в туннель — $serverAttributed от правила сервера, " +
                                "$localAttributed ваши\n($alwaysExcluded всегда мимо туннеля, " +
                                "$optOut можно отключить)"
                        }
                        else -> with(requireNotNull(mergedCounts)) {
                            "Чёрный список: $excluded исключено — $serverAttributed от правила сервера, " +
                                "$localAttributed ваши\n($alwaysExcluded всегда мимо туннеля, " +
                                "$optOut можно отключить)"
                        }
                    }
                    Text(
                        text = appStatusText,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = if (serverRuleActive) Int.MAX_VALUE else 1,
                        softWrap = serverRuleActive,
                        overflow = TextOverflow.Ellipsis,
                    )
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

            if (serverRuleActive) {
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
                        } else {
                            ""
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
                        onClick = {},
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
                        } else {
                            ""
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
                        onClick = {},
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
            }

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

        if (showAppsDialog) {
            AppListDialog(
                appsList = filteredApps,
                isAppsLoading = isAppsLoading,
                isMigrationReady = isMigrationReady,
                isRefreshing = isRefreshing,
                refreshFailed = refreshFailed,
                searchQuery = appSearchQuery,
                onSearchQueryChange = { appSearchQuery = it },
                activeSelection = userEditableSelection,
                isWhitelist = effectiveIsWhite,
                showSystemApps = showSystemAppsState,
                onShowSystemAppsChange = { value ->
                    showSystemAppsState = value
                    appPersistenceScope.launch { settingsStore.saveShowSystemApps(value) }
                },
                onToggleApp = { packageName ->
                    val newSelection = if (packageName in userEditableSelection) {
                        userEditableSelection - packageName
                    } else {
                        userEditableSelection + packageName
                    }
                    if (effectiveIsWhite) {
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
                substituted = substitutionApplied,
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

        if (showRulesTransferDialog) {
            var transferAppsSelected by rememberSaveable { mutableStateOf(true) }

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

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Button(
                                onClick = {
                                    if (!transferAppsSelected) {
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
                                    if (!transferAppsSelected) {
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
