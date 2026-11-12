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
data class ConversationMessage(
    val id: String,
    val seq: Int,
    val role: String,
    val content: String,
    @SerialName("created_at") val createdAt: Double = 0.0,
    @SerialName("operation_id") val operationID: String? = null,
    @SerialName("run_id") val runID: String? = null,
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
    val status: String = "",
    val output: String? = null,
    val error: String? = null,
)

@Serializable
data class ConversationSnapshot(
    @SerialName("conversation_id") val conversationID: String,
    val cursor: Int = 0,
    val messages: ConversationPage = ConversationPage(),
    val runs: List<AgentRun> = emptyList(),
)

@Serializable
data class ConversationEvent(
    @SerialName("conversation_id") val conversationID: String? = null,
    val cursor: Int? = null,
    val kind: String = "",
    val message: ConversationMessage? = null,
    val run: AgentRun? = null,
    @SerialName("run_event") val runEvent: AgentRunEvent? = null,
)

@Serializable
data class AgentRunEvent(
    val event: String,
    @SerialName("run_id") val runID: String = "",
    val seq: Int? = null,
    val delta: String? = null,
    val text: String? = null,
    val tool: String? = null,
    val message: ConversationMessage? = null,
    val receipt: AgentRun? = null,
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
)
