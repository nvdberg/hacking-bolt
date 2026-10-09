package com.nvdberg.workingbolt.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshContainer
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.data.LBWebSource
import com.nvdberg.workingbolt.model.TimeOffRequest
import com.nvdberg.workingbolt.model.Units
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.YearMonth

/** Consecutive days submitted together (same kind, note, status, submit time) — shown as one row. */
class TimeOffBlock(val days: List<TimeOffRequest>) {
    val id: Int get() = days[0].id
    val first: TimeOffRequest get() = days[0]
    val ids: List<Int> get() = days.map { it.id }

    companion object {
        fun group(reqs: List<TimeOffRequest>): List<TimeOffBlock> {
            val out = ArrayList<MutableList<TimeOffRequest>>()
            for (r in reqs.sortedBy { it.date }) {
                val p = out.lastOrNull()?.lastOrNull()
                if (p != null && p.kind == r.kind && p.note == r.note && p.status == r.status &&
                    p.submitted == r.submitted && isoDate(p.date)?.plusDays(1)?.toString() == r.date
                ) out.last().add(r) else out.add(mutableListOf(r))
            }
            return out.map { TimeOffBlock(it) }
        }

        fun range(b: TimeOffBlock): String {
            val a = b.days.first().date
            val z = b.days.last().date
            return if (a == z) fmt(a, "EEE, MMM d") else "${fmt(a, "EEE, MMM d")} – ${fmt(z, "EEE, MMM d")}"
        }
    }
}

/**
 * Matt's ask: request time off / a night off from Working-Bolt, see the status, cancel while pending.
 * Only ever touches the signed-in user's OWN requests; every send sits behind a confirm that says exactly
 * what goes. Opened from More (under Swap or Give Away).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TimeOffScreen(vm: AppViewModel, prefs: Prefs) {
    val c = Theme.colors
    val scope = rememberCoroutineScope()
    var composing by remember { mutableStateOf(false) }
    var cancelBlock by remember { mutableStateOf<TimeOffBlock?>(null) }
    var busy by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<Pair<Boolean, String>?>(null) }   // (ok, text)

    val today = AppViewModel.todayRegina()
    val requests = vm.myRequests
    val upcoming = remember(requests, today) { TimeOffBlock.group(requests.filter { it.date >= today }) }
    val past = remember(requests, today) { TimeOffBlock.group(requests.filter { it.date < today }).reversed() }

    LaunchedEffect(Unit) { vm.loadRequests() }

    val pull = rememberPullToRefreshState()
    if (pull.isRefreshing) {
        LaunchedEffect(Unit) {
            try { vm.loadRequests() } finally { pull.endRefresh() }
        }
    }

    Box(Modifier.fillMaxSize().background(c.bg).clipToBounds().nestedScroll(pull.nestedScrollConnection)) {
        LazyColumn(Modifier.fillMaxSize()) {
            item {
                Row(
                    Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "Time Off", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = c.ink,
                        modifier = Modifier.weight(1f),
                    )
                    if (busy || vm.requestsLoading) {
                        CircularProgressIndicator(Modifier.size(18.dp), color = c.accent, strokeWidth = 2.dp)
                    }
                }
            }
            item {
                Text(
                    "＋ New request",
                    fontWeight = FontWeight.SemiBold,
                    color = if (busy) c.muted else c.accent,
                    modifier = Modifier.fillMaxWidth()
                        .clickable(enabled = !busy) { composing = true }
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                )
            }
            result?.let { r ->
                item {
                    Text(
                        (if (r.first) "✓ " else "⚠ ") + r.second,
                        fontSize = 13.sp, color = if (r.first) c.accent else c.available,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
            }

            item { GroupLabel("Upcoming") }
            if (upcoming.isEmpty()) {
                item {
                    Text(
                        if (vm.requestsLoading) "Loading your requests…" else "No upcoming requests.",
                        fontSize = 13.sp, color = c.muted,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
            }
            items(upcoming, key = { it.id }) { b ->
                TimeOffRow(b, onCancel = if (b.first.isPending && !busy) ({ cancelBlock = b }) else null)
                HorizontalDivider(color = c.line)
            }

            if (past.isNotEmpty()) {
                item { GroupLabel("Past") }
                items(past, key = { it.id }) { b ->
                    Box(Modifier.alpha(0.6f)) { TimeOffRow(b, onCancel = null) }
                    HorizontalDivider(color = c.line)
                }
            }
            item {                                           // quiet easter egg — the feature was Matt's idea
                Text(
                    "Matt's idea 🤝",
                    fontSize = 11.sp, fontStyle = FontStyle.Italic, color = c.muted, textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(top = 24.dp, bottom = 40.dp),
                )
            }
        }
        PullToRefreshContainer(pull, Modifier.align(Alignment.TopCenter))
    }

    if (composing) {
        TimeOffCompose(
            vm, prefs,
            onDismiss = { composing = false },
            onSend = { kind, dates, note ->
                composing = false
                scope.launch {
                    busy = true
                    try {
                        val out = vm.submitTimeOff(kind, dates, note)
                        result = if (out.ok) {
                            true to "Sent — ${kind.label} for ${dates.size} day${if (dates.size == 1) "" else "s"} is pending approval."
                        } else {
                            false to (out.message ?: "Lightning Bolt didn't accept it.")
                        }
                    } finally {
                        busy = false
                    }
                }
            },
        )
    }

    cancelBlock?.let { b ->
        AlertDialog(
            onDismissRequest = { cancelBlock = null },
            title = { Text("Cancel ${b.first.kind} request?") },
            text = {
                Text(
                    "Asks Lightning Bolt to delete your ${b.first.kind} request for ${TimeOffBlock.range(b)}. " +
                        "Nothing else changes.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    cancelBlock = null
                    scope.launch {
                        busy = true
                        try {
                            val out = vm.cancelRequests(b.ids)
                            result = if (out.ok) true to "Cancelled."
                            else false to (out.message ?: "Lightning Bolt didn't accept the cancel.")
                        } finally {
                            busy = false
                        }
                    }
                }) {
                    Text(
                        if (b.days.size == 1) "Cancel this request" else "Cancel all ${b.days.size} days",
                        color = Color(0xFFD64545),
                    )
                }
            },
            dismissButton = { TextButton(onClick = { cancelBlock = null }) { Text("Keep it") } },
        )
    }
}

@Composable
private fun GroupLabel(text: String) {
    Text(
        text.uppercase(),
        fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Theme.colors.muted,
        modifier = Modifier.padding(start = 16.dp, top = 18.dp, bottom = 6.dp),
    )
}

/** One request block: kind, dates, note, status — plus Cancel while it's still pending. */
@Composable
private fun TimeOffRow(block: TimeOffBlock, onCancel: (() -> Unit)?) {
    val c = Theme.colors
    val statusColor = when (block.first.status.lowercase()) {
        "pending" -> c.available
        "approved", "granted" -> c.accent
        else -> Color(0xFFD64545)
    }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            if (block.first.kind == "Night Off") Icons.Filled.Bedtime else Icons.Filled.WbSunny,
            contentDescription = null, tint = c.muted, modifier = Modifier.width(26.dp),
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(block.first.kind, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
                if (block.days.size > 1) Text("· ${block.days.size} days", fontSize = 12.sp, color = c.muted)
            }
            Text(TimeOffBlock.range(block), fontSize = 13.sp, color = c.ink)
            if (block.first.note.isNotEmpty()) {
                Text(
                    "“${block.first.note}”", fontSize = 12.sp, color = c.muted,
                    maxLines = 2, overflow = TextOverflow.Ellipsis,
                )
            }
            val d = block.first.decision
            if (!d.isNullOrEmpty()) {
                Text(d, fontSize = 12.sp, color = statusColor, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(
                block.first.status.replaceFirstChar { it.uppercase() },
                fontSize = 11.sp, fontWeight = FontWeight.Bold, color = statusColor,
                modifier = Modifier.clip(CircleShape).background(statusColor.copy(alpha = 0.14f))
                    .padding(horizontal = 7.dp, vertical = 3.dp),
            )
            if (onCancel != null) {
                TextButton(onClick = onCancel) { Text("Cancel", fontSize = 12.sp, color = Color(0xFFD64545)) }
            }
        }
    }
}

/** Compose a new request: kind, the days (LB's own UI picks individual dates too), a reason → confirm → send. */
@Composable
private fun TimeOffCompose(
    vm: AppViewModel,
    prefs: Prefs,
    onDismiss: () -> Unit,
    onSend: (LBWebSource.RequestKind, List<String>, String) -> Unit,
) {
    val c = Theme.colors
    val today = AppViewModel.todayRegina()
    var kind by remember { mutableStateOf(LBWebSource.RequestKind.TimeOff) }
    var picked by remember { mutableStateOf(setOf<String>()) }
    var note by remember { mutableStateOf("") }
    var confirming by remember { mutableStateOf(false) }

    val dates = picked.filter { it >= today }.sorted()
    // Days I'm already rostered on — worth knowing before asking for them off.
    val log = vm.shiftLog.ifEmpty { vm.myShifts }
    val clashes = remember(dates, log) {
        val byDay = sortedMapOf<String, MutableList<String>>()   // one line per day (a Pasqua pair = two units)
        for (sh in log) if (sh.date in picked) {
            byDay.getOrPut(sh.date) { mutableListOf() }.add(Units.info[sh.unit]?.short ?: sh.unit.name)
        }
        byDay.map { it.key to it.value.joinToString(" + ") }
    }
    val datesSummary = when {
        dates.isEmpty() -> ""
        dates.size == 1 -> fmt(dates[0], "EEE, MMM d")
        else -> "${dates.size} days · ${fmt(dates.first(), "MMM d")} – ${fmt(dates.last(), "MMM d")}"
    }
    val trimmed = note.trim()

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = c.bg) {
            Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    TextButton(onClick = onDismiss) { Text("Cancel") }
                    Text("New request", fontWeight = FontWeight.Bold, color = c.ink)
                }
                HorizontalDivider(color = c.line)

                Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 32.dp)) {
                    // Type
                    Row(
                        Modifier.fillMaxWidth().padding(16.dp).clip(RoundedCornerShape(10.dp)).background(c.line),
                    ) {
                        LBWebSource.RequestKind.entries.forEach { k ->
                            val on = k == kind
                            Text(
                                k.label,
                                fontSize = 14.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                                color = c.ink, textAlign = TextAlign.Center,
                                modifier = Modifier.weight(1f).padding(3.dp)
                                    .clip(RoundedCornerShape(8.dp))
                                    .background(if (on) c.panel else Color.Transparent)
                                    .clickable { kind = k }
                                    .padding(vertical = 8.dp),
                            )
                        }
                    }

                    GroupLabel("Days")
                    DayPicker(today, prefs.weekStart, picked) { iso ->
                        picked = if (iso in picked) picked - iso else picked + iso
                    }
                    Text(
                        if (dates.isEmpty()) "Tap each day you want off." else datesSummary,
                        fontSize = 12.sp, color = c.muted,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )

                    if (clashes.isNotEmpty()) {
                        clashes.forEach { (day, units) ->
                            Text(
                                "⚠ You're rostered $units on ${fmt(day, "EEE, MMM d")}",
                                fontSize = 13.sp, color = c.available,
                                modifier = Modifier.padding(horizontal = 16.dp, vertical = 3.dp),
                            )
                        }
                        Text(
                            "A request doesn't move a shift you already have — swap or give it away separately.",
                            fontSize = 12.sp, color = c.muted,
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
                        )
                    }

                    GroupLabel("Reason")
                    OutlinedTextField(
                        value = note, onValueChange = { note = it },
                        placeholder = { Text("e.g. family event") },
                        minLines = 1, maxLines = 4,
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                    )

                    Button(
                        onClick = { confirming = true },
                        enabled = dates.isNotEmpty(),
                        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 20.dp),
                    ) { Text("Review & send", fontWeight = FontWeight.SemiBold) }
                    Text(
                        if (vm.demo) "Sample data — nothing is sent in the preview."
                        else "Goes to Lightning Bolt as a pending request for your scheduler to approve. " +
                            "You can cancel it while it's pending.",
                        fontSize = 12.sp, color = c.muted,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                    )
                }
            }
        }

        if (confirming) {
            AlertDialog(
                onDismissRequest = { confirming = false },
                title = { Text("Send this request?") },
                text = {
                    Text(
                        "${kind.label} · $datesSummary\n" +
                            (if (trimmed.isEmpty()) "No reason given" else "Reason: “$trimmed”") +
                            "\n\nSent to Lightning Bolt for your own roster only.",
                    )
                },
                confirmButton = {
                    TextButton(onClick = { confirming = false; onSend(kind, dates, trimmed) }) {
                        Text("Send ${kind.label} request")
                    }
                },
                dismissButton = { TextButton(onClick = { confirming = false }) { Text("Not yet") } },
            )
        }
    }
}

/**
 * Tap-to-toggle month grid — the stand-in for iOS's MultiDatePicker. Days before today can't be picked;
 * the header follows the Sunday/Monday week-start setting.
 */
@Composable
private fun DayPicker(today: String, weekStart: Int, picked: Set<String>, onToggle: (String) -> Unit) {
    val c = Theme.colors
    val todayDate = remember(today) { isoDate(today) ?: LocalDate.now() }
    val firstMonth = remember(todayDate) { YearMonth.from(todayDate) }
    val lastMonth = remember(firstMonth) { firstMonth.plusMonths(18) }     // as far ahead as requests are read
    var month by remember { mutableStateOf(firstMonth) }

    val first = month.atDay(1)
    val lead = ((first.dayOfWeek.value % 7) - weekStart + 7) % 7           // blank cells before the 1st
    val dow = listOf("S", "M", "T", "W", "T", "F", "S").let { it.drop(weekStart) + it.take(weekStart) }
    val cells = List(lead) { 0 } + (1..month.lengthOfMonth()).toList()

    Column(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp)
            .clip(RoundedCornerShape(14.dp)).background(c.panel).padding(10.dp),
    ) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { month = month.minusMonths(1) }, enabled = month > firstMonth) { Text("‹") }
            Text(
                monthLabelFull(first.toString()),
                fontWeight = FontWeight.SemiBold, color = c.ink, textAlign = TextAlign.Center,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = { month = month.plusMonths(1) }, enabled = month < lastMonth) { Text("›") }
        }
        Row(Modifier.fillMaxWidth()) {
            dow.forEach { d ->
                Text(
                    d, fontSize = 11.sp, color = c.muted, textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f),
                )
            }
        }
        cells.chunked(7).forEach { week ->
            Row(Modifier.fillMaxWidth()) {
                week.forEach { day ->
                    if (day == 0) {
                        Box(Modifier.weight(1f))
                    } else {
                        val iso = month.atDay(day).toString()
                        val enabled = iso >= today
                        val on = iso in picked
                        Box(
                            Modifier.weight(1f).aspectRatio(1f).padding(3.dp)
                                .clip(CircleShape)
                                .background(if (on) c.accent else Color.Transparent)
                                .then(
                                    if (iso == today && !on) Modifier.border(1.dp, c.accent, CircleShape) else Modifier,
                                )
                                .clickable(enabled = enabled) { onToggle(iso) },
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                "$day",
                                fontSize = 14.sp,
                                fontWeight = if (on) FontWeight.Bold else FontWeight.Normal,
                                color = when {
                                    on -> c.panel
                                    enabled -> c.ink
                                    else -> c.muted.copy(alpha = 0.45f)
                                },
                            )
                        }
                    }
                }
                repeat(7 - week.size) { Box(Modifier.weight(1f)) }
            }
        }
    }
}
