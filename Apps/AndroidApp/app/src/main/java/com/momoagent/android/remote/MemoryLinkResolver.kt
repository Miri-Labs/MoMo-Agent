package com.momoagent.android.remote

import com.momoagent.android.data.ContextMemory

/**
 * Resolves the relative path in a `momoagent://memory/...` link against the
 * memories the Mac has already returned. Mirrors the iPhone resolver so links
 * keep working when a note is addressed by its title, folder or file name.
 */
fun resolveMemoryPath(path: String, memories: List<ContextMemory>): ContextMemory? {
    val normalized = path.trim().trim('/')
    if (normalized.isEmpty()) return null
    val active = memories.filter { it.status != "forgotten" }
    val lower = normalized.lowercase()
    val lowerWithMarkdown = if (lower.endsWith(".md")) lower else "$lower.md"

    active.firstOrNull { memory ->
        val candidate = memory.path?.trim('/')?.lowercase() ?: return@firstOrNull false
        candidate == lower || candidate == lowerWithMarkdown
    }?.let { return it }

    if (lower == "briefing.md" || lower == "briefing") {
        active.firstOrNull { it.kind == "briefing" }?.let { return it }
    }
    if (lower == "user.md" || lower == "user") {
        active.firstOrNull { it.kind == "user" }?.let { return it }
    }
    if (lower == "memory.md" || lower == "memory") {
        active.firstOrNull { it.kind == "memory" }?.let { return it }
    }

    active.firstOrNull { memory ->
        val candidate = memory.path?.trim('/')?.lowercase() ?: return@firstOrNull false
        candidate.endsWith("/$lower") || candidate.endsWith("/$lowerWithMarkdown")
    }?.let { return it }

    val parts = normalized.split('/')
    val folder = parts.firstOrNull()?.lowercase()
    val filename = parts.last().lowercase()
    val targetKind = when (folder) {
        "projects", "project" -> "project"
        "topics", "topic" -> "topic"
        "people", "person" -> "person"
        "journal", "journals" -> "journal"
        else -> null
    }
    val candidates = if (targetKind != null) active.filter { it.kind == targetKind } else active
    candidates.firstOrNull { memory ->
        memory.path?.lowercase()?.endsWith(filename) == true
    }?.let { return it }

    val stem = filename.removeSuffix(".md")
    return candidates.firstOrNull { memory ->
        stem.isNotBlank() && memory.text.contains(stem, ignoreCase = true)
    }
}
