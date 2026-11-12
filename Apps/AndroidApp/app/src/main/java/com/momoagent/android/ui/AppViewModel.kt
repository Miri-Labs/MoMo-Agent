package com.momoagent.android.ui

import android.app.Application
import android.os.Build
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.momoagent.android.data.AgentApi
import com.momoagent.android.data.AgentConnection
import com.momoagent.android.data.AgentHttpException
import com.momoagent.android.data.PairingCode
import com.momoagent.android.data.PairingCodeException
import com.momoagent.android.data.PairingFailure
import com.momoagent.android.data.PairingInvitation
import com.momoagent.android.data.PairingStore
import com.momoagent.android.data.StoredPairing
import java.security.SecureRandom
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class ChatMessage(
    val id: String,
    val role: String,
    val content: String,
)

data class PendingReply(
    val operationID: String,
    val text: String = "",
)

data class ChatState(
    val connection: AgentConnection,
    val messages: List<ChatMessage> = emptyList(),
    val pending: List<PendingReply> = emptyList(),
    val loading: Boolean = true,
    val failure: ChatFailure? = null,
)

enum class ChatFailure { Load, Send }

enum class PairingStage { Reading, Contacting, WaitingForApproval }

data class PairingState(
    val stage: PairingStage = PairingStage.Reading,
    val code: String? = null,
    val failure: PairingFailure? = null,
)

sealed interface AppState {
    data object Loading : AppState
    data object Unpaired : AppState
    data class Pairing(val value: PairingState = PairingState()) : AppState
    data class Chat(val value: ChatState) : AppState
}

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val api = AgentApi()
    private val store = PairingStore(application)
    private val _state = MutableStateFlow<AppState>(AppState.Loading)
    val state: StateFlow<AppState> = _state

    private var pairing: StoredPairing? = null
    private var pairingJob: Job? = null

    init {
        restore()
    }

    private fun restore() {
        viewModelScope.launch {
            val saved = withContext(Dispatchers.IO) { store.load() }
            if (saved == null) {
                _state.value = AppState.Unpaired
                return@launch
            }
            pairing = saved
            _state.value = AppState.Chat(ChatState(saved.connection))
            refresh(saved)
        }
    }

    fun beginPairing(payload: String) {
        pairingJob?.cancel()
        _state.value = AppState.Pairing()
        pairingJob = viewModelScope.launch {
            try {
                val saved = withContext(Dispatchers.IO) {
                    pair(payload) { stage, code ->
                        if (_state.value is AppState.Pairing) {
                            _state.value = AppState.Pairing(PairingState(stage = stage, code = code))
                        }
                    }.also { store.save(it.connection, it.credential) }
                }
                if (!isActive) return@launch
                pairing = saved
                _state.value = AppState.Chat(ChatState(saved.connection))
                refresh(saved)
            } catch (error: CancellationException) {
                throw error
            } catch (error: PairingException) {
                if (isActive) _state.value = AppState.Pairing(PairingState(failure = error.failure))
            } catch (_: Exception) {
                if (isActive) _state.value = AppState.Pairing(PairingState(failure = PairingFailure.Unavailable))
            }
        }
    }

    fun cancelPairing() {
        pairingJob?.cancel()
        pairingJob = null
        _state.value = AppState.Unpaired
    }

    private fun pair(
        payload: String,
        emit: (PairingStage, String?) -> Unit,
    ): StoredPairing {
        val invitation = try {
            PairingCode.parse(payload)
        } catch (error: PairingCodeException) {
            throw PairingException(error.failure)
        }
        if (invitation.network == "relay") throw PairingException(PairingFailure.RelayUnsupported)
        val credential = randomCredential()
        emit(PairingStage.Contacting, null)
        var receipt = try {
            api.pairRequest(invitation, deviceName(), credential)
        } catch (error: AgentHttpException) {
            throw httpFailure(error)
        } catch (_: Exception) {
            throw PairingException(PairingFailure.Unavailable)
        }
        receipt.connection?.let { return validate(invitation, it, credential) }
        emit(PairingStage.WaitingForApproval, receipt.code)
        val deadline = System.currentTimeMillis() + 120_000
        while (true) {
            if (System.currentTimeMillis() > deadline) throw PairingException(PairingFailure.Timeout)
            Thread.sleep(1_000)
            receipt = try {
                api.pairStatus(invitation, receipt.id, credential)
            } catch (error: AgentHttpException) {
                throw httpFailure(error)
            } catch (_: Exception) {
                throw PairingException(PairingFailure.Unavailable)
            }
            receipt.connection?.let { return validate(invitation, it, credential) }
            if (receipt.state == "denied" || receipt.state == "expired") {
                throw PairingException(PairingFailure.Denied)
            }
        }
    }

    private fun validate(
        invitation: PairingInvitation,
        connection: AgentConnection,
        credential: String,
    ): StoredPairing {
        if (!PairingCode.validateConnection(invitation, connection)) {
            throw PairingException(PairingFailure.Identity)
        }
        if (!PairingCode.isSecureBaseURL(connection.baseURL)) {
            throw PairingException(PairingFailure.HttpsRequired)
        }
        return StoredPairing(connection, credential)
    }

    fun send(text: String) {
        val saved = pairing ?: return
        val chat = (_state.value as? AppState.Chat)?.value ?: return
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return
        val operationID = UUID.randomUUID().toString().lowercase()
        val localID = "local-$operationID"
        updateChat(saved) { state ->
            state.copy(
                messages = state.messages + ChatMessage(localID, "user", trimmed),
                pending = state.pending + PendingReply(operationID),
                failure = null,
            )
        }
        viewModelScope.launch {
            try {
                api.submitMessage(chat.connection, saved.credential, trimmed, operationID).collect { event ->
                    when (event.event) {
                        "message.delta" -> appendPending(operationID, event.delta.orEmpty())
                        "message.interim" -> setPending(operationID, event.text.orEmpty())
                        "run.completed", "run.failed", "run.cancelled", "run.interrupted" ->
                            finishRun(operationID, saved)
                        else -> Unit
                    }
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                updateChat(saved) { state ->
                    state.copy(
                        messages = state.messages.filterNot { it.id == localID },
                        pending = state.pending.filterNot { it.operationID == operationID },
                        failure = ChatFailure.Send,
                    )
                }
            }
        }
    }

    private fun finishRun(operationID: String, saved: StoredPairing) {
        updateChat(saved) { state ->
            state.copy(pending = state.pending.filterNot { it.operationID == operationID })
        }
        refresh(saved)
    }

    private fun refresh(saved: StoredPairing) {
        viewModelScope.launch {
            try {
                val snapshot = withContext(Dispatchers.IO) { api.snapshot(saved.connection, saved.credential) }
                val messages = snapshot.messages.data
                    .sortedBy { it.seq }
                    .map { ChatMessage(it.id, it.role, it.content) }
                updateChat(saved) { state ->
                    state.copy(messages = messages, loading = false, failure = null)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                updateChat(saved) { state ->
                    state.copy(loading = false, failure = ChatFailure.Load)
                }
            }
        }
    }

    fun retryLoad() {
        pairing?.let(::refresh)
    }

    fun dismissChatFailure() {
        _state.update { current ->
            val chat = (current as? AppState.Chat)?.value ?: return@update current
            AppState.Chat(chat.copy(failure = null))
        }
    }

    fun unpair() {
        pairingJob?.cancel()
        pairingJob = null
        pairing = null
        viewModelScope.launch { withContext(Dispatchers.IO) { store.clear() } }
        _state.value = AppState.Unpaired
    }

    private fun appendPending(operationID: String, delta: String) {
        _state.update { current ->
            val chat = (current as? AppState.Chat)?.value ?: return@update current
            AppState.Chat(chat.copy(pending = chat.pending.map { reply ->
                if (reply.operationID == operationID) reply.copy(text = reply.text + delta) else reply
            }))
        }
    }

    private fun setPending(operationID: String, value: String) {
        if (value.isEmpty()) return
        _state.update { current ->
            val chat = (current as? AppState.Chat)?.value ?: return@update current
            AppState.Chat(chat.copy(pending = chat.pending.map { reply ->
                if (reply.operationID == operationID) reply.copy(text = value) else reply
            }))
        }
    }

    private fun updateChat(saved: StoredPairing, transform: (ChatState) -> ChatState) {
        _state.update { current ->
            val chat = (current as? AppState.Chat)?.value ?: return@update current
            if (chat.connection.instanceID != saved.connection.instanceID) current
            else AppState.Chat(transform(chat))
        }
    }

    private fun httpFailure(error: AgentHttpException): PairingException =
        if (error.status in setOf(400, 401, 403, 404, 410)) {
            PairingException(PairingFailure.InvalidCode)
        } else {
            PairingException(PairingFailure.Unavailable)
        }

    private fun deviceName(): String = "Android · ${Build.MODEL}"

    private fun randomCredential(): String {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }
}

private class PairingException(val failure: PairingFailure) : Exception(failure.name)
