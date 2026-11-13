package com.momoagent.android.ui

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.momoagent.android.R

/**
 * Android approximation of iOS 26 Liquid Glass: translucent gradient, top
 * specular highlight, bright inner rim, soft ambient shadow and a spring press.
 * True backdrop diffusion is not available to a Compose surface; the app
 * backdrop and the chat page are translucent so the glass still has context.
 */
@Composable
fun GlassSurface(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(24.dp),
    tint: Color? = null,
    onClick: (() -> Unit)? = null,
    contentPadding: PaddingValues = PaddingValues(0.dp),
    content: @Composable BoxScope.() -> Unit,
) {
    val palette = LocalMoMoPalette.current
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val scale by animateFloatAsState(
        targetValue = if (pressed && onClick != null) 0.965f else 1f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = 700f),
        label = "glass-scale",
    )
    val glow by animateFloatAsState(
        targetValue = if (pressed && onClick != null) 1f else 0f,
        animationSpec = tween(durationMillis = 220),
        label = "glass-glow",
    )
    val glass = modifier
        .graphicsLayer {
            scaleX = scale
            scaleY = scale
        }
        .shadow(
            elevation = 18.dp,
            shape = shape,
            clip = false,
            ambientColor = Color.Black.copy(alpha = 0.08f),
            spotColor = Color.Black.copy(alpha = 0.10f),
        )
        .clip(shape)
        .drawBehind {
            val fill = if (dark) {
                listOf(Color.White.copy(alpha = 0.17f), Color.White.copy(alpha = 0.055f))
            } else {
                listOf(Color.White.copy(alpha = 0.74f), Color.White.copy(alpha = 0.34f))
            }
            drawRect(Brush.linearGradient(fill, Offset.Zero, Offset(size.width, size.height)))
            drawRect(
                Brush.verticalGradient(
                    listOf(
                        Color.White.copy(alpha = (if (dark) 0.16f else 0.46f) + 0.22f * glow),
                        Color.Transparent,
                    ),
                    0f,
                    size.height * 0.62f,
                ),
            )
            val bloom = Offset(size.width * 0.25f, -size.height * 0.22f)
            val radius = size.width * 0.95f
            drawCircle(
                Brush.radialGradient(
                    listOf(Color.White.copy(alpha = 0.28f + 0.30f * glow), Color.Transparent),
                    center = bloom,
                    radius = radius,
                ),
                radius = radius,
                center = bloom,
            )
            tint?.let { drawRect(it.copy(alpha = 0.18f)) }
        }
        .border(
            width = 1.dp,
            brush = Brush.linearGradient(
                listOf(Color.White.copy(alpha = 0.92f), palette.line.copy(alpha = 0.48f)),
            ),
            shape = shape,
        )
    val click = if (onClick != null) {
        Modifier.clickable(interactionSource = interaction, indication = null, onClick = onClick)
    } else {
        Modifier
    }
    Box(modifier = glass.then(click), contentAlignment = Alignment.Center) {
        Box(
            modifier = Modifier.padding(contentPadding),
            contentAlignment = Alignment.Center,
            content = content,
        )
    }
}

@Composable
fun GlassIconButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: (() -> Unit)?,
    modifier: Modifier = Modifier,
    size: Dp = 44.dp,
    tint: Color? = null,
) {
    val palette = LocalMoMoPalette.current
    val iconTint = tint ?: palette.ink
    GlassSurface(
        modifier = modifier.size(size),
        shape = CircleShape,
        onClick = onClick,
        content = {
            Icon(icon, contentDescription = label, tint = iconTint, modifier = Modifier.size(20.dp))
        },
    )
}

@Composable
fun GlassTasksButton(
    count: Int,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = LocalMoMoPalette.current
    if (count > 0) {
        GlassSurface(
            modifier = modifier.height(44.dp),
            shape = RoundedCornerShape(50),
            onClick = onClick,
            contentPadding = PaddingValues(horizontal = 12.dp),
            content = {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Icon(Icons.Filled.Checklist, contentDescription = stringResource(R.string.chat_tasks), tint = palette.ink, modifier = Modifier.size(19.dp))
                    Box(
                        modifier = Modifier
                            .size(18.dp)
                            .background(palette.ink, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = if (count > 9) "9+" else count.toString(),
                            color = palette.canvas,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            },
        )
    } else {
        GlassIconButton(Icons.Filled.Checklist, stringResource(R.string.chat_tasks), onClick, modifier)
    }
}

@Composable
fun GlassTabBar(
    items: List<Pair<androidx.compose.ui.graphics.vector.ImageVector, String>>,
    selected: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = LocalMoMoPalette.current
    GlassSurface(
        modifier = modifier
            .fillMaxWidth()
            .height(64.dp),
        shape = RoundedCornerShape(50),
        contentPadding = PaddingValues(6.dp),
    ) {
        Row(modifier = Modifier.fillMaxSize()) {
            items.forEachIndexed { index, (icon, label) ->
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .clip(RoundedCornerShape(50))
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                        ) { onSelect(index) },
                    contentAlignment = Alignment.Center,
                ) {
                    if (index == selected) {
                        val highlight = if (androidx.compose.foundation.isSystemInDarkTheme()) {
                            Color.White.copy(alpha = 0.16f)
                        } else {
                            Color.White.copy(alpha = 0.72f)
                        }
                        Box(
                            modifier = Modifier
                                .matchParentSize()
                                .clip(RoundedCornerShape(50))
                                .background(
                                    Brush.verticalGradient(
                                        listOf(highlight, palette.surface.copy(alpha = 0.48f)),
                                    ),
                                )
                                .border(1.dp, Color.White.copy(alpha = 0.55f), RoundedCornerShape(50)),
                        )
                    }
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(
                            icon,
                            contentDescription = label,
                            tint = if (index == selected) palette.ink else palette.muted,
                            modifier = Modifier.size(20.dp),
                        )
                        Text(
                            text = label,
                            style = MoMoType.caption,
                            color = if (index == selected) palette.ink else palette.muted,
                            fontSize = 11.sp,
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun GlassDialog(
    onDismiss: () -> Unit,
    title: String,
    confirmLabel: String = stringResource(R.string.chat_notice_ok),
    dismissLabel: String? = null,
    confirmEnabled: Boolean = true,
    onConfirm: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val palette = LocalMoMoPalette.current
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.16f))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onDismiss,
                )
                .padding(24.dp),
            contentAlignment = Alignment.Center,
        ) {
            GlassSurface(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(28.dp))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) {},
                shape = RoundedCornerShape(28.dp),
                contentPadding = PaddingValues(22.dp),
            ) {
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                ) {
                    Text(title, style = MoMoType.title, color = palette.ink)
                    content()
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        if (dismissLabel != null) {
                            TextButton(onClick = onDismiss) {
                                Text(dismissLabel, color = palette.muted)
                            }
                        }
                        Spacer(modifier = Modifier.weight(1f))
                        TextButton(
                            onClick = onConfirm ?: onDismiss,
                            enabled = confirmEnabled,
                        ) {
                            Text(
                                confirmLabel,
                                color = if (confirmEnabled) palette.ink else palette.muted,
                            )
                        }
                    }
                }
            }
        }
    }
}
