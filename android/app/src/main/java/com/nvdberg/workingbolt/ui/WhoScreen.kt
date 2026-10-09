package com.nvdberg.workingbolt.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.UnitKey
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

/**
 * Who's Working — the whole group's coverage.
 * Portrait: a vertical day-timeline with a date picker + Today. Landscape: a week grid.
 * Long-press MY OWN upcoming shift → the same swap / give-away screen as My Shifts. A plain tap does nothing,
 * so browsing Who's On can never trip a stray prompt.
 */
@Composable
fun WhoScreen(vm: AppViewModel, prefs: Prefs, tabTick: Int) {
    val c = Theme.colors
    val haptics = LocalHapticFeedback.current
    val days = vm.whoDays
    val byDay = vm.whoByDay
    val todayISO = AppViewModel.todayRegina()

    var selectedISO by remember { mutableStateOf(todayISO) }
    var scrollTick by remember { mutableIntStateOf(0) }
    var visibleMonth by remember { mutableStateOf("") }
    // Have we centred on today once real (current) data is present?
    var landedOnToday by remember { mutableStateOf(false) }
    var swapInitial by remember { mutableStateOf<MyShift?>(null) }
    var swapGiveAway by remember { mutableStateOf(false) }
    var swapSheet by remember { mutableStateOf(false) }
    var pastAlert by remember { mutableStateOf(false) }

    // Long-pressed one of my own shift cells → look up the live MyShift (real slot_id) and open the shared
    // swap/give-away screen. No-op in demo; falls back to an alert if the shift isn't actually giveable.
    val mineAction: (String, UnitKey, Boolean) -> Unit = action@{ iso, unit, giveAway ->
        if (vm.demo) return@action
        val s = vm.myShifts.firstOrNull {
            it.date == iso && it.unit == unit && it.slotID != null && it.date >= AppViewModel.todayRegina()
        }
        if (s == null) { pastAlert = true; return@action }
        swapInitial = s; swapGiveAway = giveAway; swapSheet = true
    }

    LaunchedEffect(Unit) {
        if (days.contains(todayISO)) landedOnToday = true
        vm.loadGroupHistory()                             // the whole group's history (2022 →), cached
    }
    LaunchedEffect(tabTick) { selectedISO = todayISO; scrollTick++ }   // tapping the tab → re-center on today
    // Stale data (expired token) can open the tab stuck in the past with today missing entirely. When fresh
    // data arrives and today shows up in the range, snap to it once — no sign-out/in needed to unstick it.
    LaunchedEffect(days) {
        if (!landedOnToday && days.contains(todayISO)) {
            landedOnToday = true
            selectedISO = todayISO
            scrollTick++
        }
    }

    DayScaffold(
        title = visibleMonth.ifEmpty { "Who's On" },
        days = days,
        selectedISO = selectedISO,
        onSelect = { selectedISO = it; scrollTick++ },
        onToday = { selectedISO = todayISO; scrollTick++ },
        todayEnabled = days.contains(todayISO),
        actions = {
            // Stethoscope toggle → doctors on call (intensivist per ICU, who's in CCU, tonight's on-call strip).
            val on = prefs.whoDoctors
            Box(
                Modifier.padding(horizontal = 2.dp).size(34.dp).clip(CircleShape)
                    .background(if (on) c.accent.copy(alpha = 0.18f) else Color.Transparent)
                    .clickable {
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        prefs.updateWhoDoctors(!on)
                    }
                    .semantics { contentDescription = if (on) "Hide doctors on call" else "Show doctors on call" },
                contentAlignment = Alignment.Center,
            ) { Text("🩺", fontSize = 16.sp, modifier = Modifier.alpha(if (on) 1f else 0.55f)) }
        },
    ) {
        val cfg = LocalConfiguration.current
        val landscape = cfg.screenWidthDp > cfg.screenHeightDp
        Box(Modifier.fillMaxSize()) {
            when {
                days.isEmpty() -> Column(
                    Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    if (vm.loading || vm.groupScanning) {
                        CircularProgressIndicator(color = c.accent)
                        Box(Modifier.height(10.dp))
                        Text("Reading your roster…", color = c.muted)
                    } else {
                        Text("No coverage loaded yet", color = c.muted)
                    }
                }
                landscape -> WhoWeekGrid(
                    days = days, byDay = byDay, todayISO = todayISO,
                    scrollTo = selectedISO, scrollTick = scrollTick,
                    availHeight = cfg.screenHeightDp.dp, unitOrder = prefs.unitOrder,
                    onVisibleMonth = { visibleMonth = it }, bottomInset = 68.dp, onMine = mineAction,
                    doctors = prefs.whoDoctors, demo = vm.demo,
                )
                else -> Column(Modifier.fillMaxSize()) {
                    if (prefs.whoDoctors) UnitPhonesBar(prefs.unitOrder)
                    WhoDayTimeline(
                        days = days, byDay = byDay, todayISO = todayISO,
                        scrollTo = selectedISO, scrollTick = scrollTick, unitOrder = prefs.unitOrder,
                        onMine = mineAction, doctors = prefs.whoDoctors, demo = vm.demo,
                    )
                }
            }
        }
    }

    if (pastAlert) {
        AlertDialog(
            onDismissRequest = { pastAlert = false },
            title = { Text("Can't do that one") },
            text = { Text("You can only swap or give away your own upcoming shifts.") },
            confirmButton = { TextButton(onClick = { pastAlert = false }) { Text("OK") } },
        )
    }

    if (swapSheet) {
        Dialog(onDismissRequest = { swapSheet = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
            Surface(Modifier.fillMaxSize(), color = c.bg) {
                Column(Modifier.fillMaxSize()) {
                    Row(
                        Modifier.fillMaxWidth().padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "Swap or Give Away", fontSize = 16.sp, fontWeight = FontWeight.Bold,
                            color = c.ink, modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = { swapSheet = false }) { Text("Close") }
                    }
                    SwapScreen(vm, initialShift = swapInitial, startInGiveAway = swapGiveAway)
                }
            }
        }
    }
}

/** The shared title bar for Who's On / Crew: anchored month, a date jump, and Today. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DayScaffold(
    title: String,
    days: List<String>,
    selectedISO: String,
    onSelect: (String) -> Unit,
    onToday: () -> Unit,
    todayEnabled: Boolean,
    actions: @Composable () -> Unit = {},
    content: @Composable () -> Unit,
) {
    val c = Theme.colors
    var showPicker by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(title, fontSize = 16.sp, color = c.ink)
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (days.isNotEmpty()) {
                    TextButton(onClick = { showPicker = true }) {
                        Text(longDate(selectedISO), fontSize = 13.sp, color = c.muted)
                    }
                    actions()
                    TextButton(onClick = onToday, enabled = todayEnabled) {
                        Text("Today", fontSize = 13.sp, color = c.muted)
                    }
                }
            }
        }
        content()
    }

    if (showPicker && days.isNotEmpty()) {
        val initial = (isoDate(selectedISO) ?: LocalDate.now())
            .atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
        val state = rememberDatePickerState(initialSelectedDateMillis = initial)
        DatePickerDialog(
            onDismissRequest = { showPicker = false },
            confirmButton = {
                TextButton(onClick = {
                    state.selectedDateMillis?.let { ms ->
                        val picked = Instant.ofEpochMilli(ms).atZone(ZoneOffset.UTC).toLocalDate().toString()
                        // Clamp into the loaded range so the jump always lands on a day we actually have.
                        val clamped = picked.coerceIn(days.first(), days.last())
                        onSelect(clamped)
                    }
                    showPicker = false
                }) { Text("Go") }
            },
            dismissButton = { TextButton(onClick = { showPicker = false }) { Text("Cancel") } },
        ) {
            DatePicker(state = state)
        }
    }
}
