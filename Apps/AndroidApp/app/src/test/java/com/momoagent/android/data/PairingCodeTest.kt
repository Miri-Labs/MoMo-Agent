package com.momoagent.android.data

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingCodeTest {
    private val now = 1_800_000_000.0

    private fun code(
        endpoint: String = "http://100.64.0.1:8767",
        network: String? = "tailscale",
        relay: String? = null,
        tls: String? = null,
        expires: Double = now + 120,
    ): String {
        val fields = buildList {
            add("\"version\":1")
            add("\"application\":\"MoMoAgent\"")
            add("\"invitation_id\":\"11111111-1111-1111-1111-111111111111\"")
            add("\"endpoint\":\"$endpoint\"")
            add("\"instance_id\":\"22222222-2222-2222-2222-222222222222\"")
            add("\"expires\":$expires")
            if (network != null) add("\"network\":\"$network\"")
            if (relay != null) add("\"relay_code\":\"$relay\"")
            if (tls != null) add("\"tls_sha256\":\"$tls\"")
        }
        return "{" + fields.joinToString(",") + "}"
    }

    @Test
    fun acceptsTailscaleInvitation() {
        val invitation = PairingCode.parse(code(), now)
        assertEquals("tailscale", invitation.network)
        assertEquals("http://100.64.0.1:8767", invitation.endpoint)
    }

    @Test
    fun tailscaleRequiresTailnetHttpOrigin() {
        val httpsError = assertThrows(PairingCodeException::class.java) {
            PairingCode.parse(code(endpoint = "https://100.64.0.1:8767"), now)
        }
        assertEquals(PairingFailure.InvalidCode, httpsError.failure)

        val publicError = assertThrows(PairingCodeException::class.java) {
            PairingCode.parse(code(endpoint = "http://100.200.0.1:8767"), now)
        }
        assertEquals(PairingFailure.HttpsRequired, publicError.failure)

        val portError = assertThrows(PairingCodeException::class.java) {
            PairingCode.parse(code(endpoint = "http://100.64.0.1:80"), now)
        }
        assertEquals(PairingFailure.HttpsRequired, portError.failure)
    }

    @Test
    fun allowedBaseURLFollowsTheNetworkType() {
        assertTrue(PairingCode.isAllowedBaseURL("http://100.64.0.1:8767", "tailscale"))
        assertFalse(PairingCode.isAllowedBaseURL("http://100.64.0.1:8767", null))
        assertTrue(PairingCode.isAllowedBaseURL("https://example.com", null))
        assertTrue(PairingCode.isAllowedBaseURL("http://127.0.0.1:8769", null))
        assertFalse(PairingCode.isAllowedBaseURL("http://100.64.0.1:80", "tailscale"))
    }

    @Test
    fun tailnetAddressesAreRecognized() {
        assertTrue(PairingCode.isTailnetHost("100.64.0.1"))
        assertTrue(PairingCode.isTailnetHost("100.127.255.254"))
        assertFalse(PairingCode.isTailnetHost("100.63.0.1"))
        assertFalse(PairingCode.isTailnetHost("100.128.0.1"))
        assertFalse(PairingCode.isTailnetHost("192.168.1.1"))
    }

    @Test
    fun rejectsExpiredCode() {
        val error = assertThrows(PairingCodeException::class.java) {
            PairingCode.parse(code(expires = now - 1), now)
        }
        assertEquals(PairingFailure.InvalidCode, error.failure)
    }

    @Test
    fun rejectsCodeThatLivesTooLong() {
        val error = assertThrows(PairingCodeException::class.java) {
            PairingCode.parse(code(expires = now + 601), now)
        }
        assertEquals(PairingFailure.InvalidCode, error.failure)
    }

    @Test
    fun rejectsCleartextRemoteEndpoint() {
        val error = assertThrows(PairingCodeException::class.java) {
            PairingCode.parse(code(endpoint = "http://192.168.1.10:8765", network = null), now)
        }
        assertEquals(PairingFailure.HttpsRequired, error.failure)
    }

    @Test
    fun acceptsLoopbackForDevelopment() {
        val invitation = PairingCode.parse(code(endpoint = "http://127.0.0.1:8765", network = null), now)
        assertEquals("http://127.0.0.1:8765", invitation.endpoint)
    }

    @Test
    fun relayRequiresCode() {
        val error = assertThrows(PairingCodeException::class.java) {
            PairingCode.parse(code(endpoint = "https://relay.example.com", network = "relay"), now)
        }
        assertEquals(PairingFailure.InvalidCode, error.failure)
    }

    @Test
    fun relayCodeIsAccepted() {
        val invitation = PairingCode.parse(
            code(endpoint = "https://relay.example.com", network = "relay", relay = "abc"),
            now,
        )
        assertEquals("abc", invitation.relayCode)
    }

    @Test
    fun connectionMustMatchInvitation() {
        val invitation = PairingCode.parse(code(), now)
        val connection = AgentConnection(
            workspaceID = "w",
            assistantID = "a",
            instanceID = invitation.instanceID,
            baseURL = invitation.endpoint,
            dataURL = "http://100.64.0.1:8767/context",
            eventTransport = "sse",
            network = "tailscale",
            relayCode = null,
        )
        assertTrue(PairingCode.validateConnection(invitation, connection))
    }

    @Test
    fun connectionRejectsDifferentDataURL() {
        val invitation = PairingCode.parse(code(), now)
        val connection = AgentConnection(
            workspaceID = "w",
            assistantID = "a",
            instanceID = invitation.instanceID,
            baseURL = invitation.endpoint,
            dataURL = "https://elsewhere.example.com/context",
            eventTransport = "sse",
            network = "tailscale",
            relayCode = null,
        )
        assertEquals(false, PairingCode.validateConnection(invitation, connection))
    }

    @Test
    fun acceptsLanInvitationWithPinnedCertificate() {
        val fingerprint = "a".repeat(64)
        val invitation = PairingCode.parse(
            code(endpoint = "https://192.168.1.10:8769", network = "lan", tls = fingerprint),
            now,
        )
        assertEquals("lan", invitation.network)
        assertEquals(fingerprint, invitation.tlsSHA256)
    }

    @Test
    fun lanRequiresFingerprint() {
        val error = assertThrows(PairingCodeException::class.java) {
            PairingCode.parse(code(endpoint = "https://192.168.1.10:8769", network = "lan"), now)
        }
        assertEquals(PairingFailure.InvalidCode, error.failure)
    }

    @Test
    fun lanRequiresPrivateAddress() {
        val error = assertThrows(PairingCodeException::class.java) {
            PairingCode.parse(
                code(endpoint = "https://203.0.113.10:8769", network = "lan", tls = "a".repeat(64)),
                now,
            )
        }
        assertEquals(PairingFailure.HttpsRequired, error.failure)
    }

    @Test
    fun lanRejectsCleartext() {
        val error = assertThrows(PairingCodeException::class.java) {
            PairingCode.parse(
                code(endpoint = "http://192.168.1.10:8769", network = "lan", tls = "a".repeat(64)),
                now,
            )
        }
        assertEquals(PairingFailure.HttpsRequired, error.failure)
    }

    @Test
    fun nonLanNetworkRejectsFingerprint() {
        val error = assertThrows(PairingCodeException::class.java) {
            PairingCode.parse(code(tls = "a".repeat(64)), now)
        }
        assertEquals(PairingFailure.InvalidCode, error.failure)
    }

    @Test
    fun lanConnectionMustMatchFingerprint() {
        val fingerprint = "a".repeat(64)
        val invitation = PairingCode.parse(
            code(endpoint = "https://192.168.1.10:8769", network = "lan", tls = fingerprint),
            now,
        )
        val connection = AgentConnection(
            workspaceID = "w",
            assistantID = "a",
            instanceID = invitation.instanceID,
            baseURL = invitation.endpoint,
            dataURL = "https://192.168.1.10:8769/context",
            eventTransport = "sse",
            network = "lan",
            tlsSHA256 = "b".repeat(64),
        )
        assertFalse(PairingCode.validateConnection(invitation, connection))
        assertTrue(PairingCode.validateConnection(invitation, connection.copy(tlsSHA256 = fingerprint)))
    }

    @Test
    fun privateAddressRangesAreRecognized() {
        assertTrue(PairingCode.isPrivateIPv4("10.2.3.4"))
        assertTrue(PairingCode.isPrivateIPv4("172.16.8.4"))
        assertTrue(PairingCode.isPrivateIPv4("192.168.1.10"))
        assertFalse(PairingCode.isPrivateIPv4("172.32.0.1"))
        assertFalse(PairingCode.isPrivateIPv4("8.8.8.8"))
        assertFalse(PairingCode.isPrivateIPv4("hello"))
    }

    @Test
    fun messageBodyUsesWireNames() {
        val json = Json { encodeDefaults = true; explicitNulls = false }
        assertEquals(
            """{"operation_id":"op","content":"hi","intent":"new"}""",
            json.encodeToString(MessageBody("op", "hi")),
        )
    }
}
