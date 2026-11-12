package com.momoagent.android.data

import java.net.URI
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json

enum class PairingFailure {
    InvalidCode,
    HttpsRequired,
    RelayUnsupported,
    Timeout,
    Denied,
    Identity,
    Unavailable,
}

class PairingCodeException(val failure: PairingFailure) : Exception(failure.name)

/** Pure validation for the QR payload. Kept free of Android types for JVM tests. */
object PairingCode {
    private val json = Json { ignoreUnknownKeys = true }
    private const val MAX_BYTES = 4_096
    private const val MAX_VALIDITY_SECONDS = 600.0

    fun parse(text: String, now: Double = System.currentTimeMillis() / 1_000.0): PairingInvitation {
        if (text.toByteArray(Charsets.UTF_8).size > MAX_BYTES) {
            throw PairingCodeException(PairingFailure.InvalidCode)
        }
        val invitation = try {
            json.decodeFromString<PairingInvitation>(text)
        } catch (_: Exception) {
            throw PairingCodeException(PairingFailure.InvalidCode)
        }
        if (invitation.version != 1 ||
            invitation.application != "MoMoAgent" ||
            invitation.expires <= now ||
            invitation.expires > now + MAX_VALIDITY_SECONDS
        ) {
            throw PairingCodeException(PairingFailure.InvalidCode)
        }
        val uri = try { URI(invitation.endpoint) } catch (_: Exception) {
            throw PairingCodeException(PairingFailure.InvalidCode)
        }
        val path = uri.path.orEmpty()
        if (uri.scheme !in setOf("https", "http") ||
            uri.host.isNullOrEmpty() ||
            uri.userInfo != null ||
            uri.query != null ||
            uri.fragment != null ||
            (path.isNotEmpty() && path != "/")
        ) {
            throw PairingCodeException(PairingFailure.InvalidCode)
        }
        if (uri.scheme == "http" && !isLoopback(uri.host)) {
            throw PairingCodeException(PairingFailure.HttpsRequired)
        }
        when (invitation.network) {
            null -> if (invitation.relayCode != null) throw PairingCodeException(PairingFailure.InvalidCode)
            "tailscale" -> if (invitation.relayCode != null) throw PairingCodeException(PairingFailure.InvalidCode)
            "relay" -> if (invitation.relayCode.isNullOrEmpty()) throw PairingCodeException(PairingFailure.InvalidCode)
            else -> throw PairingCodeException(PairingFailure.InvalidCode)
        }
        return invitation
    }

    fun validateConnection(invitation: PairingInvitation, connection: AgentConnection): Boolean =
        connection.instanceID == invitation.instanceID &&
            connection.baseURL == invitation.endpoint &&
            connection.dataURL == invitation.endpoint.trimEnd('/') + "/context" &&
            connection.network == invitation.network &&
            connection.relayCode == invitation.relayCode

    fun isSecureBaseURL(value: String): Boolean {
        val uri = runCatching { URI(value) }.getOrNull() ?: return false
        return uri.scheme == "https" || (uri.scheme == "http" && isLoopback(uri.host))
    }

    fun isLoopback(host: String?): Boolean =
        host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
}
