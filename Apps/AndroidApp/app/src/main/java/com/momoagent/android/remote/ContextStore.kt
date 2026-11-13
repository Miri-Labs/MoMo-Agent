package com.momoagent.android.remote

import com.momoagent.android.data.AgentApi
import com.momoagent.android.data.AgentConnection
import com.momoagent.android.data.ContextMemory
import com.momoagent.android.data.ContextSource
import com.momoagent.android.data.ContextSpan
import com.momoagent.android.data.ContextWindow
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext

data class TranscriptDetail(
    val source: ContextSource,
    val window: ContextWindow? = null,
    val text: String = "",
    val spans: List<ContextSpan> = emptyList(),
    val nextOffset: Int? = null,
    val complete: Boolean = false,
)

data class TranscriptSearchHit(
    val source: ContextSource,
    val window: ContextWindow,
    val snippet: String,
)

data class ContextState(
    val memories: List<ContextMemory> = emptyList(),
    val sources: List<ContextSource> = emptyList(),
    val memoriesLoading: Boolean = true,
    val sourcesLoading: Boolean = true,
    val memoriesFailure: String? = null,
    val sourcesFailure: String? = null,
    val detail: TranscriptDetail? = null,
    val detailLoading: Boolean = false,
    val detailFailure: String? = null,
    val searchQuery: String = "",
    val searchHits: List<TranscriptSearchHit> = emptyList(),
    val searchLoading: Boolean = false,
    val searchFailure: String? = null,
)

/** Read-only view of the Mac context APIs used by the Memory and Transcripts tabs. */
class ContextStore(
    private val api: AgentApi,
    private val scope: CoroutineScope,
    private val connection: AgentConnection,
    private val credential: String,
) {
    private val _state = MutableStateFlow(ContextState())
    val state: StateFlow<ContextState> = _state
    private var memoriesJob: Job? = null
    private var sourcesJob: Job? = null
    private var detailJob: Job? = null
    private var searchJob: Job? = null
    private var detailRequest = 0
    private var searchGeneration = 0
    private val fullSources = LinkedHashMap<String, TranscriptDetail>()

    fun loadAll() {
        loadMemories()
        loadSources()
    }

    fun refresh() = loadAll()

    fun loadMemories() {
        memoriesJob?.cancel()
        memoriesJob = scope.launch {
            _state.update { it.copy(memoriesLoading = true, memoriesFailure = null) }
            try {
                val items = mutableListOf<ContextMemory>()
                var cursor: String? = null
                var revision: Long? = null
                do {
                    val page = withContext(Dispatchers.IO) {
                        api.contextMemories(connection, credential, after = cursor, revision = revision, limit = 200)
                    }
                    if (revision == null) revision = page.revision
                    items += page.items
                    cursor = page.nextCursor
                    if (page.items.isEmpty()) break
                } while (cursor != null && items.size < 20_000)
                _state.update {
                    it.copy(memories = items, memoriesLoading = false, memoriesFailure = null)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update { it.copy(memoriesLoading = false, memoriesFailure = error.message) }
            }
        }
    }

    fun loadSources() {
        sourcesJob?.cancel()
        sourcesJob = scope.launch {
            _state.update { it.copy(sourcesLoading = true, sourcesFailure = null) }
            try {
                val items = mutableListOf<ContextSource>()
                var cursor: String? = null
                do {
                    val page = withContext(Dispatchers.IO) {
                        api.contextSources(connection, credential, after = cursor, limit = 200)
                    }
                    items += page.items
                    cursor = page.nextCursor
                    if (page.items.isEmpty()) break
                } while (cursor != null && items.size < 20_000)
                _state.update {
                    it.copy(sources = items, sourcesLoading = false, sourcesFailure = null)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update { it.copy(sourcesLoading = false, sourcesFailure = error.message) }
            }
        }
    }

    fun openSource(source: ContextSource, window: ContextWindow? = null) {
        detailRequest += 1
        val request = detailRequest
        detailJob?.cancel()
        val cached = synchronized(fullSources) { fullSources[cacheKey(source)] }
        if (cached != null) {
            _state.update {
                it.copy(
                    detail = cached.copy(window = window),
                    detailLoading = false,
                    detailFailure = null,
                )
            }
            return
        }
        _state.update {
            it.copy(
                detail = TranscriptDetail(source = source, window = window),
                detailLoading = true,
                detailFailure = null,
            )
        }
        detailJob = scope.launch {
            loadDetailPages(source, window, request, startOffset = 0, initial = TranscriptDetail(source, window))
        }
    }

    fun retryDetail() {
        val current = _state.value.detail ?: return
        detailRequest += 1
        val request = detailRequest
        detailJob?.cancel()
        _state.update { it.copy(detailLoading = true, detailFailure = null) }
        detailJob = scope.launch {
            loadDetailPages(current.source, current.window, request, current.nextOffset ?: 0, current)
        }
    }

    fun closeDetail() {
        detailRequest += 1
        detailJob?.cancel()
        detailJob = null
        _state.update {
            it.copy(detail = null, detailLoading = false, detailFailure = null)
        }
    }

    fun search(query: String) {
        val normalized = query.trim()
        searchJob?.cancel()
        searchGeneration += 1
        val generation = searchGeneration
        if (normalized.isEmpty()) {
            _state.update {
                it.copy(searchQuery = "", searchHits = emptyList(), searchLoading = false, searchFailure = null)
            }
            return
        }
        _state.update {
            it.copy(searchQuery = normalized, searchHits = emptyList(), searchLoading = true, searchFailure = null)
        }
        val sources = _state.value.sources
        searchJob = scope.launch {
            try {
                val semaphore = Semaphore(4)
                val hits = coroutineScope {
                    sources.map { source ->
                        async(Dispatchers.IO) {
                            semaphore.withPermit {
                                findHits(source, normalized, generation)
                            }
                        }
                    }.awaitAll().flatten()
                }
                if (generation != searchGeneration) return@launch
                _state.update { it.copy(searchHits = hits, searchLoading = false, searchFailure = null) }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                if (generation == searchGeneration) {
                    _state.update { it.copy(searchLoading = false, searchFailure = error.message) }
                }
            }
        }
    }

    private suspend fun findHits(source: ContextSource, query: String, generation: Int): List<TranscriptSearchHit> {
        val detail = runCatching { loadFullSource(source) }.getOrNull()
        if (generation != searchGeneration) return emptyList()
        val windows = source.windows.ifEmpty { listOf(syntheticWindow(source)) }
        val sourceMatch = source.summary?.contains(query, ignoreCase = true) == true ||
            source.preview?.contains(query, ignoreCase = true) == true
        val hits = mutableListOf<TranscriptSearchHit>()
        for (window in windows) {
            val local = detail?.let { windowText(it, window) }
            val index = local?.indexOf(query, ignoreCase = true) ?: -1
            val direct = window.summary?.contains(query, ignoreCase = true) == true ||
                window.preview?.contains(query, ignoreCase = true) == true
            if (index < 0 && !direct) continue
            val snippet = if (local != null && index >= 0) {
                snippet(local, index, query.length)
            } else {
                window.summary ?: window.preview ?: source.summary ?: source.preview.orEmpty()
            }
            hits += TranscriptSearchHit(source, window, snippet)
        }
        if (hits.isEmpty() && sourceMatch) {
            val window = windows.first()
            hits += TranscriptSearchHit(source, window, source.summary ?: source.preview.orEmpty())
        }
        return hits
    }

    private fun windowText(detail: TranscriptDetail, window: ContextWindow): String {
        val start = utf16Length(detail.text, window.offset)
        val end = utf16Length(detail.text, window.end)
        if (start >= detail.text.length) return ""
        return detail.text.substring(start.coerceAtLeast(0), end.coerceIn(start, detail.text.length))
    }

    private fun snippet(text: String, index: Int, length: Int): String {
        val start = (index - 48).coerceAtLeast(0)
        val end = (index + length + 96).coerceAtMost(text.length)
        return text.substring(start, end).replace('\n', ' ').trim()
    }

    private fun syntheticWindow(source: ContextSource): ContextWindow = ContextWindow(
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
    )

    private suspend fun loadDetailPages(
        source: ContextSource,
        window: ContextWindow?,
        request: Int,
        startOffset: Int,
        initial: TranscriptDetail,
    ) {
        var offset = startOffset
        var text = initial.text
        val spans = LinkedHashMap<String, ContextSpan>()
        initial.spans.forEach { spans[it.id] = it }
        try {
            while (true) {
                val page = withContext(Dispatchers.IO) {
                    api.contextSource(connection, credential, source, offset = offset, limit = 24_000)
                }
                if (request != detailRequest) return
                if (page.sourceRevision.isNotEmpty() && source.revision.isNotEmpty() &&
                    page.sourceRevision != source.revision
                ) {
                    throw IOException("Transcript changed; reload the list")
                }
                text += page.text
                page.spans.forEach { spans.putIfAbsent(it.id, it) }
                val next = page.nextOffset
                val nextDetail = TranscriptDetail(
                    source = source,
                    window = window,
                    text = text,
                    spans = spans.values.toList(),
                    nextOffset = next,
                    complete = next == null,
                )
                _state.update {
                    if (request != detailRequest) it
                    else it.copy(
                        detail = nextDetail,
                        detailLoading = next != null,
                        detailFailure = null,
                    )
                }
                if (next == null || next <= offset) break
                offset = next
            }
            _state.update { if (request == detailRequest) it.copy(detailLoading = false) else it }
            val loaded = _state.value.detail
            if (loaded != null && loaded.complete && loaded.source.id == source.id) {
                synchronized(fullSources) {
                    fullSources[cacheKey(source)] = loaded
                    while (fullSources.size > 24) {
                        val oldest = fullSources.keys.firstOrNull() ?: break
                        fullSources.remove(oldest)
                    }
                }
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (request == detailRequest) {
                _state.update { it.copy(detailLoading = false, detailFailure = error.message) }
            }
        }
    }

    private suspend fun loadFullSource(source: ContextSource): TranscriptDetail {
        synchronized(fullSources) { fullSources[cacheKey(source)] }?.let { return it }
        var offset = 0
        var text = ""
        val spans = LinkedHashMap<String, ContextSpan>()
        while (true) {
            val page = withContext(Dispatchers.IO) {
                api.contextSource(connection, credential, source, offset = offset, limit = 24_000)
            }
            if (page.sourceRevision.isNotEmpty() && source.revision.isNotEmpty() && page.sourceRevision != source.revision) {
                throw IOException("Transcript changed; reload the list")
            }
            text += page.text
            page.spans.forEach { spans.putIfAbsent(it.id, it) }
            val next = page.nextOffset
            if (next == null || next <= offset) break
            offset = next
        }
        val detail = TranscriptDetail(source, text = text, spans = spans.values.toList(), complete = true)
        synchronized(fullSources) {
            fullSources[cacheKey(source)] = detail
            while (fullSources.size > 24) {
                val oldest = fullSources.keys.firstOrNull() ?: break
                fullSources.remove(oldest)
            }
        }
        return detail
    }

    private fun cacheKey(source: ContextSource): String = source.id + "@" + source.revision

    /** Number of UTF-16 units represented in the first [codePoints] code points. */
    fun utf16Length(text: String, codePoints: Int): Int {
        if (codePoints <= 0) return 0
        var units = 0
        var points = 0
        while (units < text.length && points < codePoints) {
            val isPair = Character.isHighSurrogate(text[units]) &&
                units + 1 < text.length && Character.isLowSurrogate(text[units + 1])
            units += if (isPair) 2 else 1
            points += 1
        }
        return units
    }
}
