package com.csqtt.client.ui

import android.Manifest
import android.content.pm.PackageManager
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.core.content.ContextCompat
import com.csqtt.client.LinkSaveNotice
import com.csqtt.client.R
import com.csqtt.client.SettingsStore
import com.csqtt.client.ui.design.CsqttSizes
import com.csqtt.client.ui.dialogs.QrScannerDialog
import kotlinx.coroutines.launch

@Composable
fun FloatingToolbar(
    settingsStore: SettingsStore,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var showQrScanner by rememberSaveable { mutableStateOf(false) }

    val cameraPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) {
            showQrScanner = true
        } else {
            Toast.makeText(context, "Требуется разрешение на камеру для сканирования QR-кода", Toast.LENGTH_SHORT).show()
        }
    }

    IconButton(
        onClick = {
            val hasPermission = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
            if (hasPermission) {
                showQrScanner = true
            } else {
                cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
            }
        },
        modifier = modifier.size(CsqttSizes.MinimumTouchTarget),
    ) {
        Icon(
            painter = painterResource(id = R.drawable.ic_qr_scan),
            contentDescription = "Сканировать QR-код",
            modifier = Modifier.size(CsqttSizes.IconLarge),
            tint = MaterialTheme.colorScheme.onSurface,
        )
    }

    if (showQrScanner) {
        QrScannerDialog(
            onDismissRequest = { showQrScanner = false },
            onQrCodeScanned = { rawLink ->
                val parsed = com.csqtt.client.ui.utils.parseCsqttLink(rawLink)
                if (parsed != null) {
                    showQrScanner = false
                    val link = rawLink.trim()
                    scope.launch {
                        val saved = try {
                            settingsStore.saveCsqttParticipantLink(link)
                            true
                        } catch (_: java.io.IOException) {
                            false
                        }
                        val outcome = LinkSaveNotice.outcomeForParticipantLink(saved)
                        Toast.makeText(context, LinkSaveNotice.linkToast(outcome), Toast.LENGTH_LONG).show()
                    }
                } else {
                    Toast.makeText(context, "QR-код не содержит ссылку reCSQTT", Toast.LENGTH_SHORT).show()
                }
            }
        )
    }
}
