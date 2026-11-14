package com.momoagent.android.data

import java.net.URI
import java.net.URLDecoder

data class RecordingLink(
    val sessionID: String,
    val spanID: String,
    val version: Long,
    val generation: Long,
)

sealed interface AgentLink {
    data class Recording(val link: RecordingLink) : AgentLink
    data class Memory(val path: String) : AgentLink
    data class Web(val url: String) : AgentLink
    data object Unavailable : AgentLink
}

private val uuidPattern = Regex(
    "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
)

/** Parses the links emitted by the chat renderer without trusting the surrounding text. */
fun parseAgentLink(raw: String): AgentLink {
    val uri = runCatching { URI(raw) }.getOrNull() ?: return AgentLink.Unavailable
    return when (uri.scheme?.lowercase()) {
        "http", "https" -> if (!uri.host.isNullOrBlank()) AgentLink.Web(raw) else AgentLink.Unavailable
        "momoagent" -> parseInternalLink(uri)
        else -> AgentLink.Unavailable
    }
}

private fun parseInternalLink(uri: URI): AgentLink {
    if (uri.rawUserInfo != null || uri.port != -1 || uri.rawFragment != null) return AgentLink.Unavailable
    return when (uri.host?.lowercase()) {
        "source" -> parseRecordingLink(uri)
        "memory" -> parseMemoryLink(uri)
        else -> AgentLink.Unavailable
    }
}

private fun parseRecordingLink(uri: URI): AgentLink {
    val parts = uri.rawPath.orEmpty().split('/')
    if (parts.size != 3 || parts[0].isNotEmpty() ||
        !uuidPattern.matches(parts[1]) || !uuidPattern.matches(parts[2])
    ) {
        return AgentLink.Unavailable
    }
    val query = uri.rawQuery?.split('&') ?: return AgentLink.Unavailable
    if (query.size != 2) return AgentLink.Unavailable
    val values = mutableMapOf<String, String>()
    for (item in query) {
        val name = item.substringBefore('=', "").lowercase()
        val value = item.substringAfter('=', "")
        if (name !in setOf("version", "generation") || name in values || value.isEmpty()) {
            return AgentLink.Unavailable
        }
        values[name] = value
    }
    val version = canonicalNumber(values["version"]) ?: return AgentLink.Unavailable
    val generation = canonicalNumber(values["generation"]) ?: return AgentLink.Unavailable
    if (version <= 0 || generation < 0) return AgentLink.Unavailable
    return AgentLink.Recording(
        RecordingLink(
            sessionID = parts[1].lowercase(),
            spanID = parts[2].lowercase(),
            version = version,
            generation = generation,
        ),
    )
}

private fun parseMemoryLink(uri: URI): AgentLink {
    val raw = uri.rawPath.orEmpty().trim('/')
    if (raw.isEmpty()) return AgentLink.Unavailable
    // URLDecoder treats '+' as a space; a path plus is a literal plus.
    val path = runCatching { URLDecoder.decode(raw.replace("+", "%2B"), "UTF-8") }
        .getOrNull() ?: return AgentLink.Unavailable
    val segments = path.split('/')
    if (segments.any { it.isBlank() || it == "." || it == ".." }) return AgentLink.Unavailable
    return AgentLink.Memory(path)
}

private fun canonicalNumber(raw: String?): Long? {
    if (raw == null || raw.isEmpty() || !raw.all(Char::isDigit)) return null
    val value = raw.toLongOrNull() ?: return null
    if (raw != value.toString()) return null
    return value
}
