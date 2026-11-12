package com.momoagent.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.momoagent.android.R
import com.momoagent.android.data.PairingFailure

@Composable
fun MoMoApp(viewModel: AppViewModel = viewModel()) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    when (val value = state) {
        AppState.Loading -> LoadingScreen()
        AppState.Unpaired -> PairingScreen(onPair = viewModel::beginPairing)
        is AppState.Pairing -> PairingProgressScreen(value.value, viewModel::cancelPairing)
        is AppState.Chat -> ChatScreen(
            state = value.value,
            onSend = viewModel::send,
            onRetry = viewModel::retryLoad,
            onDismissFailure = viewModel::dismissChatFailure,
            onUnpair = viewModel::unpair,
        )
    }
}

@Composable
private fun LoadingScreen() {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator(color = MaterialTheme.colorScheme.onBackground)
    }
}

@Composable
private fun PairingProgressScreen(value: PairingState, onCancel: () -> Unit) {
    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = androidx.compose.foundation.layout.Arrangement.Center,
        ) {
            if (value.failure != null) {
                Text(
                    text = stringResource(R.string.pairing_failed),
                    style = MaterialTheme.typography.titleLarge,
                )
                Spacer(Modifier.height(16.dp))
                Text(
                    text = failureText(value.failure),
                    color = MaterialTheme.colorScheme.error,
                    textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(24.dp))
                Button(onClick = onCancel) {
                    Text(stringResource(R.string.pairing_back))
                }
            } else {
                CircularProgressIndicator()
                Spacer(Modifier.height(20.dp))
                Text(
                    text = when (value.stage) {
                        PairingStage.Reading -> stringResource(R.string.pairing_reading)
                        PairingStage.Contacting -> stringResource(R.string.pairing_contacting)
                        PairingStage.WaitingForApproval -> value.code?.let {
                            stringResource(R.string.pairing_approve_code, it)
                        } ?: stringResource(R.string.pairing_waiting)
                    },
                    textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.bodyLarge,
                )
                if (value.stage == PairingStage.WaitingForApproval) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        text = stringResource(R.string.pairing_waiting),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }
    }
}

@Composable
private fun failureText(failure: PairingFailure): String = stringResource(
    when (failure) {
        PairingFailure.InvalidCode -> R.string.pairing_invalid
        PairingFailure.HttpsRequired -> R.string.pairing_https
        PairingFailure.RelayUnsupported -> R.string.pairing_relay_unsupported
        PairingFailure.Timeout -> R.string.pairing_timeout
        PairingFailure.Denied -> R.string.pairing_denied
        PairingFailure.Identity -> R.string.pairing_identity
        PairingFailure.Unavailable -> R.string.pairing_unavailable
    },
)
