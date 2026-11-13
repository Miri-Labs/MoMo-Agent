package com.momoagent.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
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
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.momoagent.android.BuildConfig
import com.momoagent.android.R
import com.momoagent.android.remote.ConnectionState

@Composable
fun SettingsScreen(
    viewModel: AppViewModel,
    onClose: () -> Unit,
    onRepair: () -> Unit,
) {
    val palette = LocalMoMoPalette.current
    val context = LocalContext.current
    val saved = viewModel.storedPairing
    val conversation = viewModel.conversationStore
    val chatState = if (conversation != null) {
        val value by conversation.state.collectAsStateWithLifecycle()
        value
    } else {
        null
    }
    var manual by rememberSaveable { mutableStateOf(false) }
    var confirmUnpair by rememberSaveable { mutableStateOf(false) }

    val connectionLabel = when (chatState?.connection) {
        ConnectionState.Ready -> stringResource(R.string.settings_connected)
        ConnectionState.Connecting -> stringResource(R.string.settings_connecting)
        ConnectionState.Retrying -> stringResource(R.string.settings_retrying)
        ConnectionState.AuthenticationRequired -> stringResource(R.string.settings_auth_required)
        ConnectionState.Unavailable, null -> stringResource(R.string.settings_unavailable)
    }
    val route = when (saved?.connection?.network) {
        "lan" -> stringResource(R.string.settings_lan)
        "tailscale" -> stringResource(R.string.settings_tailscale)
        "relay" -> stringResource(R.string.settings_relay)
        else -> "HTTPS"
    }
    val version = BuildConfig.VERSION_NAME

    Surface(color = androidx.compose.ui.graphics.Color.Transparent, modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 12.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.settings_title), style = MoMoType.title, color = palette.ink,
                    modifier = Modifier.weight(1f))
                TextButton(onClick = onClose) {
                    Text(stringResource(R.string.settings_done), style = MoMoType.menu, color = palette.ink)
                }
            }
            SettingsSection(stringResource(R.string.settings_mac)) {
                SettingsSurface {
                    SettingsValue(
                        title = stringResource(R.string.settings_pairing_status),
                        value = if (saved != null) stringResource(R.string.settings_paired)
                        else stringResource(R.string.settings_unpaired),
                    )
                    Divider()
                    SettingsValue(
                        title = stringResource(R.string.settings_connection_status),
                        value = connectionLabel,
                    )
                    Divider()
                    if (saved != null) {
                        SettingsAction(stringResource(R.string.settings_reconnect), viewModel::reconnect)
                        Divider()
                    }
                    SettingsAction(stringResource(R.string.settings_repair), onRepair)
                    Divider()
                    SettingsAction(stringResource(R.string.connect_manual)) { manual = true }
                }
            }
            if (saved != null) {
                SettingsSection(stringResource(R.string.settings_network)) {
                    SettingsSurface {
                        SettingsValue(stringResource(R.string.settings_route), route)
                        Divider()
                        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp)) {
                            Text(stringResource(R.string.settings_address), style = MoMoType.menu, color = palette.ink)
                            Spacer(Modifier.padding(top = 4.dp))
                            SelectionContainer {
                                Text(saved.connection.baseURL, style = MoMoType.metadata, color = palette.muted)
                            }
                        }
                    }
                }
            }
            SettingsSection(stringResource(R.string.settings_about)) {
                SettingsSurface {
                    SettingsValue(stringResource(R.string.settings_version), version)
                }
            }
            if (saved != null) SettingsSection(stringResource(R.string.settings_data)) {
                SettingsSurface {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { confirmUnpair = true }
                            .padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = stringResource(R.string.settings_unpair),
                            style = MoMoType.menu,
                            color = palette.failure,
                        )
                    }
                    if (viewModel.unpairFailed) {
                        Text(
                            text = stringResource(R.string.settings_unpair_failed),
                            style = MoMoType.caption,
                            color = palette.failure,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
                        )
                    }
                }
            }
            Spacer(Modifier.padding(top = 20.dp))
        }
    }

    if (manual) {
        ManualConnectionDialog(viewModel = viewModel, onClose = { manual = false })
    }

    if (confirmUnpair) {
        GlassDialog(
            onDismiss = { confirmUnpair = false },
            title = stringResource(R.string.settings_unpair_title),
            confirmLabel = stringResource(R.string.settings_unpair),
            dismissLabel = stringResource(R.string.settings_cancel),
            onConfirm = {
                confirmUnpair = false
                viewModel.unpair()
            },
        ) {
            Text(stringResource(R.string.settings_unpair_body), color = palette.muted)
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable () -> Unit) {
    val palette = LocalMoMoPalette.current
    Column(modifier = Modifier.padding(top = 20.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MoMoType.section, color = palette.muted, modifier = Modifier.padding(start = 4.dp))
        content()
    }
}

@Composable
private fun SettingsSurface(content: @Composable () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = LocalMoMoPalette.current.surface,
        shape = RoundedCornerShape(14.dp),
    ) {
        Column(modifier = Modifier.fillMaxWidth()) { content() }
    }
}

@Composable
private fun SettingsValue(title: String, value: String) {
    val palette = LocalMoMoPalette.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MoMoType.menu, color = palette.ink)
        Spacer(Modifier.weight(1f))
        Text(value, style = MoMoType.metadata, color = palette.muted)
    }
}

@Composable
private fun SettingsAction(title: String, onClick: () -> Unit) {
    val palette = LocalMoMoPalette.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, style = MoMoType.menu, color = palette.ink)
        Spacer(Modifier.weight(1f))
        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = palette.muted)
    }
}

@Composable
private fun Divider() {
    HorizontalDivider(Modifier.padding(start = 16.dp), color = LocalMoMoPalette.current.line, thickness = 0.75.dp)
}
