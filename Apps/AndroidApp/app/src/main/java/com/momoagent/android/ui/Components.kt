package com.momoagent.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.momoagent.android.R

@Composable
fun CircleAction(
    icon: ImageVector,
    label: String,
    onClick: () -> Unit,
    badge: Int? = null,
) {
    val palette = LocalMoMoPalette.current
    Box(modifier = Modifier.size(44.dp)) {
        GlassIconButton(icon, label, onClick)
        if (badge != null && badge > 0) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .size(17.dp)
                    .clip(CircleShape)
                    .background(palette.ink),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = if (badge > 9) "9+" else badge.toString(),
                    color = palette.canvas,
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                )
            }
        }
    }
}

@Composable
fun ClientPrimaryButton(
    title: String,
    onClick: () -> Unit,
    enabled: Boolean = true,
    loading: Boolean = false,
) {
    val palette = LocalMoMoPalette.current
    Button(
        onClick = onClick,
        enabled = enabled && !loading,
        shape = CircleShape,
        colors = ButtonDefaults.buttonColors(
            containerColor = palette.ink,
            contentColor = palette.canvas,
            disabledContainerColor = palette.surface,
            disabledContentColor = palette.muted,
        ),
        modifier = Modifier
            .fillMaxWidth()
            .height(52.dp),
    ) {
        if (loading) {
            CircularProgressIndicator(
                modifier = Modifier.size(18.dp),
                strokeWidth = 2.dp,
                color = palette.canvas,
            )
        } else {
            Text(title, style = MoMoType.body, fontWeight = FontWeight.Medium)
        }
    }
}

@Composable
fun PageHeader(
    title: String,
    onBack: (() -> Unit)? = null,
    onRefresh: (() -> Unit)? = null,
    onSettings: (() -> Unit)? = null,
) {
    val palette = LocalMoMoPalette.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        if (onBack != null) {
            GlassIconButton(
                icon = Icons.Filled.ArrowBack,
                label = stringResource(R.string.transcripts_back),
                onClick = onBack,
                modifier = Modifier.align(Alignment.CenterStart),
            )
        }
        Text(
            text = title,
            style = MoMoType.subheading,
            color = palette.ink,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .align(Alignment.Center)
                .padding(horizontal = 56.dp),
        )
        Row(
            modifier = Modifier.align(Alignment.CenterEnd),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (onRefresh != null) {
                GlassIconButton(
                    icon = Icons.Filled.Refresh,
                    label = stringResource(R.string.memory_refresh),
                    onClick = onRefresh,
                )
            }
            if (onSettings != null) {
                GlassIconButton(
                    icon = Icons.Filled.Settings,
                    label = stringResource(R.string.chat_settings),
                    onClick = onSettings,
                )
            }
        }
    }
}

@Composable
fun EmptyPanel(
    title: String,
    body: String,
    action: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val palette = LocalMoMoPalette.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(title, style = MoMoType.title, color = palette.ink, textAlign = TextAlign.Center)
        Spacer(Modifier.height(10.dp))
        Text(body, style = MoMoType.body, color = palette.muted, textAlign = TextAlign.Center)
        if (action != null && onAction != null) {
            Spacer(Modifier.height(24.dp))
            ClientPrimaryButton(action, onAction)
        }
    }
}
