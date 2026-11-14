package com.momoagent.android.remote

import com.momoagent.android.data.AgentApi
import com.momoagent.android.data.AgentAttachment
import com.momoagent.android.data.AgentConnection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationStoreAttachmentTest {
    private fun store(): ConversationStore = ConversationStore(
        api = AgentApi(),
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined),
        connection = AgentConnection(
            workspaceID = "w",
            assistantID = "a",
            instanceID = "i",
            baseURL = "https://example.test",
            dataURL = "https://example.test",
        ),
        credential = "token",
        loadReadingPosition = { null },
        saveReadingPosition = {},
    )

    private fun document(id: String) = AgentAttachment(
        id = id,
        name = id,
        kind = "document",
        mediaType = "text/plain",
        byteCount = 1,
        text = "x",
    )

    private fun recording(selection: String) = RecordingSelection(
        libraryID = "11111111-1111-1111-1111-111111111111",
        sessionID = "22222222-2222-2222-2222-222222222222",
        version = 1,
        generation = 0,
        spanIDs = listOf("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"),
        name = selection,
    ).toAttachment()

    @Test
    fun replacesAnExistingRecordingReferenceAndKeepsTheDraft() {
        val store = store()
        store.setDraft("my question")
        store.addAttachment(document("d1"))
        assertTrue(store.setRecordingAttachment(recording("first")))
        assertEquals("my question", store.state.value.draft)
        assertTrue(store.setRecordingAttachment(recording("second")))
        val attachments = store.state.value.attachments
        assertEquals(2, attachments.size)
        assertEquals(listOf("second"), attachments.filter { it.recording != null }.map { it.name })
        assertEquals("my question", store.state.value.draft)
    }

    @Test
    fun refusesToExceedFourAttachments() {
        val store = store()
        (1..4).forEach { store.addAttachment(document("d$it")) }
        assertFalse(store.setRecordingAttachment(recording("blocked")))
        assertTrue(store.state.value.attachments.none { it.recording != null })
    }

    @Test
    fun serializesTheRecordingReferenceContract() {
        val json = Json {
            encodeDefaults = true
            explicitNulls = false
        }
        val encoded = json.encodeToString(recording("reference"))
        assertTrue(encoded.contains("\"recording\""))
        assertTrue(encoded.contains("\"library_id\""))
        assertTrue(encoded.contains("\"session_id\""))
        assertTrue(encoded.contains("\"span_ids\""))
        assertTrue(encoded.contains("\"byte_count\":0"))
    }
}
