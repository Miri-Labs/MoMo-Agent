package com.momoagent.android.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentLinkTest {
    private val session = "11111111-2222-3333-4444-555555555555"
    private val span = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    @Test
    fun parsesRecordingLinkInEitherQueryOrder() {
        val first = parseAgentLink("momoagent://source/$session/$span?version=3&generation=0")
        val second = parseAgentLink("momoagent://source/$session/$span?generation=2&version=4")
        val expected = RecordingLink(session, span, 3, 0)
        assertEquals(AgentLink.Recording(expected), first)
        assertEquals(AgentLink.Recording(RecordingLink(session, span, 4, 2)), second)
    }

    @Test
    fun rejectsMalformedRecordingLinks() {
        val invalid = listOf(
            "momoagent://source/$session/$span?version=0&generation=0",
            "momoagent://source/$session/$span?version=3",
            "momoagent://source/$session/$span?version=3&generation=0&extra=1",
            "momoagent://source/$session/not-a-uuid?version=3&generation=0",
            "momoagent://source/$session/$span?version=03&generation=0",
        )
        invalid.forEach { assertEquals(AgentLink.Unavailable, parseAgentLink(it)) }
    }

    @Test
    fun decodesMemoryPaths() {
        val result = parseAgentLink("momoagent://memory/projects/atlas/brief%20notes.md")
        assertEquals(AgentLink.Memory("projects/atlas/brief notes.md"), result)
        assertEquals(AgentLink.Memory("topics/C++/notes.md"), parseAgentLink("momoagent://memory/topics/C++/notes.md"))
        assertEquals(AgentLink.Unavailable, parseAgentLink("momoagent://memory/"))
        assertEquals(AgentLink.Unavailable, parseAgentLink("momoagent://memory/projects/../secret.md"))
    }

    @Test
    fun distinguishesWebFromUnavailable() {
        assertTrue(parseAgentLink("https://example.com/note") is AgentLink.Web)
        assertEquals(AgentLink.Unavailable, parseAgentLink("file:///tmp/example"))
        assertEquals(AgentLink.Unavailable, parseAgentLink("not a link"))
    }
}
