package com.momoagent.android.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import android.provider.Settings as AndroidSettings
import android.util.Base64
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.momoagent.android.BuildConfig
import com.momoagent.android.R
import com.momoagent.android.data.AgentAttachment
import com.momoagent.android.data.AgentConnection
import com.momoagent.android.remote.ConnectionState
import com.momoagent.android.remote.ConversationState
import com.momoagent.android.remote.ConversationStore
import java.io.ByteArrayOutputStream
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

@Composable
fun ChatScreen(store: ConversationStore, onSettings: () -> Unit) {
    val palette = LocalMoMoPalette.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val state by store.state.collectAsStateWithLifecycle()
    val density = LocalDensity.current
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    val reduceMotion = remember(context) {
        AndroidSettings.Global.getFloat(context.contentResolver, AndroidSettings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    val statusBarDp = with(density) { WindowInsets.statusBars.getTop(this).toDp().value }
    val headerInset = statusBarDp + 108.0
    val payload = remember(state, dark, density.fontScale, reduceMotion, headerInset) {
        store.renderPayload(dark, density.fontScale.toDouble(), reduceMotion, headerInset)
    }
    var showingStatus by rememberSaveable { mutableStateOf(false) }
    var showingTasks by rememberSaveable { mutableStateOf(false) }
    var showingAdd by rememberSaveable { mutableStateOf(false) }
    var showingDesktop by rememberSaveable { mutableStateOf(false) }
    var showingVoice by rememberSaveable { mutableStateOf(false) }
    var attachmentFailure by remember { mutableStateOf<String?>(null) }
    var preview by remember { mutableStateOf<AgentAttachment?>(null) }
    val isEmpty = state.messages.isEmpty() && state.outgoing.isEmpty()

    fun addImage(uri: Uri) {
        if (store.state.value.attachments.size >= 4) {
            attachmentFailure = context.getString(R.string.chat_attachment_limit)
            return
        }
        scope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { imageAttachment(context, uri) } }
            result.onSuccess { store.addAttachment(it) }
                .onFailure { attachmentFailure = context.getString(R.string.chat_attachment_invalid) }
        }
    }

    fun addDocument(uri: Uri) {
        if (store.state.value.attachments.size >= 4) {
            attachmentFailure = context.getString(R.string.chat_attachment_limit)
            return
        }
        scope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { documentAttachment(context, uri) } }
            result.onSuccess { store.addAttachment(it) }
                .onFailure { attachmentFailure = context.getString(R.string.chat_attachment_invalid) }
        }
    }

    val photoLauncher = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri?.let(::addImage)
    }
    val documentLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(::addDocument)
    }

    val onEvent: (String, JSONObject) -> Unit = remember(state, context) {
        { type, value ->
            when (type) {
                "readingPosition" -> store.saveReadingPosition(value.toString())
                "link" -> value.optString("value").takeIf { it.isNotBlank() }?.let { openLink(context, it) }
                "copy" -> value.optString("value").takeIf { it.isNotBlank() }?.let { copyText(context, it) }
                "retryMessage" -> value.optString("turnID").takeIf { it.isNotBlank() }?.let(store::retry)
                "attachment" -> {
                    val id = value.optString("attachmentID")
                    findAttachment(state, id)?.let { preview = it }
                }
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        if (isEmpty) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 4.dp),
            ) {
                GlassIconButton(
                    icon = Icons.Filled.Settings,
                    label = stringResource(R.string.chat_settings),
                    onClick = onSettings,
                    modifier = Modifier.align(Alignment.CenterStart),
                )
                Row(
                    modifier = Modifier.align(Alignment.CenterEnd),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    GlassTasksButton(state.works.size, onClick = { showingTasks = true })
                    GlassIconButton(
                        icon = Icons.Filled.Computer,
                        label = stringResource(R.string.chat_desktop),
                        onClick = { showingDesktop = true },
                    )
                }
            }
            Column(
                modifier = Modifier
                    .align(Alignment.Center)
                    .offset(y = (-36).dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box {
                    AvatarView(
                        size = 144.dp,
                        expression = if (state.busy) "working" else "present",
                        active = true,
                        conversationID = store.connection.assistantID,
                    )
                    StatusBadge(
                        status = state.connection,
                        onClick = { showingStatus = true },
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .offset(x = 6.dp, y = 6.dp),
                    )
                }
                Spacer(Modifier.height(6.dp))
                BrandWordmark("MoMoWordmark", height = 22.dp)
                if (state.loading) {
                    Spacer(Modifier.height(20.dp))
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = palette.muted)
                }
            }
        } else {
            ChatWebView(
                payload = payload,
                onEvent = onEvent,
                modifier = Modifier.fillMaxSize(),
            )
            Box(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .fillMaxWidth()
                    .height((statusBarDp + 128f).dp)
                    .background(
                        Brush.verticalGradient(
                            listOf(
                                palette.canvas.copy(alpha = 0.97f),
                                palette.canvas.copy(alpha = 0.78f),
                                Color.Transparent,
                            ),
                        ),
                    ),
            )
            ChatHeader(
                state = state,
                conversationID = store.connection.assistantID,
                onSettings = onSettings,
                onTasks = { showingTasks = true },
                onDesktop = { showingDesktop = true },
                onStatus = { showingStatus = true },
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 10.dp, vertical = 4.dp),
            )
        }

        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .height(180.dp)
                .background(
                    Brush.verticalGradient(
                        listOf(
                            Color.Transparent,
                            palette.canvas.copy(alpha = 0.88f),
                            palette.canvas.copy(alpha = 0.96f),
                        ),
                    ),
                ),
        )

        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth(),
        ) {
            ChatBanners(
                state = state,
                onRefresh = store::refresh,
                onDismiss = store::dismissFailure,
                onSettings = onSettings,
            )
            Composer(
                draft = state.draft,
                attachments = state.attachments,
                onDraftChange = store::setDraft,
                onAdd = { showingAdd = true },
                onRemove = store::removeAttachment,
                onSend = store::send,
                onMic = { showingVoice = true },
            )
        }

        if (showingStatus) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) { showingStatus = false },
            )
        }
        AnimatedVisibility(
            visible = showingStatus,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(top = 112.dp, start = 24.dp, end = 24.dp),
            enter = fadeIn(tween(160)) + scaleIn(
                initialScale = 0.9f,
                animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = 500f),
                transformOrigin = TransformOrigin(0.5f, 0f),
            ),
            exit = fadeOut(tween(120)) + scaleOut(targetScale = 0.96f, transformOrigin = TransformOrigin(0.5f, 0f)),
        ) {
            StatusPopover(
                connection = store.connection,
                status = state.connection,
                onSettings = {
                    showingStatus = false
                    onSettings()
                },
            )
        }
    }

    if (showingAdd) {
        GlassDialog(
            onDismiss = { showingAdd = false },
            title = stringResource(R.string.attachment_title),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = {
                    showingAdd = false
                    photoLauncher.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                    )
                }) { Text(stringResource(R.string.attachment_photos), style = MoMoType.body) }
                TextButton(onClick = {
                    showingAdd = false
                    documentLauncher.launch(arrayOf("text/*"))
                }) { Text(stringResource(R.string.attachment_files), style = MoMoType.body) }
            }
        }
    }

    attachmentFailure?.let { failure ->
        GlassDialog(
            onDismiss = { attachmentFailure = null },
            title = stringResource(R.string.attachment_title),
        ) {
            Text(failure)
        }
    }

    preview?.let { item ->
        AttachmentPreviewDialog(item, onClose = { preview = null })
    }

    if (showingTasks) {
        GlassDialog(
            onDismiss = { showingTasks = false },
            title = stringResource(R.string.chat_tasks),
        ) {
            if (state.works.isEmpty()) {
                Text(stringResource(R.string.chat_no_tasks), color = palette.muted)
            } else {
                LazyColumn(modifier = Modifier.height(260.dp)) {
                    items(state.works, key = { it.id }) { work ->
                        Column(modifier = Modifier.padding(vertical = 8.dp)) {
                            Text(work.title ?: work.id, style = MoMoType.section, color = palette.ink)
                            Text(
                                text = work.waitReason ?: work.state,
                                style = MoMoType.metadata,
                                color = palette.muted,
                            )
                        }
                    }
                }
            }
        }
    }

    if (showingDesktop) {
        GlassDialog(
            onDismiss = { showingDesktop = false },
            title = stringResource(R.string.chat_desktop),
        ) {
            Text(stringResource(R.string.chat_desktop_unavailable), color = palette.muted)
        }
    }

    if (showingVoice) {
        GlassDialog(
            onDismiss = { showingVoice = false },
            title = stringResource(R.string.chat_voice),
        ) {
            Text(stringResource(R.string.chat_voice_unavailable), color = palette.muted)
        }
    }

    state.providerNotice?.let { notice ->
        GlassDialog(
            onDismiss = { store.dismissProviderNotice() },
            title = notice.title.ifBlank { notice.providerLabel },
        ) {
            Text(notice.message, color = palette.muted)
        }
    }
}

@Composable
private fun ChatHeader(
    state: ConversationState,
    conversationID: String?,
    onSettings: () -> Unit,
    onTasks: () -> Unit,
    onDesktop: () -> Unit,
    onStatus: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier) {
        GlassIconButton(
            icon = Icons.Filled.Settings,
            label = stringResource(R.string.chat_settings),
            onClick = onSettings,
            modifier = Modifier.align(Alignment.CenterStart),
        )
        Column(
            modifier = Modifier.align(Alignment.TopCenter),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box {
                AvatarView(
                    size = 84.dp,
                    expression = if (state.busy) "working" else "present",
                    active = true,
                    conversationID = conversationID,
                )
                StatusBadge(
                    status = state.connection,
                    onClick = onStatus,
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .offset(x = 6.dp, y = 6.dp),
                )
            }
            Spacer(Modifier.height(2.dp))
            BrandWordmark("MoMoWordmark", height = 14.dp)
        }
        Row(
            modifier = Modifier.align(Alignment.CenterEnd),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            GlassTasksButton(state.works.size, onTasks)
            GlassIconButton(
                icon = Icons.Filled.Computer,
                label = stringResource(R.string.chat_desktop),
                onClick = onDesktop,
            )
        }
    }
}

@Composable
private fun StatusBadge(
    status: ConnectionState,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = LocalMoMoPalette.current
    val color = when (status) {
        ConnectionState.Ready -> palette.success
        ConnectionState.Connecting, ConnectionState.Retrying -> Color(0xFFE0A63A)
        ConnectionState.AuthenticationRequired, ConnectionState.Unavailable -> palette.failure
    }
    GlassSurface(
        modifier = modifier.size(26.dp),
        shape = CircleShape,
        onClick = onClick,
        content = {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .background(color, CircleShape),
            )
        },
    )
}

@Composable
private fun StatusPopover(
    connection: AgentConnection,
    status: ConnectionState,
    onSettings: () -> Unit,
) {
    val palette = LocalMoMoPalette.current
    val color = when (status) {
        ConnectionState.Ready -> palette.success
        ConnectionState.Connecting, ConnectionState.Retrying -> Color(0xFFE0A63A)
        ConnectionState.AuthenticationRequired, ConnectionState.Unavailable -> palette.failure
    }
    val title = stringResource(
        when (status) {
            ConnectionState.Ready -> R.string.chat_status_ready
            ConnectionState.Connecting -> R.string.chat_status_connecting
            ConnectionState.Retrying -> R.string.chat_status_retrying
            ConnectionState.AuthenticationRequired -> R.string.chat_status_auth
            ConnectionState.Unavailable -> R.string.chat_status_unavailable
        },
    )
    val hint = when (status) {
        ConnectionState.Retrying -> stringResource(R.string.chat_reconnecting)
        ConnectionState.AuthenticationRequired -> stringResource(R.string.settings_auth_required)
        ConnectionState.Unavailable -> stringResource(R.string.chat_connection_lost)
        else -> null
    }
    val route = when (connection.network) {
        "lan" -> stringResource(R.string.settings_lan)
        "tailscale" -> stringResource(R.string.settings_tailscale)
        else -> stringResource(R.string.settings_relay)
    }
    GlassSurface(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(24.dp),
        contentPadding = PaddingValues(18.dp),
    ) {
        Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(
                    modifier = Modifier
                        .size(9.dp)
                        .background(color, CircleShape),
                )
                Text(title, style = MoMoType.section, color = palette.ink)
            }
            Text(
                text = "$route · ${connection.baseURL}",
                style = MoMoType.metadata,
                color = palette.muted,
                maxLines = 2,
            )
            hint?.let {
                Text(it, style = MoMoType.caption, color = palette.muted)
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) { onSettings() }
                    .padding(vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stringResource(R.string.chat_status_settings), style = MoMoType.menu, color = palette.ink)
                Spacer(Modifier.weight(1f))
                Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = palette.muted)
            }
            Text(
                text = "MoMo Agent ${BuildConfig.VERSION_NAME}",
                style = MoMoType.caption,
                color = palette.muted,
            )
        }
    }
}

@Composable
private fun ChatBanners(
    state: ConversationState,
    onRefresh: () -> Unit,
    onDismiss: () -> Unit,
    onSettings: () -> Unit,
) {
    val palette = LocalMoMoPalette.current
    val failure = state.failure
    when {
        failure != null -> Banner(
            text = stringResource(R.string.chat_load_failed),
            color = palette.failure,
            action = stringResource(R.string.chat_retry),
            onAction = onRefresh,
            onDismiss = onDismiss,
        )
        state.connection == ConnectionState.AuthenticationRequired -> Banner(
            text = stringResource(R.string.settings_auth_required),
            color = palette.failure,
            action = stringResource(R.string.chat_retry),
            onAction = onSettings,
        )
        state.connection == ConnectionState.Retrying || state.connection == ConnectionState.Unavailable -> Banner(
            text = stringResource(
                if (state.connection == ConnectionState.Retrying) R.string.chat_reconnecting
                else R.string.chat_connection_lost,
            ),
            color = palette.muted,
            action = stringResource(R.string.chat_retry),
            onAction = onRefresh,
        )
    }
}

@Composable
private fun Banner(
    text: String,
    color: Color,
    action: String,
    onAction: () -> Unit,
    onDismiss: (() -> Unit)? = null,
) {
    val palette = LocalMoMoPalette.current
    GlassSurface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        shape = RoundedCornerShape(16.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 14.dp, end = 4.dp, top = 2.dp, bottom = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text, style = MoMoType.caption, color = color, modifier = Modifier.weight(1f))
            TextButton(onClick = onAction) { Text(action, style = MoMoType.caption, color = palette.ink) }
            if (onDismiss != null) {
                TextButton(onClick = onDismiss) {
                    Text(stringResource(R.string.chat_dismiss), style = MoMoType.caption, color = palette.ink)
                }
            }
        }
    }
}

@Composable
private fun AttachmentPreviewDialog(item: AgentAttachment, onClose: () -> Unit) {
    val palette = LocalMoMoPalette.current
    val image = remember(item.preview) {
        item.preview?.let { value ->
            runCatching {
                val bytes = Base64.decode(value, Base64.NO_WRAP)
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            }.getOrNull()
        }
    }
    GlassDialog(
        onDismiss = onClose,
        title = stringResource(R.string.attachment_preview),
    ) {
        if (image != null) {
            Image(
                bitmap = image.asImageBitmap(),
                contentDescription = item.name,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(280.dp)
                    .clip(RoundedCornerShape(16.dp)),
            )
        } else {
            Text(item.name, color = palette.muted)
        }
    }
}

private fun findAttachment(state: ConversationState, id: String): AgentAttachment? {
    if (id.isEmpty()) return null
    state.messages.asSequence().flatMap { it.attachments.orEmpty().asSequence() }
        .firstOrNull { it.id == id }?.let { return it }
    state.outgoing.asSequence().flatMap { it.attachments.asSequence() }
        .firstOrNull { it.id == id }?.let { return it }
    return state.attachments.firstOrNull { it.id == id }
}

private fun openLink(context: Context, value: String) {
    runCatching {
        context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(value)))
    }
}

private fun copyText(context: Context, value: String) {
    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("MoMo", value))
}

private fun imageAttachment(context: Context, uri: Uri): AgentAttachment {
    val resolver = context.contentResolver
    val mime = resolver.getType(uri) ?: throw IllegalArgumentException("unknown type")
    if (mime !in setOf("image/jpeg", "image/png")) throw IllegalArgumentException("unsupported image")
    val bytes = resolver.openInputStream(uri)?.use { it.readBytes() }
        ?: throw IllegalArgumentException("cannot read image")
    if (bytes.isEmpty() || bytes.size > 1_048_576) throw IllegalArgumentException("image too large")
    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        ?: throw IllegalArgumentException("cannot decode image")
    val preview = previewJpeg(bitmap) ?: throw IllegalArgumentException("cannot preview image")
    if (preview.size > 64_000) throw IllegalArgumentException("preview too large")
    return AgentAttachment(
        id = UUID.randomUUID().toString().lowercase(),
        name = displayName(context, uri, "image"),
        kind = "image",
        mediaType = mime,
        byteCount = bytes.size,
        data = Base64.encodeToString(bytes, Base64.NO_WRAP),
        preview = Base64.encodeToString(preview, Base64.NO_WRAP),
    )
}

private fun documentAttachment(context: Context, uri: Uri): AgentAttachment {
    val resolver = context.contentResolver
    val name = displayName(context, uri, "document")
    val mime = resolver.getType(uri).orEmpty()
    val extension = name.substringAfterLast('.', "").lowercase()
    if (mime.isNotEmpty() && !mime.startsWith("text/") &&
        extension !in setOf("txt", "md", "markdown", "html", "htm")
    ) {
        throw IllegalArgumentException("unsupported document")
    }
    val text = resolver.openInputStream(uri)?.use { it.readBytes() }?.toString(Charsets.UTF_8)
        ?: throw IllegalArgumentException("cannot read document")
    if (text.isBlank()) throw IllegalArgumentException("empty document")
    val byteCount = text.toByteArray(Charsets.UTF_8).size
    if (byteCount > 256_000) throw IllegalArgumentException("document too large")
    return AgentAttachment(
        id = UUID.randomUUID().toString().lowercase(),
        name = name,
        kind = "document",
        mediaType = mime.ifBlank { "text/plain" },
        byteCount = byteCount,
        text = text,
    )
}

private fun displayName(context: Context, uri: Uri, fallback: String): String {
    val name = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }.getOrNull() ?: fallback
    return name.replace("\n", " ").replace("\u0000", "").take(256).ifBlank { fallback }
}

private fun previewJpeg(source: Bitmap): ByteArray? {
    var bitmap = source
    val maxSide = 512
    val scale = minOf(1f, maxSide.toFloat() / maxOf(source.width, source.height))
    if (scale < 1f) {
        bitmap = Bitmap.createScaledBitmap(
            source,
            (source.width * scale).toInt().coerceAtLeast(1),
            (source.height * scale).toInt().coerceAtLeast(1),
            true,
        )
    }
    for (quality in intArrayOf(72, 60, 48, 36, 28)) {
        val output = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, output)
        if (output.size() <= 64_000) return output.toByteArray()
    }
    return null
}
