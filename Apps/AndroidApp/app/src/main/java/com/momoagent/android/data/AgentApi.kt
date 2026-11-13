package com.momoagent.android.data

import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartReader
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources

/**
 * HTTP and SSE client for the Mac access boundary.
 *
 * The wire contract is owned by the Swift `MoMoAgentClient` package. Keep field
 * names and routes identical; the Mac accepts no arbitrary proxy target.
 */
class AgentApi {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
        explicitNulls = false
    }
    private val mediaType = "application/json; charset=utf-8".toMediaType()

    private val http = OkHttpClient.Builder()
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    private val clients = ConcurrentHashMap<String, OkHttpClient>()

    fun pairRequest(invitation: PairingInvitation, name: String, credential: String): PairingReceipt {
        val body = json.encodeToString(PairRequestBody(invitation.invitationID, name))
        val request = Request.Builder()
            .url(join(invitation.endpoint, "pair/requests"))
            .header("Authorization", "Bearer $credential")
            .header("Content-Type", "application/json")
            .post(body.toRequestBody(mediaType))
            .build()
        return execute(request, clientFor(invitation.tlsSHA256))
    }

    fun pairStatus(invitation: PairingInvitation, id: String, credential: String): PairingReceipt {
        val request = Request.Builder()
            .url(join(invitation.endpoint, "pair/requests/$id"))
            .header("Authorization", "Bearer $credential")
            .get()
            .build()
        return execute(request, clientFor(invitation.tlsSHA256))
    }

    fun capabilities(connection: AgentConnection, credential: String): AgentCapabilities {
        val request = authenticated(connection, credential, join(connection.baseURL, "v1/capabilities"))
            .get()
            .build()
        return execute(request, clientFor(connection.tlsSHA256))
    }

    fun conversationSnapshot(connection: AgentConnection, credential: String): ConversationSnapshot {
        val request = authenticated(connection, credential, join(connection.baseURL, "momo/v1/conversation/snapshot"))
            .get()
            .build()
        return execute(request, clientFor(connection.tlsSHA256))
    }

    fun snapshot(connection: AgentConnection, credential: String): ConversationSnapshot =
        conversationSnapshot(connection, credential)

    fun subscribe(
        connection: AgentConnection,
        credential: String,
        after: Int,
    ): Flow<ConversationEvent> {
        val request = authenticated(
            connection,
            credential,
            join(connection.baseURL, "momo/v1/conversation/subscribe") + "?after=$after",
        )
            .header("Accept", "text/event-stream")
            .get()
            .build()
        return events(request, streamClientFor(connection.tlsSHA256))
            .map { json.decodeFromString<ConversationEvent>(it) }
    }

    fun sendMessage(
        connection: AgentConnection,
        credential: String,
        content: String,
        operationID: String,
        attachments: List<AgentAttachment> = emptyList(),
    ): AgentRun {
        val body = json.encodeToString(
            MessageBody(
                operationID = operationID,
                content = content,
                intent = "new",
                attachments = attachments.takeIf { it.isNotEmpty() },
            ),
        )
        val request = authenticated(connection, credential, join(connection.baseURL, "momo/v1/conversation/messages"))
            .header("Accept", "application/json")
            .post(body.toRequestBody(mediaType))
            .build()
        return execute(request, clientFor(connection.tlsSHA256))
    }

    fun submitMessage(
        connection: AgentConnection,
        credential: String,
        content: String,
        operationID: String,
    ): Flow<AgentRunEvent> {
        val body = json.encodeToString(MessageBody(operationID, content))
        val request = authenticated(connection, credential, join(connection.baseURL, "momo/v1/conversation/messages"))
            .header("Accept", "text/event-stream")
            .post(body.toRequestBody(mediaType))
            .build()
        return events(request, streamClientFor(connection.tlsSHA256))
            .map { json.decodeFromString<AgentRunEvent>(it) }
    }

    fun revoke(connection: AgentConnection, credential: String) {
        val request = Request.Builder()
            .url(join(connection.baseURL, "pair/revoke"))
            .header("Authorization", "Bearer $credential")
            .header("Content-Type", "application/json")
            .post("{}".toRequestBody(mediaType))
            .build()
        execute<RevokeResponse>(request, clientFor(connection.tlsSHA256))
    }

    fun contextStatus(connection: AgentConnection, credential: String): ContextStatus {
        val request = authenticated(connection, credential, join(connection.dataURL, "v1/status"))
            .get()
            .build()
        return execute(request, clientFor(connection.tlsSHA256))
    }

    fun contextMemories(
        connection: AgentConnection,
        credential: String,
        limit: Int = 100,
    ): MemoryPage {
        val request = authenticated(connection, credential, join(connection.dataURL, "v1/memories?limit=$limit"))
            .get()
            .build()
        return execute(request, clientFor(connection.tlsSHA256))
    }

    fun contextSources(
        connection: AgentConnection,
        credential: String,
        limit: Int = 50,
    ): SourcePage {
        val request = authenticated(
            connection,
            credential,
            join(connection.dataURL, "v1/sources?limit=$limit&summarize=1"),
        )
            .get()
            .build()
        return execute(request, clientFor(connection.tlsSHA256))
    }

    fun contextSource(
        connection: AgentConnection,
        credential: String,
        source: ContextSource,
    ): SourceTextPage {
        val path = "v1/source?source_id=${source.id}&revision=${source.revision}&offset=0&limit=12000"
        val request = authenticated(connection, credential, join(connection.dataURL, path))
            .get()
            .build()
        return execute(request, clientFor(connection.tlsSHA256))
    }

    fun desktopStatus(connection: AgentConnection, credential: String): DesktopStatus {
        val request = authenticated(connection, credential, join(connection.baseURL, "desktop/v1/status"))
            .get()
            .build()
        return execute(request, clientFor(connection.tlsSHA256))
    }

    fun desktopControl(
        connection: AgentConnection,
        credential: String,
        operation: String,
        session: String? = null,
        requestID: String? = null,
    ): DesktopStatus {
        val body = json.encodeToString(DesktopControlBody(session = session, requestID = requestID))
        val request = authenticated(connection, credential, join(connection.baseURL, "desktop/v1/$operation"))
            .post(body.toRequestBody(mediaType))
            .build()
        return execute(request, clientFor(connection.tlsSHA256))
    }

    fun desktopInput(
        connection: AgentConnection,
        credential: String,
        session: String,
        event: DesktopInputEvent,
        eventID: String,
    ) {
        val body = json.encodeToString(DesktopInputBody(session = session, eventID = eventID, event = event))
        val request = authenticated(connection, credential, join(connection.baseURL, "desktop/v1/input"))
            .post(body.toRequestBody(mediaType))
            .build()
        executeIgnoringBody(request, clientFor(connection.tlsSHA256))
    }

    fun desktopFrameAck(
        connection: AgentConnection,
        credential: String,
        streamID: String,
        sequence: Int,
    ) {
        val body = json.encodeToString(DesktopFrameReceipt(streamID = streamID, sequence = sequence))
        val request = authenticated(connection, credential, join(connection.baseURL, "desktop/v1/frame-ack"))
            .post(body.toRequestBody(mediaType))
            .build()
        executeIgnoringBody(request, clientFor(connection.tlsSHA256))
    }

    fun desktopFrames(connection: AgentConnection, credential: String): Flow<DesktopPicture> = callbackFlow {
        val request = authenticated(connection, credential, join(connection.baseURL, "desktop/v1/frames"))
            .header("Accept", "multipart/x-mixed-replace")
            .get()
            .build()
        val call = streamClientFor(connection.tlsSHA256).newCall(request)
        val worker = launch(Dispatchers.IO) {
            try {
                call.execute().use { response ->
                    if (!response.isSuccessful) {
                        throw AgentHttpException(
                            response.code,
                            response.body?.string()?.take(512).orEmpty(),
                        )
                    }
                    val reader = MultipartReader(response.body ?: throw IOException("Missing desktop stream"))
                    while (isActive) {
                        val part = reader.nextPart() ?: break
                        val streamID = part.headers["X-Stream-ID"].orEmpty()
                        val sequence = part.headers["X-Frame-Sequence"]?.toIntOrNull() ?: 0
                        val bytes = part.body.readByteArray()
                        if (streamID.isEmpty() || sequence <= 0 || bytes.size !in 5..(512 * 1024)) {
                            throw IOException("Invalid desktop frame")
                        }
                        trySend(DesktopPicture(bytes, streamID, sequence))
                    }
                }
                close()
            } catch (error: CancellationException) {
                close()
            } catch (error: Exception) {
                close(error)
            }
        }
        awaitClose {
            call.cancel()
            worker.cancel()
        }
    }.buffer(Channel.CONFLATED)

    private fun authenticated(connection: AgentConnection, credential: String, url: String): Request.Builder =
        Request.Builder()
            .url(url)
            .header("Authorization", "Bearer $credential")
            .header("X-Hermes-Session-Key", "momo:${connection.assistantID.lowercase()}")
            .header("Content-Type", "application/json")

    private fun clientFor(fingerprint: String?): OkHttpClient {
        if (fingerprint == null) return http
        return clients.getOrPut(fingerprint) { pinnedClient(http, fingerprint) }
    }

    private fun streamClientFor(fingerprint: String?): OkHttpClient =
        clientFor(fingerprint).newBuilder()
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()

    private fun events(request: Request, client: OkHttpClient): Flow<String> = callbackFlow {
        val listener = object : EventSourceListener() {
            override fun onEvent(eventSource: EventSource, id: String?, type: String?, data: String) {
                trySend(data)
            }

            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                close(t ?: IOException("Stream failed with HTTP ${response?.code}"))
            }

            override fun onClosed(eventSource: EventSource) {
                close()
            }
        }
        val source = EventSources.createFactory(client).newEventSource(request, listener)
        awaitClose { source.cancel() }
    }

    private fun executeIgnoringBody(request: Request, client: OkHttpClient = http) {
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw AgentHttpException(response.code, response.body?.string()?.take(512).orEmpty())
            }
        }
    }

    private inline fun <reified T> execute(request: Request, client: OkHttpClient = http): T {
        client.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw AgentHttpException(response.code, body.take(512))
            }
            return json.decodeFromString(body)
        }
    }

    private fun join(base: String, path: String): String = base.trimEnd('/') + "/" + path.trimStart('/')
}

class AgentHttpException(val status: Int, message: String) : IOException("HTTP $status: $message")
