package com.momoagent.android.remote

import com.momoagent.android.data.ContextMemory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MemoryLinkResolverTest {
    private fun memory(id: String, path: String?, text: String = id, kind: String = "note", status: String = "active") =
        ContextMemory(id = id, text = text, kind = kind, status = status, path = path)

    @Test
    fun resolvesExactAndNestedPaths() {
        val atlas = memory("1", "projects/atlas/brief.md", "Weekly review")
        val notes = listOf(atlas, memory("2", "topics/plans/atlas.md"))
        assertEquals(atlas, resolveMemoryPath("projects/atlas/brief.md", notes))
        assertEquals(atlas, resolveMemoryPath("projects/atlas/brief", notes))
        assertEquals(notes[1], resolveMemoryPath("plans/atlas.md", notes))
    }

    @Test
    fun fallsBackToTheNoteKindForTopLevelNotes() {
        val briefing = memory("b", "BRIEFING.md", kind = "briefing")
        val user = memory("u", "USER.md", kind = "user")
        assertEquals(briefing, resolveMemoryPath("briefing", listOf(user, briefing)))
        assertEquals(user, resolveMemoryPath("USER.md", listOf(user, briefing)))
    }

    @Test
    fun ignoresForgottenNotes() {
        val forgotten = memory("1", "projects/atlas/brief.md", status = "forgotten")
        assertNull(resolveMemoryPath("projects/atlas/brief.md", listOf(forgotten)))
    }

    @Test
    fun doesNotOpenAnUnrelatedNote() {
        val notes = listOf(memory("1", "projects/atlas/brief.md", "Weekly review"))
        assertNull(resolveMemoryPath("projects/atlas/other.md", notes))
    }
}
