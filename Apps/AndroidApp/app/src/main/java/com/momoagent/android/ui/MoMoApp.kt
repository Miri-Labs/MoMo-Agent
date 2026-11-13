package com.momoagent.android.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Modifier
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewmodel.compose.viewModel

@Composable
fun MoMoApp(viewModel: AppViewModel = viewModel()) {
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_START -> viewModel.onStart()
                Lifecycle.Event.ON_STOP -> viewModel.onStop()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        LiquidBackdrop()
        when (viewModel.setup) {
            SetupStep.Welcome -> WelcomeScreen(onFinish = { viewModel.advance(SetupStep.Connect) })
            SetupStep.Connect -> ConnectionScreen(viewModel)
            SetupStep.Completed, SetupStep.Deferred -> MainScreen(viewModel)
        }
    }
}
