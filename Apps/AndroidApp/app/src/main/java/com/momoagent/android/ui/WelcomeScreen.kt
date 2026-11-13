package com.momoagent.android.ui

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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.momoagent.android.R

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
    var index by rememberSaveable { mutableIntStateOf(0) }
    val ready = index == welcomeScenarios.size
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
            if (!ready) TextButton(onClick = onFinish) {
                Text(stringResource(R.string.welcome_skip), style = MoMoType.menu, color = palette.muted)
            }
        }
        Crossfade(targetState = index, modifier = Modifier.weight(1f).widthIn(max = 480.dp).fillMaxWidth(), label = "scenario") { page ->
            val scenario = welcomeScenarios.getOrNull(page)
            Column(
                modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = 20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                AvatarView(
                    size = if (scenario == null) 180.dp else 112.dp,
                    expression = when (page) {
                        0 -> "listening"
                        1 -> "thinking"
                        2 -> "speaking"
                        else -> "greeting"
                    },
                    active = true,
                )
                BrandWordmark("MoMoWordmark", height = 18.dp)
                Spacer(Modifier.height(20.dp))
                Text(stringResource(scenario?.title ?: R.string.brand_tagline), style = MoMoType.title,
                    color = palette.ink, textAlign = TextAlign.Center)
                if (scenario != null) ScenarioConversation(scenario)
            }
        }
        Column(
            modifier = Modifier.widthIn(max = 480.dp).fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (!ready) {
                Row(horizontalArrangement = Arrangement.spacedBy(5.dp), modifier = Modifier.padding(vertical = 12.dp)) {
                    welcomeScenarios.indices.forEach { page ->
                        Box(Modifier.size(if (index == page) 20.dp else 6.dp, 6.dp)
                            .background(if (page == index) palette.ink else palette.line, CircleShape))
                    }
                }
            }
            ClientPrimaryButton(
                title = stringResource(if (ready) R.string.welcome_start_pairing else R.string.welcome_continue),
                onClick = { if (ready) onFinish() else index++ },
            )
            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun ScenarioConversation(scenario: WelcomeScenario) {
    val palette = LocalMoMoPalette.current
    Column(Modifier.fillMaxWidth().padding(top = 22.dp)) {
        scenario.moments.zip(scenario.sources).forEach { (moment, source) ->
            Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(source), style = MoMoType.caption, color = palette.muted,
                    modifier = Modifier.width(88.dp))
                Text(stringResource(moment), style = MoMoType.menu, color = palette.ink)
            }
        }
        HorizontalDivider(Modifier.padding(vertical = 16.dp), color = palette.line)
        Text(stringResource(scenario.request), style = MoMoType.body, color = palette.canvas,
            modifier = Modifier.align(Alignment.End)
                .background(palette.ink, RoundedCornerShape(18.dp, 18.dp, 4.dp, 18.dp))
                .padding(horizontal = 14.dp, vertical = 9.dp))
        Spacer(Modifier.height(12.dp))
        Text(stringResource(scenario.reply), style = MoMoType.body, color = palette.ink)
        Spacer(Modifier.height(10.dp))
        Row(
            modifier = Modifier.fillMaxWidth().background(palette.surface, RoundedCornerShape(14.dp)).padding(14.dp),
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
