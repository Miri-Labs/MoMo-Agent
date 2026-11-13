package com.momoagent.android.remote

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/** Wire format consumed by the iPhone renderer copied into assets/chat. */
@Serializable
data class ChatRenderPayload(
    val sessionID: String,
    val locale: String,
    val messages: List<RenderMessage>,
    val busy: Boolean,
    val stopped: Boolean = false,
    val canRegenerate: Boolean = false,
    val contextState: String = "idle",
    val waitingForReply: Boolean? = null,
    val readingPosition: JsonObject? = null,
    val appearance: RenderAppearance,
)

@Serializable
data class RenderAppearance(
    val dark: Boolean,
    val reduceMotion: Boolean,
    val scale: Double,
    val headerInset: Double = 0.0,
)

@Serializable
data class RenderMessage(
    val id: String,
    val turnID: String,
    val role: String,
    val state: String,
    val blocks: List<RenderBlock>,
    val sentAtMs: Double? = null,
    val delivery: String? = null,
    val deliveryError: String? = null,
)

@Serializable
data class RenderBlock(
    val id: String,
    val type: String,
    val text: String? = null,
    val redacted: Boolean? = null,
    val tool: RenderTool? = null,
    val name: String? = null,
    val preview: String? = null,
    val kind: String? = null,
    val format: String? = null,
    val size: String? = null,
    @SerialName("attachmentID") val attachmentID: String? = null,
)

@Serializable
data class RenderTool(
    val id: String,
    val name: String,
    val input: String = "{}",
    val output: String? = null,
    val state: String = "running",
)
