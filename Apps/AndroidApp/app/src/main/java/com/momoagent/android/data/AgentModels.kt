package com.momoagent.android.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class PairingInvitation(
    val version: Int,
    val application: String,
    @SerialName("invitation_id") val invitationID: String,
    val endpoint: String,
    @SerialName("instance_id") val instanceID: String,
    val expires: Double,
    val network: String? = null,
    @SerialName("relay_code") val relayCode: String? = null,
    @SerialName("tls_sha256") val tlsSHA256: String? = null,
)

@Serializable
data class PairingReceipt(
    val id: String,
    val name: String,
    val code: String,
    val state: String,
    val expires: Double,
    val connection: AgentConnection? = null,
)

@Serializable
data class AgentConnection(
    @SerialName("workspace_id") val workspaceID: String,
    @SerialName("assistant_id") val assistantID: String,
    @SerialName("instance_id") val instanceID: String,
    @SerialName("base_url") val baseURL: String,
    @SerialName("data_url") val dataURL: String,
    @SerialName("event_transport") val eventTransport: String? = null,
    val network: String? = null,
    @SerialName("relay_code") val relayCode: String? = null,
    @SerialName("tls_sha256") val tlsSHA256: String? = null,
)

@Serializable
data class AgentAttachment(
    val id: String,
    val name: String,
    val kind: String,
    @SerialName("media_type") val mediaType: String,
    @SerialName("byte_count") val byteCount: Int,
    val data: String? = null,
    val text: String? = null,
    val preview: String? = null,
)

@Serializable
data class ConversationMessage(
    val id: String,
    val seq: Int,
    val role: String,
    val content: String,
    @SerialName("created_at") val createdAt: Double = 0.0,
    @SerialName("operation_id") val operationID: String? = null,
    @SerialName("run_id") val runID: String? = null,
    @SerialName("source_session") val sourceSession: String? = null,
    @SerialName("delivery_state") val deliveryState: String? = null,
    val attachments: List<AgentAttachment>? = null,
)

@Serializable
data class ConversationPage(
    val data: List<ConversationMessage> = emptyList(),
    @SerialName("next_cursor") val nextCursor: Int = 0,
    @SerialName("has_more") val hasMore: Boolean = false,
)

@Serializable
data class AgentRun(
    @SerialName("run_id") val runID: String,
    @SerialName("session_id") val sessionID: String? = null,
    val status: String = "",
    val output: String? = null,
    val error: String? = null,
    @SerialName("delivery_state") val deliveryState: String? = null,
    @SerialName("execution_generation") val executionGeneration: Int? = null,
    @SerialName("work_id") val workID: String? = null,
    val title: String? = null,
    @SerialName("created_at") val createdAt: Double? = null,
    val cancellable: Boolean? = null,
    @SerialName("cancel_requested") val cancelRequested: Boolean? = null,
) {
    val isTerminal: Boolean
        get() = status in setOf("completed", "failed", "cancelled", "interrupted", "not_applied")
}

@Serializable
data class ConversationSnapshot(
    @SerialName("conversation_id") val conversationID: String,
    val cursor: Int = 0,
    val messages: ConversationPage = ConversationPage(),
    val runs: List<AgentRun> = emptyList(),
    @SerialName("background_work") val backgroundWork: List<ConversationWork> = emptyList(),
    @SerialName("message_states") val messageStates: Map<String, String> = emptyMap(),
    @SerialName("provider_notice") val providerNotice: ProviderServiceNotice? = null,
)

@Serializable
data class ConversationEvent(
    @SerialName("conversation_id") val conversationID: String? = null,
    val cursor: Int? = null,
    val kind: String = "",
    val message: ConversationMessage? = null,
    val run: AgentRun? = null,
    @SerialName("run_event") val runEvent: AgentRunEvent? = null,
    @SerialName("background_work") val backgroundWork: List<ConversationWork>? = null,
    @SerialName("message_states") val messageStates: Map<String, String>? = null,
    @SerialName("provider_notice") val providerNotice: ProviderServiceNotice? = null,
)

@Serializable
data class AgentRunEvent(
    val event: String,
    @SerialName("run_id") val runID: String = "",
    val seq: Int? = null,
    val delta: String? = null,
    val text: String? = null,
    val tool: String? = null,
    @SerialName("tool_call_id") val toolCallID: String? = null,
    val message: ConversationMessage? = null,
    val input: ConversationMessage? = null,
    val receipt: AgentRun? = null,
)

@Serializable
data class ConversationWork(
    val id: String,
    val state: String = "",
    @SerialName("report_state") val reportState: String = "",
    @SerialName("work_id") val workID: String? = null,
    val title: String? = null,
    @SerialName("wait_reason") val waitReason: String? = null,
    val cancellable: Boolean? = null,
    @SerialName("created_at") val createdAt: Double? = null,
    val summary: String? = null,
)

@Serializable
data class ProviderServiceNotice(
    val id: String,
    val kind: String = "",
    val provider: String = "",
    @SerialName("provider_label") val providerLabel: String = "",
    val title: String = "",
    val message: String = "",
    @SerialName("short_error") val shortError: String? = null,
    @SerialName("created_at") val createdAt: Double = 0.0,
    @SerialName("updated_at") val updatedAt: Double? = null,
)

@Serializable
data class AgentCapabilities(
    val features: Features = Features(),
) {
    @Serializable
    data class Features(
        @SerialName("run_submission") val runSubmission: Boolean? = null,
        @SerialName("run_status") val runStatus: Boolean? = null,
        @SerialName("run_stop") val runStop: Boolean? = null,
        @SerialName("session_resources") val sessionResources: Boolean? = null,
        @SerialName("runs_idempotency") val runsIdempotency: Idempotency? = null,
        @SerialName("conversation_events") val conversationEvents: Boolean? = null,
        @SerialName("message_streaming") val messageStreaming: Boolean? = null,
    )

    @Serializable
    data class Idempotency(
        val supported: Boolean? = null,
        val durable: Boolean? = null,
        @SerialName("retention_seconds") val retentionSeconds: Int? = null,
    )
}

@Serializable
data class ContextStatus(
    @SerialName("workspace_id") val workspaceID: String = "",
    @SerialName("source_sync") val sourceSync: Boolean = false,
    @SerialName("memory_writer") val memoryWriter: String = "",
)

@Serializable
data class ContextMemory(
    val id: String,
    val text: String,
    val kind: String,
    val basis: String = "",
    val status: String = "",
    val revision: Long = 0,
    val evidence: List<Evidence> = emptyList(),
    val path: String? = null,
) {
    @Serializable
    data class Evidence(
        @SerialName("source_id") val sourceID: String = "",
        @SerialName("source_revision") val sourceRevision: String = "",
        val quote: String = "",
        @SerialName("recorded_at") val recordedAt: Double? = null,
    )
}

@Serializable
data class MemoryPage(
    val revision: Long = 0,
    val items: List<ContextMemory> = emptyList(),
    @SerialName("next_cursor") val nextCursor: String? = null,
)

@Serializable
data class ContextWindow(
    val id: String,
    @SerialName("source_id") val sourceID: String = "",
    @SerialName("source_revision") val sourceRevision: String = "",
    @SerialName("recorded_at") val recordedAt: Double? = null,
    @SerialName("end_at") val endAt: Double? = null,
    val offset: Int = 0,
    val end: Int = 0,
    @SerialName("total_characters") val totalCharacters: Int = 0,
    val preview: String? = null,
    val summary: String? = null,
)

@Serializable
data class ContextSource(
    val id: String,
    val revision: String = "",
    @SerialName("recorded_at") val recordedAt: Double? = null,
    @SerialName("total_characters") val totalCharacters: Int = 0,
    val summary: String? = null,
    val preview: String? = null,
    @SerialName("recorded_summary") val recordedSummary: String? = null,
    val windows: List<ContextWindow> = emptyList(),
)

@Serializable
data class ContextSpan(
    val id: String,
    @SerialName("recorded_at") val recordedAt: Double? = null,
    val text: String = "",
    @SerialName("citation_url") val citationURL: String? = null,
    @SerialName("is_owner") val isOwner: Boolean? = null,
    val speaker: String? = null,
    @SerialName("speaker_inferred_by_dream") val speakerInferredByDream: Boolean? = null,
)

@Serializable
data class SourcePage(
    val items: List<ContextSource> = emptyList(),
    @SerialName("next_cursor") val nextCursor: String? = null,
)

@Serializable
data class SourceTextPage(
    @SerialName("source_id") val sourceID: String = "",
    @SerialName("source_revision") val sourceRevision: String = "",
    @SerialName("text_sha256") val textSHA256: String = "",
    val text: String = "",
    val offset: Int = 0,
    val end: Int = 0,
    @SerialName("total_characters") val totalCharacters: Int = 0,
    val truncated: Boolean = false,
    @SerialName("next_offset") val nextOffset: Int? = null,
    val spans: List<ContextSpan> = emptyList(),
)

@Serializable
data class PairRequestBody(
    @SerialName("invitation_id") val invitationID: String,
    val name: String,
)

@Serializable
data class MessageBody(
    @SerialName("operation_id") val operationID: String,
    val content: String,
    val intent: String = "new",
    @SerialName("target_run_id") val targetRunID: String? = null,
    @SerialName("execution_generation") val executionGeneration: Int? = null,
    @SerialName("work_id") val workID: String? = null,
    val attachments: List<AgentAttachment>? = null,
)

@Serializable
data class RevokeResponse(val revoked: Boolean = false)

@Serializable
data class DesktopStatus(
    val approved: Boolean = false,
    val screen: Boolean = false,
    val input: Boolean = false,
    val owner: String = "",
    val active: Boolean = false,
    val epoch: Int = 0,
    val session: String? = null,
    @SerialName("input_sequence") val inputSequence: Int? = null,
    @SerialName("preview_stream") val previewStream: Boolean? = null,
)

@Serializable
data class DesktopInputEvent(
    val kind: String,
    val x: Double? = null,
    val y: Double? = null,
    @SerialName("to_x") val toX: Double? = null,
    @SerialName("to_y") val toY: Double? = null,
    val delta: Int? = null,
    @SerialName("delta_x") val deltaX: Int? = null,
    val text: String? = null,
    val key: String? = null,
    val modifiers: List<String>? = null,
    val button: String? = null,
    val sequence: Int? = null,
    @SerialName("click_count") val clickCount: Int? = null,
)

data class DesktopPicture(
    val jpeg: ByteArray,
    val streamID: String,
    val sequence: Int,
)

@Serializable
data class DesktopControlBody(
    val session: String? = null,
    @SerialName("request_id") val requestID: String? = null,
)

@Serializable
data class DesktopInputBody(
    val session: String,
    @SerialName("event_id") val eventID: String,
    val event: DesktopInputEvent,
)

@Serializable
data class DesktopFrameReceipt(
    @SerialName("stream_id") val streamID: String,
    val sequence: Int,
)
