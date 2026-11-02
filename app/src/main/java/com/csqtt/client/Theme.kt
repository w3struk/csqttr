package com.csqtt.client

import android.os.Build
import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import com.csqtt.client.CsqttConstants
import com.csqtt.client.ui.design.CsqttDarkExtendedColors
import com.csqtt.client.ui.design.CsqttLightExtendedColors
import com.csqtt.client.ui.design.CsqttMaterialShapes
import com.csqtt.client.ui.design.LocalCsqttExtendedColors

val CSQTTTypography = Typography(
    displayLarge = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.Bold, fontSize = 57.sp, lineHeight = 64.sp),
    displayMedium = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.Bold, fontSize = 45.sp, lineHeight = 52.sp),
    displaySmall = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.Bold, fontSize = 36.sp, lineHeight = 44.sp),
    headlineLarge = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.SemiBold, fontSize = 32.sp, lineHeight = 40.sp),
    headlineMedium = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.SemiBold, fontSize = 28.sp, lineHeight = 36.sp),
    headlineSmall = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.SemiBold, fontSize = 24.sp, lineHeight = 32.sp),
    titleLarge = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.SemiBold, fontSize = 22.sp, lineHeight = 28.sp),
    titleMedium = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, lineHeight = 24.sp, letterSpacing = 0.15.sp),
    titleSmall = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 20.sp, letterSpacing = 0.1.sp),
    bodyLarge = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.Normal, fontSize = 16.sp, lineHeight = 24.sp, letterSpacing = 0.5.sp),
    bodyMedium = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 20.sp, letterSpacing = 0.25.sp),
    bodySmall = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.Normal, fontSize = 12.sp, lineHeight = 16.sp, letterSpacing = 0.4.sp),
    labelLarge = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.Medium, fontSize = 14.sp, lineHeight = 20.sp, letterSpacing = 0.1.sp),
    labelMedium = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.Medium, fontSize = 12.sp, lineHeight = 16.sp, letterSpacing = 0.5.sp),
    labelSmall = TextStyle(fontFamily = FontFamily.Default, fontWeight = FontWeight.Medium, fontSize = 11.sp, lineHeight = 16.sp, letterSpacing = 0.5.sp),
)

private val BrandLightColorScheme = lightColorScheme(
    primary = Color(0xFF1A73E8),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFFE8F0FE),
    onPrimaryContainer = Color(0xFF111215),
    secondary = Color(0xFF1A73E8),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFE8F0FE),
    onSecondaryContainer = Color(0xFF111215),
    tertiary = Color(0xFFD27D00),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFFFE4B7),
    onTertiaryContainer = Color(0xFF241400),
    background = Color(0xFFFDFDFE),
    onBackground = Color(0xFF111215),
    surface = Color(0xFFFFFFFF),
    onSurface = Color(0xFF111215),
    surfaceVariant = Color(0xFFF2F2F4),
    onSurfaceVariant = Color(0xFF5F6067),
    outline = Color(0xFF898B92),
    outlineVariant = Color(0xFFD7D8DD),
    surfaceTint = Color.Transparent,
)

private val BrandDarkColorScheme = darkColorScheme(
    primary = Color(0xFF1565D8),
    onPrimary = Color(0xFFFFFFFF),
    primaryContainer = Color(0xFF173B72),
    onPrimaryContainer = Color(0xFFFFFFFF),
    secondary = Color(0xFF1565D8),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFF173B72),
    onSecondaryContainer = Color(0xFFFFFFFF),
    tertiary = Color(0xFFFFB74D),
    onTertiary = Color(0xFF271500),
    tertiaryContainer = Color(0xFF5A3900),
    onTertiaryContainer = Color(0xFFFFE5BD),
    background = Color(0xFF09090A),
    onBackground = Color(0xFFFAFAFA),
    surface = Color(0xFF121214),
    onSurface = Color(0xFFFAFAFA),
    surfaceVariant = Color(0xFF202024),
    onSurfaceVariant = Color(0xFFC9C9CF),
    outline = Color(0xFF8C8C94),
    outlineVariant = Color(0xFF35353A),
    surfaceTint = Color.Transparent,
)

private fun getAppColorScheme(isDark: Boolean): androidx.compose.material3.ColorScheme =
    if (isDark) BrandDarkColorScheme else BrandLightColorScheme

object CSQTTColors {
    val warning = Color(0xFFFFA726)
}

@Composable
fun CSQTTTheme(
    themeMode: String = "system",
    content: @Composable () -> Unit
) {
    val darkTheme = when (themeMode) {
        CsqttConstants.Theme.MODE_DARK -> true
        CsqttConstants.Theme.MODE_LIGHT -> false
        else -> isSystemInDarkTheme()
    }

    val colorScheme = remember(darkTheme) {
        getAppColorScheme(darkTheme)
    }

    val view = LocalView.current
    if (!view.isInEditMode) {
        @Suppress("DEPRECATION")
        SideEffect {
            val window = (view.context as Activity).window
            val navigationBarColor = if (darkTheme) {
                Color.Transparent
            } else {
                lerp(colorScheme.background, colorScheme.surface, 0.55f)
            }
            window.statusBarColor = Color.Transparent.toArgb()
            window.navigationBarColor = navigationBarColor.toArgb()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                window.isNavigationBarContrastEnforced = false
                window.isStatusBarContrastEnforced = false
            }
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !darkTheme
                isAppearanceLightNavigationBars = !darkTheme
            }
        }
    }

    val currentDensity = LocalDensity.current
    val fixedDensity = remember(currentDensity.density) {
        Density(density = currentDensity.density, fontScale = 1f)
    }

    CompositionLocalProvider(
        LocalCsqttExtendedColors provides if (darkTheme) CsqttDarkExtendedColors else CsqttLightExtendedColors,
        LocalDensity provides fixedDensity,
    ) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = CSQTTTypography,
            shapes = CsqttMaterialShapes,
            content = content,
        )
    }
}
