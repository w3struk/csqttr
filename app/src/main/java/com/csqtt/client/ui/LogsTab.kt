package com.csqtt.client.ui

import com.csqtt.client.showRaisedToast
import android.content.ClipData
import android.content.ClipboardManager
import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.csqtt.client.LogEntry
import com.csqtt.client.LogTimestampPolicy
import com.csqtt.client.R
import com.csqtt.client.TunnelManager
import com.csqtt.client.ui.components.CsqttEmptyState
import com.csqtt.client.ui.components.CsqttScreen
import com.csqtt.client.ui.design.CsqttShapes
import com.csqtt.client.ui.design.CsqttSizes
import com.csqtt.client.ui.design.CsqttSpacing
import com.csqtt.client.ui.design.CsqttTheme

import androidx.compose.foundation.BorderStroke

@Composable
fun LogsTab() {
    CsqttScreen {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            shape = CsqttShapes.Card,
            color = CsqttTheme.extendedColors.terminalBackground,
            contentColor = CsqttTheme.extendedColors.terminalText,
        ) {
            LogsTerminal()
        }
    }
}

@Composable
private fun LogsTerminal() {
    val context = LocalContext.current
    val currentLogs = TunnelManager.logs
    val listState = rememberLazyListState()
    val logsReportCopiedMessage = stringResource(R.string.logs_report_copied)
    val reportCopiedMessage = stringResource(R.string.report_copied)
    val copyReportWithLogsDescription = stringResource(R.string.action_copy_report)
    val copyReportOnlyDescription = stringResource(R.string.action_copy_report_only)

    var isAtBottom by remember { mutableStateOf(true) }

    LaunchedEffect(listState) {
        snapshotFlow {
            listState.isScrollInProgress to listState.canScrollForward
        }.collect { (isScrolling, canScrollForward) ->
            if (isScrolling) {
                isAtBottom = !canScrollForward
            } else if (!canScrollForward) {
                isAtBottom = true
            }
        }
    }

    LaunchedEffect(currentLogs.isEmpty()) {
        if (currentLogs.isEmpty()) {
            isAtBottom = true
        }
    }

    LaunchedEffect(currentLogs.lastOrNull()?.id) {
        if (currentLogs.isNotEmpty() && isAtBottom) {
            listState.scrollToItem(currentLogs.lastIndex)
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        if (currentLogs.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CsqttEmptyState(
                    title = stringResource(R.string.logs_empty_title),
                    icon = Icons.Outlined.Terminal,
                    modifier = Modifier.padding(CsqttSpacing.Md),
                    contentColor = CsqttTheme.extendedColors.terminalText,
                    secondaryContentColor = CsqttTheme.extendedColors.terminalMuted,
                )
            }
        } else {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(start = CsqttSpacing.Md, top = CsqttSpacing.Md, end = CsqttSpacing.Md, bottom = 64.dp),
                verticalArrangement = Arrangement.spacedBy(CsqttSpacing.Xs),
            ) {
                items(
                    items = currentLogs,
                    key = { it.id },
                    contentType = { "log_line" },
                ) { entry ->
                    LogLine(entry)
                }
            }
        }

        Row(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(
                onClick = {
                    val text = buildReportCopyText(
                        buildSupportReport(),
                        currentLogs.map { LogTimestampPolicy.copyLine(it) },
                    )
                    val clipboard = context.getSystemService(ClipboardManager::class.java)
                    clipboard?.setPrimaryClip(ClipData.newPlainText("CSQTT Report", text))
                    if (clipboard != null) {
                        context.showRaisedToast(
                            if (currentLogs.isEmpty()) reportCopiedMessage else logsReportCopiedMessage,
                            Toast.LENGTH_SHORT,
                        )
                    }
                },
                modifier = Modifier.size(CsqttSizes.MinimumTouchTarget)
            ) {
                Icon(
                    imageVector = Icons.Outlined.ContentCopy,
                    contentDescription = if (currentLogs.isEmpty()) {
                        copyReportOnlyDescription
                    } else {
                        copyReportWithLogsDescription
                    },
                    tint = Color.White,
                    modifier = Modifier.size(22.dp)
                )
            }

            IconButton(
                onClick = TunnelManager::clearLogs,
                enabled = currentLogs.isNotEmpty(),
                modifier = Modifier.size(CsqttSizes.MinimumTouchTarget)
            ) {
                Icon(
                    imageVector = Icons.Outlined.Delete,
                    contentDescription = stringResource(R.string.action_clear),
                    tint = if (currentLogs.isNotEmpty()) Color.White else Color.White.copy(alpha = 0.4f),
                    modifier = Modifier.size(22.dp)
                )
            }
        }
    }
}

