package com.vocahq.vocaphone.ui

import android.animation.ValueAnimator
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import java.util.Locale
import kotlin.math.floor
import kotlinx.coroutines.isActive

private data class WelcomeWord(
    val language: String,
    val greeting: String,
    val endX: Float,
    val endY: Float,
    val scale: Float,
)

private val welcomeWords = listOf(
    WelcomeWord("English", "Hello", -92f, -90f, 0.88f),
    WelcomeWord("हिन्दी", "नमस्ते", 88f, -73f, 0.92f),
    WelcomeWord("Español", "Hola", -110f, 24f, 0.79f),
    WelcomeWord("العربية", "مرحبا", 102f, 36f, 0.84f),
    WelcomeWord("日本語", "こんにちは", -75f, 100f, 0.8f),
    WelcomeWord("Français", "Bonjour", 64f, 108f, 0.87f),
    WelcomeWord("ਪੰਜਾਬੀ", "ਸਤ ਸ੍ਰੀ ਅਕਾਲ", -126f, -27f, 0.75f),
    WelcomeWord("Italiano", "Ciao", 120f, -22f, 0.8f),
)

private val introCanvas = Color(0xFF111A15)
private val introMint = Color(0xFFA5EFC8)
private val introPaper = Color(0xFFECF5ED)

/** First-launch invitation before the existing how-it-works and setup pages. */
@Composable
internal fun OnboardingWordFlow(onContinue: () -> Unit, modifier: Modifier = Modifier) {
    val motionEnabled = remember { ValueAnimator.areAnimatorsEnabled() }
    val activity = LocalContext.current.findActivity()
    var advancing by remember { mutableStateOf(false) }

    DisposableEffect(activity) {
        val controller = activity?.let { WindowCompat.getInsetsController(it.window, it.window.decorView) }
        val oldLightStatus = controller?.isAppearanceLightStatusBars
        val oldLightNavigation = controller?.isAppearanceLightNavigationBars
        controller?.isAppearanceLightStatusBars = false
        controller?.isAppearanceLightNavigationBars = false
        onDispose {
            if (oldLightStatus != null) controller.isAppearanceLightStatusBars = oldLightStatus
            if (oldLightNavigation != null) controller.isAppearanceLightNavigationBars = oldLightNavigation
        }
    }

    BoxWithConstraints(modifier.fillMaxSize().background(introCanvas)) {
        // Reserve the headline and bottom action so the button is visible
        // without scrolling on a normal phone. Short screens can still scroll.
        val stageHeight = (maxHeight - 400.dp).coerceAtLeast(255.dp)
        Column(
            modifier = Modifier.fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 25.dp)
                .padding(top = 24.dp, bottom = 14.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                Row(
                    modifier = Modifier.width(27.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    listOf(10, 18, 25, 18, 10).forEach { height ->
                        Box(Modifier.size(width = 2.dp, height = height.dp).background(introMint, CircleShape))
                    }
                }
                Text("voca.", color = introMint, fontSize = 19.sp, fontWeight = FontWeight.Bold)
            }

            Text(
                buildAnnotatedString {
                    append("Your words,\n")
                    withStyle(SpanStyle(color = introMint)) { append("your way.") }
                },
                modifier = Modifier.padding(top = 25.dp),
                color = introPaper,
                fontFamily = FontFamily.Serif,
                fontSize = 43.sp,
                lineHeight = 44.sp,
                letterSpacing = (-2).sp,
            )
            Text(
                "Speak naturally. We'll keep up, whichever language feels right.",
                modifier = Modifier.padding(top = 12.dp).width(300.dp),
                color = Color(0xFFAEC1B0),
                fontSize = 15.sp,
                lineHeight = 23.sp,
            )

            WelcomeWordStage(
                motionEnabled = motionEnabled,
                modifier = Modifier.fillMaxWidth().height(stageHeight),
            )

            Row(
                modifier = Modifier.fillMaxWidth().padding(bottom = 18.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
            ) {
                WelcomeBlinkDot(motionEnabled)
                Text(
                    "A place for every voice",
                    modifier = Modifier.padding(start = 8.dp),
                    color = Color(0xFF85A58F),
                    fontSize = 12.sp,
                    letterSpacing = 0.9.sp,
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth().height(56.dp)
                    .clip(RoundedCornerShape(18.dp))
                    .background(introMint)
                    .clickable(role = Role.Button, enabled = !advancing) {
                        advancing = true
                        onContinue()
                    }
                    .padding(horizontal = 21.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Get started", color = Color(0xFF14261A), fontSize = 16.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                Text("↗", color = Color(0xFF14261A), fontSize = 24.sp)
            }
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 20.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(width = 17.dp, height = 5.dp).background(introMint, CircleShape))
                Spacer(Modifier.width(6.dp))
                repeat(2) {
                    Box(Modifier.size(5.dp).background(Color(0xFF49634D), CircleShape))
                    Spacer(Modifier.width(6.dp))
                }
            }
        }
    }
}

@Composable
private fun WelcomeBlinkDot(motionEnabled: Boolean) {
    var elapsed by remember { mutableStateOf(0f) }
    LaunchedEffect(motionEnabled) {
        if (motionEnabled) {
            val started = withFrameNanos { it }
            while (isActive) {
                withFrameNanos { frame -> elapsed = (frame - started) / 1_000_000_000f }
            }
        }
    }
    val blink = if (motionEnabled) {
        0.35f + 0.65f * kotlin.math.abs(kotlin.math.cos((elapsed * Math.PI / 1.8))).toFloat()
    } else 1f
    Box(Modifier.size(6.dp).graphicsLayer { alpha = blink }.background(introMint, CircleShape))
}

/** A speech illustration. It never opens the microphone. */
@Composable
private fun WelcomeWordStage(motionEnabled: Boolean, modifier: Modifier = Modifier) {
    var elapsed by remember { mutableStateOf(0f) }
    LaunchedEffect(motionEnabled) {
        if (motionEnabled) {
            val started = withFrameNanos { it }
            while (isActive) {
                withFrameNanos { frame -> elapsed = (frame - started) / 1_000_000_000f }
            }
        }
    }
    val active = welcomeWords[(floor(elapsed / 0.95f).toInt() % welcomeWords.size)]

    BoxWithConstraints(
        modifier = modifier.clearAndSetSemantics {
            contentDescription = "Greetings in English, Hindi, Spanish, Arabic, Japanese, French, Punjabi, and Italian flow around a voice pulse"
        },
    ) {
        val diameter = minOf(228.dp, maxWidth - 20.dp, maxHeight * 0.77f)
        val scale = diameter.value / 228f
        val centerShift = maxHeight * 0.03f

        val ringTravel = if (motionEnabled) breathe(elapsed, 4f) else 0f
        val ringScale = if (motionEnabled) 0.96f + 0.11f * ringTravel else 1f
        val ringOpacity = if (motionEnabled) 0.42f + 0.36f * ringTravel else 0.62f
        listOf(1f, 190f / 228f, 142f / 228f).forEachIndexed { index, ring ->
            Box(
                Modifier.align(Alignment.Center).offset(y = centerShift)
                    .size(diameter * ring)
                    .graphicsLayer {
                        scaleX = ringScale
                        scaleY = ringScale
                        alpha = ringOpacity
                    }
                    .border(1.dp, if (index == 0) Color(0xFF416B4B) else Color(0xFF35583C), CircleShape),
            )
        }

        welcomeWords.forEachIndexed { index, item ->
            val sinceSpawn = elapsed - index * 0.95f
            val progress = if (motionEnabled) {
                if (sinceSpawn < 0f) 2f else (sinceSpawn % (welcomeWords.size * 0.95f)) / 3.3f
            }
                else if (index < 4) 0.82f else 2f
            if (progress < 1f) {
                val travel = cubicBezier(progress, 0.17f, 0.68f, 0.21f, 1f)
                val opacity = if (motionEnabled) wordOpacity(progress) else 0.72f
                Text(
                    text = item.greeting,
                    modifier = Modifier.align(Alignment.Center)
                        .offset(
                            x = (item.endX * scale * travel).dp,
                            y = centerShift + (item.endY * scale * travel).dp,
                        )
                        .graphicsLayer {
                            alpha = opacity
                            scaleX = 0.58f + (item.scale - 0.58f) * travel
                            scaleY = scaleX
                        },
                    color = if (index % 3 == 0) introMint else Color(0xFFE8F7EB),
                    style = TextStyle(shadow = Shadow(Color(0xFF0B100E), Offset(0f, 1f), 12f)),
                    fontSize = if (item.greeting.length > 8) 15.sp else 18.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                )
            }
        }

        Box(Modifier.align(Alignment.Center).offset(y = centerShift)
            .size((136 * scale).dp).background(introMint.copy(alpha = 0.06f), CircleShape))
        Box(Modifier.align(Alignment.Center).offset(y = centerShift)
            .size((106 * scale).dp).background(introMint.copy(alpha = 0.09f), CircleShape))
        Box(
            modifier = Modifier.align(Alignment.Center).offset(y = centerShift)
                .size((88 * scale).dp).background(introMint, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy((3 * scale).dp),
                verticalAlignment = Alignment.CenterVertically) {
                listOf(12f, 21f, 31f, 18f, 26f, 14f, 23f).forEachIndexed { index, envelope ->
                    val bar = index + 1
                    val delay = if (bar % 3 == 0) 0.57f else if (bar % 2 == 0) 0.33f else 0f
                    val pulse = if (motionEnabled) 0.48f + 0.8f * breathe(elapsed + delay, 1f) else 1f
                    Box(Modifier.size(width = (3 * scale).dp, height = (envelope * pulse * scale).dp)
                        .background(Color(0xFF1C3D29), CircleShape))
                }
            }
        }

        Column(
            modifier = Modifier.align(Alignment.TopCenter).padding(top = 10.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(active.language.uppercase(Locale.ROOT), color = introMint,
                fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 2.sp)
            Text(active.greeting, modifier = Modifier.padding(top = 4.dp), color = introPaper,
                fontFamily = FontFamily.Serif, fontSize = 21.sp, textAlign = TextAlign.Center)
        }
    }
}

private fun breathe(elapsed: Float, duration: Float): Float {
    val phase = (elapsed % duration) / duration
    val travel = if (phase < 0.5f) phase * 2f else (1f - phase) * 2f
    return cubicBezier(travel, 0.42f, 0f, 0.58f, 1f)
}

private fun wordOpacity(progress: Float): Float = when {
    progress < 0.12f -> 0.95f * cubicBezier(progress / 0.12f, 0.17f, 0.68f, 0.21f, 1f)
    progress < 0.72f -> 0.95f - 0.1f * cubicBezier((progress - 0.12f) / 0.6f, 0.17f, 0.68f, 0.21f, 1f)
    else -> 0.85f * (1f - cubicBezier((progress - 0.72f) / 0.28f, 0.17f, 0.68f, 0.21f, 1f))
}

private fun cubicBezier(progress: Float, x1: Float, y1: Float, x2: Float, y2: Float): Float {
    val target = progress.coerceIn(0f, 1f)
    var low = 0f
    var high = 1f
    repeat(12) {
        val t = (low + high) / 2f
        val inverse = 1f - t
        val x = 3f * inverse * inverse * t * x1 + 3f * inverse * t * t * x2 + t * t * t
        if (x < target) low = t else high = t
    }
    val t = (low + high) / 2f
    val inverse = 1f - t
    return 3f * inverse * inverse * t * y1 + 3f * inverse * t * t * y2 + t * t * t
}
