package com.momoagent.android.remote

import com.momoagent.android.data.ContextSource
import com.momoagent.android.data.ContextSpan
import com.momoagent.android.data.ContextWindow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RecordingSelectionTest {
    private val library = "11111111-1111-1111-1111-111111111111"
    private val session = "22222222-2222-2222-2222-222222222222"
    private val firstSpan = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private val secondSpan = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    private fun source() = ContextSource(
        id = "$library/$session",
        revision = "revision",
        recordedAt = 1794540000.0,
        totalCharacters = 11,
    )

    private fun window(end: Int = 5) = ContextWindow(
        id = "window",
        sourceID = source().id,
        sourceRevision = "revision",
        offset = 0,
        end = end,
        totalCharacters = 11,
    )

    private fun span(id: String, text: String, version: Int) = ContextSpan(
        id = id,
        text = text,
        citationURL = "momoagent://source/$session/$id?version=$version&generation=0",
    )

    @Test
    fun selectsOnlySpansInsideTheWindow() {
        val detail = TranscriptDetail(
            source = source(),
            window = window(),
            text = "hello\nworld",
            spans = listOf(
                span(firstSpan, "hello", 3),
                span(secondSpan, "world", 3),
            ),
        )
        val selection = recordingSelection(detail, "Recording reference")
        assertEquals(library, selection?.libraryID)
        assertEquals(session, selection?.sessionID)
        assertEquals(listOf(firstSpan), selection?.spanIDs)
        assertEquals(3L, selection?.version)
    }

    @Test
    fun rejectsMixedVersions() {
        val detail = TranscriptDetail(
            source = source(),
            window = window(end = 11),
            text = "hello\nworld",
            spans = listOf(
                span(firstSpan, "hello", 3),
                span(secondSpan, "world", 4),
            ),
        )
        assertNull(recordingSelection(detail, "Recording reference"))
    }

    @Test
    fun requiresALibraryAndSessionSourceID() {
        val detail = TranscriptDetail(
            source = source().copy(id = session),
            window = window(),
            text = "hello",
            spans = listOf(span(firstSpan, "hello", 3)),
        )
        assertNull(recordingSelection(detail, "Recording reference"))
    }
}
