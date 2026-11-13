package com.momoagent.android.ui

import androidx.compose.animation.Crossfade
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.Flight
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.momoagent.android.BuildConfig
import com.momoagent.android.R
import kotlinx.coroutines.delay

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
    var ready by rememberSaveable { mutableStateOf(false) }

    fun advance() {
        if (ready) onFinish() else if (index < welcomeScenarios.lastIndex) index += 1 else ready = true
    }

    LaunchedEffect(index, ready) {
        if (!ready) {
            delay(4_000)
            if (index < welcomeScenarios.lastIndex) index += 1 else ready = true
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            BrandIcon(size = 28.dp)
            Spacer(Modifier.width(10.dp))
            BrandWordmark("PhoneWordmark", height = 17.dp)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = onFinish) {
                Text(stringResource(R.string.welcome_skip), color = palette.muted, style = MoMoType.metadata)
            }
        }
        Spacer(Modifier.height(18.dp))
        Crossfade(targetState = ready, label = "welcome-ready") { settled ->
            if (settled) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    AvatarView(size = 220.dp, expression = "greeting", active = true)
                    Spacer(Modifier.height(10.dp))
                    BrandWordmark("MoMoWordmark", height = 24.dp)
                    Spacer(Modifier.height(18.dp))
                    Text(
                        text = stringResource(R.string.brand_tagline),
                        style = MoMoType.title,
                        color = palette.ink,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(28.dp))
                    Button(
                        onClick = onFinish,
                        shape = CircleShape,
                        colors = ButtonDefaults.buttonColors(containerColor = palette.ink, contentColor = palette.canvas),
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(52.dp),
                    ) {
                        Text(stringResource(R.string.welcome_start_pairing), style = MoMoType.body, fontWeight = FontWeight.Medium)
                    }
                }
            } else {
                val scenario = welcomeScenarios[index]
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    AvatarView(
                        size = 200.dp,
                        expression = when (index) {
                            0 -> "listening"
                            1 -> "thinking"
                            else -> "speaking"
                        },
                        active = true,
                    )
                    Spacer(Modifier.height(4.dp))
                    BrandWordmark("MoMoWordmark", height = 20.dp)
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = stringResource(scenario.title),
                        style = MoMoType.title,
                        color = palette.ink,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(18.dp))
                    scenario.moments.forEach { moment ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 3.dp),
                        ) {
                            Box(Modifier.size(6.dp).background(palette.muted, CircleShape))
                            Spacer(Modifier.width(10.dp))
                            Text(stringResource(moment), style = MoMoType.body, color = palette.muted)
                        }
                    }
                    Spacer(Modifier.height(10.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        scenario.sources.forEach { source ->
                            Surface(
                                color = palette.surface,
                                shape = CircleShape,
                            ) {
                                Text(
                                    text = stringResource(source),
                                    style = MoMoType.caption,
                                    color = palette.muted,
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                                )
                            }
                        }
                    }
                    Spacer(Modifier.height(20.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                            Surface(color = palette.ink, shape = RoundedCornerShape(20.dp)) {
                                Text(
                                    text = stringResource(scenario.request),
                                    style = MoMoType.body,
                                    color = palette.canvas,
                                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                                )
                            }
                        }
                        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Start) {
                            Surface(color = palette.surface, shape = RoundedCornerShape(20.dp)) {
                                Text(
                                    text = stringResource(scenario.reply),
                                    style = MoMoType.body,
                                    color = palette.ink,
                                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                                )
                            }
                        }
                        GlassSurface(
                            modifier = Modifier.fillMaxWidth(),
                            shape = RoundedCornerShape(18.dp),
                            contentPadding = PaddingValues(14.dp),
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Surface(color = palette.surface, shape = CircleShape) {
                                    Icon(
                                        imageVector = scenario.icon,
                                        contentDescription = null,
                                        tint = palette.ink,
                                        modifier = Modifier.padding(9.dp).size(18.dp),
                                    )
                                }
                                Spacer(Modifier.width(12.dp))
                                Column {
                                    Text(stringResource(scenario.result), style = MoMoType.section, color = palette.ink)
                                    Text(stringResource(scenario.detail), style = MoMoType.metadata, color = palette.muted)
                                }
                                Spacer(Modifier.weight(1f))
                                Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = palette.success)
                            }
                        }
                    }
                    Spacer(Modifier.height(28.dp))
                    Button(
                        onClick = { advance() },
                        shape = CircleShape,
                        colors = ButtonDefaults.buttonColors(containerColor = palette.ink, contentColor = palette.canvas),
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(52.dp),
                    ) {
                        Text(stringResource(R.string.welcome_continue), style = MoMoType.body, fontWeight = FontWeight.Medium)
                    }
                }
            }
        }
        Spacer(Modifier.height(20.dp))
        Text(
            text = "MoMo Agent ${BuildConfig.VERSION_NAME}",
            style = MoMoType.caption,
            color = palette.muted,
        )
    }
}
