package com.nvdberg.workingbolt.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedTextField
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.SwapOption
import com.nvdberg.workingbolt.model.SwapStatus
import com.nvdberg.workingbolt.model.UnitKey
import com.nvdberg.workingbolt.model.Units
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * Swap or Give Away — pick one of my upcoming shifts, then see every colleague who could genuinely trade
 * for it (both sides' rest rules and SICU competency checked), or hand it over outright.
 *
 * A swap goes out as a plain offer of my shift to that one colleague, tagged with the shift of theirs I want
 * back (the tag pairs the two halves); it is confirmed first. A pickup request is the same offer without a tag.
 */
@Composable
fun SwapScreen(vm: AppViewModel, initialShift: MyShift? = null, startInGiveAway: Boolean = false) {
    val c = Theme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val today = AppViewModel.todayRegina()

    var selShift by remember { mutableStateOf<MyShift?>(null) }
    var myOffset by remember { mutableIntStateOf(0) }
    var swapOffset by remember { mutableIntStateOf(0) }
    var selDay by remember { mutableStateOf<String?>(null) }
    var tradePart by remember { mutableStateOf(TradePart.Both) }      // for a Pasqua day: give both (24h) or one half
    var options by remember { mutableStateOf<List<SwapOption>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var requestOpt by remember { mutableStateOf<SwapOption?>(null) }
    var pickupOpt by remember { mutableStateOf<SwapOption?>(null) }
    var giveAwayOpen by remember { mutableStateOf(false) }
    var didAutoGiveAway by remember { mutableStateOf(false) }
    var filterEmps by remember { mutableStateOf(setOf<Int>()) }        // empty = everyone who can work it
    var filterUnits by remember { mutableStateOf(setOf<UnitKey>()) }   // empty = all shift types
    var showFilter by remember { mutableStateOf(false) }
    var recomputeJob by remember { mutableStateOf<Job?>(null) }
    val loadGen = remember { intArrayOf(0) }                           // bumps per pass — only the newest may publish

    // For the visual layer (the full roster), vs. what's actually tradeable (live, carrying a slot_id).
    val myAll = if (vm.shiftLog.isEmpty()) vm.myShifts else vm.shiftLog
    // A shift that has already started can't be offered or swapped.
    val myTradeable = remember(vm.myShifts, today) {
        vm.myShifts.filter { it.slotID != null && AppViewModel.notStarted(it.date, it.start) }
            .groupBy { it.date }
            .mapValues { (_, arr) -> mergeMinePasqua(arr) }
    }
    // The Pasqua Rapid+MSU halves I work on a day (both with slotIDs) — enables giving one half away.
    fun pasquaHalves(date: String): Pair<MyShift, MyShift>? {
        val day = vm.myShifts.filter { it.date == date && it.slotID != null }
        val r = day.firstOrNull { it.unit == UnitKey.PRR } ?: return null
        val m = day.firstOrNull { it.unit == UnitKey.MSU } ?: return null
        return r to m
    }

    suspend fun ensureLoaded() {
        val gen = ++loadGen[0]
        loading = true
        if (selShift == null && initialShift != null) {
            selShift = myTradeable[initialShift.date] ?: initialShift
        }
        vm.loadDirectory()
        if (vm.whoData.isEmpty()) vm.loadGroupHistory(force = true)
        // Stale-session guard: the ~1h token can expire leaving the group data OLD rather than empty — e.g. it
        // doesn't cover my selected shift's date, so no candidates match and the screen looks broken. Detect
        // that (nobody at all, not even me, recorded on my own shift's day ⇒ the data is stale) and force a
        // re-capture + reload. loadGroupHistory itself also refresh()+retries on an empty fetch.
        val stale = selShift?.let { vm.whoByDay[it.date].isNullOrEmpty() } ?: false
        if (!vm.demo && vm.loggedIn && (vm.whoData.isEmpty() || vm.roster.isEmpty() || stale)) {
            vm.refresh()
            vm.loadDirectory()
            vm.loadGroupHistory(force = true)
        }
        if (gen != loadGen[0]) return                    // a newer recompute superseded this one
        selShift?.let { options = vm.swapOptions(it) }
        loading = false
    }
    fun recompute() {
        recomputeJob?.cancel()                           // don't let an older, slower pass overwrite a newer result
        loading = true
        recomputeJob = scope.launch { ensureLoaded() }
    }

    LaunchedEffect(Unit) {
        ensureLoaded()
        if (startInGiveAway && !didAutoGiveAway && selShift != null) {
            didAutoGiveAway = true
            giveAwayOpen = true
        }
    }

    // Options after the results filter (default: everyone / all units). Drives the calendar squares AND the list.
    val filteredOptions = remember(options, filterEmps, filterUnits) {
        options.filter {
            (filterEmps.isEmpty() || it.emp in filterEmps) &&
                (filterUnits.isEmpty() || it.returnShift.unit in filterUnits)
        }
    }
    val filterActive = filterEmps.isNotEmpty() || filterUnits.isNotEmpty()
    // Distinct colleagues / units present in the RAW results — what the filter sheet offers, so you can't
    // filter down to something that has no swaps.
    val optionEmps = remember(options) {
        options.sortedBy { it.name }.distinctBy { it.emp }.map { it.emp to it.name }
    }
    val optionUnits = remember(options) {
        options.map { it.returnShift.unit }.distinct().sortedBy { it.name }
    }

    val unitsByDay = remember(filteredOptions) {
        filteredOptions.groupBy { it.returnShift.date }
            .mapValues { (_, v) -> v.map { it.returnShift.unit }.distinct().sortedBy { it.name } }
    }
    val dayOptions = selDay?.let { d -> filteredOptions.filter { it.returnShift.date == d } }.orEmpty()

    Column(
        Modifier.fillMaxSize().background(c.bg).verticalScroll(rememberScrollState()).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // 1 · my shifts
        Pane("1 · Your shifts — tap one to trade") {
            SwapCalendar(
                offset = myOffset, onOffset = { myOffset = it }, months = 13,
                myShifts = myAll, availByDay = emptyMap(),
                selectedISO = selShift?.date,
                tappable = { myTradeable[it] != null },
                onTap = { iso ->
                    myTradeable[iso]?.let { s ->
                        selShift = s; tradePart = TradePart.Both; selDay = null; swapOffset = 0
                        filterEmps = emptySet(); filterUnits = emptySet()   // a new shift → fresh results
                        recompute()
                    }
                },
            )
        }

        // 2 · available swaps
        Pane("2 · Available swaps") {
            val s = selShift
            if (s == null) {
                Text(
                    "Pick one of your shifts above, then page the months for who you could swap with.",
                    fontSize = 14.sp, color = c.muted, modifier = Modifier.padding(vertical = 8.dp),
                )
            } else {
                // Trading-away bar
                val halves = pasquaHalves(s.date)   // the 24h / Rapid / MSU choice shows only on a Pasqua day
                Column(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(c.accent.copy(alpha = 0.10f))
                        .padding(9.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Box(
                            Modifier.size(width = 4.dp, height = 30.dp)
                                .clip(RoundedCornerShape(3.dp))
                                .background(Units.color(s.unit))
                        )
                        Column(Modifier.weight(1f)) {
                            Text("Trading away", fontSize = 11.sp, color = c.muted)
                            Text(
                                "${tradeLabel(s)} · ${swapPretty(s.date)}",
                                fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.ink,
                            )
                        }
                        if (loading) CircularProgressIndicator(Modifier.size(18.dp), color = c.accent, strokeWidth = 2.dp)
                    }
                    if (halves != null) {
                        SegmentRow(
                            options = TradePart.entries.map { it.label },
                            selectedIndex = TradePart.entries.indexOf(tradePart),
                            onSelect = { i ->
                                val part = TradePart.entries[i]
                                if (part != tradePart) {
                                    tradePart = part
                                    selShift = when (part) {
                                        TradePart.Both -> mergeMinePasqua(listOf(halves.first, halves.second))
                                        TradePart.Rapid -> halves.first
                                        TradePart.Msu -> halves.second
                                    }
                                    selDay = null; swapOffset = 0
                                    filterEmps = emptySet(); filterUnits = emptySet()
                                    recompute()
                                }
                            },
                        )
                    }
                }

                // Give away instead, with the results filter beside it.
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        "Give away instead  ›",
                        fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.accent,
                        modifier = Modifier.weight(1f)
                            .clip(RoundedCornerShape(10.dp))
                            .background(c.accent.copy(alpha = 0.10f))
                            .clickable { giveAwayOpen = true }
                            .padding(horizontal = 12.dp, vertical = 11.dp),
                    )
                    Text(
                        if (filterActive) "Filtered" else "Filter",
                        fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                        color = if (filterActive) Color.White else c.accent,
                        modifier = Modifier
                            .clip(RoundedCornerShape(10.dp))
                            .background(if (filterActive) c.accent else c.accent.copy(alpha = 0.12f))
                            .clickable { showFilter = true }
                            .padding(horizontal = 12.dp, vertical = 11.dp),
                    )
                }
                // Count + Clear, only while a filter is actually narrowing things.
                if (filterActive) {
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.End,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("${filteredOptions.size} of ${options.size}", fontSize = 12.sp, color = c.muted)
                        TextButton(onClick = { filterEmps = emptySet(); filterUnits = emptySet() }) {
                            Text("Clear", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = c.accent)
                        }
                    }
                }

                SwapCalendar(
                    offset = swapOffset, onOffset = { swapOffset = it }, months = 13,
                    myShifts = myAll, availByDay = unitsByDay,
                    selectedISO = selDay,
                    tappable = { unitsByDay[it]?.isNotEmpty() == true },
                    onTap = { selDay = it },
                )
                Text(
                    "Coloured blocks = your shifts · small squares = units you could swap into (tap a day to see who)",
                    fontSize = 10.sp, color = c.muted,
                )

                // Detail for the tapped day
                when {
                    selDay != null && dayOptions.isNotEmpty() -> {
                        val sameDay = selDay == s.date
                        val cells = dayOptions.mapNotNull { it.cell?.takeIf { c2 -> c2.isNotEmpty() } }
                        Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                if (sameDay) "Same day · swap units — ${dayOptions.size}"
                                else "${swapPretty(selDay!!)} — ${dayOptions.size} you could take",
                                fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.ink,
                                modifier = Modifier.weight(1f),
                            )
                            if (cells.size > 1) {
                                TextButton(onClick = { openGroupText(context, feelerMessage(s), cells) }) {
                                    Text("Text all", fontSize = 12.sp, color = c.accent)
                                }
                            }
                        }
                        dayOptions.forEach { o ->
                            OptionRow(
                                o = o,
                                showPickup = o.returnShift.date != s.date,
                                onText = { o.cell?.let { openSwapText(context, swapMessage(s.unit, s.date, o), it) } },
                                onAskSwap = { requestOpt = o },
                                onAskPickup = { pickupOpt = o },
                            )
                        }
                    }
                    options.isNotEmpty() -> Text(
                        "Tap a day with a teal number to see who's working it.",
                        fontSize = 13.sp, color = c.muted, modifier = Modifier.padding(top = 4.dp),
                    )
                    loading -> Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.padding(top = 4.dp),
                    ) {
                        CircularProgressIndicator(Modifier.size(16.dp), color = c.accent, strokeWidth = 2.dp)
                        Text("Loading roster…", fontSize = 13.sp, color = c.muted)
                    }
                    else -> Column(Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(
                            "No one can swap this shift right now. If the whole app looks empty, your Lightning " +
                                "Bolt session may have expired — sign out and back in, then retry.",
                            fontSize = 13.sp, color = c.muted,
                        )
                        TextButton(onClick = { recompute() }) { Text("Reload", color = c.accent) }
                    }
                }
            }
            Text(
                "Robin's idea 🤝",
                fontSize = 10.sp, color = c.muted.copy(alpha = 0.7f),
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
    }

    // In-app swap (tag-paired offer, confirmed first) / pickup request (a plain pending offer with a note).
    requestOpt?.let { o ->
        selShift?.let { s -> SwapRequestSheet(vm, s, o, pickup = false) { requestOpt = null } }
    }
    pickupOpt?.let { o ->
        selShift?.let { s -> SwapRequestSheet(vm, s, o, pickup = true) { pickupOpt = null } }
    }

    if (showFilter) {
        SwapFilterSheet(
            units = optionUnits,
            colleagues = optionEmps,
            selectedUnits = filterUnits,
            selectedEmps = filterEmps,
            onToggleUnit = { u -> filterUnits = if (u in filterUnits) filterUnits - u else filterUnits + u },
            onToggleEmp = { e -> filterEmps = if (e in filterEmps) filterEmps - e else filterEmps + e },
            onClear = { filterEmps = emptySet(); filterUnits = emptySet() },
            onDismiss = { showFilter = false },
        )
    }

    if (giveAwayOpen) {
        selShift?.let { s ->
            val halves = pasquaHalves(s.date)
            GiveAwayWizard(
                vm = vm,
                shift = halves?.first ?: s,
                pasqua = halves,
                onClose = { giveAwayOpen = false },   // the view model re-reads the roster after a write
            )
        }
    }
}

/**
 * Narrow the results to particular shift types and/or particular colleagues. Only what's actually in the
 * results is offered, so you can't filter down to something that has no swaps. Empty = all.
 */
@Composable
private fun SwapFilterSheet(
    units: List<UnitKey>,
    colleagues: List<Pair<Int, String>>,
    selectedUnits: Set<UnitKey>,
    selectedEmps: Set<Int>,
    onToggleUnit: (UnitKey) -> Unit,
    onToggleEmp: (Int) -> Unit,
    onClear: () -> Unit,
    onDismiss: () -> Unit,
) {
    val c = Theme.colors
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Filter swaps") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text("SHIFT TYPES", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = c.muted)
                units.forEach { u ->
                    val on = u in selectedUnits
                    Row(
                        Modifier.fillMaxWidth().clickable { onToggleUnit(u) }.padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            Units.short(u),
                            fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Units.color(u),
                            modifier = Modifier.clip(RoundedCornerShape(50))
                                .background(Units.color(u).copy(alpha = 0.16f))
                                .padding(horizontal = 6.dp, vertical = 3.dp),
                        )
                        Box(Modifier.weight(1f))
                        if (on) Text("✓", color = c.accent, fontWeight = FontWeight.Bold)
                    }
                }
                Box(Modifier.height(10.dp))
                Text("COLLEAGUES", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = c.muted)
                colleagues.forEach { (emp, name) ->
                    Row(
                        Modifier.fillMaxWidth().clickable { onToggleEmp(emp) }.padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(name, color = c.ink, modifier = Modifier.weight(1f))
                        if (emp in selectedEmps) Text("✓", color = c.accent, fontWeight = FontWeight.Bold)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        dismissButton = { TextButton(onClick = onClear) { Text("Clear", color = c.muted) } },
    )
}

private enum class TradePart(val label: String) { Both("24h"), Rapid("Rapid"), Msu("MSU") }

/** My Pasqua Rapid+MSU on one day = one 24h "Pasqua" trade; both slots move together. */
private fun mergeMinePasqua(arr: List<MyShift>): MyShift {
    val p = arr.firstOrNull { it.unit == UnitKey.PRR }
    val m = arr.firstOrNull { it.unit == UnitKey.MSU }
    if (p != null && m != null) {
        return MyShift(
            date = p.date, unit = UnitKey.PRR, start = p.start, end = m.end, overnight = true,
            slotID = m.slotID, slotID2 = p.slotID, templateID = m.templateID ?: p.templateID,
        )
    }
    return arr.firstOrNull { it.overnight } ?: arr.first()
}

/** "Pasqua 24h" for the combined shift; the unit's short name otherwise. */
private fun tradeLabel(s: MyShift): String =
    if (s.unit == UnitKey.PRR && s.overnight) "Pasqua 24h" else Units.short(s.unit)

/** Generic group feeler (candidates each have a different return shift, so no specific reciprocal here). */
private fun feelerMessage(s: MyShift): String =
    "Hi — I'm looking to move my ${tradeLabel(s)} on ${swapPretty(s.date)}. Any of you keen to swap or take it? Let me know, thanks!"

@Composable
private fun Pane(title: String, content: @Composable ColumnScope.() -> Unit) {
    val c = Theme.colors
    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(c.panel)
            .border(1.dp, c.line, RoundedCornerShape(16.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        content = {
            Text(title, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = c.accent)
            content()
        },
    )
}

@Composable
private fun OptionRow(
    o: SwapOption,
    showPickup: Boolean,
    onText: () -> Unit,
    onAskSwap: () -> Unit,
    onAskPickup: () -> Unit,
) {
    val c = Theme.colors
    val color = Units.color(o.returnShift.unit)
    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(c.bg)
            .border(1.dp, c.line, RoundedCornerShape(12.dp))
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                Units.short(o.returnShift.unit),
                fontSize = 11.sp, fontWeight = FontWeight.Bold, color = color,
                modifier = Modifier.clip(RoundedCornerShape(50))
                    .background(color.copy(alpha = 0.16f))
                    .padding(horizontal = 6.dp, vertical = 3.dp),
            )
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(o.name, fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.ink)
                    StatusChip(o.statusOnMyDate)
                }
                Text(
                    "${o.returnShift.start}–${o.returnShift.end}${if (o.returnShift.overnight) " (+1)" else ""}",
                    fontSize = 11.sp, color = c.muted,
                )
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!o.cell.isNullOrEmpty()) {
                TextButton(onClick = onText) { Text("Text", fontSize = 12.sp, color = c.accent) }
            }
            Button(
                onClick = onAskSwap,
                colors = ButtonDefaults.buttonColors(containerColor = c.accent),
            ) { Text("Ask to swap", fontSize = 12.sp) }
            // One-way hand-off: only for a DIFFERENT day (a same-day colleague is already working, so they
            // can't also pick up my same-day shift — only swap units).
            if (showPickup) {
                TextButton(onClick = onAskPickup) { Text("Ask to pickup", fontSize = 12.sp, color = c.accent) }
            }
        }
    }
}

@Composable
private fun StatusChip(status: SwapStatus) {
    val (text, color) = when (status) {
        is SwapStatus.Free -> "free" to Color(0xFF2E9E5B)
        is SwapStatus.Off -> "⚠️ ${status.label}" to Color(0xFFE08A17)
    }
    Text(
        text, fontSize = 10.sp, fontWeight = FontWeight.Bold, color = color,
        modifier = Modifier.clip(RoundedCornerShape(50))
            .background(color.copy(alpha = 0.18f))
            .padding(horizontal = 7.dp, vertical = 2.dp),
    )
}

/**
 * In-app swap / pickup request. Both send my shift to the colleague as a pending Lightning Bolt offer carrying
 * the note. A swap is confirmed first (exactly what moves) and is tagged with the shift of theirs I want back,
 * so when they accept in Working-Bolt their shift comes straight back to me to take from the Pool.
 */
@Composable
private fun SwapRequestSheet(
    vm: AppViewModel,
    shift: MyShift,
    option: SwapOption,
    pickup: Boolean,
    onClose: () -> Unit,
) {
    val c = Theme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var note by remember {
        mutableStateOf(
            if (pickup) "Could you pick up my ${Units.short(shift.unit)} on ${swapPretty(shift.date)}? Thanks!"
            else "Swap? I'll take your ${Units.short(option.returnShift.unit)} on " +
                "${swapPretty(option.returnShift.date)} if you take my ${Units.short(shift.unit)} on ${swapPretty(shift.date)}."
        )
    }
    var sending by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }
    var ok by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf(false) }     // swap: confirm exactly what moves before sending

    // A failure, a partial result (only the Pasqua Rapid half went out) or the sample-data notice all come back
    // as the outcome's message — shown here, and the sheet stays open.
    fun sendSwap() {
        sending = true; result = null
        scope.launch {
            val out = vm.requestSwap(shift, option.returnShift, option.emp, note)
            sending = false; ok = out.ok
            result = if (out.ok) "✅ Swap sent to ${option.name}. When they accept, theirs comes back to you — take it from the Pool."
            else (out.message ?: "Couldn't send the swap — pull to refresh and try again.")
        }
    }
    fun send() {
        sending = true; result = null
        scope.launch {
            val out = vm.giveAway(shift, option.emp, note)
            sending = false; ok = out.ok
            result = if (out.ok) "✅ Sent to ${option.name}. They'll see your shift offered with the note."
            else (out.message ?: "Couldn't send — pull to refresh and try again.")
        }
    }

    AlertDialog(
        onDismissRequest = onClose,
        title = { Text(if (pickup) "Ask ${option.name} to pick up" else "Ask ${option.name} to swap") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    if (pickup)
                        "They'd take your ${Units.short(shift.unit)} on ${swapPretty(shift.date)}. You don't take one of theirs."
                    else
                        "You'd take their ${Units.short(option.returnShift.unit)} on ${swapPretty(option.returnShift.date)}; " +
                            "they'd take your ${Units.short(shift.unit)} on ${swapPretty(shift.date)}.",
                    fontSize = 12.sp, color = c.muted,
                )
                OutlinedTextField(
                    value = note, onValueChange = { note = it },
                    label = { Text("Note") }, minLines = 2, modifier = Modifier.fillMaxWidth(),
                )
                if (!option.cell.isNullOrEmpty()) {
                    TextButton(onClick = {
                        openSwapText(
                            context,
                            if (pickup) pickupMessage(shift, option) else swapMessage(shift.unit, shift.date, option),
                            option.cell,
                        )
                    }) { Text("Text ${option.firstName} instead", color = c.accent) }
                }
                result?.let {
                    Text(it, fontSize = 13.sp, color = if (ok) Color(0xFF2E9E5B) else Color(0xFFD64545))
                }
                if (!pickup) {
                    Text(
                        "They get your shift offered with this note. If they accept in Working-Bolt, their shift " +
                            "comes straight back to you — one tap in the Pool takes it.",
                        fontSize = 11.sp, color = c.muted,
                    )
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !sending && !ok && note.isNotBlank(),
                onClick = { if (pickup) send() else confirming = true },
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (sending) CircularProgressIndicator(Modifier.size(14.dp), color = c.accent, strokeWidth = 2.dp)
                    Text(if (ok) "Sent" else if (pickup) "Send pickup request" else "Send swap request")
                }
            }
        },
        dismissButton = { TextButton(onClick = onClose) { Text(if (ok) "Done" else "Cancel") } },
    )

    if (confirming) {
        val theirs = "${Units.short(option.returnShift.unit)} on ${swapPretty(option.returnShift.date)}"
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text("Send this swap?") },
            text = {
                Text(
                    "Your ${Units.short(shift.unit)} on ${swapPretty(shift.date)} for ${option.name}'s $theirs. " +
                        "When ${option.firstName} accepts and sends theirs back, their $theirs comes back to you " +
                        "to take in one tap."
                )
            },
            confirmButton = { TextButton(onClick = { confirming = false; sendSwap() }) { Text("Send swap request") } },
            dismissButton = { TextButton(onClick = { confirming = false }) { Text("Not yet") } },
        )
    }
}
