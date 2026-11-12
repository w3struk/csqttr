package com.csqtt.client.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AltRoute
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.csqtt.client.CsqttConstants
import com.csqtt.client.SettingsStore
import com.csqtt.client.ui.components.CsqttSettingRow
import com.csqtt.client.ui.design.CsqttShapes
import com.csqtt.client.ui.design.CsqttSizes

@Composable
internal fun GeneralSettingsContent(
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
    onEditProfile: (index: Int, currentName: String) -> Unit,
    onShowAutoPauseInfo: () -> Unit,
    onShowTurnSubnets: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val profileNames by settingsStore.profileNames.collectAsStateWithLifecycle(
        initialValue = emptyMap(),
    )

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = "Основные параметры",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.Bold,
            maxLines = 1,
            softWrap = false,
            overflow = TextOverflow.Ellipsis,
        )

        CompactDropdownSetting(
            title = "Профиль конфигурации",
            selectedKey = activeProfile.toString(),
            options = (CsqttConstants.Profiles.MIN_INDEX..CsqttConstants.Profiles.MAX_INDEX)
                .map { profile -> profile.toString() to (profileNames[profile] ?: "Профиль $profile") },
            enabled = true,
            onSelected = { profile ->
                profile.toIntOrNull()?.let(onActiveProfileChange)
            },
            onItemEdit = { key ->
                val p = key.toIntOrNull() ?: 0
                onEditProfile(p, profileNames[p] ?: "Профиль $p")
            },
        )

        CompactDropdownSetting(
            title = "Отпечаток",
            selectedKey = activeFingerprint,
            options = listOf(
                "chrome" to "Chrome",
                "safari" to "Safari",
                "firefox" to "Firefox",
                "edge" to "Edge",
                "opera" to "Opera",
            ),
            enabled = true,
            onSelected = onFingerprintChange,
        )

        CompactDropdownSetting(
            title = "Оформление",
            selectedKey = currentTheme,
            options = listOf(
                CsqttConstants.Theme.MODE_SYSTEM to "Система",
                CsqttConstants.Theme.MODE_LIGHT to "Светлая",
                CsqttConstants.Theme.MODE_DARK to "Тёмная",
            ),
            enabled = true,
            onSelected = onThemeChange,
        )

        CsqttSettingRow(
            title = "Автопауза при Wi-Fi",
            checked = autoPauseOnWifi,
            onCheckedChange = onAutoPauseOnWifiChange,
            onInfoClick = onShowAutoPauseInfo,
            infoContentDescription = "Как работает автопауза при Wi-Fi",
        )

        CsqttSettingRow(
            title = "Показывать логи",
            checked = participantShowLogs,
            onCheckedChange = onParticipantShowLogsChange,
        )

        OutlinedButton(
            onClick = onShowTurnSubnets,
            modifier = Modifier
                .padding(top = 4.dp, bottom = 4.dp)
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
            contentPadding = PaddingValues(horizontal = 16.dp),
        ) {
            Icon(
                imageVector = Icons.Outlined.AltRoute,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(Modifier.width(8.dp))
            Text(
                text = "Выбор TURN-подсетей",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                softWrap = false,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
