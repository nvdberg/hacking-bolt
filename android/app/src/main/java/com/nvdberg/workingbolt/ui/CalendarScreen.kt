package com.nvdberg.workingbolt.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.data.ShiftExport
import com.nvdberg.workingbolt.model.Assignment
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.UnitKey
import com.nvdberg.workingbolt.model.Units
import kotlin.math.roundToInt
import java.util.Locale

private val MONTH_NAMES = listOf(
    "", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
)

/** Where the Who's On panel was dragged (px, from bottom-centre) — kept while the app runs. */
private var lastPanelOffset = Offset.Zero

/** My Shifts — the web-style month grid (coloured blocks, 24h calls fusing into post-call). */
@Composable
fun CalendarScreen(vm: AppViewModel, tabTick: Int) {
    val c = Theme.colors
    val log = if (vm.shiftLog.isEmpty()) vm.myShifts else vm.shiftLog
    var jumpTick by remember { mutableIntStateOf(0) }
    var targetYM by remember { mutableStateOf("") }
    var showMonthMenu by remember { mutableStateOf(false) }
    var pastAlert by remember { mutableStateOf(false) }
    var choosing by remember { mutableStateOf(false) }              // "what do you want to do with this shift?"
    var pendingShift by remember { mutableStateOf<MyShift?>(null) }
    var pickerShifts by remember { mutableStateOf<List<MyShift>>(emptyList()) }   // several unrelated shifts that day
    var giveAwayShift by remember { mutableStateOf<MyShift?>(null) }   // chosen in the picker → the give-away wizard
    var busyISO by remember { mutableStateOf<String?>(null) }          // long-pressed day → busy-note prompt
    var busyText by remember { mutableStateOf("") }
    var whoISO by remember { mutableStateOf<String?>(null) }           // double-tapped day → floating Who's On panel
    var panelOffset by remember { mutableStateOf(lastPanelOffset) }
    val context = LocalContext.current
    var swapSheet by remember { mutableStateOf(false) }             // the shared Swap/Give-away screen
    var swapStartsInGiveAway by remember { mutableStateOf(false) }
    val landscape = LocalConfiguration.current.let { it.screenWidthDp > it.screenHeightDp }

    LaunchedEffect(Unit) { vm.loadHistory() }   // backfill the full log (2022 →) so the calendar shows history too

    // Months present in the log, grouped by year (both descending) — powers the "jump back" picker.
    val yearMonths = remember(log) {
        log.mapNotNull { d ->
            val y = d.date.take(4).toIntOrNull()
            val m = d.date.substring(5, 7).toIntOrNull()
            if (y != null && m != null) y to m else null
        }.groupBy({ it.first }, { it.second })
            .mapValues { it.value.distinct().sortedDescending() }
            .toList().sortedByDescending { it.first }
    }

    // Upcoming shifts I could give away — from the LIVE harvest (myShifts), which carries the real slot_id
    // (the durable shiftLog's cached entries may predate slot_id tracking). A started shift can't be offered,
    // so this is checked at tap time rather than remembered.
    fun giveable(): List<MyShift> =
        vm.myShifts.filter { it.slotID != null && AppViewModel.notStarted(it.date, it.start) }.sortedBy { it.date }

    /** Tapping one of my shift days: offer a choice — find a swap, or give it away. (Several unrelated that day → picker.) */
    fun tapMyShift(iso: String) {
        if (vm.demo) return
        val day = giveable().filter { it.date == iso }
        // A Pasqua Rapid+MSU pair I work that day (both givable) → treated as one 24h shift.
        val rapid = day.firstOrNull { it.unit == UnitKey.PRR }
        val pasqua = rapid != null && day.any { it.unit == UnitKey.MSU }
        when {
            pasqua -> { pendingShift = rapid; choosing = true }
            day.size == 1 -> { pendingShift = day.first(); choosing = true }
            day.size > 1 -> pickerShifts = day
            else -> pastAlert = true   // that day's shift is past or has no slot_id
        }
    }

    BackHandler(enabled = whoISO != null) { whoISO = null }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Box {
                TextButton(onClick = { showMonthMenu = true }, enabled = log.isNotEmpty()) {
                    Text("Jump to month", fontSize = 13.sp, color = c.muted)
                }
                DropdownMenu(expanded = showMonthMenu, onDismissRequest = { showMonthMenu = false }) {
                    yearMonths.forEach { (year, monthsOfYear) ->
                        monthsOfYear.forEach { m ->
                            DropdownMenuItem(
                                text = { Text("${MONTH_NAMES[m]} $year") },
                                onClick = {
                                    targetYM = String.format(Locale.ROOT, "%04d-%02d", year, m)
                                    showMonthMenu = false
                                },
                            )
                        }
                    }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                // Export to Calendar (.ics) → the share sheet ("Add to Calendar").
                IconButton(onClick = { ShiftExport.shareCalendar(context, log) }, enabled = log.isNotEmpty()) {
                    Icon(Icons.Filled.Share, contentDescription = "Export to Calendar", tint = c.muted)
                }
                TextButton(onClick = { jumpTick++ }) { Text("This Month", fontSize = 13.sp, color = c.muted) }
            }
        }

        BoxWithConstraints(Modifier.fillMaxSize()) {
            RosterCalendar(
                shifts = log,
                userName = vm.userName,
                landscape = landscape,
                scrollTick = jumpTick + tabTick,
                jumpToYM = targetYM,
                openDates = vm.openForAllDates,
                onOpenTap = { iso -> vm.poolJumpDate = iso; vm.selectedTab = 0 },
                onShiftTap = { iso -> tapMyShift(iso) },
                postedDates = vm.postedPendingDates,
                busyDays = vm.busyDays,
                onBusyEdit = { iso -> busyText = vm.busyDays[iso] ?: ""; busyISO = iso },
                onBusyClear = { iso -> vm.setBusy(iso, null) },
                markedISO = whoISO,
                pickMode = whoISO != null,
                onDayPick = { iso -> whoISO = iso },
            )
            if (vm.loading && vm.myShifts.isEmpty()) {
                Column(
                    Modifier.fillMaxSize(),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    CircularProgressIndicator(color = c.accent)
                    Box(Modifier.height(10.dp))
                    Text("Reading your roster…", color = c.muted)
                }
            }
            whoISO?.let { iso ->
                WhoDayPanel(
                    vm = vm, iso = iso, boundsW = maxWidth, boundsH = maxHeight,
                    offset = panelOffset,
                    onOffset = { panelOffset = it; lastPanelOffset = it },
                    onClose = { whoISO = null },
                    modifier = Modifier.align(Alignment.BottomCenter),
                )
            }
        }
    }

    if (pastAlert) {
        AlertDialog(
            onDismissRequest = { pastAlert = false },
            title = { Text("Can't give this one away") },
            text = {
                Text(
                    if (vm.myShifts.isEmpty()) "Your live roster is still loading — try again in a moment."
                    else "You can only give away upcoming shifts."
                )
            },
            confirmButton = { TextButton(onClick = { pastAlert = false }) { Text("OK") } },
        )
    }

    if (choosing) {
        AlertDialog(
            onDismissRequest = { choosing = false },
            title = { Text("What do you want to do with this shift?") },
            text = { Text(pendingShift?.let { "${Units.short(it.unit)} · ${fmt(it.date, "EEE, MMM d")}" } ?: "") },
            confirmButton = {
                TextButton(onClick = { choosing = false; swapStartsInGiveAway = false; swapSheet = true }) {
                    Text("Find a swap")
                }
            },
            dismissButton = {
                TextButton(onClick = { choosing = false; swapStartsInGiveAway = true; swapSheet = true }) {
                    Text("Give it away")
                }
            },
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
                    SwapScreen(vm, initialShift = pendingShift, startInGiveAway = swapStartsInGiveAway)
                }
            }
        }
    }

    // Several unrelated shifts on the tapped day → pick which one to give away.
    if (pickerShifts.isNotEmpty()) {
        AlertDialog(
            onDismissRequest = { pickerShifts = emptyList() },
            title = { Text("Give away which shift?") },
            text = {
                Column {
                    pickerShifts.forEach { s ->
                        TextButton(onClick = { pickerShifts = emptyList(); giveAwayShift = s }) {
                            Text(
                                "${Units.short(s.unit)} · ${fmt(s.date, "EEE, MMM d")} · ${s.start}–${s.end}",
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { pickerShifts = emptyList() }) { Text("Cancel") } },
        )
    }
    giveAwayShift?.let { s -> GiveAwayWizard(vm = vm, shift = s, onClose = { giveAwayShift = null }) }

    // Long-press a day → a short busy note. Stored on this phone only (vm.setBusy caps it at 24 characters).
    busyISO?.let { iso ->
        AlertDialog(
            onDismissRequest = { busyISO = null },
            title = { Text("Busy on ${fmt(iso, "EEE, MMM d")}") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text("Shifts in the Pool on this day will remind you before you take one. Only on this phone.")
                    OutlinedTextField(
                        value = busyText,
                        onValueChange = { busyText = it.take(24) },
                        placeholder = { Text("e.g. STARS") },
                        singleLine = true,
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { vm.setBusy(iso, busyText.trim().take(24)); busyISO = null }) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = { busyISO = null }) { Text("Cancel") } },
        )
    }
}

// ── Floating day panel (My Shifts → double-tap a date) ───────────────────────

/**
 * A small draggable card over My Shifts showing who's working one day — sized to its content so the
 * calendar stays visible underneath. Drag the header to move it; tapping another date (while open)
 * retargets it. Mirrors `WhoDayPanel` in WhoView.swift.
 *
 * @param offset committed position, in px, from the bottom-centre of the calendar area
 */
@Composable
private fun WhoDayPanel(
    vm: AppViewModel,
    iso: String,
    boundsW: Dp,
    boundsH: Dp,
    offset: Offset,
    onOffset: (Offset) -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val c = Theme.colors
    val context = LocalContext.current
    val prefs = Prefs.get(context)
    val unitOrder = prefs.unitOrder
    val doctors = prefs.panelDoctors                          // stethoscope on the panel (remembered, separate from Who's On)
    val isToday = iso == AppViewModel.todayRegina()
    val landscape = boundsW > boundsH
    var tonightH by remember { mutableStateOf(0.dp) }          // the Tonight line under the rows, measured
    // Doctors on → full width (capped sideways), and the whole card stays within about a third of the screen
    // so the calendar still scrolls under it; past that the rows scroll inside the card.
    val width = if (doctors) minOf(boundsW - 16.dp, 560.dp) else minOf(if (landscape) 340.dp else 300.dp, boundsW - 24.dp)
    val maxRowsH = if (doctors) maxOf(90.dp, boundsH * (if (landscape) 0.6f else 0.5f) - 52.dp - tonightH)
                   else maxOf(120.dp, boundsH * 0.55f - 64.dp)   // ~55% of the screen incl. header
    var size by remember { mutableStateOf(IntSize.Zero) }
    if (doctors) LaunchedEffect(iso, vm.demo) { DoctorRoster.ensure(context, iso, vm.demo) }

    fun order(u: UnitKey) = unitOrder.indexOf(u).takeIf { it >= 0 } ?: 99
    val rows = remember(vm.whoByDay, iso, unitOrder) {
        vm.whoByDay[iso].orEmpty().sortedWith(compareBy({ order(it.unit) }, { it.start }))
    }

    val loadingWho = vm.whoByDay.isEmpty()
    LaunchedEffect(loadingWho) { if (loadingWho) vm.loadGroupHistory() }

    val density = LocalDensity.current
    val boundsWPx = with(density) { boundsW.toPx() }
    val boundsHPx = with(density) { boundsH.toPx() }
    val marginPx = with(density) { 8.dp.toPx() }
    val bottomPx = with(density) { 12.dp.toPx() }
    // Keep the card inside the calendar area: x within the side margins, y between the bottom and the top.
    fun clamp(o: Offset): Offset {
        val maxX = maxOf(0f, (boundsWPx - size.width) / 2f - marginPx)
        val maxUp = maxOf(0f, boundsHPx - size.height - 2 * bottomPx)
        return Offset(o.x.coerceIn(-maxX, maxX), o.y.coerceIn(-maxUp, 0f))
    }
    // The drag gesture outlives recompositions — it reads the live position through these.
    val liveOffset by rememberUpdatedState(offset)
    val pos = clamp(offset)

    Column(
        modifier
            .padding(bottom = 12.dp)
            .offset { IntOffset(pos.x.roundToInt(), pos.y.roundToInt()) }
            .width(width)
            .onSizeChanged { size = it }
            .shadow(16.dp, RoundedCornerShape(14.dp))
            .clip(RoundedCornerShape(14.dp))
            .background(c.panel)
            .border(1.dp, c.line, RoundedCornerShape(14.dp))
            .pointerInput(Unit) { detectDragGestures { _, _ -> } }   // a drag on the card never scrolls the calendar under it
            .padding(start = 12.dp, end = 12.dp, top = 6.dp, bottom = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Grab bar + date + close. The whole header is the drag handle.
        Column(
            Modifier.fillMaxWidth().pointerInput(boundsWPx, boundsHPx) {
                detectDragGestures { change, drag ->
                    change.consume()
                    onOffset(clamp(liveOffset + drag))
                }
            },
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Box(Modifier.width(34.dp).height(4.dp).clip(CircleShape).background(c.muted.copy(alpha = 0.35f)))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    weekday(iso), fontSize = 15.sp, fontWeight = FontWeight.ExtraBold,
                    color = if (isToday) c.accent else c.ink,
                )
                Text(fmt(iso, "d MMM"), fontSize = 15.sp, color = c.muted)
                if (isToday) {
                    Text(
                        "TODAY", fontSize = fixedSp(9f), fontWeight = FontWeight.ExtraBold, color = Color.White,
                        modifier = Modifier.clip(CircleShape).background(c.accent)
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
                Box(Modifier.weight(1f))
                Box(
                    Modifier.size(28.dp).clip(CircleShape)
                        .background(if (doctors) c.accent.copy(alpha = 0.18f) else Color.Transparent)
                        .clickable { prefs.updatePanelDoctors(!doctors) }
                        .semantics { contentDescription = if (doctors) "Hide doctors" else "Show doctors" },
                    contentAlignment = Alignment.Center,
                ) { Text("🩺", fontSize = fixedSp(15f), modifier = Modifier.alpha(if (doctors) 1f else 0.55f)) }
                IconButton(onClick = onClose, modifier = Modifier.size(28.dp)) {
                    Icon(Icons.Filled.Close, contentDescription = "Close", tint = c.muted)
                }
            }
        }

        when {
            loadingWho -> Row(
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                CircularProgressIndicator(Modifier.size(14.dp), color = c.accent, strokeWidth = 2.dp)
                Text("Loading who's on…", fontSize = 12.sp, color = c.muted)
            }
            rows.isEmpty() -> Text("No one scheduled", fontSize = 12.sp, color = c.muted)
            else -> {
                // Doctor beside each unit's first row; when the roster has nobody for this day, the plain rows (no empty column).
                val docs = if (!doctors) emptyMap() else rows.indices.groupBy { rows[it].unit }
                    .mapNotNull { (u, ix) -> DocTag.of(iso, u)?.let { ix.first() to it } }.toMap()
                // The card hugs its rows; past the cap the same rows scroll inside it.
                Column(
                    Modifier.heightIn(max = maxRowsH).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(if (doctors) 4.dp else 5.dp),
                ) {
                    rows.forEachIndexed { i, a -> DayPanelRow(a, withDoctors = doctors && docs.isNotEmpty(), doc = docs[i]) }
                }
                if (doctors) {
                    TonightLine(iso, Modifier.onSizeChanged { tonightH = with(density) { it.height.toDp() } + 8.dp })
                }
            }
        }
    }
}

/** "08:00" → "08"; anything not on the hour stays as is. */
private fun hr(t: String) = if (t.endsWith(":00")) t.take(2) else t

/**
 * Compact version of the Who's On row: unit, name, hours; my own shift on the solid unit colour. With the doctors on,
 * the hours shorten ("08–08") and the unit's doctor sits in a right-hand column on its first row — same height as without.
 */
@Composable
private fun DayPanelRow(a: Assignment, withDoctors: Boolean, doc: DocTag?) {
    val c = Theme.colors
    val color = Units.color(a.unit)
    val ink = if (a.isMe) Color.White else c.ink
    val sub = if (a.isMe) Color.White.copy(alpha = 0.8f) else c.muted
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(9.dp))
            .background(if (a.isMe) color else color.copy(alpha = 0.12f))
            .padding(horizontal = 9.dp, vertical = if (withDoctors) 4.dp else 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(if (withDoctors) 7.dp else 8.dp),
    ) {
        Text(
            Units.short(a.unit), fontSize = if (withDoctors) 10.sp else 11.sp, fontWeight = FontWeight.Bold, maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            color = if (a.isMe) Color.White.copy(alpha = 0.92f) else color,
            modifier = Modifier.width(if (withDoctors) 74.dp else 78.dp),
        )
        Text(
            a.doc, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
            overflow = TextOverflow.Ellipsis, color = ink, modifier = Modifier.weight(1f),
        )
        Text(
            if (withDoctors) "${hr(a.start)}–${hr(a.end)}" else "${a.start}–${a.end}", fontSize = 11.sp, maxLines = 1,
            color = sub,
        )
        if (withDoctors) {
            Box(
                Modifier.width(1.dp).height(16.dp).background(
                    if (doc == null) Color.Transparent else if (a.isMe) Color.White.copy(alpha = 0.35f) else color.copy(alpha = 0.35f)
                )
            )
            Row(
                Modifier.width(116.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                if (doc != null) {
                    val inCCU = doc.sub == "in CCU"
                    if (inCCU) Icon(Icons.Filled.Favorite, contentDescription = "In CCU", tint = if (a.isMe) Color.White else color, modifier = Modifier.size(10.dp))
                    if (doc.night) Icon(Icons.Filled.Bedtime, contentDescription = "On call tonight", tint = if (a.isMe) Color.White else Indigo, modifier = Modifier.size(10.dp))
                    Text(
                        doc.name, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = ink,
                        maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false),
                    )
                    if (!inCCU) Text(doc.sub, fontSize = 11.sp, color = sub, maxLines = 1)
                }
            }
        }
    }
}

/** Tonight, from 17:00: the one ICU intensivist on call for all the units · cardiology On call · STEMI — one line. */
@Composable
private fun TonightLine(iso: String, modifier: Modifier = Modifier) {
    val c = Theme.colors
    val parts = listOfNotNull(
        DoctorRoster.night(iso)?.let { null to it.name },
        DoctorRoster.name(iso, "CCU", "oncall")?.let { "On call" to it },
        DoctorRoster.name(iso, "CCU", "stemi_oncall")?.let { "STEMI" to it },
    )
    if (parts.isEmpty()) return
    val ccu = Units.info[UnitKey.CCU]?.color ?: Color.Red
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(9.dp)).background(Indigo.copy(alpha = 0.07f))
            .padding(horizontal = 9.dp, vertical = 6.dp)
            .semantics(mergeDescendants = true) { contentDescription = "Tonight: " + parts.joinToString(", ") { (l, n) -> listOfNotNull(l, n).joinToString(" ") } },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(Icons.Filled.Bedtime, contentDescription = null, tint = Indigo, modifier = Modifier.size(12.dp))
        parts.forEachIndexed { i, (label, name) ->
            if (i > 0) Text("·", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = c.muted)
            if (label == "On call") Icon(Icons.Filled.Favorite, contentDescription = null, tint = ccu, modifier = Modifier.size(10.dp))   // cardiology
            if (label != null) Text(label, fontSize = 11.sp, fontWeight = FontWeight.Bold, color = ccu, maxLines = 1)
            Text(name, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = c.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}
