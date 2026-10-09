package com.nvdberg.workingbolt.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.data.LBCreds
import com.nvdberg.workingbolt.data.ShiftExport
import com.nvdberg.workingbolt.model.Units
import com.nvdberg.workingbolt.model.nextHennieHoliday
import java.util.Locale

private enum class MorePage {
    Root, Swap, TimeOff, Stats, Export, CalendarSync, Cafeteria, Guide, Advanced, AutoSignIn, WhoOrder, AppIcon, Quips, About;

    /** Where ‹ / system Back goes: Advanced's sub-pages return to Advanced, the rest to More. */
    val parent get() = if (this in setOf(AutoSignIn, WhoOrder, AppIcon, Quips)) Advanced else Root
}

/** More — settings, personalization and sign-out. */
@Composable
fun SettingsScreen(vm: AppViewModel, prefs: Prefs) {
    var page by remember { mutableStateOf(MorePage.Root) }
    var showSignOut by remember { mutableStateOf(false) }
    val c = Theme.colors

    // The system Back gesture steps back to the More list (same as the ‹ More row) instead of leaving the app.
    BackHandler(enabled = page != MorePage.Root) { page = page.parent }

    // These own their own scrolling, so they can't sit inside the shared verticalScroll column.
    if (page in FULL_PAGES) {
        Column(Modifier.fillMaxSize().background(c.bg)) {
            BackRow { page = MorePage.Root }
            when (page) {
                MorePage.Cafeteria -> CafeteriaScreen(vm, prefs)
                MorePage.Guide -> GuideScreen()
                MorePage.Stats -> StatsScreen(vm, prefs)
                MorePage.TimeOff -> TimeOffScreen(vm, prefs)
                MorePage.CalendarSync -> CalendarSyncScreen(vm, prefs)
                else -> SwapScreen(vm)
            }
        }
        return
    }

    if (page == MorePage.Root) {
        MoreRoot(vm, prefs, open = { page = it }, signOut = { showSignOut = true })
    } else Column(Modifier.fillMaxSize().background(c.bg).verticalScroll(rememberScrollState())) {
        val up = page.parent
        BackRow(if (up == MorePage.Advanced) "‹ Advanced" else "‹ More") { page = up }

        when (page) {
            MorePage.Root -> Unit   // drawn by MoreRoot

            // handled above — they need the full height, not a scroll column
            MorePage.Stats, MorePage.Swap, MorePage.TimeOff, MorePage.CalendarSync,
            MorePage.Cafeteria, MorePage.Guide -> Unit

            MorePage.AutoSignIn -> AutoSignInPage(prefs)

            MorePage.Export -> ExportPage(vm)

            MorePage.Advanced -> {
                SectionHeader("Personalize")
                Text(
                    "Open the app on",
                    fontSize = 12.sp, color = c.muted,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
                )
                listOf("Shift Pool", "My Shifts", "Who's On", "Crew").forEachIndexed { i, label ->
                    Row(
                        Modifier.fillMaxWidth().clickable { prefs.updateDefaultTab(i) }
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = prefs.defaultTab == i, onClick = { prefs.updateDefaultTab(i) })
                        Text(label, color = c.ink)
                    }
                }
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text("Shift Pool opens on “For me”", color = c.ink, modifier = Modifier.weight(1f))
                    Switch(checked = prefs.poolForMe, onCheckedChange = { prefs.updatePoolForMe(it) })
                }
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text("Show “Recently taken” in the Pool", color = c.ink, modifier = Modifier.weight(1f))
                    Switch(checked = prefs.showRecentTaken, onCheckedChange = { prefs.updateShowRecentTaken(it) })
                }
                RadioGroup(
                    "My Posts tab",
                    listOf(
                        "auto" to "Auto — when I have posts",
                        "always" to "Always show",
                        "pending" to "Only when awaiting pickup",
                    ),
                    prefs.myPostsMode,
                ) { prefs.updateMyPostsMode(it) }
                RadioGroup(
                    "Week starts on",
                    listOf(0 to "Sunday", 1 to "Monday"),
                    prefs.weekStart,
                ) { prefs.updateWeekStart(it) }
                MoreRow("Who's On order") { page = MorePage.WhoOrder }
                MoreRow("App icon") { page = MorePage.AppIcon }
                MoreRow("Witty lines") { page = MorePage.Quips }
                MoreRow("Auto sign-in") { page = MorePage.AutoSignIn }
                Text(
                    "Make it yours. Witty lines start from the built-in set — add your own, or Reset to " +
                        "bring ours back. More options coming.",
                    fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(16.dp),
                )

                // Hennie holiday — your next run of 4+ days off in a row.
                SectionHeader("Hennie holiday")
                val log = vm.shiftLog.ifEmpty { vm.myShifts }
                val hennie = remember(log) { nextHennieHoliday(log, AppViewModel.todayRegina()) }
                if (hennie != null) {
                    Column(
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp)
                            .clip(RoundedCornerShape(14.dp))
                            .background(c.panel)
                            .padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(3.dp),
                    ) {
                        Text("🌴 Next Hennie holiday", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
                        Text(
                            "${fmt(hennie.start, "EEE, MMM d")} – ${fmt(hennie.end, "EEE, MMM d")}",
                            fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.accent,
                        )
                        Text("${hennie.days} days off in a row", fontSize = 12.sp, color = c.muted)
                    }
                } else {
                    Text(
                        "No Hennie holiday on the horizon. Chin up — go pick one up. ☕️",
                        fontSize = 14.sp, color = c.ink, modifier = Modifier.padding(horizontal = 16.dp),
                    )
                }
                Text(
                    "Your next run of 4+ days off in a row. You know the one.",
                    fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(16.dp),
                )
            }

            MorePage.AppIcon -> AppIconPage()

            MorePage.Quips -> QuipsPage()

            MorePage.WhoOrder -> {
                SectionHeader("Who's On order")
                Text(
                    "The order units appear as rows in the Who's Working grid.",
                    fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(16.dp),
                )
                prefs.unitOrder.forEachIndexed { i, u ->
                    val info = Units.info[u]
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Box(
                            Modifier.size(width = 5.dp, height = 22.dp)
                                .clip(RoundedCornerShape(2.dp))
                                .background(info?.color ?: Color.Gray)
                        )
                        Text(info?.short ?: u.name, color = c.ink, modifier = Modifier.weight(1f))
                        TextButton(onClick = { prefs.moveUnit(i, i - 1) }, enabled = i > 0) { Text("↑") }
                        TextButton(
                            onClick = { prefs.moveUnit(i, i + 1) },
                            enabled = i < prefs.unitOrder.lastIndex,
                        ) { Text("↓") }
                    }
                }
                TextButton(
                    onClick = { prefs.resetUnitOrder() },
                    modifier = Modifier.padding(horizontal = 12.dp),
                ) { Text("Reset to default") }
            }

            MorePage.About -> {
                SectionHeader("About")
                Text(
                    "Working-Bolt reads your own Lightning Bolt schedule through the same web session you " +
                        "sign into — no password is ever stored, and nothing leaves your phone.",
                    fontSize = 13.sp, color = c.ink, modifier = Modifier.padding(16.dp),
                )
                Text(
                    "Android port of the iOS app. ⚡",
                    fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(horizontal = 16.dp),
                )
            }
        }
        Box(Modifier.padding(40.dp))
    }

    if (showSignOut) {
        AlertDialog(
            onDismissRequest = { showSignOut = false },
            title = { Text("Sign out?") },
            text = {
                Text(
                    "Clears the session and cached data on this device. Your history re-loads when you " +
                        "(or someone else) signs back in.",
                )
            },
            confirmButton = {
                TextButton(onClick = { showSignOut = false; vm.signOut() }) { Text("Sign out") }
            },
            dismissButton = { TextButton(onClick = { showSignOut = false }) { Text("Cancel") } },
        )
    }
}

/**
 * The More list, grouped like iOS: My shifts · Calendar · 🍴 Cafeteria · App. Row padding grows with the screen
 * height so the list fills a tall phone instead of bunching at the top (compact on a small one; scrolls if needed).
 */
@Composable
private fun MoreRoot(vm: AppViewModel, prefs: Prefs, open: (MorePage) -> Unit, signOut: () -> Unit) {
    val c = Theme.colors
    val context = LocalContext.current
    LaunchedEffect(vm.demo) { CafeteriaStore.load(context, vm.demo) }   // today's lunch under the 🍴 row
    BoxWithConstraints(Modifier.fillMaxSize().background(c.bg)) {
        val rows = 11
        val pad = (7f + (maxHeight.value - 660f) / (2 * rows)).coerceIn(7f, 15f).dp
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            Text(
                "More", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = c.ink,
                modifier = Modifier.padding(start = 4.dp, top = 10.dp, bottom = 2.dp),
            )
            MoreGroup("My shifts") {
                GroupRow("Swap or Give Away", pad) { open(MorePage.Swap) }
                GroupRow("Time Off Requests", pad) { open(MorePage.TimeOff) }
                GroupRow("My Stats", pad) { open(MorePage.Stats) }
            }
            MoreGroup("Calendar") {
                GroupRow("Sync to Calendar", pad) { open(MorePage.CalendarSync) }
                GroupRow("Export", pad) { open(MorePage.Export) }
            }
            MoreGroup(null) {
                GroupRow(
                    "🍴  Cafeteria menu", pad,
                    subtitle = CafeteriaStore.todaysLunch(prefs.cafeSite)?.let { "Today: $it" },
                ) { open(MorePage.Cafeteria) }
            }
            MoreGroup("App") {
                GroupRow("How to use Working-Bolt", pad) { open(MorePage.Guide) }
                GroupRow("Advanced", pad) { open(MorePage.Advanced) }
                StartScreenRow(prefs, pad)
                GroupRow("About", pad) { open(MorePage.About) }
                GroupRow("Sign out", pad, danger = true, onClick = signOut)
            }
            if (vm.userName.isNotEmpty()) {
                Text(
                    "Signed in as ${vm.userName}", fontSize = 12.sp, color = c.muted,
                    modifier = Modifier.padding(start = 4.dp, top = 8.dp),
                )
            }
            if (vm.demo) {
                Text(
                    "Sample-data preview — nothing here is live.", fontSize = 12.sp, color = c.muted,
                    modifier = Modifier.padding(start = 4.dp, top = 4.dp),
                )
            }
            Box(Modifier.padding(12.dp))
        }
    }
}

/** A titled card of rows (header null = no title, just the gap). Dividers between rows. */
@Composable
private fun MoreGroup(header: String?, content: @Composable () -> Unit) {
    val c = Theme.colors
    if (header != null) {
        Text(
            header.uppercase(), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = c.muted, letterSpacing = 0.5.sp,
            modifier = Modifier.padding(start = 4.dp, top = 14.dp, bottom = 5.dp),
        )
    } else {
        Box(Modifier.padding(top = 14.dp))
    }
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(c.panel)) { content() }
}

@Composable
private fun GroupRow(
    label: String, pad: Dp, subtitle: String? = null, danger: Boolean = false, onClick: () -> Unit,
) {
    val c = Theme.colors
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 14.dp, vertical = pad),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, fontSize = 16.sp, color = if (danger) Color(0xFFD64545) else c.ink)
            if (subtitle != null) {
                Text(subtitle, fontSize = 12.sp, color = c.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (!danger) Text("›", fontSize = 18.sp, color = c.muted)
    }
}

/** How long the opening screen holds — tap for a menu of 2–8 s in half-second steps (same grid as iOS). */
@Composable
private fun StartScreenRow(prefs: Prefs, pad: Dp) {
    val c = Theme.colors
    var open by remember { mutableStateOf(false) }
    val label = { s: Float -> if (s % 1f == 0f) "${s.toInt()} s" else String.format(Locale.ROOT, "%.1f s", s) }
    Row(
        Modifier.fillMaxWidth().clickable { open = true }.padding(horizontal = 14.dp, vertical = pad),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Start screen", fontSize = 16.sp, color = c.ink, modifier = Modifier.weight(1f))
        // The menu anchors to this trailing box, so it opens by the value (right side), not at the row's left edge.
        Box {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(label(prefs.splashSecs), fontSize = 16.sp, color = c.muted)
                Text("  ⌄", fontSize = 14.sp, color = c.muted)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                (4..16).map { it / 2f }.forEach { s ->
                    DropdownMenuItem(
                        text = { Text(label(s), fontWeight = if (s == prefs.splashSecs) FontWeight.SemiBold else FontWeight.Normal) },
                        onClick = { prefs.updateSplashSecs(s); open = false },
                    )
                }
            }
        }
    }
}

@Composable
private fun BackRow(label: String = "‹ More", onBack: () -> Unit) {
    val c = Theme.colors
    Column {
        Row(
            Modifier.fillMaxWidth().clickable(onClick = onBack).padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, color = c.accent, fontWeight = FontWeight.SemiBold)
        }
        HorizontalDivider(color = c.line)
    }
}

private val FULL_PAGES = setOf(
    MorePage.Stats, MorePage.Swap, MorePage.TimeOff, MorePage.CalendarSync, MorePage.Cafeteria, MorePage.Guide,
)

/** A titled single-choice list — the stand-in for a SwiftUI Picker row. */
@Composable
private fun <T> RadioGroup(title: String, options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    val c = Theme.colors
    Text(title, fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
    options.forEach { (value, label) ->
        Row(
            Modifier.fillMaxWidth().clickable { onSelect(value) }.padding(horizontal = 16.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            RadioButton(selected = selected == value, onClick = { onSelect(value) })
            Text(label, color = c.ink)
        }
    }
}

/**
 * Auto sign-in — opt in to keep your OWN Lightning Bolt login encrypted on this device, so the app signs
 * back in automatically when the LB session expires. Two modes that share one slot (so they're mutually
 * exclusive): behind a fingerprint / face check, or silent ("Keep me signed in"). Off by default.
 */
@Composable
private fun AutoSignInPage(prefs: Prefs) {
    val c = Theme.colors
    val context = LocalContext.current
    var pendingBiometric by remember { mutableStateOf<Boolean?>(null) }   // which mode the dialog is collecting for

    SectionHeader("Auto sign-in")
    if (LBCreds.biometricsAvailable(context)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Sign in automatically with fingerprint or face unlock",
                color = c.ink, modifier = Modifier.weight(1f),
            )
            Switch(
                checked = prefs.biometricLogin,
                onCheckedChange = { on ->
                    if (on) pendingBiometric = true                                   // collect creds, then store
                    else { LBCreds.clear(context); prefs.updateBiometricLogin(false) }  // forget them
                },
            )
        }
        Text(
            "Saves your Lightning Bolt username + password encrypted on this device, so the app signs you " +
                "back in automatically when your session expires. It stays on this device only, is never " +
                "sent anywhere, and is only used after a fingerprint or face unlock check. Turn off to erase it.",
            fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(horizontal = 16.dp),
        )
        Text(
            "NO FINGERPRINT OR FACE UNLOCK",
            fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = c.muted,
            modifier = Modifier.padding(start = 16.dp, top = 22.dp),
        )
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Keep me signed in", color = c.ink, modifier = Modifier.weight(1f))
        Switch(
            checked = prefs.keepSignedIn,
            onCheckedChange = { on ->
                if (on) pendingBiometric = false
                else { LBCreds.clear(context); prefs.updateKeepSignedIn(false) }
            },
        )
    }
    Text(
        "Saves your Lightning Bolt login encrypted on this device and signs you back in automatically when " +
            "your session expires — no biometrics, and nothing is ever sent anywhere. Trade-off: without a " +
            "fingerprint or face unlock check, anyone who has your phone unlocked could open the app already " +
            "signed in. Turn off to erase it.",
        fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(horizontal = 16.dp),
    )

    pendingBiometric?.let { biometric ->
        CredentialsDialog(
            biometric = biometric,
            onDismiss = { pendingBiometric = null },
            onSaved = {                                  // called only after a successful save
                prefs.updateBiometricLogin(biometric)    // the two modes share one stored login
                prefs.updateKeepSignedIn(!biometric)
                pendingBiometric = null
            },
        )
    }
}

/**
 * The user types their Lightning Bolt username + password once; it's encrypted with a Keystore key and kept
 * on this device (never transmitted). The password field is masked, and the app only holds the text long
 * enough to store it — it is not remembered across a rotation or process restart.
 */
@Composable
private fun CredentialsDialog(biometric: Boolean, onDismiss: () -> Unit, onSaved: () -> Unit) {
    val context = LocalContext.current
    var user by remember { mutableStateOf("") }
    var pass by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Lightning Bolt sign-in") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = user, onValueChange = { user = it; error = null },
                    label = { Text("Username") }, singleLine = true,
                    keyboardOptions = KeyboardOptions(
                        capitalization = KeyboardCapitalization.None,
                        autoCorrect = false,
                        keyboardType = KeyboardType.Email,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = pass, onValueChange = { pass = it; error = null },
                    label = { Text("Password") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    modifier = Modifier.fillMaxWidth(),
                )
                error?.let { Text(it, fontSize = 13.sp, color = Color(0xFFD64545)) }
                Text(
                    if (biometric) {
                        "Stored only on this device, encrypted, behind fingerprint or face unlock. Used to sign " +
                            "you back in to Lightning Bolt automatically when your session expires. It's never " +
                            "sent anywhere. Turn the toggle off to erase it."
                    } else {
                        "Stored only on this device, encrypted. Used to sign you back in to Lightning Bolt " +
                            "automatically when your session expires — no fingerprint or face unlock. It's " +
                            "never sent anywhere. Turn the toggle off to erase it."
                    },
                    fontSize = 12.sp, color = Theme.colors.muted,
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = user.isNotBlank() && pass.isNotEmpty(),
                onClick = {
                    val u = user.trim()
                    if (u.isEmpty() || pass.isEmpty()) {
                        error = "Enter both your username and password."
                    } else {
                        val e = LBCreds.save(context, u, pass)
                        if (e != null) error = e else { pass = ""; onSaved() }
                    }
                },
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Witty lines — the rotation shown on the opening screen. Add your own, or reset to ours. */
@Composable
private fun QuipsPage() {
    val c = Theme.colors
    val store = QuipStore.get(LocalContext.current)
    var draft by remember { mutableStateOf("") }
    var editing by remember { mutableStateOf<Int?>(null) }
    var editText by remember { mutableStateOf("") }

    SectionHeader("Witty lines")
    Text(
        "These rotate on the opening screen. Yours are saved on this device.",
        fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(horizontal = 16.dp),
    )
    Row(
        Modifier.fillMaxWidth().padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        OutlinedTextField(
            value = draft, onValueChange = { draft = it },
            placeholder = { Text("Add a line") }, singleLine = false,
            modifier = Modifier.weight(1f),
        )
        TextButton(onClick = { store.add(draft); draft = "" }, enabled = draft.isNotBlank()) { Text("Add") }
    }
    store.quips.forEachIndexed { i, q ->
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(q, fontSize = 13.sp, color = c.ink, modifier = Modifier.weight(1f))
            TextButton(onClick = { editing = i; editText = q }) { Text("Edit", fontSize = 12.sp) }
            TextButton(onClick = { store.delete(i) }) { Text("✕", color = c.muted) }
        }
        HorizontalDivider(color = c.line)
    }
    TextButton(
        onClick = { store.resetToDefaults() },
        modifier = Modifier.padding(horizontal = 12.dp),
    ) { Text("Reset to ours") }

    editing?.let { i ->
        AlertDialog(
            onDismissRequest = { editing = null },
            title = { Text("Edit line") },
            text = {
                OutlinedTextField(
                    value = editText, onValueChange = { editText = it },
                    modifier = Modifier.fillMaxWidth(), minLines = 2,
                )
            },
            confirmButton = {
                TextButton(onClick = { store.update(i, editText); editing = null }) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = { editing = null }) { Text("Cancel") } },
        )
    }
}

/** Export — the shift log as a calendar file or a spreadsheet, handed to the system share sheet. */
@Composable
private fun ExportPage(vm: AppViewModel) {
    val c = Theme.colors
    val context = LocalContext.current
    val log = vm.shiftLog.ifEmpty { vm.myShifts }

    SectionHeader("Export")
    Text(
        "${log.size} shift${if (log.size == 1) "" else "s"} on file.",
        fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(horizontal = 16.dp),
    )
    MoreRow("Add to Calendar (.ics)") {
        ShiftExport.share(context, "my-shifts.ics", "text/calendar", ShiftExport.ics(log))
    }
    MoreRow("Spreadsheet (CSV)") {
        ShiftExport.share(context, "shift-log.csv", "text/csv", ShiftExport.csv(log))
    }
    Text(
        "The .ics drops your shifts straight into Google or Outlook Calendar. The CSV opens in Sheets or Excel.",
        fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(16.dp),
    )
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text,
        fontSize = 20.sp, fontWeight = FontWeight.Bold, color = Theme.colors.ink,
        modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 8.dp),
    )
}

@Composable
private fun MoreRow(label: String, danger: Boolean = false, onClick: () -> Unit) {
    val c = Theme.colors
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, color = if (danger) Color(0xFFD64545) else c.ink, modifier = Modifier.weight(1f))
        if (!danger) Text("›", color = c.muted)
    }
}
