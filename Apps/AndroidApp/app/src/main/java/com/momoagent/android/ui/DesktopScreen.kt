package com.momoagent.android.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.DesktopMac
import androidx.compose.material.icons.outlined.Mouse
import androidx.compose.material.icons.outlined.SwapVert
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.AssistChip
import androidx.compose.material3.FilterChip
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.momoagent.android.R
import com.momoagent.android.data.DesktopInputEvent
import com.momoagent.android.data.DesktopStatus
import com.momoagent.android.remote.ConversationStore
import com.momoagent.android.remote.DesktopFailure
import com.momoagent.android.remote.DesktopState
import kotlin.math.min

@Composable
fun DesktopScreen(store: ConversationStore, onClose: () -> Unit) {
    val session = remember(store) { store.newDesktopSession() }
    val state by session.state.collectAsStateWithLifecycle()
    var scrollMode by rememberSaveable(state.controlling) { mutableStateOf(false) }
    var lastPoint by remember { mutableStateOf(Offset(0.5f, 0.5f)) }

    DisposableEffect(session) {
        session.open()
        onDispose { session.close() }
    }

    Dialog(
        onDismissRequest = onClose,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        val palette = LocalMoMoPalette.current
        Column(Modifier.fillMaxSize().background(palette.canvas).safeDrawingPadding()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stringResource(R.string.chat_desktop), style = MoMoType.title, color = palette.ink,
                    modifier = Modifier.weight(1f))
                GlassIconButton(Icons.Filled.Close, stringResource(R.string.desktop_close), onClose)
            }
            val status = state.status
            val failure = state.failure
            val issue = when {
                failure != null -> failureText(failure)
                status != null && !state.permitted -> permissionText(status)
                else -> null
            }
            val picture = state.picture
            if (picture == null || status?.approved == false || status?.screen == false || failure == DesktopFailure.Revoked) {
                DesktopPlaceholder(issue, onRetry = session::retry,
                    onRelease = if (state.controlling && !state.claiming) session::release else null)
            } else {
                BoxWithConstraints(Modifier.fillMaxSize().padding(12.dp)) {
                    val wide = maxWidth >= 560.dp && maxWidth > maxHeight
                    val preview: @Composable (Modifier) -> Unit = { modifier ->
                        DesktopViewer(
                            picture = picture, controlling = state.controlling && state.permitted && issue == null,
                            scrollMode = scrollMode, onPoint = { lastPoint = it }, onInput = session::send,
                            modifier = modifier.aspectRatio(picture.width.toFloat() / picture.height)
                                .clip(RoundedCornerShape(8.dp)),
                        )
                    }
                    val tools: @Composable () -> Unit = {
                        DesktopControls(
                            state = state, issue = issue, onRetry = session::retry,
                            scrollMode = scrollMode, onToggleScroll = { scrollMode = !scrollMode },
                            onRightClick = {
                                session.send(DesktopInputEvent(kind = "right_click", x = lastPoint.x.toDouble(), y = lastPoint.y.toDouble()))
                            },
                            onControl = { if (state.controlling) session.release() else session.claim() },
                        )
                    }
                    if (wide) {
                        Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                            Box(Modifier.weight(1f), contentAlignment = Alignment.Center) { preview(Modifier) }
                            Column(Modifier.width(160.dp).verticalScroll(rememberScrollState())) { tools() }
                        }
                    } else {
                        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center,
                            horizontalAlignment = Alignment.CenterHorizontally) {
                            preview(Modifier.weight(1f, fill = false))
                            Spacer(Modifier.height(18.dp))
                            tools()
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DesktopPlaceholder(issue: String?, onRetry: () -> Unit, onRelease: (() -> Unit)?) {
    val palette = LocalMoMoPalette.current
    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Outlined.DesktopMac, null, tint = palette.muted, modifier = Modifier.size(48.dp))
        Spacer(Modifier.height(18.dp))
        Text(issue ?: stringResource(R.string.desktop_connecting), style = MoMoType.body, color = palette.ink,
            textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 340.dp))
        Spacer(Modifier.height(14.dp))
        if (issue == null) CircularProgressIndicator(Modifier.size(20.dp), color = palette.muted, strokeWidth = 2.dp)
        else Button(onClick = onRetry) { Text(stringResource(R.string.desktop_retry)) }
        if (onRelease != null) TextButton(onClick = onRelease) { Text(stringResource(R.string.desktop_release_control)) }
    }
}

@Composable
private fun DesktopControls(
    state: DesktopState, issue: String?, onRetry: () -> Unit,
    scrollMode: Boolean, onToggleScroll: () -> Unit,
    onRightClick: () -> Unit, onControl: () -> Unit,
) {
    val palette = LocalMoMoPalette.current
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(issue ?: stringResource(when {
            state.otherDevice -> R.string.desktop_owner_other
            state.controlling -> R.string.desktop_controlling
            else -> R.string.desktop_view_only
        }), style = MoMoType.metadata, color = palette.muted, textAlign = TextAlign.Center)
        if (issue != null) {
            TextButton(onClick = onRetry) { Text(stringResource(R.string.desktop_retry)) }
        }
        if (state.controlling && issue == null) {
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally)) {
                FilterChip(
                    selected = scrollMode, onClick = onToggleScroll,
                    label = { Text(stringResource(R.string.desktop_scroll_mode)) },
                    leadingIcon = { Icon(Icons.Outlined.SwapVert, null, modifier = Modifier.size(18.dp)) },
                )
                AssistChip(
                    onClick = onRightClick,
                    label = { Text(stringResource(R.string.desktop_right_click)) },
                    leadingIcon = { Icon(Icons.Outlined.Mouse, null, modifier = Modifier.size(18.dp)) },
                )
            }
            Text(stringResource(if (scrollMode) R.string.desktop_scroll_hint else R.string.desktop_hint),
                style = MoMoType.caption, color = palette.muted, textAlign = TextAlign.Center)
        }
        Button(onClick = onControl, enabled = !state.claiming && (state.controlling || (!state.otherDevice && state.permitted && issue == null))) {
            Text(stringResource(when {
                state.claiming -> R.string.desktop_claiming
                state.controlling -> R.string.desktop_release_control
                else -> R.string.desktop_take_control
            }))
        }
    }
}

@Composable
private fun DesktopViewer(
    picture: Bitmap,
    controlling: Boolean,
    scrollMode: Boolean,
    onPoint: (Offset) -> Unit,
    onInput: (DesktopInputEvent) -> Unit,
    modifier: Modifier = Modifier,
) {
    var container by remember { mutableStateOf(IntSize.Zero) }
    var lastTapAt by remember { mutableStateOf(0L) }
    var lastTapPoint by remember { mutableStateOf(Offset.Zero) }
    val tapSlop = with(LocalDensity.current) { 36.dp.toPx() }
    val imageRect = remember(picture.width, picture.height, container) {
        fittedRect(picture.width, picture.height, container)
    }

    Box(modifier = modifier.onSizeChanged { container = it }) {
        Image(
            bitmap = picture.asImageBitmap(),
            contentDescription = stringResource(R.string.chat_desktop),
            contentScale = ContentScale.Fit,
            modifier = Modifier.fillMaxSize(),
        )
        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(controlling, scrollMode, imageRect) {
                    if (!controlling) return@pointerInput
                    awaitEachGesture {
                        val down = awaitFirstDown(requireUnconsumed = false)
                        if (!imageRect.contains(down.position)) return@awaitEachGesture
                        val start = down.position
                        var last = start
                        var moved = Offset.Zero
                        var dragging = false
                        while (true) {
                            val event = awaitPointerEvent()
                            if (event.changes.size > 1) {
                                if (dragging && !scrollMode) normalize(last, imageRect)?.let {
                                    onInput(DesktopInputEvent(kind = "mouse_up", x = it.x.toDouble(), y = it.y.toDouble()))
                                }
                                return@awaitEachGesture
                            }
                            val change = event.changes.firstOrNull { it.id == down.id } ?: break
                            if (!change.pressed) {
                                if (dragging) {
                                    if (!scrollMode) normalize(last, imageRect)?.let {
                                        onInput(DesktopInputEvent(kind = "mouse_up", x = it.x.toDouble(), y = it.y.toDouble()))
                                    }
                                } else {
                                    val now = System.currentTimeMillis()
                                    val isDouble = now - lastTapAt < 320 &&
                                        (start - lastTapPoint).getDistance() < tapSlop
                                    normalize(start, imageRect)?.let {
                                        onInput(
                                            DesktopInputEvent(
                                                kind = if (isDouble) "double_click" else "click",
                                                x = it.x.toDouble(),
                                                y = it.y.toDouble(),
                                                clickCount = if (isDouble) 2 else 1,
                                            ),
                                        )
                                        onPoint(it)
                                    }
                                    lastTapAt = now
                                    lastTapPoint = start
                                }
                                break
                            }
                            val delta = change.position - last
                            last = change.position
                            moved += delta
                            if (!dragging && moved.getDistance() > viewConfiguration.touchSlop) {
                                dragging = true
                                if (!scrollMode) {
                                    normalize(start, imageRect)?.let {
                                        onInput(DesktopInputEvent(kind = "mouse_down", x = it.x.toDouble(), y = it.y.toDouble()))
                                    }
                                }
                            }
                            if (dragging) {
                                change.consume()
                                val point = normalize(last, imageRect) ?: continue
                                onPoint(point)
                                if (scrollMode) {
                                    val scale = picture.width / imageRect.width
                                    val dx = (delta.x * scale).toInt()
                                    val dy = (delta.y * scale).toInt()
                                    if (dx != 0 || dy != 0) {
                                        onInput(
                                            DesktopInputEvent(
                                                kind = "scroll",
                                                x = point.x.toDouble(),
                                                y = point.y.toDouble(),
                                                delta = dy,
                                                deltaX = dx,
                                            ),
                                        )
                                    }
                                } else {
                                    onInput(DesktopInputEvent(kind = "mouse_move", x = point.x.toDouble(), y = point.y.toDouble()))
                                }
                            }
                        }
                    }
                },
        )
    }
}

private fun fittedRect(width: Int, height: Int, container: IntSize): Rect {
    if (width <= 0 || height <= 0 || container.width <= 0 || container.height <= 0) return Rect.Zero
    val scale = min(container.width.toFloat() / width, container.height.toFloat() / height)
    val left = (container.width - width * scale) / 2f
    val top = (container.height - height * scale) / 2f
    return Rect(left, top, left + width * scale, top + height * scale)
}

private fun normalize(point: Offset, rect: Rect): Offset? {
    if (rect == Rect.Zero || !rect.contains(point)) return null
    return Offset(
        ((point.x - rect.left) / rect.width).coerceIn(0f, 1f),
        ((point.y - rect.top) / rect.height).coerceIn(0f, 1f),
    )
}

@Composable
private fun permissionText(status: DesktopStatus): String = when {
    !status.approved -> stringResource(R.string.desktop_update_mac)
    !status.screen && !status.input -> stringResource(R.string.desktop_permissions)
    !status.screen -> stringResource(R.string.desktop_screen_permission)
    !status.input -> stringResource(R.string.desktop_input_permission)
    else -> stringResource(R.string.desktop_view_only)
}

@Composable
private fun failureText(failure: DesktopFailure): String = when (failure) {
    DesktopFailure.Revoked -> stringResource(R.string.desktop_pairing_lost)
    DesktopFailure.Permissions -> stringResource(R.string.desktop_permissions)
    DesktopFailure.Busy -> stringResource(R.string.desktop_busy)
    DesktopFailure.Ownership -> stringResource(R.string.desktop_ownership)
    DesktopFailure.Unavailable -> stringResource(R.string.desktop_unavailable)
    DesktopFailure.Network -> stringResource(R.string.desktop_network)
}
