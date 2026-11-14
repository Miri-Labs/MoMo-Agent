package com.momoagent.android.ui

import com.momoagent.android.data.ConversationWork
import org.junit.Assert.assertEquals
import org.junit.Test

class TaskStatusTest {
    private fun work(
        state: String = "running",
        waitReason: String? = null,
        reportState: String = "",
    ) = ConversationWork(id = "w", state = state, waitReason = waitReason, reportState = reportState)

    @Test
    fun mapsWaitingStatesToActions() {
        assertEquals(TaskHint.WaitingForComputer, taskHint(work(waitReason = "computer_human")))
        assertEquals(TaskHint.WaitingForConfirmation, taskHint(work(waitReason = "clarify")))
        assertEquals(TaskHint.Queued, taskHint(work(state = "queued")))
        assertEquals(TaskHint.Queued, taskHint(work(waitReason = "computer_task")))
    }

    @Test
    fun mapsTerminalStates() {
        assertEquals(TaskHint.Completed, taskHint(work(state = "completed")))
        assertEquals(TaskHint.Skipped, taskHint(work(state = "dropped")))
        assertEquals(TaskHint.Stopped, taskHint(work(state = "cancelled")))
        assertEquals(TaskHint.NeedsReview, taskHint(work(state = "failed")))
        assertEquals(TaskHint.NeedsReview, taskHint(work(state = "running", reportState = "failed")))
    }

    @Test
    fun defaultsToRunning() {
        assertEquals(TaskHint.Running, taskHint(work()))
    }
}
