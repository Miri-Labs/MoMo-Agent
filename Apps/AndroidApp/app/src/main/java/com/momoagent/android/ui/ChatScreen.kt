package com.momoagent.android.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.momoagent.android.R

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    state: ChatState,
    onSend: (String) -> Unit,
    onRetry: () -> Unit,
    onDismissFailure: () -> Unit,
    onUnpair: () -> Unit,
) {
    var draft by rememberSaveable { mutableStateOf("") }
    var confirmUnpair by rememberSaveable { mutableStateOf(false) }
    val rows = remember(state.messages, state.pending) {
        buildList {
            state.messages.forEach { add(ChatRow.Message(it)) }
            state.pending.forEach { add(ChatRow.Pending(it)) }
        }
    }
    val listState = rememberLazyListState()

    LaunchedEffect(rows.size, rows.lastOrNull()?.textLength) {
        if (rows.isNotEmpty()) listState.animateScrollToItem(rows.lastIndex)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            text = stringResource(R.string.chat_title),
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(
                                modifier = Modifier
                                    .size(7.dp)
                                    .clip(CircleShape)
                                    .background(
                                        if (state.failure == ChatFailure.Load) MoMoFailure else MoMoSuccess,
                                    ),
                            )
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = stringResource(
                                    if (state.failure == ChatFailure.Load) R.string.chat_offline
                                    else R.string.chat_connected,
                                ),
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                },
                actions = {
                    TextButton(onClick = { confirmUnpair = true }) {
                        Text(stringResource(R.string.chat_unpair))
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                    titleContentColor = MaterialTheme.colorScheme.onSurface,
                ),
            )
        },
        bottomBar = {
            Composer(
                draft = draft,
                onDraftChange = { draft = it },
                onSend = {
                    val value = draft
                    draft = ""
                    onSend(value)
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            state.failure?.let { failure ->
                FailureBanner(failure = failure, onRetry = onRetry, onDismiss = onDismissFailure)
            }
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxSize()
                    .weight(1f),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (rows.isEmpty() && !state.loading) {
                    item {
                        Text(
                            text = stringResource(R.string.chat_empty),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(top = 96.dp, start = 24.dp, end = 24.dp),
                        )
                    }
                }
                items(items = rows, key = { it.key }) { row ->
                    when (row) {
                        is ChatRow.Message -> MessageBubble(row.value)
                        is ChatRow.Pending -> PendingBubble(row.value)
                    }
                }
                if (state.loading) {
                    item {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(24.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(20.dp),
                                strokeWidth = 2.dp,
                            )
                        }
                    }
                }
            }
        }
    }

    if (confirmUnpair) {
        AlertDialog(
            onDismissRequest = { confirmUnpair = false },
            title = { Text(stringResource(R.string.chat_unpair_title)) },
            text = { Text(stringResource(R.string.chat_unpair_body)) },
            confirmButton = {
                TextButton(
                    onClick = {
                        confirmUnpair = false
                        onUnpair()
                    },
                ) {
                    Text(stringResource(R.string.chat_unpair), color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmUnpair = false }) {
                    Text(stringResource(R.string.chat_cancel))
                }
            },
        )
    }
}

private sealed interface ChatRow {
    val key: String
    val textLength: Int

    data class Message(val value: ChatMessage) : ChatRow {
        override val key: String = value.id
        override val textLength: Int = value.content.length
    }

    data class Pending(val value: PendingReply) : ChatRow {
        override val key: String = value.operationID
        override val textLength: Int = value.text.length
    }
}

@Composable
private fun MessageBubble(message: ChatMessage) {
    val fromUser = message.role == "user"
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (fromUser) Arrangement.End else Arrangement.Start,
    ) {
        Surface(
            color = if (fromUser) MoMoInk else MoMoPaper,
            contentColor = if (fromUser) Color.White else MoMoInk,
            shape = RoundedCornerShape(18.dp),
            border = if (fromUser) null else BorderStroke(1.dp, MoMoLine),
            modifier = Modifier.widthIn(max = 320.dp),
        ) {
            Text(
                text = message.content,
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            )
        }
    }
}

@Composable
private fun PendingBubble(reply: PendingReply) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.Start,
    ) {
        Surface(
            color = MoMoPaper,
            contentColor = MoMoInk,
            shape = RoundedCornerShape(18.dp),
            border = BorderStroke(1.dp, MoMoLine),
            modifier = Modifier.widthIn(max = 320.dp),
        ) {
            if (reply.text.isEmpty()) {
                Row(
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(12.dp),
                        strokeWidth = 2.dp,
                        color = MoMoMuted,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = stringResource(R.string.chat_thinking),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MoMoMuted,
                    )
                }
            } else {
                Text(
                    text = reply.text,
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                )
            }
        }
    }
}

@Composable
private fun FailureBanner(failure: ChatFailure, onRetry: () -> Unit, onDismiss: () -> Unit) {
    Surface(color = MoMoFailure.copy(alpha = 0.10f), contentColor = MoMoFailure) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 8.dp, top = 6.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = stringResource(
                    if (failure == ChatFailure.Load) R.string.chat_load_failed
                    else R.string.chat_send_failed,
                ),
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.weight(1f),
            )
            if (failure == ChatFailure.Load) {
                TextButton(onClick = onRetry) {
                    Text(stringResource(R.string.chat_retry))
                }
            } else {
                TextButton(onClick = onDismiss) {
                    Text(stringResource(R.string.chat_dismiss))
                }
            }
        }
    }
}

@Composable
private fun Composer(draft: String, onDraftChange: (String) -> Unit, onSend: () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surface) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .imePadding()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            OutlinedTextField(
                value = draft,
                onValueChange = onDraftChange,
                placeholder = { Text(stringResource(R.string.chat_placeholder)) },
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { if (draft.isNotBlank()) onSend() }),
                modifier = Modifier.weight(1f),
                maxLines = 5,
                shape = RoundedCornerShape(22.dp),
            )
            Spacer(Modifier.width(8.dp))
            FilledIconButton(
                onClick = onSend,
                enabled = draft.isNotBlank(),
                modifier = Modifier.size(48.dp),
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.Send,
                    contentDescription = stringResource(R.string.chat_send),
                )
            }
        }
    }
}
