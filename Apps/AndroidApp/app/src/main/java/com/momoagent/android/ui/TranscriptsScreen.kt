package com.momoagent.android.ui

import android.app.DatePickerDialog
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.momoagent.android.R
import com.momoagent.android.data.ContextSource
import com.momoagent.android.data.ContextSpan
import com.momoagent.android.data.ContextWindow
import com.momoagent.android.remote.ContextStore
import com.momoagent.android.remote.TranscriptDetail
import com.momoagent.android.remote.TranscriptSearchHit
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlinx.coroutines.delay

private const val DAY_START_HOUR = 8

private data class TranscriptWindowItem(
    val source: ContextSource,
    val window: ContextWindow,
) {
    val start: Double get() = window.recordedAt ?: source.recordedAt ?: 0.0
    val end: Double get() = window.endAt ?: start
    val preview: String?
        get() = window.summary?.takeIf { it.isNotBlank() }
            ?: window.preview?.takeIf { it.isNotBlank() }
            ?: source.summary?.takeIf { it.isNotBlank() }
            ?: source.preview
    val day: LocalDate get() = logicalDay(start)
}

private data class SpanLine(val time: String, val speaker: String?, val body: String)

@Composable
fun TranscriptsScreen(
    contextStore: ContextStore?,
    onConnect: () -> Unit,
    onSettings: () -> Unit,
    onDiscuss: (List<String>) -> Unit,
) {
    val palette = LocalMoMoPalette.current
    if (contextStore == null) {
        Column(modifier = Modifier.fillMaxSize()) {
            PageHeader(stringResource(R.string.transcripts_title), onSettings = onSettings)
            EmptyPanel(
                title = stringResource(R.string.transcripts_title),
                body = stringResource(R.string.transcripts_empty),
                action = stringResource(R.string.memory_connect),
                onAction = onConnect,
            )
        }
        return
    }

    val state by contextStore.state.collectAsStateWithLifecycle()
    var selectedDay by rememberSaveable { mutableStateOf(LocalDate.now().toString()) }
    var searchOpen by rememberSaveable { mutableStateOf(false) }
    var query by rememberSaveable { mutableStateOf("") }
    val selectedDate = remember(selectedDay) { LocalDate.parse(selectedDay) }
    val meLabel = stringResource(R.string.transcripts_speaker_me)
    val listState = rememberLazyListState()

    LaunchedEffect(selectedDate) { listState.scrollToItem(0) }

    LaunchedEffect(searchOpen, query) {
        if (!searchOpen || query.isBlank()) {
            contextStore.search("")
        } else {
            delay(300)
            contextStore.search(query)
        }
    }

    val detail = state.detail
    if (detail != null) {
        TranscriptDetailView(
            store = contextStore,
            detail = detail,
            loading = state.detailLoading,
            failure = state.detailFailure,
            meLabel = meLabel,
            onBack = { contextStore.closeDetail() },
            onSettings = onSettings,
            onDiscuss = onDiscuss,
        )
        return
    }

    val windows = remember(state.sources) {
        state.sources.flatMap { source -> windowsOf(source).map { TranscriptWindowItem(source, it) } }
    }
    val dayWindows = remember(windows, selectedDate) {
        windows.filter { it.day == selectedDate }.sortedBy { it.start }
    }
    val today = remember { LocalDate.now() }

    Column(modifier = Modifier.fillMaxSize()) {
        PageHeader(
            title = stringResource(R.string.transcripts_title),
            onRefresh = { contextStore.loadSources() },
            onSettings = onSettings,
        )
        TranscriptDateBar(
            selectedDate = selectedDate,
            searchOpen = searchOpen,
            canGoNext = selectedDate < today,
            onPrevious = { selectedDay = selectedDate.minusDays(1).toString() },
            onNext = { if (selectedDate < today) selectedDay = selectedDate.plusDays(1).toString() },
            onPickDate = { selectedDay = it.toString() },
            onToggleSearch = {
                searchOpen = !searchOpen
                if (!searchOpen) query = ""
            },
        )
        if (searchOpen) {
            TranscriptSearchField(
                query = query,
                onQueryChange = { query = it },
                onClear = { query = "" },
            )
        }
        Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
            when {
                state.sourcesLoading && windows.isEmpty() -> Loading()
                state.sourcesFailure != null && windows.isEmpty() -> EmptyPanel(
                    title = stringResource(R.string.transcripts_failed),
                    body = state.sourcesFailure.orEmpty(),
                    action = stringResource(R.string.chat_retry),
                    onAction = { contextStore.loadSources() },
                )
                searchOpen && query.isNotBlank() -> SearchResults(
                    hits = state.searchHits,
                    loading = state.searchLoading,
                    failure = state.searchFailure,
                    onOpen = { hit -> contextStore.openSource(hit.source, hit.window) },
                    onRetry = { contextStore.search(query) },
                )
                windows.isEmpty() -> EmptyPanel(
                    title = stringResource(R.string.transcripts_no_recordings),
                    icon = Icons.Outlined.GraphicEq,
                    body = stringResource(R.string.transcripts_synced_empty),
                )
                dayWindows.isEmpty() -> EmptyPanel(
                    title = stringResource(R.string.transcripts_title),
                    body = stringResource(R.string.transcripts_no_day),
                )
                else -> LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    item {
                        Text(
                            text = stringResource(R.string.transcripts_remote_hint),
                            style = MoMoType.caption,
                            color = palette.muted,
                            modifier = Modifier.padding(bottom = 4.dp),
                        )
                    }
                    items(dayWindows, key = { it.source.id + "@" + it.window.id }) { item ->
                        TranscriptWindowRow(item) { contextStore.openSource(item.source, item.window) }
                    }
                }
            }
        }
    }
}

@Composable
private fun TranscriptDateBar(
    selectedDate: LocalDate,
    searchOpen: Boolean,
    canGoNext: Boolean,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onPickDate: (LocalDate) -> Unit,
    onToggleSearch: () -> Unit,
) {
    val context = LocalContext.current
    Row(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = onPrevious) {
            Icon(
                Icons.Filled.ChevronLeft,
                contentDescription = stringResource(R.string.transcripts_previous_day),
            )
        }
        TextButton(
            onClick = {
                DatePickerDialog(
                    context,
                    { _, year, month, day -> onPickDate(LocalDate.of(year, month + 1, day)) },
                    selectedDate.year,
                    selectedDate.monthValue - 1,
                    selectedDate.dayOfMonth,
                ).apply { datePicker.maxDate = System.currentTimeMillis() }.show()
            },
            modifier = Modifier.weight(1f),
        ) {
            Text(formatDay(selectedDate))
            Icon(
                Icons.Filled.KeyboardArrowDown,
                contentDescription = stringResource(R.string.transcripts_pick_date),
                modifier = Modifier.size(18.dp),
            )
        }
        IconButton(onClick = onNext, enabled = canGoNext) {
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = stringResource(R.string.transcripts_next_day),
            )
        }
        IconButton(onClick = onToggleSearch) {
            Icon(
                if (searchOpen) Icons.Filled.Close else Icons.Filled.Search,
                contentDescription = stringResource(
                    if (searchOpen) R.string.transcripts_close_search else R.string.transcripts_search_hint,
                ),
            )
        }
    }
}

@Composable
private fun TranscriptSearchField(query: String, onQueryChange: (String) -> Unit, onClear: () -> Unit) {
    val palette = LocalMoMoPalette.current
    GlassSurface(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        shape = RoundedCornerShape(50),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Search, contentDescription = null, tint = palette.muted, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
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
                            Text(
                                stringResource(R.string.transcripts_search_hint),
                                style = MoMoType.body,
                                color = palette.muted,
                            )
                        }
                        inner()
                    }
                },
            )
            if (query.isNotEmpty()) {
                IconButton(onClick = onClear, modifier = Modifier.size(32.dp)) {
                    Icon(
                        Icons.Filled.Close,
                        contentDescription = stringResource(R.string.transcripts_clear_search),
                        tint = palette.muted,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun SearchResults(
    hits: List<TranscriptSearchHit>,
    loading: Boolean,
    failure: String?,
    onOpen: (TranscriptSearchHit) -> Unit,
    onRetry: () -> Unit,
) {
    val palette = LocalMoMoPalette.current
    when {
        loading && hits.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                CircularProgressIndicator(
                    modifier = Modifier.size(22.dp),
                    strokeWidth = 2.dp,
                    color = palette.muted,
                )
                Text(stringResource(R.string.transcripts_searching), style = MoMoType.caption, color = palette.muted)
            }
        }
        failure != null && hits.isEmpty() -> EmptyPanel(
            title = stringResource(R.string.transcripts_search_failed),
            body = failure,
            action = stringResource(R.string.chat_retry),
            onAction = onRetry,
        )
        hits.isEmpty() -> EmptyPanel(
            title = stringResource(R.string.transcripts_title),
            body = stringResource(R.string.transcripts_search_empty),
        )
        else -> LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(hits, key = { it.source.id + "@" + it.window.id }) { hit ->
                TranscriptWindowRow(
                    item = TranscriptWindowItem(hit.source, hit.window),
                    previewOverride = hit.snippet.ifBlank { null },
                    showDate = true,
                ) { onOpen(hit) }
            }
        }
    }
}

@Composable
private fun TranscriptWindowRow(
    item: TranscriptWindowItem,
    previewOverride: String? = null,
    showDate: Boolean = false,
    onClick: () -> Unit,
) {
    val palette = LocalMoMoPalette.current
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Outlined.GraphicEq,
            contentDescription = null,
            tint = palette.ink,
            modifier = Modifier.background(palette.surface, RoundedCornerShape(12.dp)).padding(10.dp).size(22.dp),
        )
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(
                text = if (showDate) {
                    formatDay(item.day) + " · " + formatTimeRange(item.start, item.end)
                } else {
                    formatTimeRange(item.start, item.end)
                },
                style = MoMoType.section,
                color = palette.ink,
            )
            val preview = previewOverride?.takeIf { it.isNotBlank() } ?: item.preview
            if (!preview.isNullOrBlank()) {
                Text(
                    text = preview,
                    style = MoMoType.menu,
                    color = palette.ink,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                text = stringResource(R.string.transcripts_characters, item.window.totalCharacters),
                style = MoMoType.caption,
                color = palette.muted,
            )
        }
        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = palette.muted, modifier = Modifier.size(18.dp))
    }
    HorizontalDivider(color = palette.line)
}

@Composable
private fun TranscriptDetailView(
    store: ContextStore,
    detail: TranscriptDetail,
    loading: Boolean,
    failure: String?,
    meLabel: String,
    onBack: () -> Unit,
    onSettings: () -> Unit,
    onDiscuss: (List<String>) -> Unit,
) {
    val palette = LocalMoMoPalette.current
    BackHandler(onBack = onBack)
    val listState = rememberLazyListState()
    val windowKey = detail.source.id + "@" + (detail.window?.id ?: "")
    var scrolledKey by remember { mutableStateOf<String?>(null) }
    val spans = detail.spans
    val citations = remember(detail) { citationsForWindow(detail) }

    LaunchedEffect(windowKey, detail.complete) {
        if (!detail.complete || scrolledKey == windowKey) return@LaunchedEffect
        val index = spanIndexForWindow(detail) ?: return@LaunchedEffect
        listState.scrollToItem(index + 1)
        scrolledKey = windowKey
    }

    Column(modifier = Modifier.fillMaxSize()) {
        PageHeader(
            title = detail.window?.let { formatTimeRange(it.recordedAt ?: detail.source.recordedAt ?: 0.0, it.endAt ?: it.recordedAt ?: 0.0) }
                ?: stringResource(R.string.transcripts_detail_title),
            onBack = onBack,
            onRefresh = if (!detail.complete || failure != null) ({ store.retryDetail() }) else null,
            onSettings = onSettings,
        )
        when {
            spans.isEmpty() && detail.text.isEmpty() && loading -> Loading()
            spans.isEmpty() && detail.text.isEmpty() && failure != null -> EmptyPanel(
                title = stringResource(R.string.transcripts_detail_failed),
                body = failure,
                action = stringResource(R.string.chat_retry),
                onAction = { store.retryDetail() },
            )
            else -> {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxWidth().weight(1f),
                    contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    item(key = "detail-header") { TranscriptDetailHeader(detail) }
                    if (spans.isNotEmpty()) {
                        itemsIndexed(spans, key = { _, span -> span.id }) { _, span ->
                            SpanRow(span, meLabel)
                        }
                    } else {
                        item(key = "detail-text") {
                            SelectionContainer {
                                Text(detail.text, style = MoMoType.body, color = palette.ink)
                            }
                        }
                    }
                    if (loading) {
                        item(key = "detail-loading") {
                            Row(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(16.dp),
                                    strokeWidth = 2.dp,
                                    color = palette.muted,
                                )
                                Text(
                                    stringResource(R.string.transcripts_loading),
                                    style = MoMoType.caption,
                                    color = palette.muted,
                                )
                            }
                        }
                    }
                    val currentFailure = failure
                    if (currentFailure != null) {
                        item(key = "detail-failure") {
                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(
                                    stringResource(R.string.transcripts_partial_failed),
                                    style = MoMoType.caption,
                                    color = palette.failure,
                                )
                                TextButton(onClick = { store.retryDetail() }) {
                                    Text(stringResource(R.string.chat_retry))
                                }
                            }
                        }
                    }
                }
                if (detail.window != null && citations.isNotEmpty() && !loading) {
                    Button(
                        onClick = { onDiscuss(citations) },
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
                    ) {
                        Text(stringResource(R.string.transcripts_discuss))
                    }
                }
            }
        }
    }
}

@Composable
private fun TranscriptDetailHeader(detail: TranscriptDetail) {
    val palette = LocalMoMoPalette.current
    val start = detail.window?.recordedAt ?: detail.source.recordedAt ?: 0.0
    val end = detail.window?.endAt ?: detail.window?.recordedAt ?: start
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(
            formatDay(logicalDay(start)) + " · " + formatTimeRange(start, end),
            style = MoMoType.section,
            color = palette.ink,
        )
        Text(
            stringResource(R.string.transcripts_characters, detail.source.totalCharacters),
            style = MoMoType.caption,
            color = palette.muted,
        )
    }
}

@Composable
private fun SpanRow(span: ContextSpan, meLabel: String) {
    val palette = LocalMoMoPalette.current
    val line = remember(span, meLabel) { spanLine(span, meLabel) }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(line.time, style = MoMoType.caption, color = palette.muted)
            line.speaker?.let { Text(it, style = MoMoType.caption, color = palette.ink) }
        }
        SelectionContainer {
            Text(line.body, style = MoMoType.body, color = palette.ink)
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

private fun windowsOf(source: ContextSource): List<ContextWindow> =
    source.windows.ifEmpty {
        listOf(
            ContextWindow(
                id = source.id,
                sourceID = source.id,
                sourceRevision = source.revision,
                recordedAt = source.recordedAt,
                endAt = source.recordedAt,
                offset = 0,
                end = source.totalCharacters,
                totalCharacters = source.totalCharacters,
                preview = source.preview,
                summary = source.summary,
            ),
        )
    }

private fun logicalDay(seconds: Double): LocalDate {
    val zoned = Instant.ofEpochSecond(seconds.toLong()).atZone(ZoneId.systemDefault())
    return if (zoned.hour < DAY_START_HOUR) zoned.toLocalDate().minusDays(1) else zoned.toLocalDate()
}

private val dayFormatter: DateTimeFormatter = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
private val timeFormatter: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm")
private val fullTimeFormatter: DateTimeFormatter = DateTimeFormatter.ofPattern("HH:mm:ss")

private fun formatDay(date: LocalDate): String = date.format(dayFormatter)

private fun formatTime(seconds: Double?, withSeconds: Boolean = false): String {
    if (seconds == null) return "—"
    val time = Instant.ofEpochSecond(seconds.toLong()).atZone(ZoneId.systemDefault())
    return (if (withSeconds) fullTimeFormatter else timeFormatter).format(time)
}

private fun formatTimeRange(start: Double, end: Double): String {
    val from = formatTime(start)
    if (end <= start) return from
    return from + "–" + formatTime(end)
}

private fun spanLine(span: ContextSpan, meLabel: String): SpanLine {
    val match = SPEAKER_PREFIX.find(span.text)
    val prefix = match?.groupValues?.getOrNull(1)?.takeIf { it.isNotBlank() }
    val speaker = span.speaker?.takeIf { it.isNotBlank() }
        ?: prefix
        ?: if (span.isOwner == true) meLabel else null
    val body = if (match != null) span.text.substring(match.range.last + 1) else span.text
    return SpanLine(
        time = formatTime(span.recordedAt, withSeconds = true),
        speaker = speaker,
        body = body.ifBlank { span.text },
    )
}

private val SPEAKER_PREFIX = Regex("^\\[([^\\]\\r\\n]{1,32})\\]\\s+")

private fun spanIndexForWindow(detail: TranscriptDetail): Int? {
    val window = detail.window ?: return null
    var offset = 0
    detail.spans.forEachIndexed { index, span ->
        val length = span.text.codePointCount(0, span.text.length)
        if (offset + length > window.offset && offset < window.end) return index
        offset += length + 1
    }
    return null
}

private fun citationsForWindow(detail: TranscriptDetail): List<String> {
    val window = detail.window ?: return emptyList()
    val result = mutableListOf<String>()
    var offset = 0
    for (span in detail.spans) {
        val length = span.text.codePointCount(0, span.text.length)
        if (offset + length > window.offset && offset < window.end) {
            span.citationURL?.let { result.add(it) }
        }
        offset += length + 1
    }
    return result
}
