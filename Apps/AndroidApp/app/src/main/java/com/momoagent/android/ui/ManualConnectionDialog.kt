package com.momoagent.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.momoagent.android.R

@Composable
fun ManualConnectionDialog(viewModel: AppViewModel, onClose: () -> Unit) {
    var configuration by rememberSaveable { mutableStateOf("") }
    var credential by rememberSaveable { mutableStateOf("") }
    val palette = LocalMoMoPalette.current
    val connecting = viewModel.manualConnecting
    var entrySuccess by rememberSaveable { mutableIntStateOf(viewModel.manualSuccess) }

    LaunchedEffect(viewModel.manualSuccess) {
        if (viewModel.manualSuccess != entrySuccess) {
            credential = ""
            onClose()
        }
    }

    GlassDialog(
        onDismiss = { if (!connecting) onClose() },
        title = stringResource(R.string.manual_title),
        confirmLabel = stringResource(if (connecting) R.string.manual_saving else R.string.manual_save),
        dismissLabel = stringResource(R.string.settings_cancel),
        confirmEnabled = !connecting && configuration.isNotBlank() && credential.isNotBlank(),
        dismissEnabled = !connecting,
        onConfirm = { viewModel.manualConnect(configuration, credential) },
    ) {
        Column(
            modifier = Modifier.verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (connecting) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        strokeWidth = 2.dp,
                        color = palette.muted,
                    )
                    Text(stringResource(R.string.manual_saving), style = MoMoType.caption, color = palette.muted)
                }
            }
            OutlinedTextField(
                value = configuration,
                onValueChange = { configuration = it },
                enabled = !connecting,
                label = { Text(stringResource(R.string.manual_connection)) },
                minLines = 4,
                maxLines = 8,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = credential,
                onValueChange = { credential = it },
                enabled = !connecting,
                label = { Text(stringResource(R.string.manual_credential)) },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth(),
            )
            Text(
                text = stringResource(R.string.manual_connection_hint),
                style = MoMoType.caption,
                color = palette.muted,
            )
            viewModel.manualFailure?.let {
                Text(it, style = MoMoType.caption, color = palette.failure)
            }
        }
    }
}
