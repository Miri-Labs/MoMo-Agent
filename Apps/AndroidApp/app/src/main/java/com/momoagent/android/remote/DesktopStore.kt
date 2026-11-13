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
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

enum class DesktopFailure { Revoked, Permissions, Busy, Ownership, Unavailable, Network }

data class DesktopState(
    val status: DesktopStatus? = null,
    val picture: Bitmap? = null,
    val loading: Boolean = true,
    val claiming: Boolean = false,
    val failure: DesktopFailure? = null,
) {
    val permitted: Boolean get() = status?.approved == true && status.screen && status.input
    val controlling: Boolean get() = status?.owner == "you" && status.active
    val otherDevice: Boolean get() = status?.owner == "other"
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
    private val inputSignal = Channel<Unit>(Channel.CONFLATED)
    private val inputQueue = ArrayDeque<DesktopInputEvent>()
    private val inputLock = Mutex()
    private var inputSequence = 0

    fun open() {
        if (pollJob?.isActive == true) return
        _state.value = DesktopState()
        pollJob = scope.launch { pollLoop() }
        streamJob = scope.launch { streamLoop() }
        if (inputJob == null) inputJob = scope.launch { inputLoop() }
    }

    fun retry() {
        pollJob?.cancel()
        streamJob?.cancel()
        pollJob = scope.launch { pollLoop() }
        streamJob = scope.launch { streamLoop() }
    }

    fun close() {
        val status = _state.value.status
        val controlling = _state.value.controlling
        pollJob?.cancel(); streamJob?.cancel(); heartbeatJob?.cancel(); inputJob?.cancel()
        pollJob = null; streamJob = null; heartbeatJob = null; inputJob = null
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
        val status = _state.value.status ?: return
        if (status.session == null) return
        if (!_state.value.controlling || !status.screen || !status.input) return
        inputSequence += 1
        val sequenced = event.copy(sequence = inputSequence)
        scope.launch {
            inputLock.withLock {
                if (sequenced.kind == "mouse_move" && inputQueue.peekLast()?.kind == "mouse_move") {
                    inputQueue.removeLast()
                } else if (inputQueue.size >= 128) {
                    inputQueue.removeFirst()
                }
                inputQueue.addLast(sequenced)
            }
            inputSignal.trySend(Unit)
        }
    }

    private suspend fun pollLoop() {
        while (scope.isActive) {
            try {
                val next = api.desktopStatus(connection, credential)
                applyStatus(next)
                _state.update { it.copy(loading = false, failure = null) }
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
                        _state.update { it.copy(picture = bitmap, loading = false, failure = null) }
                        runCatching {
                            api.desktopFrameAck(connection, credential, frame.streamID, frame.sequence)
                        }
                    }
                }
                backoff = 700L
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (_state.value.picture == null) fail(error)
            }
            delay(backoff)
            backoff = (backoff * 2).coerceAtMost(4_000)
        }
    }

    private suspend fun inputLoop() {
        while (true) {
            inputSignal.receive()
            while (true) {
                val event = inputLock.withLock { inputQueue.pollFirst() } ?: break
                val status = _state.value.status ?: break
                val session = status.session ?: break
                try {
                    api.desktopInput(connection, credential, session, event, UUID.randomUUID().toString())
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
        inputSequence = maxOf(inputSequence, next.inputSequence ?: 0)
        _state.update { it.copy(status = next, loading = false) }
        if (next.owner == "you" && next.active && next.session != null) startHeartbeat() else stopHeartbeat()
    }

    private fun startHeartbeat() {
        if (heartbeatJob?.isActive == true) return
        heartbeatJob = scope.launch {
            while (isActive) {
                delay(5_000)
                val status = _state.value.status ?: break
                val session = status.session ?: break
                if (!_state.value.controlling) break
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

    private fun fail(error: Throwable) {
        _state.update { it.copy(loading = false, failure = classify(error)) }
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
