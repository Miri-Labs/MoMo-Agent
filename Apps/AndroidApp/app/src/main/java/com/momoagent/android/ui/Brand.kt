package com.momoagent.android.ui

import android.graphics.Color as AndroidColor
import android.view.View
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.viewinterop.AndroidView
import com.momoagent.android.R
import org.json.JSONObject

/**
 * Brand artwork is pre-rendered from the iPhone SVG sources into tintable PNGs.
 * AndroidSVG rendered the outlined "Agent" glyphs and MoMoStill incorrectly on
 * device, so the PNGs are the source of truth for the Android client.
 */
@Composable
fun BrandWordmark(
    name: String,
    height: Dp,
    modifier: Modifier = Modifier,
    color: Color = LocalMoMoPalette.current.ink,
) {
    val resource = when (name) {
        "PhoneWordmark" -> R.drawable.phone_wordmark
        "MoMoWordmark" -> R.drawable.momo_wordmark
        "MoMoStill" -> R.drawable.momo_still
        else -> return
    }
    Image(
        painter = painterResource(resource),
        contentDescription = null,
        colorFilter = ColorFilter.tint(color),
        contentScale = ContentScale.Fit,
        modifier = modifier.height(height),
    )
}

@Composable
fun BrandIcon(size: Dp, modifier: Modifier = Modifier) {
    Image(
        painter = painterResource(R.drawable.phone_brand_icon),
        contentDescription = null,
        contentScale = ContentScale.Fit,
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(size * 0.27f)),
    )
}

@Composable
fun AvatarView(
    size: Dp,
    expression: String,
    active: Boolean,
    modifier: Modifier = Modifier,
    conversationID: String? = null,
    playful: Boolean = false,
) {
    val dark = androidx.compose.foundation.isSystemInDarkTheme()
    var greeting by remember { mutableIntStateOf(0) }
    val controller = remember { AvatarWebController() }
    val appearance = remember(dark, active, expression, conversationID, greeting, playful) {
        JSONObject().apply {
            put("dark", dark)
            put("reduceMotion", false)
            put("active", active)
            put("greeting", greeting)
            put("playful", playful)
            put("expression", expression)
            put("conversationID", conversationID ?: "")
            put("lowPower", false)
        }.toString()
    }
    Box(modifier = modifier.size(size), contentAlignment = Alignment.Center) {
        // Keep the still behind the live web actor. If the WebView cannot paint
        // the SVG actor on this device, the character still has a visible body.
        BrandWordmark("MoMoStill", height = size, modifier = Modifier.height(size))
        AndroidView(
            factory = { context ->
                WebView(context).apply {
                    setBackgroundColor(AndroidColor.TRANSPARENT)
                    isVerticalScrollBarEnabled = false
                    isHorizontalScrollBarEnabled = false
                    overScrollMode = View.OVER_SCROLL_NEVER
                    isClickable = false
                    isFocusable = false
                    settings.javaScriptEnabled = true
                    settings.allowFileAccess = true
                    settings.allowContentAccess = false
                    settings.blockNetworkLoads = true
                    settings.mediaPlaybackRequiresUserGesture = false
                    settings.setSupportZoom(false)
                    settings.builtInZoomControls = false
                    settings.displayZoomControls = false
                    settings.useWideViewPort = true
                    settings.loadWithOverviewMode = true
                    setLayerType(View.LAYER_TYPE_HARDWARE, null)
                    webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView, url: String) {
                            controller.attach(view)
                            controller.ready = true
                            controller.applyPending()
                        }
                    }
                    controller.web = this
                    loadUrl("file:///android_asset/chat/agent-avatar.html")
                }
            },
            update = { controller.render(appearance) },
            modifier = Modifier.size(size),
        )
        Box(
            modifier = Modifier
                .size(size)
                .clip(RoundedCornerShape(size / 2))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) { greeting += 1 },
        )
    }
    DisposableEffect(controller) {
        onDispose { controller.destroy() }
    }
}

private class AvatarWebController {
    var web: WebView? = null
    var ready = false
    private var pending: String? = null

    fun attach(value: WebView) {
        web = value
    }

    fun render(value: String) {
        pending = value
        if (ready) applyPending()
    }

    fun applyPending() {
        val value = pending ?: return
        web?.evaluateJavascript(
            "window.agentAvatar && window.agentAvatar.update($value)",
            null,
        )
    }

    fun destroy() {
        web?.stopLoading()
        web?.destroy()
        web = null
        ready = false
    }
}
