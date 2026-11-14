package com.momoagent.android.remote

import com.momoagent.android.data.AgentAttachment
import com.momoagent.android.data.AgentLink
import com.momoagent.android.data.RecordingLink
import com.momoagent.android.data.RecordingReference
import com.momoagent.android.data.parseAgentLink
import java.util.UUID

data class RecordingSelection(
    val libraryID: String,
    val sessionID: String,
    val version: Long,
    val generation: Long,
    val spanIDs: List<String>,
    val name: String,
)

/** Builds one server reference from the spans that overlap the selected window. */
fun recordingSelection(detail: TranscriptDetail, name: String): RecordingSelection? {
    val window = detail.window ?: return null
    if (detail.spans.isEmpty()) return null
    val references = mutableListOf<RecordingLink>()
    var offset = 0
    for (span in detail.spans) {
        val length = span.text.codePointCount(0, span.text.length)
        if (offset + length > window.offset && offset < window.end) {
            val link = span.citationURL?.let(::parseAgentLink) as? AgentLink.Recording ?: return null
            references += link.link
        }
        offset += length + 1
    }
    if (references.isEmpty()) return null
    val first = references.first()
    if (references.any {
            it.sessionID != first.sessionID ||
                it.version != first.version ||
                it.generation != first.generation
        }
    ) {
        return null
    }
    if (references.map { it.spanID }.toSet().size != references.size) return null
    val libraryID = detail.source.id.substringBeforeLast('/')
    if (libraryID == detail.source.id) return null
    return RecordingSelection(
        libraryID = libraryID,
        sessionID = first.sessionID,
        version = first.version,
        generation = first.generation,
        spanIDs = references.map { it.spanID },
        name = name,
    )
}

fun RecordingSelection.toAttachment(): AgentAttachment = AgentAttachment(
    id = UUID.randomUUID().toString().lowercase(),
    name = name,
    kind = "document",
    mediaType = "application/vnd.momo.recording-reference",
    byteCount = 0,
    recording = RecordingReference(
        libraryID = libraryID,
        sessions = listOf(
            RecordingReference.Session(
                sessionID = sessionID,
                version = version,
                generation = generation,
                spanIDs = spanIDs,
            ),
        ),
    ),
)
