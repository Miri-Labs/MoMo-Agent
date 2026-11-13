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
        val tailnet = invitation.network == "tailscale"
        if (uri.scheme == "http" &&
            !isLoopback(uri.host) &&
            !(tailnet && isTailnetHost(uri.host) && uri.port == 8767)
        ) {
            throw PairingCodeException(PairingFailure.HttpsRequired)
        }
        when (invitation.network) {
            null -> if (invitation.relayCode != null || invitation.tlsSHA256 != null) {
                throw PairingCodeException(PairingFailure.InvalidCode)
            }
            "tailscale" -> {
                if (uri.scheme != "http" || !isTailnetHost(uri.host) || uri.port != 8767) {
                    throw PairingCodeException(PairingFailure.InvalidCode)
                }
                if (invitation.relayCode != null || invitation.tlsSHA256 != null) {
                    throw PairingCodeException(PairingFailure.InvalidCode)
                }
            }
            "relay" -> if (invitation.relayCode.isNullOrEmpty() || invitation.tlsSHA256 != null) {
                throw PairingCodeException(PairingFailure.InvalidCode)
            }
            "lan" -> {
                if (uri.scheme != "https" || !isPrivateIPv4(uri.host)) {
                    throw PairingCodeException(PairingFailure.HttpsRequired)
                }
                if (invitation.tlsSHA256?.matches(Regex("[0-9a-f]{64}")) != true) {
                    throw PairingCodeException(PairingFailure.InvalidCode)
                }
            }
            else -> throw PairingCodeException(PairingFailure.InvalidCode)
        }
        return invitation
    }

    fun validateConnection(invitation: PairingInvitation, connection: AgentConnection): Boolean =
        connection.instanceID == invitation.instanceID &&
            connection.baseURL == invitation.endpoint &&
            connection.dataURL == invitation.endpoint.trimEnd('/') + "/context" &&
            connection.network == invitation.network &&
            connection.relayCode == invitation.relayCode &&
            connection.tlsSHA256 == invitation.tlsSHA256

    fun isPrivateIPv4(host: String?): Boolean {
        val octets = host?.split('.')?.map { it.toIntOrNull() ?: return false } ?: return false
        if (octets.size != 4 || octets.any { it !in 0..255 }) return false
        return octets[0] == 10 ||
            (octets[0] == 172 && octets[1] in 16..31) ||
            (octets[0] == 192 && octets[1] == 168)
    }

    fun isAllowedBaseURL(value: String, network: String?): Boolean {
        val uri = runCatching { URI(value) }.getOrNull() ?: return false
        return when {
            uri.scheme == "https" -> true
            uri.scheme == "http" && isLoopback(uri.host) -> true
            uri.scheme == "http" && network == "tailscale" &&
                isTailnetHost(uri.host) && uri.port == 8767 -> true
            else -> false
        }
    }

    fun isTailnetHost(host: String?): Boolean {
        val parts = host?.split('.') ?: return false
        if (parts.size != 4) return false
        val octets = parts.map { it.toIntOrNull() ?: return false }
        if (octets.any { it !in 0..255 } || octets.map { it.toString() } != parts) return false
        return octets[0] == 100 && octets[1] in 64..127
    }

    fun isLoopback(host: String?): Boolean =
        host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
}
