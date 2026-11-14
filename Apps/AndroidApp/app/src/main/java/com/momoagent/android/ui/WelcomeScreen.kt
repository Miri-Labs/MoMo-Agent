package com.momoagent.android.ui

import android.content.Context
import android.view.accessibility.AccessibilityManager
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.Crossfade
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Flight
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.momoagent.android.R
import kotlinx.coroutines.delay

private const val STAGE_RESULT = 3

private data class WelcomeScenario(
    val title: Int,
    val moments: List<Int>,
    val sources: List<Int>,
    val request: Int,
    val reply: Int,
    val result: Int,
    val detail: Int,
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
)

private val welcomeScenarios = listOf(
    WelcomeScenario(
        R.string.welcome_travel_title,
        listOf(R.string.welcome_travel_moment_1, R.string.welcome_travel_moment_2),
        listOf(R.string.welcome_travel_source_1, R.string.welcome_travel_source_2),
        R.string.welcome_travel_request,
        R.string.welcome_travel_reply,
        R.string.welcome_travel_result,
        R.string.welcome_travel_detail,
        Icons.Filled.Flight,
    ),
    WelcomeScenario(
        R.string.welcome_work_title,
        listOf(R.string.welcome_work_moment_1, R.string.welcome_work_moment_2),
        listOf(R.string.welcome_work_source_1, R.string.welcome_work_source_2),
        R.string.welcome_work_request,
        R.string.welcome_work_reply,
        R.string.welcome_work_result,
        R.string.welcome_work_detail,
        Icons.Filled.Description,
    ),
    WelcomeScenario(
        R.string.welcome_family_title,
        listOf(R.string.welcome_family_moment_1, R.string.welcome_family_moment_2),
        listOf(R.string.welcome_family_source_1, R.string.welcome_family_source_2),
        R.string.welcome_family_request,
        R.string.welcome_family_reply,
        R.string.welcome_family_result,
        R.string.welcome_family_detail,
        Icons.Filled.Restaurant,
    ),
)

@Composable
fun WelcomeScreen(onFinish: () -> Unit) {
    val palette = LocalMoMoPalette.current
    val context = LocalContext.current
    val accessibility = remember(context) {
        context.getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
    }
    var touchExploration by remember { mutableStateOf(accessibility.isTouchExplorationEnabled) }
    DisposableEffect(accessibility) {
        val listener = AccessibilityManager.TouchExplorationStateChangeListener {
            touchExploration = it
        }
        accessibility.addTouchExplorationStateChangeListener(listener)
        onDispose { accessibility.removeTouchExplorationStateChangeListener(listener) }
    }

    val resumed by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    var index by rememberSaveable { mutableIntStateOf(0) }
    var stage by rememberSaveable { mutableIntStateOf(0) }
    val ready = index == welcomeScenarios.size

    val advance = {
        if (index < welcomeScenarios.size) {
            if (stage < STAGE_RESULT) {
                stage += 1
            } else if (index + 1 < welcomeScenarios.size) {
                index += 1
                stage = 0
            } else {
                index = welcomeScenarios.size
                stage = STAGE_RESULT
            }
        }
    }

    LaunchedEffect(index, stage, ready, touchExploration, resumed) {
        if (ready || touchExploration || !resumed.isAtLeast(Lifecycle.State.RESUMED)) return@LaunchedEffect
        delay(if (stage < STAGE_RESULT) 900 else 1_600)
        advance()
    }

    Column(
        modifier = Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()
            .padding(horizontal = 24.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            BrandIcon(size = 28.dp)
            Spacer(Modifier.width(10.dp))
            BrandWordmark("PhoneWordmark", height = 17.dp)
            Spacer(Modifier.weight(1f))
            if (!ready) {
                Text(
                    text = stringResource(R.string.welcome_demo),
                    style = MoMoType.caption,
                    color = palette.muted,
                    modifier = Modifier.padding(end = 4.dp),
                )
                TextButton(onClick = {
                    index = welcomeScenarios.size
                    stage = STAGE_RESULT
                }) {
                    Text(stringResource(R.string.welcome_skip), style = MoMoType.menu, color = palette.muted)
                }
            }
        }
        Crossfade(
            targetState = index,
            modifier = Modifier.weight(1f).widthIn(max = 480.dp).fillMaxWidth(),
            label = "scenario",
        ) { page ->
            val scenario = welcomeScenarios.getOrNull(page)
            Column(
                modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = 20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                if (scenario == null) {
                    AvatarView(size = 104.dp, expression = "greeting", active = true)
                    BrandWordmark("MoMoWordmark", height = 18.dp)
                    Spacer(Modifier.height(20.dp))
                    Text(
                        text = stringResource(R.string.brand_tagline),
                        style = MoMoType.title,
                        color = palette.ink,
                        textAlign = TextAlign.Center,
                    )
                } else {
                    AvatarView(
                        size = 112.dp,
                        expression = when (stage) {
                            0 -> "listening"
                            1 -> "thinking"
                            2 -> "speaking"
                            else -> "settled"
                        },
                        active = true,
                    )
                    BrandWordmark("MoMoWordmark", height = 18.dp)
                    Spacer(Modifier.height(20.dp))
                    Text(
                        text = stringResource(scenario.title),
                        style = MoMoType.title,
                        color = palette.ink,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        text = stringResource(R.string.welcome_demo_hint),
                        style = MoMoType.caption,
                        color = palette.muted,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                    ScenarioConversation(scenario, stage)
                }
            }
        }
        Column(
            modifier = Modifier.widthIn(max = 480.dp).fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (!ready) {
                Row(horizontalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.padding(vertical = 12.dp)) {
                    welcomeScenarios.indices.forEach { page ->
                        Box(
                            Modifier.size(if (index == page) 20.dp else 6.dp, 6.dp)
                                .background(if (page == index) palette.ink else palette.line, CircleShape),
                        )
                    }
                }
            }
            ClientPrimaryButton(
                title = stringResource(
                    when {
                        ready -> R.string.welcome_start_pairing
                        stage < STAGE_RESULT -> R.string.welcome_continue
                        else -> R.string.welcome_next_scene
                    },
                ),
                onClick = { if (ready) onFinish() else advance() },
            )
            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun ScenarioConversation(scenario: WelcomeScenario, stage: Int) {
    val palette = LocalMoMoPalette.current
    Column(Modifier.fillMaxWidth().padding(top = 22.dp)) {
        scenario.moments.zip(scenario.sources).forEach { (moment, source) ->
            Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    stringResource(source),
                    style = MoMoType.caption,
                    color = palette.muted,
                    modifier = Modifier.width(88.dp),
                )
                Text(stringResource(moment), style = MoMoType.menu, color = palette.ink)
            }
        }
        AnimatedVisibility(visible = stage >= 1) {
            Column(Modifier.fillMaxWidth()) {
                HorizontalDivider(Modifier.padding(vertical = 16.dp), color = palette.line)
                Text(
                    text = stringResource(scenario.request),
                    style = MoMoType.body,
                    color = palette.canvas,
                    modifier = Modifier.align(Alignment.End)
                        .background(palette.ink, RoundedCornerShape(18.dp, 18.dp, 4.dp, 18.dp))
                        .padding(horizontal = 14.dp, vertical = 9.dp),
                )
            }
        }
        AnimatedVisibility(visible = stage >= 2) {
            Text(
                text = stringResource(scenario.reply),
                style = MoMoType.body,
                color = palette.ink,
                modifier = Modifier.padding(top = 12.dp),
            )
        }
        AnimatedVisibility(visible = stage >= STAGE_RESULT) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 10.dp)
                    .background(palette.surface, RoundedCornerShape(14.dp)).padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Icon(scenario.icon, null, tint = palette.ink, modifier = Modifier.size(22.dp))
                Column {
                    Text(stringResource(scenario.result), style = MoMoType.section, color = palette.ink)
                    Text(stringResource(scenario.detail), style = MoMoType.metadata, color = palette.muted)
                }
            }
        }
    }
}
