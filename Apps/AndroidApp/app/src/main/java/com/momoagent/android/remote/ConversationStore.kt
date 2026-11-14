package com.momoagent.android.remote

import android.util.Base64
import com.momoagent.android.data.AgentApi
import com.momoagent.android.data.AgentAttachment
import com.momoagent.android.data.AgentConnection
import com.momoagent.android.data.AgentHttpException
import com.momoagent.android.data.AgentRun
import com.momoagent.android.data.AgentRunEvent
import com.momoagent.android.data.ConversationEvent
import com.momoagent.android.data.ConversationMessage
import com.momoagent.android.data.ConversationSnapshot
import com.momoagent.android.data.ConversationWork
import com.momoagent.android.data.ProviderServiceNotice
import java.util.Locale
import java.util.UUID
import kotlin.math.min
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject

enum class ConnectionState { Connecting, Ready, Retrying, AuthenticationRequired, Unavailable }

data class OutgoingMessage(
    val operationID: String,
    val content: String,
    val attachments: List<AgentAttachment>,
    val createdAt: Double = System.currentTimeMillis() / 1_000.0,
    val runID: String? = null,
    val failed: Boolean = false,
    val failure: String? = null,
)

data class ConversationState(
    val conversationID: String = "",
    val messages: List<ConversationMessage> = emptyList(),
    val outgoing: List<OutgoingMessage> = emptyList(),
    val runs: Map<String, AgentRun> = emptyMap(),
    val streaming: Map<String, String> = emptyMap(),
    val works: List<ConversationWork> = emptyList(),
    val messageStates: Map<String, String> = emptyMap(),
    val providerNotice: ProviderServiceNotice? = null,
    val cursor: Int = 0,
    val loading: Boolean = true,
    val failure: String? = null,
    val connection: ConnectionState = ConnectionState.Connecting,
    val draft: String = "",
    val attachments: List<AgentAttachment> = emptyList(),
) {
    val busy: Boolean
        get() = runs.values.any { !it.isTerminal } ||
            outgoing.any { !it.failed && it.runID == null }
}

/**
 * Mirrors the parts of the iPhone RemoteTaskStore the Android client consumes:
 * snapshot + conversation subscription, optimistic sends, receipts and streaming.
 */
class ConversationStore(
    private val api: AgentApi,
    private val scope: CoroutineScope,
    val connection: AgentConnection,
    private val credential: String,
    private val loadReadingPosition: () -> String?,
    private val saveReadingPosition: (String?) -> Unit,
) {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    }
    private val _state = MutableStateFlow(ConversationState())
    val state: StateFlow<ConversationState> = _state

    private var job: Job? = null
    private var subscriptionStarted = false

    fun start() {
        if (job?.isActive == true) return
        job = scope.launch {
            loadSnapshot()
            subscribeLoop()
        }
    }

    fun stop() {
        job?.cancel()
        job = null
        subscriptionStarted = false
    }

    fun refresh() {
        if (job?.isActive != true) {
            start()
            return
        }
        scope.launch { loadSnapshot() }
    }

    fun newDesktopSession(): DesktopStore = DesktopStore(api, connection, credential)

    fun setDraft(value: String) {
        _state.update { it.copy(draft = value) }
    }

    fun addAttachment(value: AgentAttachment) {
        _state.update { current ->
            if (current.attachments.size >= 4) current
            else current.copy(attachments = current.attachments + value)
        }
    }

    fun removeAttachment(id: String) {
        _state.update { it.copy(attachments = it.attachments.filterNot { item -> item.id == id }) }
    }

    fun dismissProviderNotice() {
        _state.update { it.copy(providerNotice = null) }
    }

    fun dismissFailure() {
        _state.update { it.copy(failure = null) }
    }

    fun send() {
        val current = _state.value
        val content = current.draft.trim()
        if (content.isEmpty() && current.attachments.isEmpty()) return
        val operationID = UUID.randomUUID().toString().lowercase()
        val outgoing = OutgoingMessage(operationID, content, current.attachments)
        _state.update {
            it.copy(
                outgoing = it.outgoing + outgoing,
                draft = "",
                attachments = emptyList(),
                failure = null,
            )
        }
        dispatch(outgoing)
    }

    fun retry(operationID: String) {
        val outgoing = _state.value.outgoing.firstOrNull { it.operationID == operationID } ?: return
        _state.update { current ->
            current.copy(
                outgoing = current.outgoing.map {
                    if (it.operationID == operationID) it.copy(failed = false, failure = null) else it
                },
                failure = null,
            )
        }
        dispatch(outgoing.copy(failed = false, failure = null))
    }

    private fun dispatch(outgoing: OutgoingMessage) {
        scope.launch {
            try {
                val run = withContext(Dispatchers.IO) {
                    api.sendMessage(connection, credential, outgoing.content, outgoing.operationID, outgoing.attachments)
                }
                _state.update { current ->
                    current.copy(
                        outgoing = current.outgoing.map {
                            if (it.operationID == outgoing.operationID) it.copy(runID = run.runID) else it
                        },
                        runs = current.runs + (run.runID to run),
                    )
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                val message = error.message ?: "send failed"
                _state.update { current ->
                    current.copy(
                        outgoing = current.outgoing.map {
                            if (it.operationID == outgoing.operationID) {
                                it.copy(failed = true, failure = message)
                            } else it
                        },
                        failure = message,
                    )
                }
            }
        }
    }

    private suspend fun loadSnapshot() {
        _state.update { it.copy(loading = true, connection = ConnectionState.Connecting) }
        try {
            val snapshot = withContext(Dispatchers.IO) { api.conversationSnapshot(connection, credential) }
            val echoed = snapshot.messages.data.mapNotNull { it.operationID }.toSet()
            _state.update { current ->
                current.copy(
                    conversationID = snapshot.conversationID,
                    messages = snapshot.messages.data.sortedBy { it.seq },
                    runs = snapshot.runs.associateBy { it.runID },
                    works = snapshot.backgroundWork,
                    messageStates = snapshot.messageStates,
                    providerNotice = snapshot.providerNotice ?: current.providerNotice,
                    cursor = maxOf(current.cursor, snapshot.cursor),
                    outgoing = current.outgoing.filterNot { it.operationID in echoed },
                    loading = false,
                    connection = ConnectionState.Ready,
                    failure = null,
                )
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            val auth = (error as? AgentHttpException)?.status == 401
            _state.update {
                it.copy(
                    loading = false,
                    connection = if (auth) ConnectionState.AuthenticationRequired else ConnectionState.Unavailable,
                    failure = error.message,
                )
            }
        }
    }

    private suspend fun subscribeLoop() {
        var backoff = 250L
        while (scope.isActive) {
            if (subscriptionStarted.not()) subscriptionStarted = true
            try {
                api.subscribe(connection, credential, _state.value.cursor).collect { event ->
                    apply(event)
                }
                delay(250)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                val message = error.message.orEmpty()
                if (message.contains("401")) {
                    _state.update { it.copy(connection = ConnectionState.AuthenticationRequired) }
                    return
                }
                _state.update {
                    it.copy(
                        connection = if (it.connection == ConnectionState.AuthenticationRequired) {
                            it.connection
                        } else ConnectionState.Retrying,
                    )
                }
                delay(backoff)
                backoff = min(5_000L, backoff * 2)
            }
        }
    }

    private fun apply(event: ConversationEvent) {
        if (event.kind == "ready" || event.kind == "heartbeat") {
            _state.update { it.copy(connection = ConnectionState.Ready) }
            return
        }
        val cursor = event.cursor
        _state.update { current ->
            if (cursor != null && cursor <= current.cursor) return@update current
            var next = current.copy(cursor = cursor ?: current.cursor)
            event.providerNotice?.let { next = next.copy(providerNotice = it) }
            event.messageStates?.let { next = next.copy(messageStates = next.messageStates + it) }
            event.backgroundWork?.let { next = next.copy(works = it) }
            when (event.kind) {
                "message.created" -> event.message?.let { message ->
                    val echoed = message.operationID
                    val outgoing = next.outgoing.filterNot { it.operationID == echoed }
                    val messages = (next.messages.filterNot { it.id == message.id } + message)
                        .sortedBy { it.seq }
                    next = next.copy(messages = messages, outgoing = outgoing)
                    if (message.role == "assistant" && message.runID != null) {
                        next = next.copy(streaming = next.streaming - message.runID)
                    }
                }
                "run.updated" -> event.run?.let { run ->
                    next = next.copy(runs = next.runs + (run.runID to run))
                }
                "run.event" -> event.runEvent?.let { value -> next = applyRunEvent(next, value) }
            }
            next.copy(connection = ConnectionState.Ready)
        }
    }

    private fun applyRunEvent(current: ConversationState, event: AgentRunEvent): ConversationState {
        val runID = event.runID
        if (runID.isEmpty()) return current
        val previous = current.streaming[runID].orEmpty()
        val text = when (event.event) {
            "message.delta" -> previous + event.delta.orEmpty()
            "message.interim" -> event.text ?: previous
            else -> previous
        }
        val run = current.runs[runID]
        val terminal = event.event in setOf("run.completed", "run.failed", "run.cancelled", "run.interrupted")
        val updatedRun = when {
            run == null && terminal -> AgentRun(runID = runID, status = terminalStatus(event.event))
            run != null && terminal -> run.copy(status = terminalStatus(event.event))
            else -> run
        }
        return current.copy(
            streaming = if (text.isNotEmpty()) current.streaming + (runID to text) else current.streaming,
            runs = if (updatedRun != null) current.runs + (runID to updatedRun) else current.runs,
        )
    }

    private fun terminalStatus(event: String): String = when (event) {
        "run.completed" -> "completed"
        "run.failed" -> "failed"
        "run.cancelled" -> "cancelled"
        "run.interrupted" -> "interrupted"
        else -> "running"
    }

    fun renderPayload(dark: Boolean, scale: Double, reduceMotion: Boolean, headerInset: Double = 0.0): String {
        val current = _state.value
        val rendered = mutableListOf<RenderMessage>()
        val confirmedAssistantRuns = current.messages
            .filter { it.role == "assistant" }
            .mapNotNull { it.runID }
            .toSet()
        for (message in current.messages) {
            if (message.role !in setOf("user", "assistant", "system")) continue
            val blocks = renderBlocks(message)
            rendered += RenderMessage(
                id = message.id,
                turnID = message.runID ?: if (message.role == "user") message.operationID ?: message.id else message.id,
                role = message.role,
                state = "complete",
                blocks = blocks,
                sentAtMs = message.createdAt.takeIf { it > 0 }?.times(1_000),
                delivery = if (message.role == "user") receipt(message) else null,
            )
        }
        for (outgoing in current.outgoing) {
            if (current.messages.any { it.operationID == outgoing.operationID }) continue
            val blocks = buildList {
                outgoing.attachments.forEach { add(attachmentBlock("${outgoing.operationID}:${it.id}", it)) }
                if (outgoing.content.isNotEmpty() || isEmpty()) {
                    add(RenderBlock(id = "${outgoing.operationID}:text", type = "text", text = outgoing.content))
                }
            }
            rendered += RenderMessage(
                id = "local-${outgoing.operationID}",
                turnID = outgoing.operationID,
                role = "user",
                state = "complete",
                blocks = blocks,
                sentAtMs = outgoing.createdAt * 1_000,
                delivery = if (outgoing.failed) "failed" else receipt(outgoing),
                deliveryError = outgoing.failure,
            )
        }
        for (run in current.runs.values) {
            val text = current.streaming[run.runID].orEmpty()
            if (text.isEmpty() || run.runID in confirmedAssistantRuns) continue
            rendered += RenderMessage(
                id = "${run.runID}:streaming",
                turnID = run.runID,
                role = "assistant",
                state = if (run.isTerminal) "complete" else "streaming",
                blocks = listOf(RenderBlock(id = "${run.runID}:text", type = "text", text = text)),
                sentAtMs = run.createdAt?.times(1_000),
            )
        }
        val lastUser = rendered.indexOfLast { it.role == "user" }
        val waiting = lastUser >= 0 &&
            rendered[lastUser].delivery in setOf("delivered", "read") &&
            rendered.drop(lastUser + 1).none { it.role == "assistant" }
        val payload = ChatRenderPayload(
            sessionID = connection.assistantID,
            locale = renderLocale(),
            messages = rendered,
            busy = current.busy,
            waitingForReply = waiting,
            readingPosition = readingPosition(),
            appearance = RenderAppearance(dark = dark, reduceMotion = reduceMotion, scale = scale, headerInset = headerInset),
        )
        return json.encodeToString(ChatRenderPayload.serializer(), payload)
    }

    private fun renderBlocks(message: ConversationMessage): List<RenderBlock> = buildList {
        message.attachments?.forEach { add(attachmentBlock("${message.id}:${it.id}", it)) }
        if (message.content.isNotEmpty() || isEmpty()) {
            add(RenderBlock(id = "${message.id}:text", type = "text", text = message.content))
        }
    }

    private fun attachmentBlock(id: String, item: AgentAttachment): RenderBlock {
        val preview = item.preview?.let { "data:image/jpeg;base64,$it" }
        return RenderBlock(
            id = id,
            type = "attachment",
            name = item.name,
            preview = preview,
            kind = item.kind,
            format = displayFormat(item),
            size = displaySize(item.byteCount),
            attachmentID = item.id,
        )
    }

    private fun displayFormat(item: AgentAttachment): String {
        val subtype = item.mediaType.substringAfter('/', "").uppercase(Locale.ROOT)
        if (subtype.isNotEmpty()) return subtype
        return item.name.substringAfterLast('.', "").uppercase(Locale.ROOT)
    }

    private fun displaySize(bytes: Int): String = when {
        bytes >= 1_048_576 -> String.format(Locale.US, "%.1f MB", bytes / 1_048_576.0)
        bytes >= 1_024 -> String.format(Locale.US, "%.1f KB", bytes / 1_024.0)
        else -> "$bytes B"
    }

    private fun receipt(message: ConversationMessage): String? {
        val state = currentState(message.id) ?: message.deliveryState
        if (state == "not_applied") return "failed"
        if (state == "applied") return "read"
        val run = message.runID?.let { _state.value.runs[it] }
        if (run != null) return receipt(run, state)
        return when (state) {
            "read" -> "read"
            "delivered" -> "delivered"
            else -> null
        }
    }

    private fun receipt(outgoing: OutgoingMessage): String? {
        if (outgoing.failed) return "failed"
        val run = outgoing.runID?.let { _state.value.runs[it] } ?: return null
        return receipt(run, null)
    }

    private fun receipt(run: AgentRun, messageState: String?): String? {
        if (run.deliveryState == "not_applied" || run.status == "not_applied" || messageState == "not_applied") {
            return "failed"
        }
        if (run.deliveryState == "applied") return "read"
        if (run.deliveryState in setOf("pending", "steering")) return "delivered"
        if (messageState in setOf("pending", "steering")) return "delivered"
        if (run.executionGeneration != null ||
            run.status in setOf(
                "running", "waiting_for_approval", "waiting_for_input",
                "waiting_for_computer", "stopping", "completed",
            )
        ) {
            return "read"
        }
        return "delivered"
    }

    private fun currentState(messageID: String): String? = _state.value.messageStates[messageID]

    private fun readingPosition(): JsonObject? {
        val raw = loadReadingPosition() ?: return null
        return runCatching { json.parseToJsonElement(raw).jsonObject }.getOrNull()
    }

    fun saveReadingPosition(value: String?) {
        saveReadingPosition.invoke(value)
    }

    private fun renderLocale(): String = when (Locale.getDefault().language) {
        "zh" -> "zh-Hans"
        "ja" -> "ja"
        "ko" -> "ko"
        else -> "en"
    }
}

private fun Base64.decodeOrNull(value: String): ByteArray? =
    runCatching { Base64.decode(value, Base64.DEFAULT) }.getOrNull()
