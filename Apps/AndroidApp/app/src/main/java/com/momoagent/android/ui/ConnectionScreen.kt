package com.momoagent.android.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.momoagent.android.R
import com.momoagent.android.data.PairingFailure
import com.momoagent.android.remote.PairingStage

@Composable
fun ConnectionScreen(viewModel: AppViewModel) {
    val palette = LocalMoMoPalette.current
    val pairing by viewModel.pairing.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    var scanning by rememberSaveable { mutableStateOf(false) }
    var manual by rememberSaveable { mutableStateOf(false) }
    var help by rememberSaveable { mutableStateOf(false) }

    if (scanning) {
        androidx.activity.compose.BackHandler { scanning = false }
        QrScanner(
            onResult = { value ->
                scanning = false
                viewModel.scan(value)
            },
            onClose = { scanning = false },
        )
        return
    }

    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        Column(
            modifier = Modifier.widthIn(max = 520.dp)
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                BrandIcon(size = 28.dp)
                Spacer(Modifier.width(10.dp))
                BrandWordmark("PhoneWordmark", height = 17.dp)
                Spacer(Modifier.weight(1f))
                TextButton(onClick = { help = true }) {
                    Text(stringResource(R.string.connect_help), color = palette.muted, style = MoMoType.metadata)
                }
            }
            Spacer(Modifier.height(36.dp))
            val bezel = RoundedCornerShape(14.dp)
            Box(
                modifier = Modifier.size(168.dp, 109.dp).background(palette.paper, bezel).border(2.dp, palette.ink, bezel),
                contentAlignment = Alignment.Center,
            ) {
                AvatarView(
                    size = 90.dp,
                    expression = if (pairing.stage == PairingStage.Approved) "settled" else "present",
                    active = false,
                )
            }
            Spacer(Modifier.size(3.dp, 8.dp).background(palette.ink))
            Spacer(Modifier.size(42.dp, 3.dp).background(palette.ink, CircleShape))
            Spacer(Modifier.height(28.dp))

            when {
                pairing.stage == PairingStage.Approved -> {
                    Text(
                        text = stringResource(R.string.connect_success),
                        style = MoMoType.title,
                        color = palette.ink,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(10.dp))
                    Text(
                        text = stringResource(R.string.connect_verified),
                        style = MoMoType.body,
                        color = palette.success,
                    )
                    Spacer(Modifier.height(28.dp))
                    ClientPrimaryButton(
                        title = stringResource(R.string.connect_start_chat),
                        onClick = viewModel::finishPairing,
                    )
                }
                pairing.failure != null -> {
                    Text(
                        text = stringResource(R.string.connect_ended),
                        style = MoMoType.title,
                        color = palette.ink,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(10.dp))
                    Text(
                        text = failureText(pairing.failure!!, pairing.transient),
                        style = MoMoType.body,
                        color = palette.failure,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(28.dp))
                    ClientPrimaryButton(
                        title = stringResource(R.string.connect_rescan),
                        onClick = {
                            viewModel.clearPairing()
                            scanning = true
                        },
                    )
                    if (pairing.transient) {
                        Spacer(Modifier.height(8.dp))
                        TextButton(onClick = viewModel::retryPairing) {
                            Text(stringResource(R.string.connect_retry), color = palette.muted)
                        }
                    }
                }
                pairing.stage == PairingStage.Contacting || pairing.stage == PairingStage.Waiting -> {
                    Text(
                        text = stringResource(R.string.connect_verify_code),
                        style = MoMoType.title,
                        color = palette.ink,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(12.dp))
                    if (pairing.code != null) {
                        GlassSurface(
                            shape = RoundedCornerShape(22.dp),
                            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 28.dp, vertical = 12.dp),
                        ) {
                            SelectionContainer {
                                Text(
                                    text = pairing.code.orEmpty(),
                                    style = MoMoType.title.copy(
                                        fontFamily = FontFamily.Monospace,
                                        fontSize = 36.sp,
                                        letterSpacing = 4.sp,
                                        fontWeight = FontWeight.Medium,
                                    ),
                                    color = palette.ink,
                                )
                            }
                        }
                        Spacer(Modifier.height(10.dp))
                    }
                    if (pairing.stage == PairingStage.Contacting) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp, color = palette.muted)
                        Spacer(Modifier.height(10.dp))
                        Text(stringResource(R.string.connect_contacting), style = MoMoType.metadata, color = palette.muted)
                    } else {
                        Text(
                            text = if (pairing.receiptState == "approved") {
                                stringResource(R.string.connect_mac_allowed)
                            } else {
                                stringResource(R.string.connect_confirm_hint)
                            },
                            style = MoMoType.metadata,
                            color = palette.muted,
                        )
                    }
                    if (pairing.network == "tailscale") {
                        Spacer(Modifier.height(10.dp))
                        Text(
                            text = stringResource(R.string.connect_tailscale_hint),
                            style = MoMoType.caption,
                            color = palette.muted,
                            textAlign = TextAlign.Center,
                        )
                    }
                    Spacer(Modifier.height(24.dp))
                    TextButton(onClick = {
                        viewModel.clearPairing()
                        scanning = true
                    }) {
                        Text(stringResource(R.string.connect_rescan), color = palette.muted)
                    }
                }
                else -> {
                    Text(
                        text = stringResource(R.string.connect_scan_title),
                        style = MoMoType.title,
                        color = palette.ink,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(10.dp))
                    Text(
                        text = stringResource(R.string.connect_scan_instructions),
                        style = MoMoType.body,
                        color = palette.muted,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(24.dp))
                    ClientPrimaryButton(
                        title = stringResource(R.string.connect_scan),
                        onClick = { scanning = true },
                    )
                    Spacer(Modifier.height(10.dp))
                    TextButton(onClick = viewModel::deferPairing) {
                        Text(stringResource(R.string.connect_later), color = palette.muted)
                    }
                }
            }
        }
    }

    if (manual) {
        ManualConnectionDialog(
            viewModel = viewModel,
            onClose = { manual = false },
        )
    }
    if (help) {
        AlertDialog(
            onDismissRequest = { help = false },
            title = { Text(stringResource(R.string.connect_help)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(stringResource(R.string.connect_lan_hint), style = MoMoType.body)
                    Text(stringResource(R.string.connect_tailscale_hint), style = MoMoType.body)
                    TextButton(onClick = { openTailscale(context) }) {
                        Text(stringResource(R.string.connect_tailscale_login))
                    }
                    TextButton(onClick = { help = false; manual = true }) {
                        Text(stringResource(R.string.connect_manual))
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { help = false }) { Text(stringResource(R.string.chat_notice_ok)) }
            },
        )
    }
}

@Composable
private fun failureText(failure: PairingFailure, transient: Boolean): String = stringResource(
    when (failure) {
        PairingFailure.InvalidCode -> R.string.connect_invalid_code
        PairingFailure.HttpsRequired -> R.string.connect_https
        PairingFailure.RelayUnsupported -> R.string.connect_relay_unsupported
        PairingFailure.Timeout -> R.string.connect_timeout
        PairingFailure.Denied -> R.string.connect_rejected
        PairingFailure.Identity -> R.string.connect_identity
        PairingFailure.Unavailable -> if (transient) R.string.connect_transient_failure else R.string.connect_unavailable
    },
)

private fun openTailscale(context: Context) {
    runCatching {
        val intent = context.packageManager.getLaunchIntentForPackage("com.tailscale.ipn")
        if (intent != null) {
            context.startActivity(intent)
        } else {
            context.startActivity(
                Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("https://play.google.com/store/apps/details?id=com.tailscale.ipn"),
                ),
            )
        }
    }
}
