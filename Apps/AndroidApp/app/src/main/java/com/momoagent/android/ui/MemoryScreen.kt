package com.momoagent.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.AutoStories
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.momoagent.android.R
import com.momoagent.android.data.ContextMemory
import com.momoagent.android.remote.ContextStore

@Composable
fun MemoryScreen(
    contextStore: ContextStore?,
    onConnect: () -> Unit,
    onSettings: () -> Unit,
) {
    val palette = LocalMoMoPalette.current
    var selected by remember { mutableStateOf<ContextMemory?>(null) }
    var query by rememberSaveable { mutableStateOf("") }

    Column(modifier = Modifier.fillMaxSize()) {
        PageHeader(
            title = stringResource(R.string.memory_title),
            onRefresh = contextStore?.let { { it.loadMemories() } },
            onSettings = onSettings,
        )
        if (contextStore == null) {
            EmptyPanel(
                title = stringResource(R.string.memory_no_notes),
                icon = Icons.Outlined.AutoStories,
                body = stringResource(R.string.memory_empty),
                action = stringResource(R.string.memory_connect),
                onAction = onConnect,
            )
        } else {
            val state by contextStore.state.collectAsStateWithLifecycle()
            when {
                state.loading && state.memories.isEmpty() -> {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(22.dp),
                            strokeWidth = 2.dp,
                            color = palette.muted,
                        )
                    }
                }
                state.failure != null && state.memories.isEmpty() -> {
                    EmptyPanel(
                        title = stringResource(R.string.memory_failed),
                        body = state.failure.orEmpty(),
                        action = stringResource(R.string.memory_refresh),
                        onAction = { contextStore.loadMemories() },
                    )
                }
                state.memories.isEmpty() -> {
                    EmptyPanel(
                        title = stringResource(R.string.memory_no_notes),
                        icon = Icons.Outlined.AutoStories,
                        body = stringResource(R.string.memory_synced_empty),
                    )
                }
                else -> {
                    val filtered = state.memories.filter { memory ->
                        query.isBlank() ||
                            memory.text.contains(query, ignoreCase = true) ||
                            memory.kind.contains(query, ignoreCase = true)
                    }
                    Column(modifier = Modifier.fillMaxSize()) {
                        MemorySearch(query = query, onQueryChange = { query = it })
                        if (filtered.isEmpty()) {
                            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                                Text(stringResource(R.string.memory_search_empty), style = MoMoType.body, color = palette.muted)
                            }
                        } else {
                            LazyColumn(
                                modifier = Modifier.fillMaxSize(),
                                contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp),
                            ) {
                                items(filtered, key = { it.id }) { memory ->
                                    MemoryCard(memory) { selected = memory }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    selected?.let { memory ->
        MemoryDetail(memory) { selected = null }
    }
}

@Composable
private fun MemorySearch(query: String, onQueryChange: (String) -> Unit) {
    val palette = LocalMoMoPalette.current
    GlassSurface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        shape = RoundedCornerShape(50),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Search, contentDescription = null, tint = palette.muted, modifier = Modifier.size(18.dp))
            Spacer(Modifier.size(8.dp))
            BasicTextField(
                value = query,
                onValueChange = onQueryChange,
                singleLine = true,
                textStyle = MoMoType.body.copy(color = palette.ink),
                cursorBrush = SolidColor(palette.ink),
                modifier = Modifier.weight(1f),
                decorationBox = { inner ->
                    Box {
                        if (query.isEmpty()) {
                            Text(stringResource(R.string.memory_search_hint), style = MoMoType.body, color = palette.muted)
                        }
                        inner()
                    }
                },
            )
        }
    }
}

@Composable
private fun MemoryCard(memory: ContextMemory, onClick: () -> Unit) {
    val palette = LocalMoMoPalette.current
    Column(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(memory.text, style = MoMoType.body, color = palette.ink, maxLines = 4, overflow = TextOverflow.Ellipsis)
        val metadata = listOfNotNull(
            memory.kind.takeIf { it.isNotBlank() },
            memory.basis.takeIf { it.isNotBlank() },
            if (memory.evidence.isEmpty()) null else stringResource(R.string.memory_evidence_count, memory.evidence.size),
        )
        if (metadata.isNotEmpty()) Text(metadata.joinToString(" · "), style = MoMoType.metadata, color = palette.muted)
    }
    HorizontalDivider(color = palette.line)
}

@Composable
private fun MemoryDetail(memory: ContextMemory, onClose: () -> Unit) {
    val palette = LocalMoMoPalette.current
    GlassDialog(
        onDismiss = onClose,
        title = stringResource(R.string.memory_title),
    ) {
        Column(
            modifier = Modifier
                .heightIn(max = 380.dp)
                .verticalScroll(rememberScrollState())
                .fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(memory.text, style = MoMoType.body, color = palette.ink)
            if (memory.evidence.isNotEmpty()) {
                Text(stringResource(R.string.memory_evidence), style = MoMoType.section, color = palette.ink)
                memory.evidence.forEach { evidence ->
                    Surface(
                        color = palette.surface.copy(alpha = 0.6f),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            text = evidence.quote,
                            style = MoMoType.metadata,
                            color = palette.muted,
                            modifier = Modifier.padding(12.dp),
                        )
                    }
                }
            }
        }
    }
}
