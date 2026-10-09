package com.nvdberg.workingbolt.ui

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Swap the home-screen icon. Android has no runtime icon API, so each look is an `activity-alias` in
 * the manifest and we enable exactly one, disabling the rest.
 *
 * Order matters: the target is enabled FIRST, so the app is never momentarily absent from the launcher.
 */
data class IconOption(
    val alias: String,
    val name: String,
    val note: String,
    val tint: Color,
    val bg: Color,
)

val ICON_OPTIONS = listOf(
    IconOption("LauncherClassic", "Classic", "Stealth black", Color(0xFF6E7681), Color(0xFF15181D)),
    IconOption("LauncherNeon", "Neon", "Electric cyan", Color(0xFF67E8F9), Color(0xFF0B1220)),
    IconOption("LauncherGold", "Gold", "Solid gold", Color(0xFFF5C542), Color(0xFF161206)),
    IconOption("LauncherRed", "Code Red", "Night-shift red", Color(0xFFFF5B6B), Color(0xFF1A0A0C)),
)

private fun component(context: Context, alias: String) =
    ComponentName(context.packageName, "${context.packageName}.$alias")

fun currentIconAlias(context: Context): String {
    val pm = context.packageManager
    for (o in ICON_OPTIONS) {
        val state = pm.getComponentEnabledSetting(component(context, o.alias))
        if (state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED) return o.alias
    }
    return ICON_OPTIONS.first().alias      // nothing explicitly set → the manifest default (Classic)
}

fun setIconAlias(context: Context, alias: String) {
    val pm = context.packageManager
    // Enable the target first — if we disabled everything else up front and this failed, the app would
    // vanish from the home screen.
    pm.setComponentEnabledSetting(
        component(context, alias),
        PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
        PackageManager.DONT_KILL_APP,
    )
    for (o in ICON_OPTIONS) {
        if (o.alias == alias) continue
        pm.setComponentEnabledSetting(
            component(context, o.alias),
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP,
        )
    }
}

@Composable
fun AppIconPage() {
    val c = Theme.colors
    val context = LocalContext.current
    var current by remember { mutableStateOf(currentIconAlias(context)) }

    Text(
        "App icon",
        fontSize = 20.sp, fontWeight = FontWeight.Bold, color = c.ink,
        modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 8.dp),
    )
    ICON_OPTIONS.forEach { opt ->
        val on = opt.alias == current
        Row(
            Modifier.fillMaxWidth()
                .clickable { setIconAlias(context, opt.alias); current = opt.alias }
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Box(
                Modifier.size(54.dp)
                    .clip(RoundedCornerShape(13.dp))
                    .background(opt.bg)
                    .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(13.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Text("⚡", fontSize = 24.sp, color = opt.tint)
            }
            Column(Modifier.weight(1f)) {
                Text(opt.name, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = c.ink)
                Text(opt.note, fontSize = 12.sp, color = c.muted)
            }
            if (on) Text("✓", color = c.accent, fontWeight = FontWeight.Bold)
        }
    }
    Text(
        "Your launcher may take a moment to redraw the icon — some launchers only refresh on the next " +
            "home-screen reload.",
        fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(16.dp),
    )
}
