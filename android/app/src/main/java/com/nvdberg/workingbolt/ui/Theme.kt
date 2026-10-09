package com.nvdberg.workingbolt.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp

/**
 * Design tokens matched to stage2/site (the web app the user likes) — the same pairs as iOS Theme.swift,
 * resolved for the current light/dark mode.
 */
data class WBColors(
    val bg: Color,
    val panel: Color,
    val ink: Color,
    val muted: Color,
    val line: Color,
    val accent: Color,      // teal
    val available: Color,   // amber "Available"
    val brand: Color,       // the bolt orange
)

private val LightColors = WBColors(
    bg = Color(0xFFEEF3F3),
    panel = Color(0xFFFFFFFF),
    ink = Color(0xFF111F26),
    muted = Color(0xFF5A6D75),
    line = Color(0xFFE3E9EA),
    accent = Color(0xFF0F766E),
    available = Color(0xFFE19614),
    brand = Color(0xFFF97316),
)

private val DarkColors = WBColors(
    bg = Color(0xFF0A1216),
    panel = Color(0xFF111F27),
    ink = Color(0xFFE7EFF2),
    muted = Color(0xFF9DB0B8),
    line = Color(0xFF1E323B),
    accent = Color(0xFF5EEAD4),
    available = Color(0xFFF0B24A),
    brand = Color(0xFFFB923C),
)

private val LocalWBColors = staticCompositionLocalOf { LightColors }

/** `Theme.bg`-style access from any composable, matching how the SwiftUI code reads its tokens. */
object Theme {
    val colors: WBColors
        @Composable @ReadOnlyComposable get() = LocalWBColors.current
}

/**
 * A text size pinned to physical size, ignoring the system font scale.
 *
 * Use ONLY inside fixed-height containers — calendar cells, the Who's-On week grid, tab labels — where
 * the box can't grow. Samsung users very often run 130%+ font with a denser display size, which
 * otherwise truncates unit names to "SI…" or wraps tab labels onto two lines. Everything else in the
 * app scales normally and should keep doing so.
 */
@Composable
@ReadOnlyComposable
fun fixedSp(size: Float): TextUnit = with(LocalDensity.current) { size.dp.toSp() }

@Composable
fun WorkingBoltTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val wb = if (dark) DarkColors else LightColors
    val scheme = if (dark) {
        darkColorScheme(
            primary = wb.accent, onPrimary = Color(0xFF00201C),
            background = wb.bg, onBackground = wb.ink,
            surface = wb.panel, onSurface = wb.ink,
            surfaceVariant = wb.line, onSurfaceVariant = wb.muted,
        )
    } else {
        lightColorScheme(
            primary = wb.accent, onPrimary = Color.White,
            background = wb.bg, onBackground = wb.ink,
            surface = wb.panel, onSurface = wb.ink,
            surfaceVariant = wb.line, onSurfaceVariant = wb.muted,
        )
    }
    CompositionLocalProvider(LocalWBColors provides wb) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
