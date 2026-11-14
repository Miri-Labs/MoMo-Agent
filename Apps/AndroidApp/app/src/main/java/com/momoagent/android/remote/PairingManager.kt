package com.momoagent.android.remote

import com.momoagent.android.data.AgentApi
import com.momoagent.android.data.AgentHttpException
import com.momoagent.android.data.PairingCode
import com.momoagent.android.data.PairingCodeException
import com.momoagent.android.data.PairingFailure
import com.momoagent.android.data.PairingInvitation
import com.momoagent.android.data.PairingReceipt
import com.momoagent.android.data.PairingStore
import com.momoagent.android.data.StoredPairing
import com.momoagent.android.data.StoredPending
import java.security.SecureRandom
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class PairingStage { Idle, Contacting, Waiting, Approved, Ended }

data class PairingState(
    val stage: PairingStage = PairingStage.Idle,
    val code: String? = null,
    val receiptState: String? = null,
    val failure: PairingFailure? = null,
    val transient: Boolean = false,
    val network: String? = null,
)

/** Mirrors PhonePairing: pending invitation, credential and request survive restarts. */
class PairingManager(
    private val api: AgentApi,
    private val store: PairingStore,
    private val scope: CoroutineScope,
) {
    private val _state = MutableStateFlow(PairingState())
    val state: StateFlow<PairingState> = _state

    private var job: Job? = null
    var onConnected: ((StoredPairing) -> Unit)? = null

    fun scan(payload: String) {
        val invitation = try {
            PairingCode.parse(payload)
        } catch (error: PairingCodeException) {
            _state.value = PairingState(failure = error.failure)
            return
        }
        if (invitation.network == "relay") {
            _state.value = PairingState(failure = PairingFailure.RelayUnsupported, network = invitation.network)
            return
        }
        val previous = store.loadPending()
        val reusable = previous?.takeIf {
            it.invitation.instanceID == invitation.instanceID &&
                it.invitation.endpoint == invitation.endpoint &&
                it.invitation.network == invitation.network &&
                it.invitation.relayCode == invitation.relayCode
        }
        val pending = StoredPending(
            invitation = invitation,
            credential = reusable?.credential ?: randomCredential(),
            requestID = if (reusable?.invitation?.invitationID == invitation.invitationID) reusable.requestID else null,
        )
        store.savePending(pending)
        _state.value = PairingState(stage = PairingStage.Contacting, network = invitation.network)
        resume()
    }

    fun resume(deviceName: String = "Android") {
        job?.cancel()
        val pending = store.loadPending() ?: return
        _state.value = PairingState(
            stage = PairingStage.Contacting,
            code = _state.value.code,
            network = pending.invitation.network,
        )
        job = scope.launch {
            try {
                poll(pending, deviceName)
            } catch (error: CancellationException) {
                throw error
            } catch (error: PairingCodeException) {
                _state.value = PairingState(failure = error.failure, network = pending.invitation.network)
            } catch (error: AgentHttpException) {
                val invalid = error.status in setOf(400, 401, 403, 404, 410)
                _state.value = PairingState(
                    failure = if (invalid) PairingFailure.InvalidCode else PairingFailure.Unavailable,
                    network = pending.invitation.network,
                )
            } catch (error: Exception) {
                _state.value = PairingState(
                    failure = PairingFailure.Unavailable,
                    transient = true,
                    network = pending.invitation.network,
                )
            }
        }
    }

    fun cancel() {
        job?.cancel()
        job = null
        _state.value = PairingState()
    }

    fun clear() {
        job?.cancel()
        job = null
        store.clearPending()
        _state.value = PairingState()
    }

    private suspend fun poll(initial: StoredPending, deviceName: String) {
        var pending = initial
        if (pending.requestID == null) {
            val receipt = retryTransient(pending.invitation.network) {
                withContext(Dispatchers.IO) {
                    api.pairRequest(pending.invitation, deviceName, pending.credential)
                }
            }
            pending = pending.copy(requestID = receipt.id)
            store.savePending(pending)
            _state.value = PairingState(
                stage = PairingStage.Waiting,
                code = receipt.code,
                receiptState = receipt.state,
                network = pending.invitation.network,
            )
        }
        val requestID = pending.requestID ?: throw PairingCodeException(PairingFailure.InvalidCode)
        while (true) {
            val receipt = retryTransient(pending.invitation.network) {
                withContext(Dispatchers.IO) {
                    api.pairStatus(pending.invitation, requestID, pending.credential)
                }
            }
            _state.value = PairingState(
                stage = PairingStage.Waiting,
                code = receipt.code,
                receiptState = receipt.state,
                network = pending.invitation.network,
            )
            when (receipt.state) {
                "approved" -> {
                    val connection = receipt.connection
                        ?: throw PairingCodeException(PairingFailure.Identity)
                    if (!PairingCode.validateConnection(pending.invitation, connection) ||
                        !PairingCode.isAllowedBaseURL(connection.baseURL, pending.invitation.network)
                    ) {
                        throw PairingCodeException(PairingFailure.Identity)
                    }
                    val saved = StoredPairing(connection, pending.credential)
                    store.save(connection, pending.credential)
                    store.clearPending()
                    _state.value = PairingState(
                        stage = PairingStage.Approved,
                        code = receipt.code,
                        receiptState = receipt.state,
                        network = pending.invitation.network,
                    )
                    onConnected?.invoke(saved)
                    return
                }
                "pending" -> delay(2_000)
                "expired" -> {
                    _state.value = PairingState(
                        stage = PairingStage.Ended,
                        failure = PairingFailure.InvalidCode,
                        network = pending.invitation.network,
                    )
                    return
                }
                "rejected", "revoked" -> {
                    _state.value = PairingState(
                        stage = PairingStage.Ended,
                        failure = PairingFailure.Denied,
                        network = pending.invitation.network,
                    )
                    return
                }
                else -> throw PairingCodeException(PairingFailure.Unavailable)
            }
        }
    }

    private suspend fun <T> retryTransient(network: String?, operation: suspend () -> T): T {
        val attempts = if (network == "tailscale") 4 else 1
        var last: Exception? = null
        for (index in 0 until attempts) {
            try {
                return operation()
            } catch (error: CancellationException) {
                throw error
            } catch (error: AgentHttpException) {
                if (error.status in 400..499) throw error
                last = error
            } catch (error: Exception) {
                last = error
            }
            if (index < attempts - 1) delay(2_000)
        }
        throw last ?: PairingCodeException(PairingFailure.Unavailable)
    }

    private fun randomCredential(): String {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }
}
