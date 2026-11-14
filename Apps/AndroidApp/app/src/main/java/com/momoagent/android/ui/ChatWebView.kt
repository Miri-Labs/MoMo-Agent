package com.momoagent.android.ui

import android.graphics.Color as AndroidColor
import android.os.Handler
import android.os.Looper
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import org.json.JSONObject

/**
 * Hosts the iPhone chat renderer (assets/chat) unchanged apart from a tiny
 * window.webkit shim that forwards its messages to AndroidChat.
 */
@Composable
fun ChatWebView(
    payload: String,
    onEvent: (type: String, value: JSONObject) -> Unit,
    modifier: Modifier = Modifier,
) {
    val currentEvent = rememberUpdatedState(onEvent)
    val controller = remember { ChatWebController() }
    SideEffect { controller.onEvent = { type, value -> currentEvent.value(type, value) } }

    AndroidView(
        factory = { context ->
            WebView(context).apply {
                setBackgroundColor(AndroidColor.TRANSPARENT)
                isVerticalScrollBarEnabled = false
                isHorizontalScrollBarEnabled = false
                overScrollMode = View.OVER_SCROLL_NEVER
                settings.javaScriptEnabled = true
                settings.allowFileAccess = true
                settings.allowContentAccess = false
                settings.blockNetworkLoads = true
                settings.domStorageEnabled = false
                settings.mediaPlaybackRequiresUserGesture = false
                settings.setSupportZoom(false)
                settings.builtInZoomControls = false
                settings.displayZoomControls = false
                settings.useWideViewPort = true
                settings.loadWithOverviewMode = true
                settings.cacheMode = android.webkit.WebSettings.LOAD_DEFAULT
                addJavascriptInterface(AndroidChatBridge(controller), "AndroidChat")
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean = true
                }
                controller.web = this
                loadUrl("file:///android_asset/chat/index.html")
            }
        },
        update = { controller.render(payload) },
        modifier = modifier,
    )

    DisposableEffect(controller) {
        onDispose { controller.destroy() }
    }
}

private class AndroidChatBridge(private val controller: ChatWebController) {
    @JavascriptInterface
    fun postMessage(value: String) = controller.receive(value)
}

private class ChatWebController {
    var web: WebView? = null
    var onEvent: ((String, JSONObject) -> Unit)? = null
    private var ready = false
    private var pending: String? = null

    fun render(payload: String) {
        pending = payload
        if (ready) flush()
    }

    fun receive(raw: String) {
        val message = runCatching { JSONObject(raw) }.getOrNull() ?: return
        val type = message.optString("type")
        if (type == "ready") {
            Handler(Looper.getMainLooper()).post {
                ready = true
                flush()
            }
            return
        }
        val rawValue = message.opt("value")
        val value = rawValue as? JSONObject ?: JSONObject().put("value", rawValue)
        Handler(Looper.getMainLooper()).post { onEvent?.invoke(type, value) }
    }

    private fun flush() {
        val payload = pending ?: return
        web?.evaluateJavascript("window.MoMoChat && window.MoMoChat.render($payload)", null)
    }

    fun destroy() {
        web?.removeJavascriptInterface("AndroidChat")
        web?.stopLoading()
        web?.destroy()
        web = null
        ready = false
    }
}
