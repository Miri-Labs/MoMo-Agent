package com.momoagent.android.ui

import android.animation.ValueAnimator
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color as AndroidColor
import android.os.PowerManager
import android.view.View
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
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
        contentDescription = when (name) {
            "PhoneWordmark" -> stringResource(R.string.brand_momo_agent)
            "MoMoWordmark" -> stringResource(R.string.brand_momo)
            else -> null
        },
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

/**
 * The SVG keeps its original 300-unit square canvas. The cropped PNG only holds
 * the visible contour (~183 x 193), so draw it at that contour size inside the
 * avatar's square layout. Without the margins the still silhouette appears much
 * wider than the live SVG until the WebView reports its first frame.
 */
private const val STILL_CONTOUR_HEIGHT = 193f / 300f
/** The live SVG is drawn on a 1.5x transparent surface so greetings do not clip. */
private const val AVATAR_SURFACE_SCALE = 1.5f

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
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val foreground = lifecycleState.isAtLeast(Lifecycle.State.STARTED)
    val lowPower = rememberPowerSaveMode()
    val reduceMotion = !ValueAnimator.areAnimatorsEnabled()
    var greeting by remember { mutableIntStateOf(0) }
    val controller = remember { AvatarWebController() }
    val appearance = remember(
        dark,
        active,
        foreground,
        expression,
        conversationID,
        greeting,
        playful,
        reduceMotion,
        lowPower,
    ) {
        JSONObject().apply {
            put("dark", dark)
            put("reduceMotion", reduceMotion)
            put("active", active && foreground)
            put("greeting", greeting)
            put("playful", playful)
            put("expression", expression)
            put("conversationID", conversationID ?: "")
            put("lowPower", lowPower)
        }.toString()
    }
    val greetingLabel = stringResource(R.string.avatar_greeting)

    Box(modifier = modifier.size(size), contentAlignment = Alignment.Center) {
        if (!controller.painted) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                BrandWordmark("MoMoStill", height = size * STILL_CONTOUR_HEIGHT)
            }
        }
        key(controller.generation) {
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
                                if (controller.web !== view) return
                                controller.attach(view)
                                controller.applyPending()
                            }

                            override fun onRenderProcessGone(
                                view: WebView,
                                detail: RenderProcessGoneDetail,
                            ): Boolean {
                                controller.markUnavailable(view)
                                return true
                            }
                        }
                        controller.web = this
                        loadUrl("file:///android_asset/chat/agent-avatar.html")
                    }
                },
                update = { controller.render(appearance) },
                onRelease = { view -> controller.release(view) },
                modifier = Modifier
                    .requiredSize(size * AVATAR_SURFACE_SCALE)
                    .alpha(if (controller.painted) 1f else 0f),
            )
        }
        Box(
            modifier = Modifier
                .size(size)
                .clip(RoundedCornerShape(size / 2))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    role = Role.Button,
                    onClickLabel = greetingLabel,
                ) { greeting += 1 }
                .semantics {
                    contentDescription = greetingLabel
                    role = Role.Button
                },
        )
    }
    DisposableEffect(controller) {
        onDispose { controller.destroy() }
    }
}

@Composable
private fun rememberPowerSaveMode(): Boolean {
    val context = LocalContext.current
    val manager = remember(context) {
        context.getSystemService(Context.POWER_SERVICE) as PowerManager
    }
    var saving by remember(manager) { mutableStateOf(manager.isPowerSaveMode) }
    DisposableEffect(context, manager) {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                saving = manager.isPowerSaveMode
            }
        }
        ContextCompat.registerReceiver(
            context,
            receiver,
            IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
        onDispose { context.unregisterReceiver(receiver) }
    }
    return saving
}

private class AvatarWebController {
    var web: WebView? = null
    var ready = false
    var generation by mutableIntStateOf(0)
        private set
    var painted by mutableStateOf(false)
        private set
    private var pending: String? = null
    private var callbackToken = 0

    fun attach(view: WebView) {
        if (web === view) ready = true
    }

    fun render(value: String) {
        pending = value
        if (ready) applyPending()
    }

    fun applyPending() {
        val value = pending ?: return
        val view = web ?: return
        val token = ++callbackToken
        // A WebView that loaded but never drew the avatar must keep the still silhouette.
        view.evaluateJavascript(
            "Boolean(window.agentAvatar && document.querySelector('svg.life-avatar path[d]') && " +
                "(window.agentAvatar.update($value), true))",
        ) { rendered ->
            if (token == callbackToken && web === view && rendered == "true") painted = true
        }
    }

    fun markUnavailable(view: WebView) {
        if (web !== view) return
        painted = false
        ready = false
        web = null
        generation += 1
    }

    fun release(view: WebView) {
        if (web === view) {
            callbackToken += 1
            painted = false
            ready = false
            web = null
        }
        view.stopLoading()
        view.destroy()
    }

    fun destroy() {
        web?.let(::release)
    }
}
