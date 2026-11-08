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
    substituted: Boolean = false,
    lockedPackages: Set<String> = emptySet(),
    preset: PresetApps = PresetApps(red = emptySet(), orange = emptySet()),
    orangeTunnelEnabled: Set<String> = emptySet(),
    onToggleOrange: (String) -> Unit = {},
) {
    val focusManager = LocalFocusManager.current
    val appListState = rememberLazyListState()
    var menuExpanded by remember { mutableStateOf(false) }

    val filtersActive = searchQuery.isNotBlank() || !showSystemApps

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

                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        text = stringResource(R.string.exceptions_selected_count, activeSelection.size),
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Ellipsis,
                    )
                    // Подмена: белый список правила непуст, но ни одного из его
                    // пакетов нет среди установленных (например, они в приватном
                    // пространстве). Тогда план — «все приложения», и пользовательский
                    // выбор на него не влияет. Признак считается вызывающим по
                    // нефильтрованному набору установленных тем же предикатом, что у
                    // сборщика плана, счётчиков карточки и per-UID триггера.
                    if (serverLocked) {
                        Text(
                            text = if (substituted) {
                                "Ваши выборы не применяются, пока действует правило на все приложения"
                            } else {
                                "Режим задан правилом сервера. Вы редактируете свой ${if (isWhitelist) "белый" else "чёрный"} список — он дополняет правило"
                            },
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }

                // The preset sections are rendered as elements of the list below,
                // not as a fixed column above it: they have to scroll with the
                // apps and must not take height away from them (the preset holds
                // 184 red packages, dozens of which can be installed).

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
                            val sections = AppDialogPolicy.buildSections(
                                apps = appsList,
                                packageName = { it.packageName },
                                ruleActive = serverLocked,
                                rulePackages = lockedPackages,
                                preset = preset,
                            )

                            sections.forEach { section ->
                                when (section.source) {
                                    AppSectionSource.RED -> {
                                        item(key = "header-${section.source.name}", contentType = "preset-header") {
                                            PresetSectionHeader(
                                                title = section.title,
                                                shownCount = section.rows.size,
                                                totalInPreset = section.total,
                                                risk = PresetRisk.RED,
                                                filtersActive = filtersActive,
                                            )
                                        }
                                        items(
                                            items = section.rows,
                                            key = { "section-${section.source.name}-${it.packageName}" },
                                            contentType = { "preset-row" },
                                        ) { app ->
                                            AppRow(
                                                app = app.copy(presetRisk = PresetRisk.RED),
                                                isSelected = presetRowChecked(
                                                    risk = PresetRisk.RED,
                                                    isWhitelist = isWhitelist,
                                                    packageName = app.packageName,
                                                    orangeTunnelEnabled = orangeTunnelEnabled,
                                                ),
                                                enabled = false,
                                                onClick = {},
                                            )
                                        }
                                    }

                                    AppSectionSource.SERVER -> {
                                        item(key = "header-${section.source.name}", contentType = "server-header") {
                                            ServerSectionHeader(
                                                title = section.title,
                                                shownCount = section.rows.size,
                                                totalInRule = section.total,
                                                filtersActive = filtersActive,
                                            )
                                        }
                                        items(
                                            items = section.rows,
                                            key = { "section-${section.source.name}-${it.packageName}" },
                                            contentType = { "server-row" },
                                        ) { app ->
                                            AppRow(
                                                app = app.copy(serverRule = true),
                                                isSelected = true,
                                                enabled = false,
                                                onClick = {},
                                            )
                                        }
                                    }

                                    AppSectionSource.ORANGE -> {
                                        item(key = "header-${section.source.name}", contentType = "preset-header") {
                                            PresetSectionHeader(
                                                title = section.title,
                                                shownCount = section.rows.size,
                                                totalInPreset = section.total,
                                                risk = PresetRisk.ORANGE,
                                                filtersActive = filtersActive,
                                            )
                                        }
                                        items(
                                            items = section.rows,
                                            key = { "section-${section.source.name}-${it.packageName}" },
                                            contentType = { "preset-row" },
                                        ) { app ->
                                            AppRow(
                                                app = app.copy(presetRisk = PresetRisk.ORANGE),
                                                isSelected = presetRowChecked(
                                                    risk = PresetRisk.ORANGE,
                                                    isWhitelist = isWhitelist,
                                                    packageName = app.packageName,
                                                    orangeTunnelEnabled = orangeTunnelEnabled,
                                                ),
                                                enabled = true,
                                                onClick = { onToggleOrange(app.packageName) },
                                            )
                                        }
                                    }

                                    AppSectionSource.USER -> {
                                        items(
                                            items = section.rows,
                                            key = { "section-${section.source.name}-${it.packageName}" },
                                            contentType = { "application" },
                                        ) { app ->
                                            AppRow(
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

@Composable
private fun ServerSectionHeader(
    title: String,
    shownCount: Int,
    totalInRule: Int,
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
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
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
                    "не установлено ни одного приложения (в правиле $totalInRule)"
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
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
