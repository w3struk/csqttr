package com.csqtt.client.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.csqtt.client.SettingsStore
import com.csqtt.client.ui.components.CsqttScreen
import com.csqtt.client.ui.design.CsqttShapes
import com.csqtt.client.ui.design.CsqttSizes
import com.csqtt.client.ui.dialogs.TurnSubnetsDialog
import kotlinx.coroutines.launch

@Composable
internal fun GeneralSettingsTab(
    settingsStore: SettingsStore,
    activeProfile: Int,
    onActiveProfileChange: (Int) -> Unit,
    currentTheme: String,
    onThemeChange: (String) -> Unit,
    activeFingerprint: String,
    onFingerprintChange: (String) -> Unit,
    autoPauseOnWifi: Boolean,
    onAutoPauseOnWifiChange: (Boolean) -> Unit,
    participantShowLogs: Boolean,
    onParticipantShowLogsChange: (Boolean) -> Unit,
    savedExcluded: String,
    savedWhitelist: String,
    showSystemApps: Boolean,
    isWhitelist: Boolean,
    serverRoutingActive: Boolean,
) {
    val scope = rememberCoroutineScope()
    val selectedTurnSubnet by settingsStore.selectedTurnSubnet.collectAsStateWithLifecycle(
        initialValue = "",
    )
    val turnSubnetIpLimit by settingsStore.turnSubnetIpLimit.collectAsStateWithLifecycle(
        initialValue = "ALL",
    )
    var showAutoPauseInfo by rememberSaveable { mutableStateOf(false) }
    var showTurnSubnetsDialog by rememberSaveable { mutableStateOf(false) }
    var editingProfileIndex by rememberSaveable { mutableStateOf<Int?>(null) }
    var editingProfileName by rememberSaveable { mutableStateOf("") }

    CsqttScreen {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            AppSectionCard {
                GeneralSettingsContent(
                    settingsStore = settingsStore,
                    activeProfile = activeProfile,
                    onActiveProfileChange = onActiveProfileChange,
                    currentTheme = currentTheme,
                    onThemeChange = onThemeChange,
                    activeFingerprint = activeFingerprint,
                    onFingerprintChange = onFingerprintChange,
                    autoPauseOnWifi = autoPauseOnWifi,
                    onAutoPauseOnWifiChange = onAutoPauseOnWifiChange,
                    participantShowLogs = participantShowLogs,
                    onParticipantShowLogsChange = onParticipantShowLogsChange,
                    onEditProfile = { index, currentName ->
                        editingProfileIndex = index
                        editingProfileName = currentName
                    },
                    onShowAutoPauseInfo = { showAutoPauseInfo = true },
                    onShowTurnSubnets = { showTurnSubnetsDialog = true },
                )
            }

            AppRoutingSection(
                settingsStore = settingsStore,
                savedExcluded = savedExcluded,
                savedWhitelist = savedWhitelist,
                showSystemApps = showSystemApps,
                isWhitelist = isWhitelist,
                serverRoutingActive = serverRoutingActive,
            )

            CsqttActionsCard(
                settingsStore = settingsStore,
            )
        }
    }

    if (showAutoPauseInfo) {
        WifiAutoPauseInfoDialog(onDismiss = { showAutoPauseInfo = false })
    }

    if (showTurnSubnetsDialog) {
        TurnSubnetsDialog(
            selectedSubnetId = selectedTurnSubnet,
            turnSubnetIpLimit = turnSubnetIpLimit,
            onSelectSubnet = { id ->
                scope.launch { settingsStore.saveSelectedTurnSubnet(id) }
            },
            onSelectIpLimit = { limit ->
                scope.launch { settingsStore.saveTurnSubnetIpLimit(limit) }
            },
            onDismiss = { showTurnSubnetsDialog = false },
        )
    }

    editingProfileIndex?.let { p ->
        Dialog(
            onDismissRequest = { editingProfileIndex = null },
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
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 18.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = "Название профиля",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            maxLines = 1,
                            softWrap = false,
                            overflow = TextOverflow.Ellipsis,
                        )
                        IconButton(
                            onClick = { editingProfileIndex = null },
                            modifier = Modifier.size(CsqttSizes.MinimumTouchTarget),
                        ) {
                            Icon(
                                imageVector = Icons.Default.Close,
                                contentDescription = "Закрыть",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }

                    OutlinedTextField(
                        value = editingProfileName,
                        onValueChange = { editingProfileName = it },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        shape = CsqttShapes.Control,
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = MaterialTheme.colorScheme.primary,
                            unfocusedBorderColor = MaterialTheme.colorScheme.outline.copy(alpha = 0.3f),
                        ),
                        trailingIcon = {
                            IconButton(
                                onClick = { editingProfileName = "" },
                                modifier = Modifier.size(CsqttSizes.MinimumTouchTarget),
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Close,
                                    contentDescription = "Очистить",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(20.dp),
                                )
                            }
                        },
                    )

                    Button(
                        onClick = {
                            val targetProfile = p
                            val targetName = editingProfileName
                            editingProfileIndex = null
                            scope.launch {
                                settingsStore.saveProfileName(targetProfile, targetName)
                            }
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(CsqttSizes.ControlHeight),
                        shape = CsqttShapes.Control,
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.primary,
                            contentColor = MaterialTheme.colorScheme.onPrimary,
                        ),
                    ) {
                        Text(
                            text = "Сохранить",
                            style = MaterialTheme.typography.labelLarge,
                            fontWeight = FontWeight.SemiBold,
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
