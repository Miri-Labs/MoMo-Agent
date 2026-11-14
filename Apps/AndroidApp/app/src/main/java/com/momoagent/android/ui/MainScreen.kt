package com.momoagent.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Article
import androidx.compose.material.icons.filled.ChatBubbleOutline
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.momoagent.android.R
import com.momoagent.android.remote.ConnectionState

@Composable
fun MainScreen(viewModel: AppViewModel) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var settings by rememberSaveable { mutableStateOf(false) }

    if (settings) {
        androidx.activity.compose.BackHandler { settings = false }
        SettingsScreen(
            viewModel = viewModel,
            onClose = { settings = false },
            onRepair = {
                settings = false
                viewModel.advance(SetupStep.Connect)
            },
        )
        return
    }

    val conversation = viewModel.conversationStore
    val context = viewModel.contextStore
    val discussPrompt = stringResource(R.string.transcripts_discuss_prompt)
    val density = LocalDensity.current
    val imeVisible = WindowInsets.ime.getBottom(density) > 0
    val tabs = listOf(
        Icons.Filled.ChatBubbleOutline to stringResource(R.string.chat_tab),
        Icons.Filled.Article to stringResource(R.string.transcripts_tab),
        Icons.Filled.Psychology to stringResource(R.string.memory_tab),
    )

    Scaffold(
        containerColor = Color.Transparent,
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        bottomBar = {
            if (!imeVisible) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .padding(horizontal = 24.dp, vertical = 6.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    GlassTabBar(
                        items = tabs,
                        selected = tab,
                        onSelect = { tab = it },
                        modifier = Modifier.widthIn(max = 360.dp),
                    )
                }
            }
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            when (tab) {
                0 -> if (conversation != null) {
                    ChatScreen(
                        store = conversation,
                        contextStore = context,
                        onSettings = { settings = true },
                        onOpenTranscripts = { tab = 1 },
                        onOpenMemory = { tab = 2 },
                    )
                } else {
                    EmptyChat(
                        onStartPairing = { viewModel.advance(SetupStep.Connect) },
                        onSettings = { settings = true },
                        onOpenTranscripts = { tab = 1 },
                    )
                }
                1 -> TranscriptsScreen(
                    contextStore = context,
                    onConnect = { viewModel.advance(SetupStep.Connect) },
                    onSettings = { settings = true },
                    onDiscuss = { citations ->
                        val store = conversation
                        if (store != null && citations.isNotEmpty()) {
                            store.setDraft(discussPrompt + "\n" + citations.joinToString("\n"))
                            tab = 0
                        }
                    },
                )
                else -> MemoryScreen(
                    contextStore = context,
                    onConnect = { viewModel.advance(SetupStep.Connect) },
                    onSettings = { settings = true },
                )
            }
        }
    }
}

@Composable
private fun EmptyChat(onStartPairing: () -> Unit, onSettings: () -> Unit, onOpenTranscripts: () -> Unit) {
    val palette = LocalMoMoPalette.current
    var showingStatus by rememberSaveable { mutableStateOf(false) }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Box(modifier = Modifier.fillMaxWidth()) {
            GlassIconButton(
                icon = Icons.Filled.Settings,
                label = stringResource(R.string.chat_settings),
                onClick = onSettings,
                modifier = Modifier.align(Alignment.CenterStart),
            )
        }
        Box(
            modifier = Modifier.fillMaxWidth().weight(1f),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                modifier = Modifier.padding(top = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box {
                    AvatarView(
                        size = 120.dp,
                        expression = "present",
                        active = !showingStatus,
                    )
                    CaptureStatusBadge(
                        onClick = { showingStatus = true },
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .offset(x = 8.dp, y = 8.dp),
                    )
                }
                Spacer(Modifier.height(6.dp))
                BrandWordmark("MoMoWordmark", height = 26.dp)
                Spacer(Modifier.height(16.dp))
                Text(stringResource(R.string.brand_tagline), style = MoMoType.subheading, color = palette.muted)
            }
        }
        ClientPrimaryButton(stringResource(R.string.chat_start_pairing), onStartPairing)
        Spacer(Modifier.height(20.dp))
    }
    if (showingStatus) {
        CaptureStatusDialog(
            status = ConnectionState.Unavailable,
            onOpenTranscripts = {
                showingStatus = false
                onOpenTranscripts()
            },
            onSettings = {
                showingStatus = false
                onSettings()
            },
            onClose = { showingStatus = false },
        )
    }
}
