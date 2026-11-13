package com.momoagent.android.remote

import com.momoagent.android.data.AgentApi
import com.momoagent.android.data.AgentConnection
import com.momoagent.android.data.ContextMemory
import com.momoagent.android.data.ContextSource
import com.momoagent.android.data.SourceTextPage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class ContextState(
    val memories: List<ContextMemory> = emptyList(),
    val sources: List<ContextSource> = emptyList(),
    val loading: Boolean = false,
    val failure: String? = null,
    val sourceDetail: SourceTextPage? = null,
    val sourceDetailSource: ContextSource? = null,
    val detailLoading: Boolean = false,
    val detailFailure: String? = null,
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

    fun loadAll() {
        loadMemories()
        loadSources()
    }

    fun refresh() = loadAll()

    fun loadMemories() {
        scope.launch {
            _state.update { it.copy(loading = true, failure = null) }
            try {
                val page = withContext(Dispatchers.IO) {
                    api.contextMemories(connection, credential, limit = 100)
                }
                _state.update {
                    it.copy(memories = page.items, loading = false, failure = null)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update { it.copy(loading = false, failure = error.message) }
            }
        }
    }

    fun loadSources() {
        scope.launch {
            try {
                val page = withContext(Dispatchers.IO) {
                    api.contextSources(connection, credential, limit = 50)
                }
                _state.update { it.copy(sources = page.items) }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update { it.copy(failure = error.message) }
            }
        }
    }

    fun openSource(source: ContextSource) {
        scope.launch {
            _state.update {
                it.copy(sourceDetail = null, sourceDetailSource = source, detailLoading = true, detailFailure = null)
            }
            try {
                val page = withContext(Dispatchers.IO) {
                    api.contextSource(connection, credential, source)
                }
                _state.update {
                    it.copy(sourceDetail = page, sourceDetailSource = source, detailLoading = false)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update {
                    it.copy(detailLoading = false, detailFailure = error.message)
                }
            }
        }
    }

    fun closeDetail() {
        _state.update { it.copy(sourceDetail = null, sourceDetailSource = null, detailFailure = null) }
    }
}
