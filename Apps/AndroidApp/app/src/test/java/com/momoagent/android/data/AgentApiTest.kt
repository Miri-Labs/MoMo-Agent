package com.momoagent.android.data

import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
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

    private fun connection(tlsSHA256: String? = null): AgentConnection {
        val base = server.url("/").toString().trimEnd('/')
        return AgentConnection(
            workspaceID = "w",
            assistantID = "a",
            instanceID = "i",
            baseURL = base,
            dataURL = base + "/context",
            eventTransport = "sse",
            tlsSHA256 = tlsSHA256,
        )
    }

    private fun startHttps(): HeldCertificate {
        server.shutdown()
        server = MockWebServer()
        val held = HeldCertificate.Builder()
            .commonName("localhost")
            .addSubjectAlternativeName("localhost")
            .addSubjectAlternativeName("127.0.0.1")
            .build()
        val certificates = HandshakeCertificates.Builder()
            .heldCertificate(held)
            .build()
        server.useHttps(certificates.sslSocketFactory(), false)
        server.start()
        return held
    }

    private fun fingerprint(certificate: X509Certificate): String =
        MessageDigest.getInstance("SHA-256")
            .digest(certificate.encoded)
            .joinToString("") { "%02x".format(it) }

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

    @Test
    fun lanSnapshotPinsTheServerCertificate() = runBlocking {
        val held = startHttps()
        server.enqueue(
            MockResponse()
                .setHeader("Content-Type", "application/json")
                .setBody("{\"conversation_id\":\"c\",\"cursor\":1,\"messages\":{\"data\":[]},\"runs\":[]}"),
        )

        val snapshot = api.snapshot(connection(fingerprint(held.certificate)), "credential")

        assertEquals("c", snapshot.conversationID)
    }

    @Test
    fun wrongCertificatePinIsRejected() = runBlocking {
        startHttps()
        server.enqueue(
            MockResponse()
                .setHeader("Content-Type", "application/json")
                .setBody("{\"conversation_id\":\"c\",\"cursor\":1,\"messages\":{\"data\":[]},\"runs\":[]}"),
        )

        val result = runCatching { api.snapshot(connection("0".repeat(64)), "credential") }

        assertTrue(result.isFailure)
    }
}
