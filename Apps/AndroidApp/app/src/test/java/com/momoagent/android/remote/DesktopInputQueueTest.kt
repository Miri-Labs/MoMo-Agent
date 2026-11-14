package com.momoagent.android.remote

import com.momoagent.android.data.DesktopInputEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DesktopInputQueueTest {
    private fun event(kind: String = "click", x: Double = 0.5) =
        DesktopInputEvent(kind = kind, x = x, y = 0.5)

    @Test
    fun returnsEventsForTheCurrentFrameAndSession() {
        val queue = DesktopInputQueue()
        queue.enqueue(QueuedDesktopInput(event(), generation = 3, session = "session-a"))
        assertEquals("click", queue.poll(3, "session-a")?.event?.kind)
        assertNull(queue.poll(3, "session-a"))
    }

    @Test
    fun dropsInputFromBeforeTheFrameStreamWasLost() {
        val queue = DesktopInputQueue()
        queue.enqueue(QueuedDesktopInput(event(), generation = 3, session = "session-a"))
        assertNull(queue.poll(4, "session-a"))
    }

    @Test
    fun dropsInputFromAnotherControlSession() {
        val queue = DesktopInputQueue()
        queue.enqueue(QueuedDesktopInput(event(), generation = 3, session = "session-a"))
        assertNull(queue.poll(3, "session-b"))
    }

    @Test
    fun onlyCoalescesMouseMovesFromTheSameGenerationAndSession() {
        val queue = DesktopInputQueue()
        queue.enqueue(QueuedDesktopInput(event("mouse_move", 0.1), 3, "session-a"))
        queue.enqueue(QueuedDesktopInput(event("mouse_move", 0.2), 4, "session-a"))
        assertEquals(0.2, queue.poll(4, "session-a")?.event?.x)
        assertNull(queue.poll(4, "session-a"))
    }

    @Test
    fun clearRemovesPendingInput() {
        val queue = DesktopInputQueue()
        queue.enqueue(QueuedDesktopInput(event(), 1, "session-a"))
        queue.clear()
        assertNull(queue.poll(1, "session-a"))
    }
}
