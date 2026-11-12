package com.momoagent.android.data

import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class AgentApiTest {
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
    fun submitMessageParsesSseAndSendsWireBody() = runBlocking {
        server.enqueue(
            MockResponse()
                .setHeader("Content-Type", "text/event-stream")
                .setBody(
                    "data: {\"event\":\"run.accepted\",\"run_id\":\"r1\",\"receipt\":{\"run_id\":\"r1\",\"status\":\"queued\"}}\n\n" +
                        "data: {\"event\":\"message.delta\",\"run_id\":\"r1\",\"seq\":1,\"delta\":\"Hi\"}\n\n" +
                        "data: {\"event\":\"run.completed\",\"run_id\":\"r1\",\"seq\":2}\n\n",
                ),
        )

        val events = api.submitMessage(connection(), "credential", "hello", "op-1")
            .take(3)
            .toList()

        assertEquals(
            listOf("run.accepted", "message.delta", "run.completed"),
            events.map { it.event },
        )
        assertEquals("Hi", events[1].delta)

        val request = server.takeRequest(2, TimeUnit.SECONDS)!!
        assertEquals("POST", request.method)
        assertEquals("/momo/v1/conversation/messages", request.path)
        assertEquals("Bearer credential", request.getHeader("Authorization"))
        assertEquals("text/event-stream", request.getHeader("Accept"))
        assertTrue(request.body.readUtf8().contains("\"operation_id\":\"op-1\""))
    }

    @Test
    fun snapshotSendsSessionKeyAndDecodesPage() = runBlocking {
        server.enqueue(
            MockResponse()
                .setHeader("Content-Type", "application/json")
                .setBody(
                    "{\"conversation_id\":\"c\",\"cursor\":3," +
                        "\"messages\":{\"data\":[{\"id\":\"m\",\"seq\":1,\"role\":\"user\",\"content\":\"hi\"}]}," +
                        "\"runs\":[]}",
                ),
        )

        val snapshot = api.snapshot(connection(), "credential")

        assertEquals("c", snapshot.conversationID)
        assertEquals(3, snapshot.cursor)
        assertEquals("hi", snapshot.messages.data.single().content)

        val request = server.takeRequest(2, TimeUnit.SECONDS)!!
        assertEquals("/momo/v1/conversation/snapshot", request.path)
        assertEquals("momo:a", request.getHeader("X-Hermes-Session-Key"))
    }
}
