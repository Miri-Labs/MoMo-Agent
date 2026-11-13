package com.momoagent.android.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
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

private val DesktopBackground = Color(0xFF0D0D0D)
private val DesktopMuted = Color(0xFFB8B8B8)

@Composable
fun DesktopScreen(store: ConversationStore, onClose: () -> Unit) {
    val session = remember(store) { store.newDesktopSession() }
    val state by session.state.collectAsStateWithLifecycle()
    var scrollMode by rememberSaveable { mutableStateOf(false) }
    var lastPoint by remember { mutableStateOf(Offset(0.5f, 0.5f)) }

    DisposableEffect(session) {
        session.open()
        onDispose { session.close() }
    }

    Dialog(
        onDismissRequest = onClose,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Surface(modifier = Modifier.fillMaxSize(), color = DesktopBackground) {
            Column(modifier = Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
                DesktopTopBar(
                    state = state,
                    scrollMode = scrollMode,
                    onToggleScroll = { scrollMode = !scrollMode },
                    onRightClick = {
                        session.send(
                            DesktopInputEvent(kind = "right_click", x = lastPoint.x.toDouble(), y = lastPoint.y.toDouble()),
                        )
                    },
                    onControl = { if (state.controlling) session.release() else session.claim() },
                    onClose = onClose,
                )
                DesktopViewer(
                    state = state,
                    scrollMode = scrollMode,
                    onPoint = { lastPoint = it },
                    onInput = session::send,
                    onRetry = session::retry,
                    modifier = Modifier.fillMaxWidth().weight(1f),
                )
                Text(
                    text = stringResource(R.string.desktop_hint),
                    color = DesktopMuted,
                    modifier = Modifier.padding(horizontal = 20.dp, vertical = 14.dp),
                )
            }
        }
    }
}

@Composable
private fun DesktopTopBar(
    state: DesktopState,
    scrollMode: Boolean,
    onToggleScroll: () -> Unit,
    onRightClick: () -> Unit,
    onControl: () -> Unit,
    onClose: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        IconButton(onClick = onClose) {
            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.desktop_close), tint = Color.White)
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(stringResource(R.string.chat_desktop), color = Color.White, fontWeight = FontWeight.Medium)
            Text(desktopStatusText(state), color = DesktopMuted)
        }
        TextButton(onClick = onToggleScroll, enabled = state.controlling) {
            Text(
                text = stringResource(R.string.desktop_scroll_mode),
                color = if (scrollMode) Color.White else DesktopMuted,
                fontWeight = if (scrollMode) FontWeight.SemiBold else FontWeight.Normal,
            )
        }
        TextButton(onClick = onRightClick, enabled = state.controlling) {
            Text(stringResource(R.string.desktop_right_click), color = DesktopMuted)
        }
        Button(
            onClick = onControl,
            enabled = canControl(state),
            colors = ButtonDefaults.buttonColors(
                containerColor = Color.White,
                contentColor = DesktopBackground,
                disabledContainerColor = Color(0xFF303030),
                disabledContentColor = DesktopMuted,
            ),
            shape = RoundedCornerShape(50),
        ) {
            Text(
                when {
                    state.claiming -> stringResource(R.string.desktop_claiming)
                    state.controlling -> stringResource(R.string.desktop_release_control)
                    else -> stringResource(R.string.desktop_take_control)
                },
            )
        }
    }
}

@Composable
private fun DesktopViewer(
    state: DesktopState,
    scrollMode: Boolean,
    onPoint: (Offset) -> Unit,
    onInput: (DesktopInputEvent) -> Unit,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var container by remember { mutableStateOf(IntSize.Zero) }
    var lastTapAt by remember { mutableStateOf(0L) }
    var lastTapPoint by remember { mutableStateOf(Offset.Zero) }
    val tapSlop = with(LocalDensity.current) { 36.dp.toPx() }
    val picture = state.picture
    val imageRect = remember(picture, container) {
        if (picture == null) Rect.Zero else fittedRect(picture.width, picture.height, container)
    }
    val controlling = state.controlling

    Box(modifier = modifier.onSizeChanged { container = it }) {
        if (picture != null) {
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
                                    if (dragging) normalize(last, imageRect)?.let {
                                        onInput(DesktopInputEvent(kind = "mouse_up", x = it.x.toDouble(), y = it.y.toDouble()))
                                    }
                                    return@awaitEachGesture
                                }
                                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                                if (!change.pressed) {
                                    if (dragging) {
                                        normalize(last, imageRect)?.let {
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
        } else {
            Column(
                modifier = Modifier.fillMaxSize().padding(32.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                val failure = state.failure
                if (failure != null) {
                    Text(failureText(failure), color = Color.White)
                    Spacer(modifier = Modifier.size(12.dp))
                    Button(onClick = onRetry) { Text(stringResource(R.string.desktop_retry)) }
                } else {
                    CircularProgressIndicator(color = Color.White)
                    Spacer(modifier = Modifier.size(12.dp))
                    Text(stringResource(R.string.desktop_connecting), color = DesktopMuted)
                }
            }
        }
        if (state.status != null && !state.permitted) {
            Surface(
                color = Color(0xFF232323),
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier.align(Alignment.TopCenter).padding(16.dp),
            ) {
                Text(permissionText(state.status), color = Color.White, modifier = Modifier.padding(14.dp))
            }
        }
    }
}

private fun canControl(state: DesktopState): Boolean {
    val status = state.status ?: return false
    if (state.claiming || state.otherDevice || !state.permitted) return false
    return state.controlling || state.picture != null
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
private fun desktopStatusText(state: DesktopState): String {
    val status = state.status
    val failure = state.failure
    return when {
        failure != null -> failureText(failure)
        status == null -> stringResource(R.string.desktop_connecting)
        !status.approved -> stringResource(R.string.desktop_update_mac)
        !status.screen || !status.input -> stringResource(R.string.desktop_permissions)
        state.otherDevice -> stringResource(R.string.desktop_owner_other)
        state.controlling -> stringResource(R.string.desktop_controlling)
        else -> stringResource(R.string.desktop_view_only)
    }
}

@Composable
private fun permissionText(status: DesktopStatus): String = when {
    !status.approved -> stringResource(R.string.desktop_update_mac)
    !status.screen || !status.input -> stringResource(R.string.desktop_permissions)
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
