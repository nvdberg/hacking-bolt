package com.nvdberg.workingbolt.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * More → "How to use Working-Bolt": every crew-facing feature, by tab, searchable. Android copy of iOS Guide.swift.
 *
 * KEEP THIS CURRENT: any build that adds or changes something a user can see or do updates this file in the same
 * build, and bumps [Guide.updatedForBuild] (the Android versionCode). Crew-facing only — nothing owner/admin,
 * nothing iOS-only (no push notifications, no TestFlight feedback, no PDF export).
 */
object Guide {
    const val updatedForBuild = 7

    class Item(val title: String, val how: String)
    class Topic(val icon: String, val title: String, val items: List<Item>)

    val topics = listOf(
        Topic("👆", "Quick gestures", listOf(
            Item("Tap one of your shifts (My Shifts)", "Choose Find a swap or Give it away."),
            Item("Double-tap any day (My Shifts)",
                "Opens a small Who's On card for that day. Drag its header to move it; tap other days to switch; × closes it. Its 🩺 adds the doctors: each ICU's intensivist + on-call number (🌙 = also on call tonight), ♥ who's in CCU, and a Tonight line — 🌙 ICU on call · ♥ cardiology On call · STEMI. It stays on till you tap it again."),
            Item("Press and hold a day (My Shifts)",
                "Mark busy… — add a note like STARS. The Pool then warns you before you take a shift that day."),
            Item("Tap an orange square (calendars)", "Jumps to that open shift in the Pool."),
            Item("Press and hold your own shift (Who's On)", "Find a swap or Give it away, straight from the roster."),
            Item("Pull down (Pool, My Shifts, Time Off)", "Refreshes from Lightning Bolt."),
            Item("Turn your phone sideways", "My Shifts and Who's On switch to a wider week/month view."),
            Item("Back gesture inside More", "Returns to the More list."),
        )),
        Topic("⚡", "Pool — open shifts", listOf(
            Item("All · For me · My posts",
                "All = every shift anyone can pick up. For me = only ones that don't clash with your roster or a busy day. My posts = shifts you've offered (shows when you have some — change in More → Advanced)."),
            Item("Picking one up",
                "Tap Available → Lightning Bolt's own accept page opens inside the app. Nothing is taken until you accept there. It shows in My Shifts as soon as LB has it."),
            Item("Clash labels",
                "\"You're on …\", \"Post-call\" or \"Pre-call\" means it overlaps or sits next to one of your shifts. \"You're busy\" = a day you marked busy — tapping asks Take it anyway?"),
            Item("Mini-calendars on top", "Your shifts in colour, open shifts as orange squares. Tap a square to jump to it."),
            Item("Updated · Recently taken",
                "Updated shows when the Pool was last checked. Recently taken (bottom) lists shifts picked up in the last 2 days — no names — so a shift that vanished was taken, not lost. Under For me it only shows ones you could have taken. Hide it with the eye."),
            Item("Swaps card",
                "Swaps sent to you (Accept swap), the return half of a swap you sent (Take it), and swaps that didn't go through show at the top."),
            Item("Private offers", "A swap or shift offered to one person only shows in their Pool — not everyone's."),
        )),
        Topic("📅", "My Shifts", listOf(
            Item("Your calendar",
                "Colour = unit. 24-hour calls run into a faded post-call day. A purple outline = a shift you've posted. Orange square = an open shift you could take."),
            Item("Jump around", "This Month returns to today; scroll back through earlier months."),
            Item("Busy days",
                "Press and hold a day → Mark busy… → note → Save. Grey dashed tag on the day. Hold again to edit or clear. Stored on this phone only (never sent anywhere). Your LB time-off requests count as busy too."),
            Item("Share icon (top right)", "Sends your shifts as a calendar file (.ics)."),
        )),
        Topic("🔁", "Swaps & give-aways", listOf(
            Item("Find a swap",
                "Pick your shift → the app lists colleagues who are free that day and have a shift you could take back. Filter by person or unit. Send it with a note; when they accept and send theirs back, it appears in your Pool as Take it."),
            Item("Give it away",
                "Offer to everyone eligible (goes to the Pool) or to one person. You can give away part of a shift — note: only a scheduler can merge pieces back."),
            Item("Cancel an offer", "Pool → My posts → Cancel on the post → Withdraw offer."),
            Item("Text colleagues",
                "In Find a swap, Text all opens one group message to everyone listed; each swap option can also text that person."),
        )),
        Topic("👥", "Who's On", listOf(
            Item("Who's working",
                "Upright: a day-by-day list of who's on each unit — scroll, or pick a date / Today. Sideways: a week grid, units down the side. You're highlighted."),
            Item("Doctors on call",
                "Tap the stethoscope (top right). Each ICU row adds that day's intensivist and their on-call number (a slim bar along the top holds each unit's desk number, with the CCA call room 🛏 under it — Pasqua wards too); CCU shows who's in CCU this week (Fri → Thu). Under each day, two lines: 🌙 ICU = the one intensivist on call tonight for all the ICUs (plus 2nd call for mass events); ♥ = who's in CCU this week (Friday to Thursday, handover Friday) · 8–5 consults, with RGH cardiology On call · STEMI on the line under it. A circled name = on call from 17:00. Sideways, it adds a Tonight row. Tap again to hide."),
            Item("Unit order", "Reorder the unit rows in More → Advanced → Who's On order."),
        )),
        Topic("🧑‍🤝‍🧑", "Crew", listOf(
            Item("Compare people",
                "Pick a few colleagues to see only their shifts in the Who's On layout — handy for finding days you're all off."),
        )),
        Topic("🌙", "More → Time Off Requests", listOf(
            Item("New request",
                "Choose Time Off or Night Off, pick the days (any mix of dates), add a reason → confirm → sent to Lightning Bolt. Days you're already rostered on are pointed out first."),
            Item("Status",
                "Upcoming and Past requests with their status (pending, approved, declined). Days sent together show as one row. Pull down to refresh."),
            Item("Cancel", "Tap Cancel on a pending request. Only pending ones can be cancelled."),
        )),
        Topic("📊", "More → My Stats", listOf(
            Item("Cards",
                "Month by month · Monthly average · Coming up (your next shift + what's booked by month) · Year to date · By year · Custom range (pick From/To)."),
            Item("Reorder", "Tap Reorder (top right), move the cards up or down, tap Done. Saved on this phone."),
            Item("Your shift log",
                "Kept on this phone back to 2022 — even shifts no longer in the roster. Future shifts update as you pick up or give away. A Pasqua Rapid + MSU day counts as one shift."),
        )),
        Topic("📤", "More → Export", listOf(
            Item("Your shifts as…", "Add to Calendar (.ics) · Spreadsheet (CSV for Excel / Sheets) — your whole shift log."),
            Item("Sharing", "Opens Android's share sheet — save to Drive or Files, email, message…"),
        )),
        Topic("🔗", "More → Sync to Calendar", listOf(
            Item("Live calendar link",
                "Turn it on to get a private subscribe link. Unlike Export (a one-off copy), it keeps updating itself with new shifts, swaps and pickups."),
            Item("Google Calendar",
                "Copy the link → on a computer, calendar.google.com → Other calendars → + → From URL → paste. Then in the phone app, turn on Sync for it. Google refreshes on its own schedule — a new shift can take up to a day."),
        )),
        Topic("⚙️", "More → Advanced", listOf(
            Item("Open the app on", "Shift Pool, My Shifts, Who's On or Crew."),
            Item("Shift Pool opens on “For me”", "Start the Pool on shifts you can actually take."),
            Item("Show “Recently taken” in the Pool", "On/off for the list at the bottom of the Pool."),
            Item("My Posts tab", "Auto (when you have posts) · Always show · Only when awaiting pickup."),
            Item("Week starts on", "Sunday or Monday, for the month calendars (My Shifts, Pool and the swap calendars)."),
            Item("Who's On order", "Move the unit rows into the order you like."),
            Item("App icon", "Pick a different home-screen icon."),
            Item("Witty lines", "The one-liners the app shows — add your own, delete, or Reset to defaults."),
            Item("Auto sign-in",
                "Optional. Fingerprint or face unlock: your LB sign-in is unlocked with a fingerprint or face check when LB logs you out. Keep me signed in: same, without the check. Encrypted and stored only on this phone — never sent anywhere."),
            Item("Hennie holiday", "Your next run of 4+ days off in a row."),
        )),
        Topic("➕", "More → the rest", listOf(
            Item("Swap or Give Away", "The same swap / give-away screen as tapping a shift — see Swaps & give-aways."),
            Item("Cafeteria menu",
                "On More (🍴, just above App), with today's lunch feature underneath. The day's specials at RGH or Pasqua with prices — ☀ lunch feature and its sides first, then pizza, soup and 🌙 supper. Arrows step through the days."),
            Item("Start screen",
                "In the App section: tap it to pick how long the opening screen holds, 2 to 8 seconds (default 8). Tap the opening screen to skip it anytime."),
            Item("About", "What Working-Bolt is and how it treats your data."),
            Item("Sign out", "Clears the session and roster data cached on this phone."),
        )),
        Topic("✋", "Good to know", listOf(
            Item("Updates", "When a newer Android build is out, a banner shows above the tabs. Tap Update: the app downloads it, installs it and closes. Open it again and you are on the new build. The first time, your phone asks you to switch on “Allow from this source” for Working-Bolt; do that, come back and tap Update again. Nothing installs unless you tap."),
            Item("Lightning Bolt stays in charge",
                "Working-Bolt reads your roster and opens LB's own pages for anything that changes it. Every send asks you first."),
            Item("What's kept on your phone",
                "Your shift log, busy days, settings and (if you turn it on) your sign-in. Signing out clears the roster data cached on this phone."),
        )),
    )
}

@Composable
fun GuideScreen() {
    val c = Theme.colors
    var query by rememberSaveable { mutableStateOf("") }
    val q = query.trim().lowercase()
    val shown = remember(q) {
        if (q.isEmpty()) Guide.topics
        else Guide.topics.mapNotNull { t ->
            val hits = t.items.filter { "${t.title} ${it.title} ${it.how}".lowercase().contains(q) }
            if (hits.isEmpty()) null else Guide.Topic(t.icon, t.title, hits)
        }
    }

    LazyColumn(Modifier.fillMaxSize().background(c.bg), contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 40.dp)) {
        item {
            Text(
                "How to use Working-Bolt", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = c.ink,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp),
            )
            OutlinedTextField(
                value = query, onValueChange = { query = it },
                placeholder = { Text("Search the guide", color = c.muted) },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null, tint = c.muted) },
                singleLine = true,
                shape = RoundedCornerShape(12.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = c.accent, unfocusedBorderColor = c.line,
                    focusedTextColor = c.ink, unfocusedTextColor = c.ink,
                ),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            )
            if (q.isEmpty()) {
                Text(
                    "Everything Working-Bolt can do, by tab. Start with Quick gestures — most features live behind a tap, double-tap or press-and-hold.",
                    fontSize = 14.sp, color = c.muted, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
            }
        }
        items(shown, key = { it.title }) { t ->
            Column(Modifier.padding(horizontal = 16.dp)) {
                Text(
                    "${t.icon}  ${t.title}", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.muted,
                    modifier = Modifier.padding(start = 4.dp, top = 16.dp, bottom = 6.dp),
                )
                Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(c.panel)) {
                    t.items.forEachIndexed { i, it ->
                        if (i > 0) HorizontalDivider(color = c.line, modifier = Modifier.padding(start = 30.dp))
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 9.dp),
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Spacer(
                                Modifier.padding(top = 7.dp).size(7.dp).clip(CircleShape).background(c.accent),
                            )
                            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(it.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
                                Text(it.how, fontSize = 13.sp, color = c.muted, lineHeight = 18.sp)
                            }
                        }
                    }
                }
            }
        }
        if (shown.isEmpty()) {
            item {
                Text("Nothing matches “$query”.", color = c.muted, modifier = Modifier.padding(16.dp))
            }
        }
        item {
            Spacer(Modifier.height(16.dp))
            Text(
                "Guide updated for build ${Guide.updatedForBuild}.",
                fontSize = 11.sp, color = c.muted, modifier = Modifier.padding(horizontal = 20.dp),
            )
        }
    }
}
