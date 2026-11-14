package com.momoagent.android.ui

import android.app.Application
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.momoagent.android.data.AgentApi
import com.momoagent.android.data.AgentAttachment
import com.momoagent.android.data.AgentConnection
import com.momoagent.android.data.AgentHttpException
import com.momoagent.android.data.PairingCode
import com.momoagent.android.data.PairingStore
import com.momoagent.android.data.StoredPairing
import com.momoagent.android.remote.ConnectionState
import com.momoagent.android.remote.ContextStore
import com.momoagent.android.remote.ConversationStore
import com.momoagent.android.remote.PairingManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

enum class SetupStep { Welcome, Connect, Completed, Deferred }

class AppViewModel(application: Application) : AndroidViewModel(application) {
    private val api = AgentApi()
    private val store = PairingStore(application)
    private val json = Json { ignoreUnknownKeys = true }
    val pairing = PairingManager(api, store, viewModelScope)

    var setup by mutableStateOf(SetupStep.Welcome)
        private set
    var storedPairing by mutableStateOf<StoredPairing?>(null)
        private set
    var conversationStore by mutableStateOf<ConversationStore?>(null)
        private set
    var contextStore by mutableStateOf<ContextStore?>(null)
        private set
    var manualFailure by mutableStateOf<String?>(null)
        private set
    var manualConnecting by mutableStateOf(false)
        private set
    var manualSuccess by mutableIntStateOf(0)
        private set
    var unpairFailed by mutableStateOf(false)
        private set

    init {
        pairing.onConnected = { saved ->
            storedPairing = saved
            createStores(saved)
        }
        val saved = store.load()
        if (saved != null) {
            storedPairing = saved
            setup = SetupStep.Completed
            createStores(saved)
        } else {
            setup = when (store.loadSetupStep()) {
                "connect" -> SetupStep.Connect
                "deferred" -> SetupStep.Deferred
                else -> SetupStep.Welcome
            }
        }
    }

    fun onStart() {
        val saved = storedPairing
        if (saved != null) {
            conversationStore?.start()
            contextStore?.loadAll()
        } else if (setup == SetupStep.Connect) {
            pairing.resume(deviceName())
        }
    }

    fun onStop() {
        conversationStore?.stop()
        if (pairing.state.value.stage != com.momoagent.android.remote.PairingStage.Approved) {
            pairing.cancel()
        }
    }

    fun advance(step: SetupStep) {
        setup = step
        store.saveSetupStep(
            when (step) {
                SetupStep.Welcome -> "welcome"
                SetupStep.Connect -> "connect"
                SetupStep.Completed -> "completed"
                SetupStep.Deferred -> "deferred"
            },
        )
    }

    fun finishPairing() = advance(SetupStep.Completed)

    fun deferPairing() {
        pairing.clear()
        advance(SetupStep.Deferred)
    }

    fun scan(payload: String) {
        pairing.scan(payload)
    }

    fun retryPairing() {
        pairing.resume(deviceName())
    }

    fun clearPairing() {
        pairing.clear()
    }

    fun reconnect() {
        conversationStore?.refresh()
        contextStore?.loadAll()
    }

    fun send() {
        conversationStore?.send()
    }

    fun setDraft(value: String) {
        conversationStore?.setDraft(value)
    }

    fun addAttachment(value: AgentAttachment) {
        conversationStore?.addAttachment(value)
    }

    fun removeAttachment(id: String) {
        conversationStore?.removeAttachment(id)
    }

    fun retry(operationID: String) {
        conversationStore?.retry(operationID)
    }

    fun dismissChatFailure() {
        conversationStore?.dismissFailure()
    }

    fun dismissProviderNotice() {
        conversationStore?.dismissProviderNotice()
    }

    fun saveReadingPosition(value: String?) {
        conversationStore?.saveReadingPosition(value)
    }

    fun refreshAll() {
        conversationStore?.refresh()
        contextStore?.loadAll()
    }

    fun unpair() {
        val saved = storedPairing
        if (saved == null) {
            clearLocal()
            return
        }
        unpairFailed = false
        viewModelScope.launch {
            val revoked = try {
                withContext(Dispatchers.IO) { api.revoke(saved.connection, saved.credential) }
                true
            } catch (error: AgentHttpException) {
                error.status == 401 || error.status == 404
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                false
            }
            if (!revoked) {
                unpairFailed = true
                return@launch
            }
            clearLocal()
        }
    }

    private fun clearLocal() {
        conversationStore?.stop()
        conversationStore = null
        contextStore = null
        storedPairing = null
        store.clear()
        pairing.clear()
        advance(SetupStep.Connect)
    }

    fun manualConnect(configuration: String, credential: String) {
        if (manualConnecting) return
        manualFailure = null
        manualConnecting = true
        viewModelScope.launch {
            try {
                val connection = json.decodeFromString<AgentConnection>(configuration.trim())
                val key = credential.trim()
                if (key.isEmpty()) throw IllegalArgumentException("credential required")
                if (!PairingCode.isAllowedBaseURL(connection.baseURL, connection.network)) {
                    throw IllegalArgumentException("connection address is not allowed")
                }
                withContext(Dispatchers.IO) {
                    val capabilities = api.capabilities(connection, key)
                    if (capabilities.features.runSubmission != true ||
                        capabilities.features.runsIdempotency?.durable != true
                    ) {
                        throw IllegalArgumentException("Mac Agent does not support durable runs")
                    }
                    val status = api.contextStatus(connection, key)
                    if (status.workspaceID != connection.workspaceID || !status.sourceSync) {
                        throw IllegalArgumentException("Mac context identity mismatch")
                    }
                }
                store.save(connection, key)
                store.saveSetupStep("completed")
                storedPairing = StoredPairing(connection, key)
                setup = SetupStep.Completed
                createStores(storedPairing!!)
                manualSuccess += 1
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                manualFailure = error.message ?: "connection failed"
            } finally {
                manualConnecting = false
            }
        }
    }

    private fun createStores(saved: StoredPairing) {
        conversationStore?.stop()
        conversationStore = ConversationStore(
            api = api,
            scope = viewModelScope,
            connection = saved.connection,
            credential = saved.credential,
            loadReadingPosition = { store.loadReadingPosition(saved.connection.assistantID) },
            saveReadingPosition = { value -> store.saveReadingPosition(saved.connection.assistantID, value) },
        )
        contextStore = ContextStore(api, viewModelScope, saved.connection, saved.credential)
        conversationStore?.start()
        contextStore?.loadAll()
    }

    private fun deviceName(): String = "Android · ${Build.MODEL}"
}
