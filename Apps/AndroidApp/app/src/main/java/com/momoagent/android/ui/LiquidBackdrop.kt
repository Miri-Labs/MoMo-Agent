package com.momoagent.android.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

/**
 * Very low-contrast ambient field behind the translucent glass. The iPhone
 * reference uses a clean white canvas; these glows stay close to neutral so the
 * glass stays bright and text contrast is preserved.
 */
@Composable
fun LiquidBackdrop(modifier: Modifier = Modifier) {
    val palette = LocalMoMoPalette.current
    val dark = isSystemInDarkTheme()
    Canvas(modifier = modifier.fillMaxSize()) {
        drawRect(palette.canvas)
        val unit = size.minDimension
        fun glow(color: Color, fx: Float, fy: Float, radiusFactor: Float, alpha: Float) {
            val center = Offset(size.width * fx, size.height * fy)
            val radius = unit * radiusFactor
            drawCircle(
                Brush.radialGradient(
                    colors = listOf(color.copy(alpha = alpha), Color.Transparent),
                    center = center,
                    radius = radius,
                ),
                radius = radius,
                center = center,
            )
        }
        if (dark) {
            glow(Color(0xFF2A3340), 0.12f, 0.08f, 0.9f, 0.30f)
            glow(Color(0xFF3B2A3F), 0.92f, 0.25f, 0.8f, 0.24f)
            glow(Color(0xFF203A35), 0.10f, 0.92f, 0.9f, 0.20f)
            glow(Color(0xFF2B2B3F), 0.90f, 0.92f, 0.8f, 0.20f)
        } else {
            glow(Color(0xFFF0E3D4), 0.12f, 0.08f, 0.9f, 0.30f)
            glow(Color(0xFFDDE9F5), 0.92f, 0.22f, 0.8f, 0.28f)
            glow(Color(0xFFE5EDDD), 0.10f, 0.92f, 0.9f, 0.24f)
            glow(Color(0xFFECE4F4), 0.90f, 0.92f, 0.8f, 0.24f)
        }
    }
}
