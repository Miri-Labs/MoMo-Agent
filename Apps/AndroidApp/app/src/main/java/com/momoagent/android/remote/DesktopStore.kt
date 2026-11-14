package com.momoagent.android.remote

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.momoagent.android.data.AgentApi
import com.momoagent.android.data.AgentConnection
import com.momoagent.android.data.AgentHttpException
import com.momoagent.android.data.DesktopInputEvent
import com.momoagent.android.data.DesktopStatus
import java.util.ArrayDeque
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
enum class DesktopFailure { Revoked, Permissions, Busy, Ownership, Unavailable, Network }

data class DesktopState(
    val status: DesktopStatus? = null,
    val picture: Bitmap? = null,
    val loading: Boolean = true,
    val streaming: Boolean = false,
    val claiming: Boolean = false,
    val failure: DesktopFailure? = null,
) {
    val permitted: Boolean get() = status?.approved == true && status.screen && status.input
    val controlling: Boolean get() = status?.owner == "you" && status.active
    val otherDevice: Boolean get() = status?.owner == "other"
}

internal data class QueuedDesktopInput(
    val event: DesktopInputEvent,
    val generation: Int,
    val session: String,
)

/** Inputs belong to the frame generation and control session they were produced for. */
internal class DesktopInputQueue {
    private val entries = ArrayDeque<QueuedDesktopInput>()

    @Synchronized
    fun enqueue(entry: QueuedDesktopInput) {
        val last = entries.lastOrNull()
        if (entry.event.kind == "mouse_move" && last?.event?.kind == "mouse_move" &&
            last.generation == entry.generation && last.session == entry.session
        ) {
            entries.removeLast()
        } else if (entries.size >= 128) {
            entries.removeFirst()
        }
        entries.addLast(entry)
    }

    @Synchronized
    fun poll(generation: Int, session: String): QueuedDesktopInput? {
        while (true) {
            val entry = entries.pollFirst() ?: return null
            if (entry.generation == generation && entry.session == session) return entry
        }
    }

    @Synchronized
    fun clear() = entries.clear()
}

/**
 * Desktop preview and control over the access boundary's HTTP routes.
 * The frame endpoint is a multipart JPEG stream; input is acknowledged per event.
 */
class DesktopStore(
    private val api: AgentApi,
    private val connection: AgentConnection,
    private val credential: String,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val _state = MutableStateFlow(DesktopState())
    val state: StateFlow<DesktopState> = _state
    private var pollJob: Job? = null
    private var streamJob: Job? = null
    private var heartbeatJob: Job? = null
    private var inputJob: Job? = null
    private var watchdogJob: Job? = null
    private var lastFrameAt = 0L
    private var inputGeneration = 0
    private val inputSignal = Channel<Unit>(Channel.CONFLATED)
    private val inputQueue = DesktopInputQueue()
    private var inputSequence = 0

    fun open() {
        if (pollJob?.isActive == true) return
        lastFrameAt = 0L
        invalidateInputs()
        _state.value = DesktopState()
        pollJob = scope.launch { pollLoop() }
        streamJob = scope.launch { streamLoop() }
        watchdogJob = scope.launch { frameWatchdog() }
        if (inputJob == null) inputJob = scope.launch { inputLoop() }
    }

    fun retry() {
        pollJob?.cancel()
        streamJob?.cancel()
        invalidateInputs()
        pollJob = scope.launch { pollLoop() }
        streamJob = scope.launch { streamLoop() }
    }

    fun close() {
        val status = _state.value.status
        val controlling = _state.value.controlling
        invalidateInputs()
        pollJob?.cancel(); streamJob?.cancel(); heartbeatJob?.cancel(); inputJob?.cancel(); watchdogJob?.cancel()
        pollJob = null; streamJob = null; heartbeatJob = null; inputJob = null; watchdogJob = null
        if (controlling && status?.session != null) {
            val session = status.session
            CoroutineScope(Dispatchers.IO).launch {
                runCatching {
                    val reset = DesktopInputEvent(kind = "reset", sequence = ++inputSequence)
                    api.desktopInput(connection, credential, session, reset, UUID.randomUUID().toString())
                }
                runCatching { api.desktopControl(connection, credential, "release", session = session) }
            }
        }
        _state.value = DesktopState()
    }

    fun claim() {
        if (_state.value.claiming || _state.value.controlling) return
        if (!_state.value.streaming || _state.value.picture == null) return
        _state.update { it.copy(claiming = true, failure = null) }
        scope.launch {
            try {
                applyStatus(api.desktopControl(connection, credential, "claim", requestID = UUID.randomUUID().toString()))
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                fail(error)
            } finally {
                _state.update { it.copy(claiming = false) }
            }
        }
    }

    fun release() {
        val session = _state.value.status?.session ?: return
        if (_state.value.claiming) return
        _state.update { it.copy(claiming = true) }
        scope.launch {
            try {
                applyStatus(api.desktopControl(connection, credential, "release", session = session))
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                fail(error)
            } finally {
                _state.update { it.copy(claiming = false) }
            }
        }
    }

    fun send(event: DesktopInputEvent) {
        val state = _state.value
        val status = state.status ?: return
        val session = status.session ?: return
        if (!state.streaming || state.picture == null) return
        if (!state.controlling || !status.screen || !status.input) return
        inputSequence += 1
        inputQueue.enqueue(
            QueuedDesktopInput(
                event = event.copy(sequence = inputSequence),
                generation = inputGeneration,
                session = session,
            ),
        )
        inputSignal.trySend(Unit)
    }

    private suspend fun pollLoop() {
        while (scope.isActive) {
            try {
                val next = api.desktopStatus(connection, credential)
                applyStatus(next)
                _state.update {
                    it.copy(loading = false, failure = if (it.streaming) null else it.failure)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                fail(error)
            }
            delay(2_000)
        }
    }

    private suspend fun streamLoop() {
        var backoff = 700L
        while (scope.isActive) {
            try {
                api.desktopFrames(connection, credential).collect { frame ->
                    val bitmap = BitmapFactory.decodeByteArray(frame.jpeg, 0, frame.jpeg.size)
                    if (bitmap != null) {
                        lastFrameAt = System.currentTimeMillis()
                        _state.update {
                            it.copy(picture = bitmap, streaming = true, loading = false, failure = null)
                        }
                        runCatching {
                            api.desktopFrameAck(connection, credential, frame.streamID, frame.sequence)
                        }
                    }
                }
                backoff = 700L
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                loseFrames(error)
            }
            if (_state.value.streaming) loseFrames(null)
            delay(backoff)
            backoff = (backoff * 2).coerceAtMost(4_000)
        }
    }

    private suspend fun inputLoop() {
        while (true) {
            inputSignal.receive()
            while (true) {
                val state = _state.value
                val status = state.status ?: break
                val session = status.session ?: break
                if (!state.streaming || state.picture == null || !state.controlling) {
                    inputQueue.clear()
                    break
                }
                val queued = inputQueue.poll(inputGeneration, session) ?: break
                try {
                    api.desktopInput(connection, credential, session, queued.event, UUID.randomUUID().toString())
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    fail(error)
                    break
                }
            }
        }
    }

    private fun applyStatus(next: DesktopStatus) {
        val previous = _state.value.status
        if (previous != null && (
                previous.session != next.session ||
                    previous.owner != next.owner ||
                    previous.active != next.active
                )
        ) {
            invalidateInputs()
        }
        inputSequence = maxOf(inputSequence, next.inputSequence ?: 0)
        _state.update { it.copy(status = next, loading = false) }
        if (next.owner == "you" && next.active && next.session != null && _state.value.streaming) {
            startHeartbeat()
        } else {
            stopHeartbeat()
        }
    }

    private fun startHeartbeat() {
        if (heartbeatJob?.isActive == true) return
        heartbeatJob = scope.launch {
            while (isActive) {
                delay(5_000)
                val status = _state.value.status ?: break
                val session = status.session ?: break
                if (!_state.value.controlling || !_state.value.streaming) break
                try {
                    applyStatus(api.desktopControl(connection, credential, "heartbeat", session = session))
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    fail(error)
                    break
                }
            }
            heartbeatJob = null
        }
    }

    private fun stopHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = null
    }

    private fun loseFrames(error: Throwable?) {
        invalidateInputs()
        stopHeartbeat()
        _state.update {
            it.copy(
                picture = null,
                streaming = false,
                loading = true,
                failure = error?.let(::classify) ?: DesktopFailure.Network,
            )
        }
    }

    private fun invalidateInputs() {
        inputGeneration += 1
        inputQueue.clear()
    }

    private suspend fun frameWatchdog() {
        while (scope.isActive) {
            delay(2_000)
            if (_state.value.streaming && System.currentTimeMillis() - lastFrameAt > 4_000) {
                loseFrames(null)
            }
        }
    }

    private fun fail(error: Throwable) {
        _state.update { it.copy(loading = false, failure = classify(error)) }
    }

    fun pause() {
        val status = _state.value.status
        val controlling = _state.value.controlling
        invalidateInputs()
        pollJob?.cancel(); streamJob?.cancel(); heartbeatJob?.cancel(); inputJob?.cancel(); watchdogJob?.cancel()
        pollJob = null; streamJob = null; heartbeatJob = null; inputJob = null; watchdogJob = null
        if (controlling && status?.session != null) {
            val session = status.session
            CoroutineScope(Dispatchers.IO).launch {
                runCatching {
                    val reset = DesktopInputEvent(kind = "reset", sequence = ++inputSequence)
                    api.desktopInput(connection, credential, session, reset, UUID.randomUUID().toString())
                }
                runCatching { api.desktopControl(connection, credential, "release", session = session) }
            }
        }
        _state.value = DesktopState()
    }

    private fun classify(error: Throwable): DesktopFailure {
        if (error !is AgentHttpException) return DesktopFailure.Network
        val body = error.message.orEmpty()
        return when {
            body.contains("device_revoked") || error.status == 401 || error.status == 403 -> DesktopFailure.Revoked
            body.contains("desktop_permissions") -> DesktopFailure.Permissions
            body.contains("capture_busy") -> DesktopFailure.Busy
            body.contains("ownership_changed") -> DesktopFailure.Ownership
            else -> DesktopFailure.Unavailable
        }
    }
}
