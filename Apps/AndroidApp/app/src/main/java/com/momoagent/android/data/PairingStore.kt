package com.momoagent.android.data

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

data class StoredPairing(
    val connection: AgentConnection,
    val credential: String,
)

/** Stores the Mac connection and its bearer credential behind an Android Keystore key. */
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
        prefs.edit { clear() }
    }

    private companion object {
        const val KEY_CONNECTION = "connection"
        const val KEY_CREDENTIAL = "credential"
    }
}
