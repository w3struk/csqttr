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
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmap
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.csqtt.client.AppRoutingPolicy
import com.csqtt.client.CsqttConstants
import com.csqtt.client.MergedRoutingPolicy
import com.csqtt.client.PresetApps
import com.csqtt.client.SettingsStore
import com.csqtt.client.TunnelManager
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
internal fun AppRoutingSection(
    settingsStore: SettingsStore,
    savedExcluded: String,
    savedWhitelist: String,
    showSystemApps: Boolean,
    isWhitelist: Boolean,
    serverRoutingActive: Boolean,
) {
    val context = LocalContext.current.applicationContext
    val scope = rememberCoroutineScope()
    val tunnelRunning by TunnelManager.running.collectAsStateWithLifecycle()
    val serverRoutingActiveLive by TunnelManager.serverRoutingActive.collectAsStateWithLifecycle(
        initialValue = serverRoutingActive
    )
    val isServerRouting = serverRoutingActive || serverRoutingActiveLive
    val activeServerRule by TunnelManager.activeServerRoutingRule.collectAsStateWithLifecycle()

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
                if (blackChanged) {
                    settingsStore.saveExcludedApps(currentBlack.sorted().joinToString(","))
                }
                if (whiteChanged) {
                    settingsStore.saveWhitelistApps(currentWhite.sorted().joinToString(","))
                }
                if (modeChanged) {
                    settingsStore.saveIsWhitelist(currentIsWhite)
                }
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
    // атрибуирует «ваши»: под правилом — только чёрный список, без него —
    // список режима профиля. Белый список под правилом не редактируется.
    val effectiveIsWhite = if (serverRuleActive) serverIsWhite else isWhitelist
    val userEditableSelection = if (serverRuleActive) blacklistSelection else activeAppSelection

    // Подмена «правило на все приложения» для подписи диалога считается один раз
    // здесь — по нефильтрованному набору установленных и по СЫРОМУ правилу.
    // Диалог получает список, уже суженный поиском, поэтому выводить из него
    // установленность нельзя, а исключения пользователя не должны превращать
    // видимое правило в подмену.
    val substitutionApplied = AppDialogPolicy.substitutionApplied(
        serverLocked = serverRuleActive,
        isWhite = effectiveIsWhite,
        rulePackages = rulePackages,
        installedPackages = installedPackages,
    )

    // The system apps that carried a rule when the dialog opened for the
    // current mode stay visible for the whole session: unchecking a rule must
    // not make the row disappear under the finger that just tapped it.
    val pinnedForSession = remember(showAppsDialog, isWhitelist) {
        if (showAppsDialog) userEditableSelection else emptySet()
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

    // Под правилом тап пишет только чёрный ключ: белый список не трогается и
    // после остановки туннеля остаётся тем, каким был до правила.
    fun persistUserBlacklist(selection: Set<String>, reload: Boolean) {
        appPersistenceScope.launch {
            settingsStore.saveExcludedApps(selection.sorted().joinToString(","))
            if (reload) TunnelManager.reloadVpn()
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
                if (blacklistChanged) {
                    settingsStore.saveExcludedApps(pendingBlacklist.sorted().joinToString(","))
                }
                if (whitelistChanged) {
                    settingsStore.saveWhitelistApps(pendingWhitelist.sorted().joinToString(","))
                }
            }
        }
    }

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
                        "$localAttributed исключены вами\n($alwaysExcluded всегда мимо туннеля, " +
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
                val selection = userEditableSelection
                val newSelection = if (packageName in selection) {
                    selection - packageName
                } else {
                    selection + packageName
                }
                // Под правилом правка применяется к живому туннелю сразу и
                // снимок гасит повторное сохранение при закрытии. Локальный
                // режим сохраняет прежнее поведение: применяется при
                // закрытии диалога.
                val forWhitelist = !serverRuleActive && effectiveIsWhite
                if (forWhitelist) {
                    whitelistSelection = newSelection
                    appPersistenceScope.launch {
                        settingsStore.saveWhitelistApps(newSelection.sorted().joinToString(","))
                    }
                } else {
                    blacklistSelection = newSelection
                    if (serverRuleActive) dialogSnapshotBlacklist = newSelection
                    persistUserBlacklist(newSelection, reload = serverRuleActive)
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
}
