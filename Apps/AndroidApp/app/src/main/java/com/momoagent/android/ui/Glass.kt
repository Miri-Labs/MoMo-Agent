package com.momoagent.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.momoagent.android.R

@Composable
fun GlassSurface(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(24.dp),
    onClick: (() -> Unit)? = null,
    contentPadding: PaddingValues = PaddingValues(0.dp),
    content: @Composable BoxScope.() -> Unit,
) {
    val palette = LocalMoMoPalette.current
    val surface = modifier
        .clip(shape)
        .background(palette.paper.copy(alpha = 0.97f))
        .border(1.dp, palette.line, shape)
    val action = if (onClick == null) Modifier else Modifier.clickable(role = Role.Button, onClick = onClick)
    Box(
        modifier = surface.then(action).padding(contentPadding),
        contentAlignment = Alignment.Center,
        content = content,
    )
}

@Composable
fun GlassIconButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: (() -> Unit)?,
    modifier: Modifier = Modifier,
    size: Dp = 48.dp,
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
            modifier = modifier.height(48.dp),
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
    GlassSurface(modifier = modifier, shape = CircleShape, contentPadding = PaddingValues(5.dp)) {
        Row(Modifier.fillMaxWidth().selectableGroup(), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            items.forEachIndexed { index, (icon, label) ->
                val active = selected == index
                val color = if (active) palette.canvas else palette.muted
                Column(
                    modifier = Modifier.weight(1f).height(48.dp).clip(CircleShape)
                        .background(if (active) palette.ink else Color.Transparent)
                        .selectable(active, role = Role.Tab, onClick = { onSelect(index) }),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(19.dp))
                    Text(label, style = MoMoType.caption, color = color, maxLines = 1)
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
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = palette.paper,
        titleContentColor = palette.ink,
        textContentColor = palette.ink,
        shape = RoundedCornerShape(24.dp),
        title = { Text(title, style = MoMoType.title) },
        text = content,
        dismissButton = dismissLabel?.let { label ->
            { TextButton(onClick = onDismiss) { Text(label, color = palette.muted) } }
        },
        confirmButton = {
            TextButton(onClick = onConfirm ?: onDismiss, enabled = confirmEnabled) { Text(confirmLabel) }
        },
    )
}
