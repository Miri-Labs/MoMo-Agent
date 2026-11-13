package com.momoagent.android.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

data class MoMoPalette(
    val canvas: Color,
    val surface: Color,
    val paper: Color,
    val ink: Color,
    val muted: Color,
    val line: Color,
    val failure: Color,
    val success: Color,
)

private val LightPalette = MoMoPalette(
    canvas = Color(0xFFFAFAFA),
    surface = Color(0xFFF1F1F1),
    paper = Color(0xFFFFFFFF),
    ink = Color(0xFF252525),
    muted = Color(0xFF686868),
    line = Color(0xFFE1E1E1),
    failure = Color(0xFFA43434),
    success = Color(0xFF35664D),
)

private val DarkPalette = MoMoPalette(
    canvas = Color(0xFF161616),
    surface = Color(0xFF292929),
    paper = Color(0xFF202020),
    ink = Color(0xFFF2F2F2),
    muted = Color(0xFFAAAAAA),
    line = Color(0xFF454545),
    failure = Color(0xFFE38E8E),
    success = Color(0xFF7FB08A),
)

val LocalMoMoPalette = staticCompositionLocalOf { LightPalette }

object MoMoType {
    val body = TextStyle(fontSize = 16.sp, lineHeight = 23.sp)
    val title = TextStyle(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.SemiBold)
    val subheading = TextStyle(fontSize = 17.sp, lineHeight = 22.sp)
    val section = TextStyle(fontSize = 14.sp, lineHeight = 19.sp, fontWeight = FontWeight.Medium)
    val navigation = TextStyle(fontSize = 16.sp, lineHeight = 20.sp)
    val menu = TextStyle(fontSize = 15.sp, lineHeight = 20.sp)
    val history = TextStyle(fontSize = 14.sp, lineHeight = 18.sp)
    val metadata = TextStyle(fontSize = 13.sp, lineHeight = 17.sp)
    val caption = TextStyle(fontSize = 12.sp, lineHeight = 16.sp)
    val code = TextStyle(fontSize = 14.sp, lineHeight = 18.sp, fontFamily = FontFamily.Monospace)
}

private fun scheme(palette: MoMoPalette, dark: Boolean) = if (dark) {
    darkColorScheme(
        primary = palette.ink,
        onPrimary = palette.canvas,
        secondaryContainer = palette.ink,
        onSecondaryContainer = palette.canvas,
        surfaceContainerLow = palette.paper,
        surfaceContainerHigh = palette.paper,
        background = palette.canvas,
        onBackground = palette.ink,
        surface = palette.paper,
        onSurface = palette.ink,
        surfaceVariant = palette.surface,
        onSurfaceVariant = palette.muted,
        outline = palette.line,
        outlineVariant = palette.line,
        error = palette.failure,
        onError = palette.canvas,
    )
} else {
    lightColorScheme(
        primary = palette.ink,
        onPrimary = palette.canvas,
        secondaryContainer = palette.ink,
        onSecondaryContainer = palette.canvas,
        surfaceContainerLow = palette.paper,
        surfaceContainerHigh = palette.paper,
        background = palette.canvas,
        onBackground = palette.ink,
        surface = palette.paper,
        onSurface = palette.ink,
        surfaceVariant = palette.surface,
        onSurfaceVariant = palette.muted,
        outline = palette.line,
        outlineVariant = palette.line,
        error = palette.failure,
        onError = palette.canvas,
    )
}

@Composable
fun MoMoTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val palette = if (dark) DarkPalette else LightPalette
    MaterialTheme(
        colorScheme = scheme(palette, dark),
        typography = Typography(
            bodyLarge = MoMoType.body,
            bodyMedium = MoMoType.menu,
            titleLarge = MoMoType.title,
            titleMedium = MoMoType.subheading,
            labelLarge = MoMoType.section,
            labelSmall = MoMoType.caption,
        ),
    ) {
        CompositionLocalProvider(LocalMoMoPalette provides palette, content = content)
    }
}
