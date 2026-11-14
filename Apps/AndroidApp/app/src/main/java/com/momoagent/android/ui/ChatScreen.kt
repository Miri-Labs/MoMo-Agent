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
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateIntOffsetAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.core.graphics.scale
import androidx.core.net.toUri
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.momoagent.android.R
import com.momoagent.android.data.AgentAttachment
import com.momoagent.android.data.AgentLink
import com.momoagent.android.data.ContextMemory
import com.momoagent.android.data.ConversationWork
import com.momoagent.android.data.parseAgentLink
import com.momoagent.android.remote.ConnectionState
import com.momoagent.android.remote.ContextStore
import com.momoagent.android.remote.ConversationState
import com.momoagent.android.remote.ConversationStore
import com.momoagent.android.remote.MemoryLinkResult
import com.momoagent.android.remote.RecordingLinkResult
import java.io.ByteArrayOutputStream
import java.text.DateFormat
import java.util.Date
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

@Composable
fun ChatScreen(
    store: ConversationStore,
    contextStore: ContextStore?,
    onSettings: () -> Unit,
    onOpenTranscripts: () -> Unit,
    onOpenMemory: () -> Unit,
) {
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
    var headerHeightPx by remember { mutableIntStateOf(0) }
    var parentPosition by remember { mutableStateOf<Offset?>(null) }
    var emptyAvatarPlaceholder by remember { mutableStateOf<AvatarPlaceholder?>(null) }
    var headerAvatarPlaceholder by remember { mutableStateOf<AvatarPlaceholder?>(null) }
    val measuredHeaderDp = with(density) { headerHeightPx.toDp().value.toDouble() }
    // The measured child excludes the status bar and the header's 4 dp vertical padding.
    val headerInset = if (headerHeightPx > 0) statusBarDp + 8.0 + measuredHeaderDp else statusBarDp + 108.0
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
    var linkRecording by remember { mutableStateOf<RecordingLinkResult.Found?>(null) }
    var linkMemory by remember { mutableStateOf<ContextMemory?>(null) }
    var linkFailure by remember { mutableStateOf<LinkFailure?>(null) }
    val isEmpty = state.messages.isEmpty() && state.outgoing.isEmpty()
    val avatarActive = !showingStatus && !showingTasks && !showingAdd && !showingDesktop &&
        !showingVoice && preview == null && attachmentFailure == null &&
        linkRecording == null && linkMemory == null && linkFailure == null &&
        state.providerNotice == null && !state.recordingReferenceFailure
    var settled by remember { mutableStateOf(false) }
    var previousBusy by remember { mutableStateOf(state.busy) }
    LaunchedEffect(state.busy) {
        if (state.busy) {
            settled = false
        } else if (previousBusy) {
            settled = true
            delay(1_700)
            settled = false
        }
        previousBusy = state.busy
    }
    val avatarExpression = when {
        state.busy -> "working"
        settled -> "settled"
        else -> "present"
    }
    val avatarTarget = if (isEmpty) {
        emptyAvatarPlaceholder?.target(parentPosition, 144.dp)
            ?: headerAvatarPlaceholder?.target(parentPosition, 72.dp)
    } else {
        headerAvatarPlaceholder?.target(parentPosition, 72.dp)
            ?: emptyAvatarPlaceholder?.target(parentPosition, 144.dp)
    }

    fun openAgentLink(value: String) {
        when (val link = parseAgentLink(value)) {
            is AgentLink.Web -> {
                runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, link.url.toUri())) }
                    .onFailure {
                        linkFailure = LinkFailure(
                            context.getString(R.string.link_web_failed),
                            LinkFailureKind.Web,
                        )
                    }
            }
            is AgentLink.Recording -> {
                val store = contextStore
                if (store == null) {
                    linkFailure = LinkFailure(
                        context.getString(R.string.link_requires_mac),
                        LinkFailureKind.Source,
                    )
                    return
                }
                scope.launch {
                    when (val result = store.resolveRecordingLink(link.link)) {
                        is RecordingLinkResult.Found -> linkRecording = result
                        RecordingLinkResult.Missing -> linkFailure = LinkFailure(
                            context.getString(R.string.link_source_missing),
                            LinkFailureKind.Source,
                        )
                        RecordingLinkResult.Changed -> linkFailure = LinkFailure(
                            context.getString(R.string.link_source_changed),
                            LinkFailureKind.Source,
                        )
                        is RecordingLinkResult.Failed -> linkFailure = LinkFailure(
                            context.getString(R.string.link_open_failed),
                            LinkFailureKind.Source,
                        )
                    }
                }
            }
            is AgentLink.Memory -> {
                val store = contextStore
                if (store == null) {
                    linkFailure = LinkFailure(
                        context.getString(R.string.link_requires_mac),
                        LinkFailureKind.Memory,
                    )
                    return
                }
                scope.launch {
                    when (val result = store.resolveMemoryLink(link.path)) {
                        is MemoryLinkResult.Found -> linkMemory = result.memory
                        MemoryLinkResult.Missing -> linkFailure = LinkFailure(
                            context.getString(R.string.link_memory_missing),
                            LinkFailureKind.Memory,
                        )
                        is MemoryLinkResult.Failed -> linkFailure = LinkFailure(
                            context.getString(R.string.link_open_failed),
                            LinkFailureKind.Memory,
                        )
                    }
                }
            }
            AgentLink.Unavailable -> linkFailure = LinkFailure(
                context.getString(R.string.link_unavailable),
                LinkFailureKind.Web,
            )
        }
    }

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

    val onEvent: (String, JSONObject) -> Unit = remember(state, context, contextStore) {
        { type, value ->
            when (type) {
                "readingPosition" -> store.saveReadingPosition(value.toString())
                "link" -> value.optString("value").takeIf { it.isNotBlank() }?.let(::openAgentLink)
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
        Column(Modifier.fillMaxSize()) {
            Box(
                Modifier.fillMaxWidth().weight(1f).onGloballyPositioned { coords ->
                    val position = coords.positionInWindow()
                    if (position != parentPosition) parentPosition = position
                },
            ) {
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
                            .padding(top = 24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Box(
                            Modifier.size(144.dp).onGloballyPositioned { coords ->
                                val next = AvatarPlaceholder(
                                    position = coords.positionInWindow(),
                                    size = with(density) { coords.size.width.toDp() },
                                )
                                if (next != emptyAvatarPlaceholder) emptyAvatarPlaceholder = next
                            },
                        )
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
                            .height((headerInset + 24.0).toFloat().dp)
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
                        onSettings = onSettings,
                        onTasks = { showingTasks = true },
                        onDesktop = { showingDesktop = true },
                        onMeasured = { headerHeightPx = it },
                        onAvatarPlaceholder = { position, size ->
                            val next = AvatarPlaceholder(position, size)
                            if (next != headerAvatarPlaceholder) headerAvatarPlaceholder = next
                        },
                        modifier = Modifier
                            .align(Alignment.TopCenter)
                            .fillMaxWidth()
                            .statusBarsPadding()
                            .padding(horizontal = 10.dp, vertical = 4.dp),
                    )
                }

                avatarTarget?.let { target ->
                    val dpSpec = if (reduceMotion) {
                        snap<Dp>()
                    } else {
                        spring<Dp>(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = 500f)
                    }
                    val offsetSpec = if (reduceMotion) {
                        snap<IntOffset>()
                    } else {
                        spring<IntOffset>(dampingRatio = Spring.DampingRatioNoBouncy, stiffness = 500f)
                    }
                    val animatedSize by animateDpAsState(target.size, dpSpec, label = "avatar-size")
                    val animatedHeight by animateDpAsState(target.layoutHeight, dpSpec, label = "avatar-height")
                    val animatedOffset by animateIntOffsetAsState(target.offset, offsetSpec, label = "avatar-offset")
                    Box(
                        modifier = Modifier
                            .offset { animatedOffset }
                            .width(animatedSize)
                            .height(animatedHeight),
                    ) {
                        AvatarView(
                            size = animatedSize,
                            expression = avatarExpression,
                            active = avatarActive,
                            conversationID = state.conversationID.ifBlank { store.connection.assistantID },
                            modifier = Modifier.align(Alignment.TopCenter),
                        )
                        CaptureStatusBadge(
                            onClick = { showingStatus = true },
                            modifier = Modifier
                                .align(Alignment.BottomEnd)
                                .offset(x = 8.dp, y = 8.dp),
                        )
                    }
                }
            }
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

    }

    if (showingStatus) {
        CaptureStatusDialog(
            status = state.connection,
            onOpenTranscripts = {
                showingStatus = false
                onOpenTranscripts()
            },
            onSettings = {
                showingStatus = false
                onSettings()
            },
            onClose = { showingStatus = false },
        )
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
        TasksDialog(state.works, onDismiss = { showingTasks = false })
    }

    linkRecording?.let { found ->
        RecordingLinkDialog(
            found = found,
            onOpen = {
                linkRecording = null
                contextStore?.openSource(found.source, found.window)
                onOpenTranscripts()
            },
            onClose = { linkRecording = null },
        )
    }

    linkMemory?.let { memory ->
        MemoryNoteDialog(memory, onClose = { linkMemory = null })
    }

    linkFailure?.let { failure ->
        LinkFailureDialog(
            failure = failure,
            onOpenTranscripts = {
                linkFailure = null
                onOpenTranscripts()
            },
            onOpenMemory = {
                linkFailure = null
                onOpenMemory()
            },
            onClose = { linkFailure = null },
        )
    }

    if (showingDesktop) {
        DesktopScreen(store = store, onClose = { showingDesktop = false })
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

    if (state.recordingReferenceFailure) {
        GlassDialog(
            onDismiss = store::dismissRecordingReferenceFailure,
            title = stringResource(R.string.recording_reference_failed_title),
        ) {
            Text(stringResource(R.string.recording_reference_changed), color = palette.muted)
        }
    }
}

@Composable
private fun ChatHeader(
    state: ConversationState,
    onSettings: () -> Unit,
    onTasks: () -> Unit,
    onDesktop: () -> Unit,
    onMeasured: (Int) -> Unit,
    onAvatarPlaceholder: (Offset, Dp) -> Unit,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    Box(modifier = modifier.onSizeChanged { onMeasured(it.height) }) {
        Row(
            modifier = Modifier.align(Alignment.TopStart).height(72.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GlassIconButton(
                icon = Icons.Filled.Settings,
                label = stringResource(R.string.chat_settings),
                onClick = onSettings,
            )
        }
        Column(
            modifier = Modifier.align(Alignment.TopCenter),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(
                Modifier.height(72.dp).width(84.dp).onGloballyPositioned { coords ->
                    onAvatarPlaceholder(
                        coords.positionInWindow(),
                        with(density) { coords.size.width.toDp() },
                    )
                },
            )
            Spacer(Modifier.height(6.dp))
            BrandWordmark("MoMoWordmark", height = 14.dp)
            Spacer(Modifier.height(8.dp))
        }
        Row(
            modifier = Modifier.align(Alignment.TopEnd).height(72.dp),
            verticalAlignment = Alignment.CenterVertically,
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
fun CaptureStatusBadge(onClick: () -> Unit, modifier: Modifier = Modifier) {
    val palette = LocalMoMoPalette.current
    val label = stringResource(R.string.chat_capture_badge)
    Box(
        modifier = modifier
            .size(48.dp)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                role = Role.Button,
                onClickLabel = label,
                onClick = onClick,
            )
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        GlassSurface(
            modifier = Modifier.height(24.dp),
            shape = CircleShape,
            contentPadding = PaddingValues(horizontal = 8.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Icon(
                    Icons.Filled.Watch,
                    contentDescription = null,
                    tint = palette.ink,
                    modifier = Modifier.size(14.dp),
                )
                Box(Modifier.size(5.dp).background(WatchPending, CircleShape))
            }
        }
    }
}

private val WatchPending = Color(0xFFE0A63A)

@Composable
fun CaptureStatusDialog(
    status: ConnectionState,
    onOpenTranscripts: () -> Unit,
    onSettings: () -> Unit,
    onClose: () -> Unit,
) {
    val palette = LocalMoMoPalette.current
    GlassDialog(
        onDismiss = onClose,
        title = stringResource(R.string.chat_capture_status),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(Icons.Filled.Watch, contentDescription = null, tint = palette.ink, modifier = Modifier.size(20.dp))
                Text(stringResource(R.string.chat_watch_unknown), style = MoMoType.section, color = palette.ink)
                Spacer(Modifier.weight(1f))
                Box(Modifier.size(8.dp).background(WatchPending, CircleShape))
            }
            Text(stringResource(R.string.chat_watch_unknown_body), style = MoMoType.metadata, color = palette.muted)
            HorizontalDivider(color = palette.line)
            Text(stringResource(R.string.chat_mac_connection), style = MoMoType.caption, color = palette.muted)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = statusTitle(status),
                    style = MoMoType.menu,
                    color = palette.ink,
                    modifier = Modifier.weight(1f),
                )
                Box(Modifier.size(7.dp).background(connectionColor(status), CircleShape))
            }
            DialogAction(stringResource(R.string.chat_open_transcripts), onOpenTranscripts)
            DialogAction(stringResource(R.string.chat_status_settings), onSettings)
        }
    }
}

@Composable
private fun DialogAction(text: String, onClick: () -> Unit) {
    val palette = LocalMoMoPalette.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = MoMoType.menu, color = palette.ink)
        Spacer(Modifier.weight(1f))
        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = palette.muted)
    }
}

@Composable
private fun statusTitle(status: ConnectionState): String = stringResource(
    when (status) {
        ConnectionState.Ready -> R.string.chat_status_ready
        ConnectionState.Connecting -> R.string.chat_status_connecting
        ConnectionState.Retrying -> R.string.chat_status_retrying
        ConnectionState.AuthenticationRequired -> R.string.chat_status_auth
        ConnectionState.Unavailable -> R.string.chat_status_unavailable
    },
)

@Composable
private fun connectionColor(status: ConnectionState): Color {
    val palette = LocalMoMoPalette.current
    return when (status) {
        ConnectionState.Ready -> palette.success
        ConnectionState.Connecting, ConnectionState.Retrying -> WatchPending
        ConnectionState.AuthenticationRequired, ConnectionState.Unavailable -> palette.failure
    }
}

@Composable
private fun TasksDialog(works: List<ConversationWork>, onDismiss: () -> Unit) {
    val palette = LocalMoMoPalette.current
    var selectedID by rememberSaveable { mutableStateOf<String?>(null) }
    val selected = works.firstOrNull { it.id == selectedID }
    GlassDialog(
        onDismiss = { if (selected != null) selectedID = null else onDismiss() },
        title = stringResource(if (selected != null) R.string.chat_task_detail else R.string.chat_tasks),
        confirmLabel = stringResource(
            if (selected != null) R.string.chat_task_back else R.string.chat_notice_ok,
        ),
        onConfirm = if (selected != null) ({ selectedID = null }) else null,
    ) {
        if (selected != null) {
            TaskDetail(selected)
        } else if (works.isEmpty()) {
            Text(stringResource(R.string.chat_no_tasks), color = palette.muted)
        } else {
            LazyColumn(modifier = Modifier.height(280.dp)) {
                items(works, key = { it.id }) { work ->
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .clickable { selectedID = work.id }
                            .padding(horizontal = 4.dp, vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            Text(
                                text = taskTitle(work),
                                style = MoMoType.section,
                                color = palette.ink,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                text = taskHintLabel(taskHint(work)),
                                style = MoMoType.metadata,
                                color = palette.muted,
                            )
                        }
                        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = palette.muted)
                    }
                    HorizontalDivider(color = palette.line)
                }
            }
        }
    }
}

@Composable
private fun TaskDetail(work: ConversationWork) {
    val palette = LocalMoMoPalette.current
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(taskTitle(work), style = MoMoType.subheading, color = palette.ink)
        Text(taskHintLabel(taskHint(work)), style = MoMoType.section, color = palette.ink)
        work.summary?.takeIf { it.isNotBlank() }?.let {
            Text(it, style = MoMoType.body, color = palette.muted)
        }
        work.createdAt?.takeIf { it > 0 }?.let { created ->
            Text(
                text = stringResource(R.string.chat_task_started, formatTime(created)),
                style = MoMoType.metadata,
                color = palette.muted,
            )
        }
    }
}

@Composable
private fun taskTitle(work: ConversationWork): String {
    val title = work.title?.trim().orEmpty()
    val identifier = work.id.substringAfter(':')
    val internal = title.isEmpty() || title == identifier || title == work.id || title == work.workID
    return if (internal) stringResource(R.string.chat_task_untitled) else title
}

@Composable
private fun taskHintLabel(hint: TaskHint): String = stringResource(
    when (hint) {
        TaskHint.WaitingForComputer -> R.string.task_hint_waiting_computer
        TaskHint.WaitingForConfirmation -> R.string.task_hint_waiting_confirm
        TaskHint.Queued -> R.string.task_hint_queued
        TaskHint.Finalizing -> R.string.task_hint_finalizing
        TaskHint.NeedsReview -> R.string.task_hint_needs_review
        TaskHint.Running -> R.string.task_hint_running
        TaskHint.Completed -> R.string.task_hint_completed
        TaskHint.Skipped -> R.string.task_hint_skipped
        TaskHint.Stopped -> R.string.task_hint_stopped
        TaskHint.Failed -> R.string.task_hint_failed
    },
)

@Composable
private fun RecordingLinkDialog(
    found: RecordingLinkResult.Found,
    onOpen: () -> Unit,
    onClose: () -> Unit,
) {
    val palette = LocalMoMoPalette.current
    GlassDialog(
        onDismiss = onClose,
        title = stringResource(R.string.link_recording_title),
        confirmLabel = stringResource(R.string.link_open_transcripts),
        dismissLabel = stringResource(R.string.chat_dismiss),
        onConfirm = onOpen,
    ) {
        Column(
            modifier = Modifier
                .heightIn(max = 360.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            val recordedAt = found.span.recordedAt ?: found.source.recordedAt
            recordedAt?.takeIf { it > 0 }?.let {
                Text(formatTime(it), style = MoMoType.metadata, color = palette.muted)
            }
            val speaker = if (found.span.isOwner == true) {
                stringResource(R.string.transcripts_speaker_me)
            } else {
                found.span.speaker?.takeIf { it.isNotBlank() }
            }
            speaker?.let {
                Text(it, style = MoMoType.section, color = palette.ink)
            }
            SelectionContainer {
                Text(found.span.text, style = MoMoType.body, color = palette.ink)
            }
        }
    }
}

@Composable
private fun LinkFailureDialog(
    failure: LinkFailure,
    onOpenTranscripts: () -> Unit,
    onOpenMemory: () -> Unit,
    onClose: () -> Unit,
) {
    val palette = LocalMoMoPalette.current
    GlassDialog(
        onDismiss = onClose,
        title = stringResource(R.string.link_unavailable_title),
        onConfirm = onClose,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(failure.message, style = MoMoType.body, color = palette.muted)
            when (failure.kind) {
                LinkFailureKind.Source -> TextButton(onClick = onOpenTranscripts) {
                    Text(stringResource(R.string.link_open_transcripts), style = MoMoType.menu)
                }
                LinkFailureKind.Memory -> TextButton(onClick = onOpenMemory) {
                    Text(stringResource(R.string.link_open_memory), style = MoMoType.menu)
                }
                LinkFailureKind.Web -> Unit
            }
        }
    }
}

private enum class LinkFailureKind { Source, Memory, Web }

private data class LinkFailure(val message: String, val kind: LinkFailureKind)

private fun formatTime(epochSeconds: Double): String =
    DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
        .format(Date((epochSeconds * 1_000).toLong()))

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
        bitmap = source.scale(
            (source.width * scale).toInt().coerceAtLeast(1),
            (source.height * scale).toInt().coerceAtLeast(1),
        )
    }
    for (quality in intArrayOf(72, 60, 48, 36, 28)) {
        val output = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, output)
        if (output.size() <= 64_000) return output.toByteArray()
    }
    return null
}
