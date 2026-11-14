package com.momoagent.android.ui

import com.momoagent.android.data.ConversationWork

enum class TaskHint {
    WaitingForComputer,
    WaitingForConfirmation,
    Queued,
    Finalizing,
    NeedsReview,
    Running,
    Completed,
    Skipped,
    Stopped,
    Failed,
}

/** Maps the Mac work contract to the action the person needs to take, never the raw field. */
fun taskHint(work: ConversationWork): TaskHint = when {
    work.waitReason == "computer_human" -> TaskHint.WaitingForComputer
    work.waitReason == "clarify" -> TaskHint.WaitingForConfirmation
    work.state == "queued" || work.waitReason == "computer_task" -> TaskHint.Queued
    work.state == "finalizing" -> TaskHint.Finalizing
    work.state == "failed" || work.reportState == "failed" -> TaskHint.NeedsReview
    work.state == "completed" -> TaskHint.Completed
    work.state == "dropped" -> TaskHint.Skipped
    work.state == "cancelled" -> TaskHint.Stopped
    work.state == "interrupted" -> TaskHint.Failed
    else -> TaskHint.Running
}
