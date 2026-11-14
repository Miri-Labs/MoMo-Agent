package com.momoagent.android.data

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class DesktopClientTest {
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
            dataURL = base + "/context",
            eventTransport = "sse",
        )
    }

    @Test
    fun decodesDesktopStatus() {
        val status = Json { ignoreUnknownKeys = true }.decodeFromString<DesktopStatus>(
            """{"approved":true,"screen":true,"input":true,"owner":"you","active":true,"epoch":2,"session":"s","input_sequence":7,"preview_stream":true}""",
        )
        assertTrue(status.approved)
        assertEquals("you", status.owner)
        assertTrue(status.active)
        assertEquals(7, status.inputSequence)
        assertEquals("s", status.session)
    }

    @Test
    fun claimSendsRequestIDWithoutSession() {
        server.enqueue(
            MockResponse()
                .addHeader("Content-Type", "application/json")
                .setBody("""{"approved":true,"screen":true,"input":true,"owner":"you","active":true,"session":"s","epoch":1}"""),
        )
        val status = api.desktopControl(connection(), "token", "claim", requestID = "req-1")
        val recorded = server.takeRequest()
        assertEquals("POST", recorded.method)
        assertEquals("/desktop/v1/claim", recorded.path)
        val body = recorded.body.readUtf8()
        assertTrue(body.contains("\"request_id\":\"req-1\""))
        assertFalse(body.contains("\"session\""))
        assertTrue(status.active)
    }

    @Test
    fun inputSendsNestedEvent() {
        server.enqueue(MockResponse().setBody("""{"ok":true}"""))
        val event = DesktopInputEvent(kind = "click", x = 0.5, y = 0.25, clickCount = 1, sequence = 3)
        api.desktopInput(connection(), "token", "session-1", event, "event-1")
        val recorded = server.takeRequest()
        assertEquals("/desktop/v1/input", recorded.path)
        val body = recorded.body.readUtf8()
        assertTrue(body.contains("\"session\":\"session-1\""))
        assertTrue(body.contains("\"event_id\":\"event-1\""))
        assertTrue(body.contains("\"kind\":\"click\""))
        assertTrue(body.contains("\"click_count\":1"))
        assertTrue(body.contains("\"sequence\":3"))
    }

    @Test
    fun streamsMultipartJPEGFrames() = runBlocking {
        val jpeg = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 2, 3, 4, 0xFF.toByte(), 0xD9.toByte())
        val body = Buffer().apply {
            writeUtf8(
                "--momo-frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.size}\r\n" +
                    "X-Frame-Sequence: 1\r\nX-Stream-ID: 11111111-1111-1111-1111-111111111111\r\n\r\n",
            )
            write(jpeg)
            writeUtf8("\r\n--momo-frame--\r\n")
        }
        server.enqueue(
            MockResponse()
                .addHeader("Content-Type", "multipart/x-mixed-replace; boundary=momo-frame")
                .setBody(body),
        )
        val frame = api.desktopFrames(connection(), "token").first()
        assertEquals(1, frame.sequence)
        assertEquals("11111111-1111-1111-1111-111111111111", frame.streamID)
        assertArrayEquals(jpeg, frame.jpeg)
    }
}
