package com.momoagent.android.data

import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import okhttp3.OkHttpClient

/**
 * Trusts exactly the self-signed certificate whose SHA-256 fingerprint is in
 * the pairing code. The certificate is still checked for validity; the pin is
 * what replaces the public CA chain for a LAN-only Mac.
 */
fun pinnedClient(base: OkHttpClient, fingerprint: String): OkHttpClient {
    val digest = fingerprint.hexToBytes()
    val trust = PinnedTrustManager(digest)
    val context = SSLContext.getInstance("TLS").apply {
        init(null, arrayOf<TrustManager>(trust), SecureRandom())
    }
    return base.newBuilder()
        .sslSocketFactory(context.socketFactory, trust)
        .build()
}

private class PinnedTrustManager(private val digest: ByteArray) : X509TrustManager {
    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        throw CertificateException("Client certificates are not accepted")
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        val leaf = chain?.firstOrNull() ?: throw CertificateException("Missing server certificate")
        leaf.checkValidity()
        val actual = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
        if (!MessageDigest.isEqual(actual, digest)) {
            throw CertificateException("Server certificate does not match the pairing code")
        }
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

private fun String.hexToBytes(): ByteArray {
    require(length % 2 == 0) { "Invalid certificate fingerprint" }
    return ByteArray(length / 2) { index ->
        substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}
