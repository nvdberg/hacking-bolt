package com.nvdberg.workingbolt.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay

private val Amber = Color(0xFFF0B24A)
private val Teal = Color(0xFF5EEAD4)
private val Ink = Color(0xFF06131A)

/**
 * The branded opening screen: the bolt mark fades in and pulses, "Hacking" is struck through and
 * "Working" lands above it, then the tagline and a witty line. Commits to the teal/amber identity in
 * both light and dark (a deliberate branded moment). Auto-dismisses; tap anywhere to skip.
 */
@Composable
fun LaunchScreen(onDone: () -> Unit) {
    val context = LocalContext.current
    val prefs = Prefs.get(context)
    val quipStore = QuipStore.get(context)
    val pool = quipStore.quips.ifEmpty { QuipStore.defaults }
    // Start on a random line, then cycle while the screen holds.
    var qi by remember { mutableIntStateOf(pool.indices.random()) }

    var lift by remember { mutableStateOf(false) }      // mark + wordmark rise in
    var strike by remember { mutableStateOf(false) }    // cross out "Hacking"
    var working by remember { mutableStateOf(false) }   // "Working" pops in above

    val liftA by animateFloatAsState(if (lift) 1f else 0f, tween(700), label = "lift")
    val strikeA by animateFloatAsState(if (strike) 1f else 0f, tween(500), label = "strike")
    val workingA by animateFloatAsState(if (working) 1f else 0f, tween(500), label = "working")

    // A slow heartbeat on the bolt.
    val beat = rememberInfiniteTransition(label = "beat")
    val beatScale by beat.animateFloat(
        initialValue = 1f, targetValue = 1.08f,
        animationSpec = infiniteRepeatable(tween(900, easing = LinearEasing), RepeatMode.Reverse),
        label = "beatScale",
    )

    LaunchedEffect(Unit) {
        // The intro beats are fixed; the remainder of the hold is the user's setting (More → App → Start screen).
        val holdMs = (prefs.splashSecs * 1000).toLong().coerceAtLeast(2_000L)
        lift = true
        delay(1_100); strike = true
        delay(500); working = true
        var elapsed = 1_600L
        // Cycle the witty line for whatever hold time is left, then hand over.
        while (elapsed < holdMs - 400L) {
            val step = minOf(2_200L, holdMs - 400L - elapsed)
            delay(step)
            elapsed += step
            qi = (qi + 1) % pool.size
        }
        delay(400)
        onDone()
    }

    Box(
        Modifier.fillMaxSize()
            .background(Brush.verticalGradient(listOf(Ink, Color(0xFF0A1F28), Ink)))
            .clickable(
                indication = null,
                interactionSource = remember { MutableInteractionSource() },
                onClick = onDone,      // tap to skip
            ),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Text(
                "⚡",
                fontSize = 68.sp,
                modifier = Modifier.alpha(liftA).scale(beatScale),
            )
            Box(Modifier.height(14.dp))

            // "Working" scrawled above the struck-out "Hacking" — the reveal needs headroom, so the box
            // reserves the scrawl's line height rather than letting the two words collide.
            Box(Modifier.padding(top = 30.dp), contentAlignment = Alignment.Center) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "Hacking",
                        fontSize = 34.sp, fontWeight = FontWeight.ExtraBold, color = Color.White,
                        textDecoration = if (strikeA > 0.5f) TextDecoration.LineThrough else TextDecoration.None,
                        modifier = Modifier.alpha(liftA * (1f - 0.45f * strikeA)),
                    )
                    Text(
                        "-Bolt",
                        fontSize = 34.sp, fontWeight = FontWeight.ExtraBold, color = Amber,
                        modifier = Modifier.alpha(liftA),
                    )
                }
                Text(
                    "Working",
                    fontSize = 30.sp, fontWeight = FontWeight.ExtraBold, color = Teal,
                    modifier = Modifier
                        .padding(bottom = 52.dp)
                        .alpha(workingA)
                        .scale(0.85f + 0.15f * workingA),
                )
            }

            Box(Modifier.height(18.dp))
            Text(
                "Your shift board & roster, minus the clutter.",
                fontSize = 14.sp, color = Color.White.copy(alpha = 0.75f * liftA),
                textAlign = TextAlign.Center,
            )
            Box(Modifier.height(6.dp))
            Text(
                "Disclaimer: this is only a prototype — but a damn good one.",
                fontSize = 11.sp, color = Color.White.copy(alpha = 0.45f * liftA),
                textAlign = TextAlign.Center,
            )

            Box(Modifier.height(34.dp))
            // The witty line — cycles through the rotation; the "sleepless nights" line pops larger.
            QuipLine(pool[qi])

            Box(Modifier.height(30.dp))
            Text(
                "Unofficial · a personal shift companion",
                fontSize = 10.sp, color = Color.White.copy(alpha = 0.35f * liftA),
                textAlign = TextAlign.Center,
            )
        }
    }
}

/** One witty line. Animates its own entrance; the "sleepless nights" line springs up larger for effect. */
@Composable
private fun QuipLine(text: String) {
    val punch = QuipStore.isPunch(text)
    var show by remember(text) { mutableStateOf(false) }
    val a by animateFloatAsState(if (show) 1f else 0f, tween(450), label = "quip")
    LaunchedEffect(text) { show = true }

    Text(
        text,
        fontSize = if (punch) 18.sp else 13.5.sp,
        fontWeight = if (punch) FontWeight.Bold else FontWeight.Normal,
        color = Color.White.copy(alpha = (if (punch) 0.95f else 0.62f) * a),
        textAlign = TextAlign.Center,
        modifier = Modifier
            .fillMaxWidth()
            .scale(if (punch) 0.8f + 0.5f * a else 0.96f + 0.04f * a),
    )
}
