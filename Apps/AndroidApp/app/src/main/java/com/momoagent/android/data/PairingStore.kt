package com.momoagent.android.data

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

data class StoredPairing(
    val connection: AgentConnection,
    val credential: String,
)

@Serializable
data class StoredPending(
    val invitation: PairingInvitation,
    val credential: String,
    val requestID: String? = null,
)

/** Stores the Mac connection and pending pairing behind an Android Keystore key. */
class PairingStore(context: Context) {
    private val json = Json { ignoreUnknownKeys = true }

    private val prefs: SharedPreferences = run {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            "momo_secure",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    fun load(): StoredPairing? {
        val credential = prefs.getString(KEY_CREDENTIAL, null) ?: return null
        val raw = prefs.getString(KEY_CONNECTION, null) ?: return null
        return runCatching {
            StoredPairing(json.decodeFromString<AgentConnection>(raw), credential)
        }.getOrNull()
    }

    fun save(connection: AgentConnection, credential: String) {
        prefs.edit {
            putString(KEY_CONNECTION, json.encodeToString(connection))
            putString(KEY_CREDENTIAL, credential)
        }
    }

    fun clear() {
        prefs.edit {
            remove(KEY_CONNECTION)
            remove(KEY_CREDENTIAL)
            remove(KEY_PENDING)
        }
    }

    fun loadPending(): StoredPending? {
        val raw = prefs.getString(KEY_PENDING, null) ?: return null
        return runCatching { json.decodeFromString<StoredPending>(raw) }.getOrNull()
    }

    fun savePending(pending: StoredPending) {
        prefs.edit { putString(KEY_PENDING, json.encodeToString(pending)) }
    }

    fun clearPending() {
        prefs.edit { remove(KEY_PENDING) }
    }

    fun loadSetupStep(): String? = prefs.getString(KEY_SETUP, null)

    fun saveSetupStep(step: String) {
        prefs.edit { putString(KEY_SETUP, step) }
    }

    fun loadReadingPosition(sessionID: String): String? = prefs.getString("reading.$sessionID", null)

    fun saveReadingPosition(sessionID: String, value: String?) {
        prefs.edit {
            if (value == null) remove("reading.$sessionID") else putString("reading.$sessionID", value)
        }
    }

    private companion object {
        const val KEY_CONNECTION = "connection"
        const val KEY_CREDENTIAL = "credential"
        const val KEY_PENDING = "pending"
        const val KEY_SETUP = "setup"
    }
}
