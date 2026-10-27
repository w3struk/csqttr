package com.csqtt.client.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.Apps
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.csqtt.client.AppRoutingPolicy
import com.csqtt.client.PresetApps
import com.csqtt.client.PresetRisk
import com.csqtt.client.R
import com.csqtt.client.ui.components.CsqttBanner
import com.csqtt.client.ui.components.CsqttEmptyState
import com.csqtt.client.ui.components.CsqttLoadingState
import com.csqtt.client.ui.design.CsqttShapes
import com.csqtt.client.ui.design.CsqttSizes
import com.csqtt.client.ui.design.CsqttSpacing

/**
 * Full-width dialog with the list of applications and the per-app split
 * tunneling rules.
 *
 * The list is already filtered and sorted by the caller — this composable only
 * presents it and reports user intent back.
 */
@Composable
internal fun AppListDialog(
    appsList: List<AppItem>,
    isAppsLoading: Boolean,
    isMigrationReady: Boolean,
    isRefreshing: Boolean,
    refreshFailed: Boolean,
    searchQuery: String,
    onSearchQueryChange: (String) -> Unit,
    activeSelection: Set<String>,
    isWhitelist: Boolean,
    showSystemApps: Boolean,
    onShowSystemAppsChange: (Boolean) -> Unit,
    onToggleApp: (String) -> Unit,
    onRefresh: () -> Unit,
    onSwitchMode: (Boolean) -> Unit,
    onClose: () -> Unit,
    serverLocked: Boolean = false,
    lockedPackages: Set<String> = emptySet(),
    preset: PresetApps = PresetApps(red = emptySet(), orange = emptySet()),
    orangeTunnelEnabled: Set<String> = emptySet(),
    onToggleOrange: (String) -> Unit = {},
) {
    val focusManager = LocalFocusManager.current
    val appListState = rememberLazyListState()
    var menuExpanded by remember { mutableStateOf(false) }

    // The preset lists only say which packages exist in a level; the sections
    // show the ones actually installed on the device. `appsList` is already
    // narrowed by the caller, so the sections must not claim a device-wide
    // installed count while a filter is on.
    fun installedPresetApps(pkgs: Set<String>): List<AppItem> =
        appsList.filter { it.packageName in pkgs }

    val filtersActive = searchQuery.isNotBlank() || !showSystemApps

    // A white rule without packages — «правило на все приложения» — routes every
    // installed app through the tunnel. The predicate is shared with the routing
    // card and `TunVpnService` so the checkbox cannot disagree with them.
    val isDeviceWideRule = serverLocked &&
        AppRoutingPolicy.isDeviceWideRule(isWhitelist, lockedPackages)

    // The viewport resets on mode and query changes so the selected group is
    // visible again.
    LaunchedEffect(isWhitelist, searchQuery) {
        appListState.scrollToItem(0)
    }

    Dialog(
        onDismissRequest = onClose,
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
                verticalArrangement = Arrangement.spacedBy(8.dp),
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
                            imageVector = Icons.Outlined.Apps,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.size(22.dp),
                        )
                        Text(
                            text = "Список приложений",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    IconButton(
                        onClick = onClose,
                        modifier = Modifier.size(36.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = null,
                        )
                    }
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (!isWhitelist) {
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
                            enabled = isMigrationReady && !serverLocked,
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
                            onClick = { onSwitchMode(false) },
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
                            enabled = isMigrationReady && !serverLocked,
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

                    if (isWhitelist) {
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
                            enabled = isMigrationReady && !serverLocked,
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
                            onClick = { onSwitchMode(true) },
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
                            enabled = isMigrationReady && !serverLocked,
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

                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = onSearchQueryChange,
                    label = {
                        Text(
                            stringResource(R.string.exceptions_search_label),
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                    placeholder = {
                        Text(
                            stringResource(R.string.exceptions_search_placeholder),
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Ellipsis,
                        )
                    },
                    leadingIcon = { Icon(Icons.Outlined.Search, contentDescription = null) },
                    trailingIcon = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            if (searchQuery.isNotEmpty()) {
                                IconButton(onClick = { onSearchQueryChange("") }) {
                                    Icon(Icons.Default.Clear, contentDescription = null)
                                }
                            }
                            Box {
                                if (isRefreshing) {
                                    // The spinner replaces the menu anchor, so the
                                    // menu has to stay closed while it spins.
                                    Box(
                                        modifier = Modifier.size(48.dp),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        CircularProgressIndicator(
                                            modifier = Modifier.size(20.dp),
                                            strokeWidth = 2.dp,
                                        )
                                    }
                                } else {
                                    IconButton(onClick = { menuExpanded = true }) {
                                        Icon(Icons.Default.MoreVert, contentDescription = null)
                                    }
                                }
                                DropdownMenu(
                                    expanded = menuExpanded,
                                    onDismissRequest = { menuExpanded = false },
                                    modifier = Modifier.widthIn(min = 200.dp, max = 240.dp),
                                ) {
                                    DropdownMenuItem(
                                        text = { Text("Обновить список") },
                                        leadingIcon = {
                                            Box(
                                                modifier = Modifier.size(CsqttSizes.IconLarge),
                                                contentAlignment = Alignment.Center,
                                            ) {
                                                Icon(
                                                    imageVector = Icons.Default.Refresh,
                                                    contentDescription = null,
                                                    modifier = Modifier.size(CsqttSizes.IconLarge),
                                                )
                                            }
                                        },
                                        onClick = {
                                            menuExpanded = false
                                            onRefresh()
                                        },
                                        modifier = Modifier.heightIn(min = CsqttSizes.ControlHeight),
                                    )
                                    DropdownMenuItem(
                                        text = { Text("Показать системные приложения") },
                                        leadingIcon = {
                                            Box(
                                                modifier = Modifier.size(CsqttSizes.IconLarge),
                                                contentAlignment = Alignment.Center,
                                            ) {
                                                Checkbox(
                                                    checked = showSystemApps,
                                                    onCheckedChange = null,
                                                    modifier = Modifier.size(CsqttSizes.IconLarge),
                                                )
                                            }
                                        },
                                        // Every menu action closes the menu; the
                                        // list behind it shows the new state.
                                        onClick = {
                                            menuExpanded = false
                                            onShowSystemAppsChange(!showSystemApps)
                                        },
                                        modifier = Modifier.heightIn(min = CsqttSizes.ControlHeight),
                                    )
                                }
                            }
                        }
                    },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { focusManager.clearFocus() }),
                    shape = CsqttShapes.Control,
                    modifier = Modifier.fillMaxWidth(),
                )

                if (refreshFailed) {
                    CsqttBanner(
                        text = "Не удалось обновить список приложений",
                        containerColor = MaterialTheme.colorScheme.errorContainer,
                        contentColor = MaterialTheme.colorScheme.onErrorContainer,
                        icon = Icons.Outlined.Warning,
                    )
                }

                Text(
                    text = stringResource(R.string.exceptions_selected_count, activeSelection.size),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    softWrap = false,
                    overflow = TextOverflow.Ellipsis,
                )

                // The preset sections are rendered as elements of the list below,
                // not as a fixed column above it: they have to scroll with the
                // apps and must not take height away from them (the preset holds
                // 172 red packages, dozens of which can be installed).

                when {
                    !isMigrationReady || isAppsLoading -> {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f),
                            contentAlignment = Alignment.Center,
                        ) {
                            CsqttLoadingState(label = stringResource(R.string.exceptions_loading))
                        }
                    }

                    appsList.isEmpty() -> {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f),
                            contentAlignment = Alignment.Center,
                        ) {
                            CsqttEmptyState(
                                title = stringResource(R.string.exceptions_empty_title),
                                description = stringResource(R.string.exceptions_empty_description),
                                icon = Icons.Outlined.Apps,
                            )
                        }
                    }

                    else -> {
                        LazyColumn(
                            state = appListState,
                            modifier = Modifier
                                .fillMaxWidth()
                                .weight(1f),
                            contentPadding = PaddingValues(bottom = 8.dp),
                            verticalArrangement = Arrangement.spacedBy(CsqttSpacing.Xs),
                        ) {
                            if (serverLocked && preset.all.isNotEmpty()) {
                                presetSection(
                                    title = "Всегда мимо туннеля",
                                    installed = installedPresetApps(preset.red),
                                    totalInPreset = preset.red.size,
                                    risk = PresetRisk.RED,
                                    isWhitelist = isWhitelist,
                                    orangeTunnelEnabled = orangeTunnelEnabled,
                                    filtersActive = filtersActive,
                                    onToggleOrange = onToggleOrange,
                                )
                                presetSection(
                                    title = "Можно отключить",
                                    installed = installedPresetApps(preset.orange),
                                    totalInPreset = preset.orange.size,
                                    risk = PresetRisk.ORANGE,
                                    isWhitelist = isWhitelist,
                                    orangeTunnelEnabled = orangeTunnelEnabled,
                                    filtersActive = filtersActive,
                                    onToggleOrange = onToggleOrange,
                                )
                            }

                            items(
                                items = appsList,
                                key = { it.packageName },
                                contentType = { "application" },
                            ) { app ->
                                val risk = preset.riskOf(app.packageName)
                                when {
                                    // Preset rows win over the lock: an orange
                                    // package stays under user control even
                                    // when the operator's rule lists it.
                                    risk != null -> AppRow(
                                        app = app.copy(presetRisk = risk),
                                        isSelected = presetRowChecked(
                                            risk = risk,
                                            isWhitelist = isWhitelist,
                                            packageName = app.packageName,
                                            orangeTunnelEnabled = orangeTunnelEnabled,
                                        ),
                                        enabled = risk == PresetRisk.ORANGE,
                                        onClick = {
                                            if (risk == PresetRisk.ORANGE) onToggleOrange(app.packageName)
                                        },
                                    )

                                    serverLocked && app.packageName in lockedPackages -> AppRow(
                                        app = app,
                                        isSelected = true,
                                        enabled = false,
                                        onClick = {},
                                    )

                                    // Reached only under a server rule: the row
                                    // cannot change routing, so it must not
                                    // pretend the user can toggle it. Under a
                                    // device-wide rule every non-preset app goes
                                    // through the tunnel, hence the checked box.
                                    serverLocked -> AppRow(
                                        app = app,
                                        isSelected = isDeviceWideRule,
                                        enabled = false,
                                        onClick = {},
                                    )

                                    else -> AppRow(
                                        app = app,
                                        isSelected = app.packageName in activeSelection,
                                        onClick = { onToggleApp(app.packageName) },
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

/**
 * Effective checkbox state of a preset row — "is this app routed the way the
 * level dictates", not "is the package in the mode's own list".
 *
 * In the blacklist mode the checkbox means "excluded from the tunnel", in the
 * whitelist mode it means "goes through the tunnel".
 */
private fun presetRowChecked(
    risk: PresetRisk,
    isWhitelist: Boolean,
    packageName: String,
    orangeTunnelEnabled: Set<String>,
): Boolean = when (risk) {
    PresetRisk.RED -> !isWhitelist                 // чёрный: всегда исключён; белый: никогда в туннеле
    PresetRisk.ORANGE -> if (isWhitelist) packageName in orangeTunnelEnabled
                         else packageName !in orangeTunnelEnabled
}

/**
 * One preset level, emitted as regular items of the app list so the section
 * scrolls with the list and never takes a fixed slice of the dialog height.
 * Red rows are informational only, orange rows stay under user control.
 *
 * Keys are prefixed by the level: the same package can appear both here and in
 * the list below, and the list requires keys to be unique.
 */
private fun LazyListScope.presetSection(
    title: String,
    installed: List<AppItem>,
    totalInPreset: Int,
    risk: PresetRisk,
    isWhitelist: Boolean,
    orangeTunnelEnabled: Set<String>,
    filtersActive: Boolean,
    onToggleOrange: (String) -> Unit,
) {
    item(key = "preset-header-${risk.name}", contentType = "preset-header") {
        PresetSectionHeader(
            title = title,
            shownCount = installed.size,
            totalInPreset = totalInPreset,
            risk = risk,
            filtersActive = filtersActive,
        )
    }
    items(
        items = installed,
        key = { "preset-${risk.name}-${it.packageName}" },
        contentType = { "preset-row" },
    ) { item ->
        AppRow(
            app = item.copy(presetRisk = risk),
            isSelected = presetRowChecked(risk, isWhitelist, item.packageName, orangeTunnelEnabled),
            enabled = risk == PresetRisk.ORANGE,
            // Red rows are informational: the toggle is spelled out per level
            // instead of relying on the row ignoring clicks.
            onClick = if (risk == PresetRisk.ORANGE) {
                { onToggleOrange(item.packageName) }
            } else {
                {}
            },
        )
    }
}

@Composable
private fun PresetSectionHeader(
    title: String,
    shownCount: Int,
    totalInPreset: Int,
    risk: PresetRisk,
    filtersActive: Boolean,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = CsqttSpacing.Xs),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
                color = if (risk == PresetRisk.RED) Color(0xFFE5484D) else Color(0xFFF76B15),
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            // The list arrives filtered, so the count only describes the device
            // when no filter is on.
            Text(
                text = if (filtersActive) "Показано: $shownCount" else "Установлено: $shownCount",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (shownCount == 0) {
            Text(
                text = if (filtersActive) {
                    "нет совпадений с фильтром"
                } else {
                    "не установлено ни одного приложения (в пресете $totalInPreset)"
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}
