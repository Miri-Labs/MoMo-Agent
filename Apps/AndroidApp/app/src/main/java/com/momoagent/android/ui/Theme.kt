package com.momoagent.android.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val MoMoInk = Color(0xFF252525)
val MoMoMuted = Color(0xFF686868)
val MoMoLine = Color(0xFFE1E1E1)
val MoMoPaper = Color(0xFFFFFFFF)
val MoMoSurface = Color(0xFFF1F1F1)
val MoMoCanvas = Color(0xFFFAFAFA)
val MoMoSuccess = Color(0xFF35664D)
val MoMoFailure = Color(0xFFA23C32)

private val MoMoColors = lightColorScheme(
    primary = MoMoInk,
    onPrimary = Color.White,
    primaryContainer = MoMoSurface,
    onPrimaryContainer = MoMoInk,
    background = MoMoCanvas,
    onBackground = MoMoInk,
    surface = MoMoPaper,
    onSurface = MoMoInk,
    surfaceVariant = MoMoSurface,
    onSurfaceVariant = MoMoMuted,
    outline = MoMoLine,
    outlineVariant = MoMoLine,
    error = MoMoFailure,
    onError = Color.White,
)

@Composable
fun MoMoTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = MoMoColors,
        typography = Typography(),
        content = content,
    )
}
