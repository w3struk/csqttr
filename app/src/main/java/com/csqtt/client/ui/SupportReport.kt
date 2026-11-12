package com.csqtt.client.ui

import android.os.Build
import com.csqtt.client.BuildConfig

internal fun buildSupportReport(): String {
    val androidVersion = Build.VERSION.RELEASE ?: "?"
    val sdkInt = Build.VERSION.SDK_INT
    val primaryAbi = Build.SUPPORTED_ABIS.firstOrNull().orEmpty().ifBlank { "unknown" }
    val supportedAbis = Build.SUPPORTED_ABIS.joinToString().ifBlank { "unknown" }
    val manufacturer = Build.MANUFACTURER.orEmpty().ifBlank { "unknown" }
    val brand = Build.BRAND.orEmpty().ifBlank { "unknown" }
    val model = Build.MODEL.orEmpty().ifBlank { "unknown" }
    val device = Build.DEVICE.orEmpty().ifBlank { "unknown" }
    val product = Build.PRODUCT.orEmpty().ifBlank { "unknown" }
    val hardware = Build.HARDWARE.orEmpty().ifBlank { "unknown" }
    val board = Build.BOARD.orEmpty().ifBlank { "unknown" }
    val romDisplay = Build.DISPLAY.orEmpty().ifBlank { "unknown" }
    val buildId = Build.ID.orEmpty().ifBlank { "unknown" }
    val buildFingerprint = Build.FINGERPRINT.orEmpty().ifBlank { "unknown" }
    val buildType = Build.TYPE.orEmpty().ifBlank { "unknown" }
    val soc = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        val socManufacturer = Build.SOC_MANUFACTURER.orEmpty().ifBlank { "unknown" }
        val socModel = Build.SOC_MODEL.orEmpty().ifBlank { "unknown" }
        "$socManufacturer / $socModel"
    } else {
        "n/a"
    }

    return buildString {
        appendLine("Версия приложения: ${BuildConfig.VERSION_NAME}")
        appendLine("Android: $androidVersion (SDK $sdkInt)")
        appendLine("Устройство: $manufacturer / $brand / $model")
        appendLine("Код устройства: $device")
        appendLine("Продукт: $product")
        appendLine("ABI: $primaryAbi")
        appendLine("Все ABI: $supportedAbis")
        appendLine("SoC: $soc")
        appendLine("Hardware: $hardware")
        appendLine("Board: $board")
        appendLine("ROM: $romDisplay")
        appendLine("Build ID: $buildId")
        appendLine("Build type: $buildType")
        appendLine("Fingerprint: $buildFingerprint")
    }.trim()
}

/**
 * Joins the support report with the journal for the clipboard.
 *
 * A non-empty journal is separated from the report by exactly one blank line and has no
 * trailing newline. An empty journal yields the report alone, also without a trailing
 * newline — the support report is already trimmed.
 */
internal fun buildReportCopyText(report: String, logLines: List<String>): String =
    if (logLines.isEmpty()) report else report + "\n\n" + logLines.joinToString("\n")
