package com.momoagent.android.remote

import com.momoagent.android.data.AgentApi
import com.momoagent.android.data.AgentConnection
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class ContextStoreTest {
    private lateinit var server: MockWebServer
    private lateinit var api: AgentApi

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        api = AgentApi()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun connection(): AgentConnection {
        val base = server.url("/").toString().trimEnd('/')
        return AgentConnection(
            workspaceID = "w",
            assistantID = "a",
            instanceID = "i",
            baseURL = base,
            dataURL = base,
            eventTransport = "sse",
        )
    }

    private fun source(id: String, revision: String = "r-$id"): String =
        """{"id":"$id","revision":"$revision","recorded_at":1794540000.0,"total_characters":10,"preview":"preview $id","windows":[{"id":"w-$id","source_id":"$id","source_revision":"$revision","recorded_at":1794540000.0,"end_at":1794540060.0,"offset":0,"end":5,"total_characters":5,"preview":"window $id","summary":"summary $id"}]}"""

    @Test
    fun sourcesConsumeEveryCursorPage() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"revision":1,"items":[${source("s1")}],"next_cursor":"s1"}"""))
        server.enqueue(MockResponse().setBody("""{"revision":1,"items":[${source("s2")}],"next_cursor":null}"""))
        val store = ContextStore(api, this, connection(), "token")
        store.loadSources()
        val state = withTimeout(5_000) { store.state.first { !it.sourcesLoading } }
        assertEquals(listOf("s1", "s2"), state.sources.map { it.id })
        assertEquals("w-s1", state.sources.first().windows.single().id)
        val first = server.takeRequest()
        val second = server.takeRequest()
        assertTrue(first.path.orEmpty().contains("/v1/sources?limit=200&summarize=1"))
        assertTrue(second.path.orEmpty().contains("after=s1"))
    }

    @Test
    fun memoriesReuseTheFirstRevisionWhilePaging() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"revision":42,"items":[{"id":"m1","text":"one","kind":"note","path":"projects/atlas/brief.md"}],"next_cursor":"m1"}"""))
        server.enqueue(MockResponse().setBody("""{"revision":42,"items":[{"id":"m2","text":"two","kind":"note"}],"next_cursor":null}"""))
        val store = ContextStore(api, this, connection(), "token")
        store.loadMemories()
        val state = withTimeout(5_000) { store.state.first { !it.memoriesLoading } }
        assertEquals(listOf("m1", "m2"), state.memories.map { it.id })
        server.takeRequest()
        val second = server.takeRequest()
        assertTrue(second.path.orEmpty().contains("after=m1"))
        assertTrue(second.path.orEmpty().contains("revision=42"))
    }

    @Test
    fun searchReturnsTheMatchingWindow() = runBlocking {
        val multiWindow = """{"id":"s1","revision":"r-s1","recorded_at":1794540000.0,"total_characters":10,"windows":[
            {"id":"w1","source_id":"s1","source_revision":"r-s1","recorded_at":1794540000.0,"end_at":1794540030.0,"offset":0,"end":5,"total_characters":5},
            {"id":"w2","source_id":"s1","source_revision":"r-s1","recorded_at":1794543600.0,"end_at":1794543630.0,"offset":6,"end":10,"total_characters":4}]}"""
        server.enqueue(MockResponse().setBody("""{"revision":1,"items":[$multiWindow],"next_cursor":null}"""))
        server.enqueue(
            MockResponse().setBody(
                """{"source_id":"s1","source_revision":"r-s1","text":"alpha\nbeta","offset":0,"end":10,"total_characters":10,"next_offset":null,"spans":[
                    {"id":"p1","recorded_at":1794540000.0,"text":"alpha","citation_url":"momoagent://source/x/p1?version=1&generation=1"},
                    {"id":"p2","recorded_at":1794543600.0,"text":"beta","citation_url":"momoagent://source/x/p2?version=1&generation=1"}]}""",
            ),
        )
        val store = ContextStore(api, this, connection(), "token")
        store.loadSources()
        withTimeout(5_000) { store.state.first { !it.sourcesLoading } }
        store.search("beta")
        val state = withTimeout(5_000) { store.state.first { !it.searchLoading && it.searchQuery == "beta" } }
        assertEquals(listOf("w2"), state.searchHits.map { it.window.id })
        assertTrue(state.searchHits.single().snippet.contains("beta"))
    }

    @Test
    fun detailLoadsEveryOffsetAndMergesSpans() = runBlocking {
        server.enqueue(
            MockResponse().setBody(
                """{"source_id":"s1","source_revision":"r-s1","text":"hello ","offset":0,"end":6,"total_characters":11,"truncated":true,"next_offset":6,"spans":[{"id":"p1","recorded_at":1794540000.0,"text":"hello ","citation_url":"momoagent://source/x/p1?version=1&generation=1"}]}""",
            ),
        )
        server.enqueue(
            MockResponse().setBody(
                """{"source_id":"s1","source_revision":"r-s1","text":"world","offset":6,"end":11,"total_characters":11,"truncated":false,"next_offset":null,"spans":[{"id":"p2","recorded_at":1794540001.0,"text":"world","citation_url":"momoagent://source/x/p2?version=1&generation=1"}]}""",
            ),
        )
        val store = ContextStore(api, this, connection(), "token")
        val source = com.momoagent.android.data.ContextSource(
            id = "s1",
            revision = "r-s1",
            recordedAt = 1794540000.0,
            totalCharacters = 11,
        )
        store.openSource(source)
        val state = withTimeout(5_000) { store.state.first { it.detail?.complete == true } }
        assertEquals("hello world", state.detail?.text)
        assertEquals(listOf("p1", "p2"), state.detail?.spans?.map { it.id })
        val first = server.takeRequest()
        val second = server.takeRequest()
        assertTrue(first.path.orEmpty().contains("offset=0"))
        assertTrue(second.path.orEmpty().contains("offset=6"))
    }

    @Test
    fun recordingLinkMatchesVersionAndWindow() = runBlocking {
        val session = "11111111-2222-3333-4444-555555555555"
        val span = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        server.enqueue(
            MockResponse().setBody(
                """{"revision":1,"items":[{"id":"lib/$session","revision":"r-source","recorded_at":1794540000.0,"total_characters":12,
                    "windows":[{"id":"w1","source_id":"lib/$session","source_revision":"r-source","recorded_at":1794540000.0,"end_at":1794540060.0,"offset":0,"end":6,"total_characters":12}]}],"next_cursor":null}""",
            ),
        )
        server.enqueue(
            MockResponse().setBody(
                """{"source_id":"lib/$session","source_revision":"r-source","text":"hello\nworld","offset":0,"end":12,"total_characters":12,"next_offset":null,"spans":[
                    {"id":"$span","recorded_at":1794540000.0,"text":"hello","citation_url":"momoagent://source/$session/$span?version=2&generation=0"}]}""",
            ),
        )
        val store = ContextStore(api, this, connection(), "token")
        val result = store.resolveRecordingLink(
            com.momoagent.android.data.RecordingLink(session, span, 2, 0),
        )
        assertTrue(result is RecordingLinkResult.Found)
        val found = result as RecordingLinkResult.Found
        assertEquals("w1", found.window?.id)
        server.enqueue(
            MockResponse().setBody(
                """{"source_id":"lib/$session","source_revision":"r-source","text":"hello\nworld","offset":0,"end":12,"total_characters":12,"next_offset":null,"spans":[
                    {"id":"$span","recorded_at":1794540000.0,"text":"hello","citation_url":"momoagent://source/$session/$span?version=2&generation=0"}]}""",
            ),
        )
        val stale = store.resolveRecordingLink(
            com.momoagent.android.data.RecordingLink(session, span, 1, 0),
        )
        assertEquals(RecordingLinkResult.Changed, stale)
    }

    @Test
    fun recordingLinkRefreshesAChangedSourceAndAcceptsTheNewVersion() = runBlocking {
        val session = "11111111-2222-3333-4444-555555555555"
        val span = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        fun sourceList(revision: String) =
            """{"revision":1,"items":[{"id":"lib/$session","revision":"$revision","recorded_at":1794540000.0,"total_characters":5,
                "windows":[{"id":"w1","source_id":"lib/$session","source_revision":"$revision","recorded_at":1794540000.0,"end_at":1794540060.0,"offset":0,"end":5,"total_characters":5}]}],"next_cursor":null}"""
        fun sourceText(revision: String, version: Int) =
            """{"source_id":"lib/$session","source_revision":"$revision","text":"hello","offset":0,"end":5,"total_characters":5,"next_offset":null,"spans":[
                {"id":"$span","recorded_at":1794540000.0,"text":"hello","citation_url":"momoagent://source/$session/$span?version=$version&generation=0"}]}"""

        server.enqueue(MockResponse().setBody(sourceList("r1")))
        server.enqueue(MockResponse().setBody(sourceText("r1", 2)))
        val store = ContextStore(api, this, connection(), "token")
        assertTrue(
            store.resolveRecordingLink(com.momoagent.android.data.RecordingLink(session, span, 2, 0))
                is RecordingLinkResult.Found,
        )

        server.enqueue(MockResponse().setResponseCode(409).setBody("""{"code":"source_changed"}"""))
        server.enqueue(MockResponse().setBody(sourceList("r2")))
        server.enqueue(MockResponse().setBody(sourceText("r2", 3)))
        assertEquals(
            RecordingLinkResult.Changed,
            store.resolveRecordingLink(com.momoagent.android.data.RecordingLink(session, span, 2, 0)),
        )

        server.enqueue(MockResponse().setBody(sourceText("r2", 3)))
        assertTrue(
            store.resolveRecordingLink(com.momoagent.android.data.RecordingLink(session, span, 3, 0))
                is RecordingLinkResult.Found,
        )
    }

    @Test
    fun searchReportsABodyReadFailure() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"revision":1,"items":[${source("s1")}],"next_cursor":null}"""))
        server.enqueue(MockResponse().setResponseCode(503).setBody("temporarily unavailable"))
        val store = ContextStore(api, this, connection(), "token")
        store.loadSources()
        withTimeout(5_000) { store.state.first { !it.sourcesLoading } }
        store.search("needle")
        val state = withTimeout(5_000) {
            store.state.first { it.searchQuery == "needle" && !it.searchLoading }
        }
        assertNotNull(state.searchFailure)
        assertTrue(state.searchHits.isEmpty())
    }
}
