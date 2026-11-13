package com.momoagent.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.momoagent.android.R
import com.momoagent.android.data.ContextSource
import com.momoagent.android.remote.ContextStore
import java.text.DateFormat
import java.util.Date

@Composable
fun TranscriptsScreen(
    contextStore: ContextStore?,
    onConnect: () -> Unit,
    onSettings: () -> Unit,
) {
    val palette = LocalMoMoPalette.current
    if (contextStore == null) {
        Column(modifier = Modifier.fillMaxSize()) {
            PageHeader(stringResource(R.string.transcripts_title), onSettings = onSettings)
            EmptyPanel(
                title = stringResource(R.string.transcripts_no_recordings),
                icon = Icons.Outlined.GraphicEq,
                body = stringResource(R.string.transcripts_empty),
                action = stringResource(R.string.memory_connect),
                onAction = onConnect,
            )
        }
        return
    }

    val state by contextStore.state.collectAsStateWithLifecycle()
    val detail = state.sourceDetailSource
    Column(modifier = Modifier.fillMaxSize()) {
        if (detail != null) {
            androidx.activity.compose.BackHandler { contextStore.closeDetail() }
            PageHeader(
                title = sourceTime(detail.recordedAt),
                onBack = { contextStore.closeDetail() },
                onSettings = onSettings,
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
            ) {
                when {
                    state.detailLoading -> Loading()
                    state.detailFailure != null -> EmptyPanel(
                        title = stringResource(R.string.transcripts_detail_failed),
                        body = state.detailFailure.orEmpty(),
                        action = stringResource(R.string.chat_retry),
                        onAction = { contextStore.openSource(detail) },
                    )
                    else -> SelectionContainer {
                        Text(
                            text = state.sourceDetail?.text.orEmpty(),
                            style = MoMoType.body,
                            color = palette.ink,
                            modifier = Modifier
                                .fillMaxSize()
                                .verticalScroll(rememberScrollState())
                                .padding(horizontal = 20.dp, vertical = 12.dp),
                        )
                    }
                }
            }
        } else {
            PageHeader(
                title = stringResource(R.string.transcripts_title),
                onRefresh = { contextStore.loadSources() },
                onSettings = onSettings,
            )
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f),
            ) {
                when {
                    state.sources.isEmpty() && state.loading -> Loading()
                    state.failure != null && state.sources.isEmpty() -> EmptyPanel(
                        title = stringResource(R.string.transcripts_failed),
                        body = state.failure.orEmpty(),
                        action = stringResource(R.string.chat_retry),
                        onAction = { contextStore.loadSources() },
                    )
                    state.sources.isEmpty() -> EmptyPanel(
                        title = stringResource(R.string.transcripts_no_recordings),
                        icon = Icons.Outlined.GraphicEq,
                        body = stringResource(R.string.transcripts_synced_empty),
                    )
                    else -> LazyColumn(
                        modifier = Modifier.fillMaxSize(),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 20.dp, vertical = 12.dp),
                    ) {
                        item {
                            Text(
                                text = stringResource(R.string.transcripts_remote_hint),
                                style = MoMoType.caption,
                                color = palette.muted,
                                modifier = Modifier.padding(bottom = 4.dp),
                            )
                        }
                        items(state.sources, key = { it.id }) { source ->
                            SourceCard(source) { contextStore.openSource(source) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Loading() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(
            modifier = Modifier.size(22.dp),
            strokeWidth = 2.dp,
            color = LocalMoMoPalette.current.muted,
        )
    }
}

@Composable
private fun SourceCard(source: ContextSource, onClick: () -> Unit) {
    val palette = LocalMoMoPalette.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.GraphicEq, null, tint = palette.ink,
            modifier = Modifier.background(palette.surface, RoundedCornerShape(12.dp)).padding(10.dp).size(22.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(sourceTime(source.recordedAt), style = MoMoType.section, color = palette.ink)
            val preview = source.summary?.takeIf { it.isNotBlank() } ?: source.preview
            if (!preview.isNullOrBlank()) {
                Text(preview, style = MoMoType.menu, color = palette.ink, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            Text(stringResource(R.string.transcripts_characters, source.totalCharacters), style = MoMoType.caption, color = palette.muted)
        }
        Icon(Icons.Filled.ChevronRight, null, tint = palette.muted, modifier = Modifier.size(18.dp))
    }
    HorizontalDivider(color = palette.line)
}

private fun sourceTime(seconds: Double?): String {
    if (seconds == null) return "—"
    return DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
        .format(Date((seconds * 1000).toLong()))
}
