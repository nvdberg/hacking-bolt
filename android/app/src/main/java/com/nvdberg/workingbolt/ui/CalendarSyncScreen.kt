package com.nvdberg.workingbolt.ui

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.data.Supabase
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID

private const val SERVER_ERROR = "Couldn’t reach the server — check your connection and try again."
private const val TOKEN_EMP_KEY = "wb_cal_token_emp"      // whose token is kept on this device

/**
 * Live calendar subscription. Unlike the one-tap Export (a snapshot .ics you re-send whenever the roster
 * changes), this gives you a *subscribe URL*: the poller regenerates your .ics every few minutes, so once
 * Google Calendar is subscribed it keeps itself up to date — new shifts, swaps, and pickups all flow in on
 * their own. The URL carries a random, unguessable token; nothing is public without it.
 */
@Composable
fun CalendarSyncScreen(vm: AppViewModel, prefs: Prefs) {
    val c = Theme.colors
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()

    var enabled by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(true) }
    var working by remember { mutableStateOf(false) }
    var copied by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }      // bumped by "Try again"

    val token = prefs.calToken
    val feedURL = if (token.isEmpty()) "" else Supabase.calendarURL(token)

    LaunchedEffect(attempt) {
        val emp = vm.userEmp.toIntOrNull()
        if (emp == null) {
            error = "Sign in to Lightning Bolt first, then come back to set up calendar sync."
            loading = false
            return@LaunchedEffect
        }
        // Prefer the server's record (survives reinstalls, keeps the URL stable); fall back to the local token.
        val r = Supabase.calSub(emp)
        if (!r.ok) {                                      // never mint a new token on a failed read — it would replace the live URL
            error = SERVER_ERROR
            loading = false
            return@LaunchedEffect
        }
        val sub = r.sub
        if (sub != null) {
            prefs.updateCalToken(sub.token)
            prefs.putString(TOKEN_EMP_KEY, emp.toString())
            enabled = sub.enabled ?: true
        } else if (prefs.calToken.isEmpty() || prefs.getString(TOKEN_EMP_KEY) != emp.toString()) {
            // first ever — mint a stable token (also when the one kept here belongs to whoever signed in before)
            prefs.updateCalToken(UUID.randomUUID().toString().lowercase())
            prefs.putString(TOKEN_EMP_KEY, emp.toString())
        }
        loading = false
    }

    fun setEnabled(on: Boolean) {
        val emp = vm.userEmp.toIntOrNull() ?: return
        val t = prefs.calToken
        if (t.isEmpty()) return
        working = true
        enabled = on
        scope.launch {
            val ok = Supabase.enrollCalendar(emp, t, on)
            working = false
            if (!ok) { enabled = !on; error = SERVER_ERROR }
        }
    }

    Column(Modifier.fillMaxSize().background(c.bg).verticalScroll(rememberScrollState())) {
        Text(
            "Sync to Calendar",
            fontSize = 20.sp, fontWeight = FontWeight.Bold, color = c.ink,
            modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 8.dp),
        )

        val err = error
        when {
            loading -> Row(
                Modifier.padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                CircularProgressIndicator(Modifier.size(18.dp), color = c.accent, strokeWidth = 2.dp)
                Text("Loading…", color = c.muted)
            }

            err != null -> {
                Text(err, fontSize = 14.sp, color = Color(0xFFD64545), modifier = Modifier.padding(16.dp))
                if (vm.userEmp.isNotEmpty()) {
                    TextButton(
                        onClick = { error = null; loading = true; attempt++ },
                        modifier = Modifier.padding(horizontal = 12.dp),
                    ) { Text("Try again") }
                }
            }

            else -> {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Keep a calendar in sync", color = c.ink, modifier = Modifier.weight(1f))
                    Switch(checked = enabled, onCheckedChange = { setEnabled(it) }, enabled = !working)
                }
                Footer(
                    "Turns your roster into a live calendar feed. Subscribe once in Google Calendar and it " +
                        "updates itself — every new shift, swap and pickup appears automatically. Colour-tagged " +
                        "titles, 24-hour calls folded, Pasqua Rapid/MSU merged, just like Export.",
                )

                if (enabled) {
                    Label("Your subscribe link")
                    SelectionContainer {
                        Text(
                            feedURL,
                            fontSize = 12.sp, fontFamily = FontFamily.Monospace, color = c.accent,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
                        )
                    }
                    ActionRow(if (copied) "✓ Copied!" else "Copy link") {
                        clipboard.setText(AnnotatedString(feedURL))
                        copied = true
                        scope.launch { delay(1_500); copied = false }
                    }
                    ActionRow("Share link") {
                        val send = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, feedURL)
                        }
                        runCatching { context.startActivity(Intent.createChooser(send, null)) }
                    }
                    Footer(
                        "Private to you — the link contains a random token. Just turned on? Give it a few " +
                            "minutes to fill in the first time.",
                    )

                    Label("Add it to Google Calendar")
                    Step(
                        1, "Open Google Calendar on a computer",
                        "calendar.google.com — the phone app can’t add a calendar by link, but once it’s added " +
                            "on the web it shows up on your phone too.",
                    )
                    Step(
                        2, "Other calendars → + → From URL",
                        "In the left sidebar, next to “Other calendars”, tap +, then choose “From URL”.",
                    )
                    Step(
                        3, "Paste the link → Add calendar",
                        "Paste your subscribe link and confirm. It lands under “Other calendars”.",
                    )
                    Step(
                        4, "Show it on your phone",
                        "In the Google Calendar app: ☰ → Settings → the new calendar → tick “Sync”.",
                    )
                    Footer(
                        "Heads-up: Google refreshes subscribed calendars on its own schedule — usually every " +
                            "8–24 hours — so a brand-new shift can take up to a day to appear there. That’s a " +
                            "Google limit, not the app.",
                    )
                }
            }
        }
        Box(Modifier.padding(40.dp))
    }
}

@Composable
private fun Label(text: String) {
    Text(
        text.uppercase(),
        fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Theme.colors.muted,
        modifier = Modifier.padding(start = 16.dp, top = 18.dp, bottom = 6.dp),
    )
}

@Composable
private fun Footer(text: String) {
    Text(
        text, fontSize = 12.sp, color = Theme.colors.muted,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
    )
}

@Composable
private fun ActionRow(label: String, onClick: () -> Unit) {
    val c = Theme.colors
    Text(
        label, color = c.accent,
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 12.dp),
    )
    HorizontalDivider(color = c.line)
}

@Composable
private fun Step(n: Int, title: String, detail: String) {
    val c = Theme.colors
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 7.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(22.dp).clip(CircleShape).background(c.accent), contentAlignment = Alignment.Center) {
            Text("$n", fontSize = fixedSp(12f), fontWeight = FontWeight.Bold, color = c.panel)
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
            Text(detail, fontSize = 12.sp, color = c.muted)
        }
    }
}
