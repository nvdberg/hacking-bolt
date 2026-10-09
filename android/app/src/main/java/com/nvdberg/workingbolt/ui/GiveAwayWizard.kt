package com.nvdberg.workingbolt.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.model.ConflictEngine
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.UnitKey
import com.nvdberg.workingbolt.model.Units
import kotlinx.coroutines.launch
import java.util.Locale

private enum class Phase { Form, Sending, DoneOne, DoneGroup, Failed }
private enum class PasquaPart(val label: String) { Both("24h"), Rapid("Rapid"), Msu("MSU") }

/**
 * Give away one of my shifts — to the whole pool or one colleague — with a note.
 *
 * REAL schedule mutation, behind an explicit confirm; individual offers are reversible via cancel until
 * accepted. Nothing is written until the confirm dialog's action is tapped.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GiveAwayWizard(
    vm: AppViewModel,
    shift: MyShift,
    /** When the tapped day is a Pasqua Rapid+MSU pair, both halves so we can offer 24h / Rapid / MSU. */
    pasqua: Pair<MyShift, MyShift>? = null,
    onClose: () -> Unit,
) {
    val c = Theme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var phase by remember { mutableStateOf(Phase.Form) }
    var everyone by remember { mutableStateOf(false) }
    var selectedEmps by remember { mutableStateOf(setOf<Int>()) }
    var freeText by remember { mutableStateOf("") }
    val note = freeText.trim()
    var pasquaPart by remember { mutableStateOf(PasquaPart.Both) }
    var giveWhole by remember { mutableStateOf(true) }
    var giveStartISO by remember { mutableStateOf("") }
    var giveEndISO by remember { mutableStateOf("") }
    var confirming by remember { mutableStateOf(false) }
    var failMessage by remember { mutableStateOf<String?>(null) }
    // Half a Pasqua 24h went through → don't claim "nothing changed" and don't offer a retry.
    var failPartial by remember { mutableStateOf(false) }
    var showRecipients by remember { mutableStateOf(false) }

    // The shift actually being given away — for a Pasqua day this reflects the 24h / Rapid / MSU choice
    // (24h carries both LB slots via slotID + slotID2, so the give-away moves both halves).
    val activeShift = remember(pasqua, pasquaPart, shift) {
        val p = pasqua ?: return@remember shift
        when (pasquaPart) {
            PasquaPart.Both -> MyShift(
                date = p.first.date, unit = UnitKey.PRR, start = "08:00", end = "08:00", overnight = true,
                slotID = p.first.slotID, slotID2 = p.second.slotID,
                templateID = p.first.templateID ?: p.second.templateID,
            )
            PasquaPart.Rapid -> p.first
            PasquaPart.Msu -> p.second
        }
    }
    val isPasqua24h = pasqua != null && pasquaPart == PasquaPart.Both
    val unitInfo = Units.info[activeShift.unit]
    val whatShort = if (isPasqua24h) "Pasqua 24h" else Units.short(activeShift.unit)
    val niceDate = fmt(activeShift.date, "EEE, MMM d")
    // Eligibility scans the whole group history — computed once per shift / data change (it follows whoByDay,
    // so a group reload while the wizard is open re-filters the list), not on every note keystroke.
    val eligible = remember(activeShift, vm.roster, vm.whoByDay) { vm.eligibleColleagues(activeShift) }

    // Day-aware 30-min timeline across the whole shift (handles 24h + overnight): each step carries a full
    // ISO timestamp (correct day) + a label ("08:00", "00:00 (+1)", …).
    val timeline = remember(activeShift) { buildTimeline(activeShift) }
    LaunchedEffect(timeline) {
        if (giveStartISO.isEmpty() && timeline.size >= 2) {
            giveStartISO = timeline[timeline.size / 2].first
            giveEndISO = timeline.last().first
        }
        if (vm.colleagues.isEmpty()) vm.loadGroupHistory()
        vm.loadDirectory()
    }

    fun labelFor(iso: String) = timeline.firstOrNull { it.first == iso }?.second ?: iso.substring(11, 16)
    fun nameOf(emp: Int) = vm.roster[emp] ?: ""
    fun firstOf(emp: Int) = nameOf(emp).split(" ").firstOrNull() ?: nameOf(emp)
    fun cellFor(emp: Int) = vm.directory[emp]?.cell?.takeIf { it.isNotEmpty() }

    val oneEmp = selectedEmps.singleOrNull()
    val chosen = everyone || selectedEmps.isNotEmpty()
    val isGroup = everyone || selectedEmps.size >= 2
    // A time-split can only go to ONE person or the whole pool — offering a part to several picked people
    // isn't a thing, so selecting 2+ specific colleagues always hands over the whole shift.
    val effectiveWhole = giveWhole || (selectedEmps.size >= 2 && !everyone)
    val partValid = giveStartISO.isNotEmpty() && giveEndISO.isNotEmpty() && giveStartISO < giveEndISO
    val sendable = chosen && (effectiveWhole || partValid)
    val recipientLabel = when {
        everyone -> "Everyone who can work it"
        selectedEmps.isEmpty() -> "Choose…"
        selectedEmps.size == 1 -> nameOf(oneEmp!!)
        else -> "${selectedEmps.size} colleagues"
    }
    val sendLabel = when {
        everyone -> "Post to the pool"
        selectedEmps.size >= 2 -> "Offer to ${selectedEmps.size} colleagues"
        oneEmp != null -> "Give away to ${nameOf(oneEmp)}"
        else -> "Give away"
    }
    val giveHours =
        if (effectiveWhole) "${activeShift.start}–${activeShift.end}"
        else "${labelFor(giveStartISO)}–${labelFor(giveEndISO)}"

    fun askOne(emp: Int) =
        "Hi ${firstOf(emp)}, are you able to take my $whatShort on $niceDate? I'm offering it to you — let me know. Thanks!"
    fun askGroup() = "Hi — are any of you able to take my $whatShort on $niceDate? Let me know if you can, thanks!"

    fun send() {
        phase = Phase.Sending
        scope.launch {
            val groupEmps = if (everyone) eligible.map { it.first } else selectedEmps.toList()
            val out = when {
                !effectiveWhole && everyone ->                       // time-split → the pool
                    vm.giveAwayPart(activeShift, giveStartISO, giveEndISO, null, true, note)
                !effectiveWhole && oneEmp != null ->                 // time-split → one colleague
                    vm.giveAwayPart(activeShift, giveStartISO, giveEndISO, oneEmp, false, note)
                isGroup -> vm.giveAwayToGroup(activeShift, groupEmps, note)   // whole shift → pool / picked group
                oneEmp != null -> vm.giveAway(activeShift, oneEmp, note)      // whole shift → one colleague
                else -> null
            }
            when {
                out == null -> phase = Phase.Failed
                out.ok -> phase = if (isGroup) Phase.DoneGroup else Phase.DoneOne
                else -> { failMessage = out.message; failPartial = out.partial; phase = Phase.Failed }
            }
        }
    }

    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize(), color = c.bg) {
            Column(Modifier.fillMaxSize()) {
                TopAppBar(
                    title = { Text("Give away shift") },
                    actions = { if (phase == Phase.Form) TextButton(onClick = onClose) { Text("Close") } },
                )
                when (phase) {
                    Phase.Sending -> Column(
                        Modifier.fillMaxSize(),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        CircularProgressIndicator(color = c.accent)
                        Box(Modifier.height(14.dp))
                        Text(
                            if (isGroup) "Offering…" else "Offering to ${oneEmp?.let(::nameOf) ?: ""}…",
                            color = c.muted,
                        )
                    }

                    Phase.DoneOne, Phase.DoneGroup -> DonePane(
                        title = when {
                            phase == Phase.DoneOne -> "Offered to ${oneEmp?.let(::nameOf) ?: ""}"
                            everyone -> "Posted to the pool"
                            else -> "Offered to ${selectedEmps.size} colleagues"
                        },
                        detail = "$whatShort · $niceDate." + if (phase == Phase.DoneGroup)
                            " Whoever's eligible can pick it up."
                        else " Pending until they accept — you can cancel below.",
                        note = note,
                        canText = phase == Phase.DoneOne && oneEmp != null && cellFor(oneEmp) != null,
                        textLabel = "Text ${oneEmp?.let(::firstOf) ?: ""}",
                        onText = { oneEmp?.let { e -> cellFor(e)?.let { openSwapText(context, askOne(e), it) } } },
                        canCancel = phase == Phase.DoneOne,
                        onCancel = {
                            val slot = activeShift.slotID
                            val emp = oneEmp
                            if (slot != null && emp != null) {
                                phase = Phase.Sending
                                scope.launch { vm.cancelGiveAway(slot, emp); onClose() }
                            }
                        },
                        onDone = onClose,
                    )

                    Phase.Failed -> Column(
                        Modifier.fillMaxSize().padding(24.dp),
                        verticalArrangement = Arrangement.Center,
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text("⚠️", fontSize = 40.sp)
                        Text("Couldn't give it away", fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
                        Box(Modifier.height(8.dp))
                        Text(
                            failMessage ?: "Nothing was changed. Check your connection and try again.",
                            fontSize = 14.sp, color = c.muted, textAlign = TextAlign.Center,
                        )
                        if (!failPartial) {
                            Box(Modifier.height(4.dp))
                            Text("Nothing was changed on your schedule.", fontSize = 12.sp, color = c.muted)
                        }
                        Box(Modifier.height(16.dp))
                        // A partial result (only the Rapid half went out) can't be retried from here — close.
                        Button(
                            onClick = { if (failPartial) onClose() else { failMessage = null; phase = Phase.Form } },
                            colors = ButtonDefaults.buttonColors(containerColor = c.accent),
                        ) { Text(if (failPartial) "Done" else "Back") }
                    }

                    Phase.Form -> Column(Modifier.fillMaxSize()) {
                        Column(
                            Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(14.dp),
                        ) {
                            // The shift being given away
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Box(
                                    Modifier.size(width = 6.dp, height = 38.dp)
                                        .clip(RoundedCornerShape(6.dp))
                                        .background(unitInfo?.color ?: Color.Gray)
                                )
                                Column {
                                    Text(
                                        if (isPasqua24h) "Pasqua (Rapid + MSU)" else (unitInfo?.full ?: activeShift.unit.name),
                                        fontSize = 16.sp, fontWeight = FontWeight.Bold, color = c.ink,
                                    )
                                    Text(
                                        "$niceDate · ${activeShift.start}–${activeShift.end}",
                                        fontSize = 14.sp, color = c.muted,
                                    )
                                }
                            }
                            HorizontalDivider(color = c.line)

                            if (pasqua != null) {
                                // Pasqua Rapid+MSU is one 24h shift — hand over both, or one half (separate LB slots).
                                SectionLabel("Which part?")
                                SegmentRow(
                                    options = PasquaPart.entries.map { it.label },
                                    selectedIndex = PasquaPart.entries.indexOf(pasquaPart),
                                    onSelect = { pasquaPart = PasquaPart.entries[it] },
                                )
                                Text(
                                    if (pasquaPart == PasquaPart.Both) "Gives away the whole 24h (Rapid + MSU)."
                                    else "Gives away just the ${if (pasquaPart == PasquaPart.Rapid) "Rapid (08:00–17:00)" else "MSU (17:00–08:00)"} half; you keep the other.",
                                    fontSize = 12.sp, color = c.muted,
                                )
                            } else {
                                SectionLabel("How much?")
                                SegmentRow(
                                    options = listOf("Whole shift", "Just a part"),
                                    selectedIndex = if (giveWhole) 0 else 1,
                                    onSelect = { giveWhole = it == 0 },
                                )
                                if (!giveWhole) {
                                    TimePickRow("Give away from", labelFor(giveStartISO), timeline.dropLast(1)) {
                                        giveStartISO = it
                                        if (giveEndISO <= it) giveEndISO = timeline.last().first
                                    }
                                    TimePickRow("until", labelFor(giveEndISO), timeline.filter { it.first > giveStartISO }) {
                                        giveEndISO = it
                                    }
                                    Text(
                                        "You keep the rest. Heads-up: Lightning Bolt only lets a scheduler merge " +
                                            "pieces back — so split when you mean it.",
                                        fontSize = 12.sp, color = c.muted,
                                    )
                                }
                            }

                            HorizontalDivider(color = c.line)
                            SectionLabel("Give it to")
                            Row(
                                Modifier.fillMaxWidth()
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(c.panel)
                                    .clickable { showRecipients = true }
                                    .padding(14.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    recipientLabel,
                                    color = if (chosen) c.ink else c.muted,
                                    modifier = Modifier.weight(1f),
                                )
                                Text("›", color = c.muted)
                            }

                            SectionLabel("Note (optional)")
                            OutlinedTextField(
                                value = freeText,
                                onValueChange = { freeText = it },
                                placeholder = { Text("Add a note") },
                                modifier = Modifier.fillMaxWidth(),
                                minLines = 2,
                            )
                            if (everyone) {
                                Text(
                                    "Posted to the pool, whoever's eligible can grab it. LB can't attach a note " +
                                        "here — Working-Bolt keeps yours and shows it in the Pool.",
                                    fontSize = 12.sp, color = c.muted,
                                )
                            }
                        }
                        // The one and only path to a write.
                        Button(
                            onClick = { confirming = true },
                            enabled = sendable,
                            modifier = Modifier.fillMaxWidth().padding(16.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = c.accent),
                        ) {
                            Text(
                                if (!chosen) "Choose who gets it" else if (!sendable) "Set the times" else sendLabel,
                                fontWeight = FontWeight.Bold,
                            )
                        }
                    }
                }
            }
        }
    }

    if (confirming) {
        val what = if (effectiveWhole) "your $whatShort shift" else "the $giveHours part of your $whatShort shift"
        val recipientPhrase = when {
            everyone -> "the pool"
            selectedEmps.size >= 2 -> "${selectedEmps.size} colleagues"
            else -> nameOf(oneEmp ?: 0)
        }
        AlertDialog(
            onDismissRequest = { confirming = false },
            title = {
                Text(
                    if (everyone) "Post $what on $niceDate to the pool?"
                    else "Offer $what on $niceDate to $recipientPhrase?"
                )
            },
            text = {
                Text(
                    (if (effectiveWhole) "" else "This splits your shift in Lightning Bolt (you keep the rest). ") +
                        if (isGroup) "Anyone eligible you offered it to can pick it up. You can withdraw it in Lightning Bolt."
                        else "They'll get it as a pending offer. You can cancel until they accept."
                )
            },
            confirmButton = {
                // A split can't be undone from the app, so its action reads as destructive (as on iOS).
                TextButton(onClick = { confirming = false; send() }) {
                    Text(sendLabel, color = if (effectiveWhole) c.accent else Color(0xFFD64545))
                }
            },
            dismissButton = { TextButton(onClick = { confirming = false }) { Text("Cancel") } },
        )
    }

    if (showRecipients) {
        RecipientList(
            colleagues = eligible,
            everyone = everyone,
            selected = selectedEmps,
            cellFor = ::cellFor,
            onEveryone = { everyone = true; selectedEmps = emptySet() },
            onToggle = { emp ->
                everyone = false
                selectedEmps = if (emp in selectedEmps) selectedEmps - emp else selectedEmps + emp
            },
            onTextOne = { emp -> cellFor(emp)?.let { openSwapText(context, askOne(emp), it) } },
            onTextMany = { emps -> openGroupText(context, askGroup(), emps.mapNotNull(::cellFor)) },
            onDismiss = { showRecipients = false },
        )
    }
}

private fun buildTimeline(shift: MyShift): List<Pair<String, String>> {
    fun mins(s: String): Int {
        val p = s.split(":").mapNotNull { it.toIntOrNull() }
        return if (p.size == 2) p[0] * 60 + p[1] else 0
    }
    val startM = mins(shift.start)
    val endM = mins(shift.end)
    val span = if (shift.overnight) 1440 - startM + endM else endM - startM
    if (span <= 0) return emptyList()
    val out = ArrayList<Pair<String, String>>()
    var t = 0
    while (t <= span) {
        val abs = startM + t
        val dayOff = abs / 1440
        val clk = abs % 1440
        val date = if (dayOff == 0) shift.date else ConflictEngine.addDays(shift.date, dayOff)
        val iso = String.format(Locale.ROOT, "%sT%02d:%02d:00", date, clk / 60, clk % 60)
        val label = String.format(Locale.ROOT, "%02d:%02d", clk / 60, clk % 60) + if (dayOff > 0) " (+$dayOff)" else ""
        out.add(iso to label)
        t += 30
    }
    return out
}

@Composable
private fun SectionLabel(t: String) {
    Text(t.uppercase(), fontSize = 10.sp, fontWeight = FontWeight.Bold, color = Theme.colors.muted)
}

@Composable
internal fun SegmentRow(options: List<String>, selectedIndex: Int, onSelect: (Int) -> Unit) {
    val c = Theme.colors
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        options.forEachIndexed { i, label ->
            val on = i == selectedIndex
            Text(
                label,
                fontSize = 13.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal,
                color = if (on) c.accent else c.ink, textAlign = TextAlign.Center,
                modifier = Modifier.weight(1f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(if (on) c.accent.copy(alpha = 0.16f) else c.panel)
                    .border(1.dp, if (on) c.accent.copy(alpha = 0.4f) else c.line, RoundedCornerShape(10.dp))
                    .clickable { onSelect(i) }
                    .padding(vertical = 10.dp),
            )
        }
    }
}

@Composable
private fun TimePickRow(label: String, current: String, options: List<Pair<String, String>>, onPick: (String) -> Unit) {
    val c = Theme.colors
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(10.dp))
                .background(c.panel)
                .clickable { open = true }
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(label, fontSize = 14.sp, color = c.muted, modifier = Modifier.weight(1f))
            Text(current, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { (iso, lbl) ->
                DropdownMenuItem(text = { Text(lbl) }, onClick = { onPick(iso); open = false })
            }
        }
    }
}

@Composable
private fun DonePane(
    title: String,
    detail: String,
    note: String,
    canText: Boolean,
    textLabel: String,
    onText: () -> Unit,
    canCancel: Boolean,
    onCancel: () -> Unit,
    onDone: () -> Unit,
) {
    val c = Theme.colors
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("✅", fontSize = 44.sp)
        Box(Modifier.height(10.dp))
        Text(title, fontSize = 18.sp, fontWeight = FontWeight.SemiBold, color = c.ink, textAlign = TextAlign.Center)
        Box(Modifier.height(8.dp))
        Text(detail, fontSize = 14.sp, color = c.muted, textAlign = TextAlign.Center)
        if (note.isNotEmpty()) {
            Box(Modifier.height(12.dp))
            Text(
                "“$note”", fontSize = 14.sp, fontStyle = FontStyle.Italic, color = c.ink,
                modifier = Modifier.clip(RoundedCornerShape(10.dp)).background(c.panel).padding(12.dp),
            )
        }
        Box(Modifier.height(20.dp))
        if (canText) {
            TextButton(onClick = onText) { Text(textLabel, color = c.accent) }
        }
        if (canCancel) {
            TextButton(onClick = onCancel) { Text("Cancel this offer", color = Color(0xFFD64545)) }
        }
        Button(
            onClick = onDone,
            modifier = Modifier.fillMaxWidth(),
            colors = ButtonDefaults.buttonColors(containerColor = c.accent),
        ) { Text("Done", fontWeight = FontWeight.Bold) }
    }
}

/**
 * Searchable multi-select recipient picker: "Everyone" (pool) at the top, then tick one or several
 * colleagues. Only people who can genuinely take the shift are listed.
 */
@Composable
private fun RecipientList(
    colleagues: List<Pair<Int, String>>,
    everyone: Boolean,
    selected: Set<Int>,
    cellFor: (Int) -> String?,
    onEveryone: () -> Unit,
    onToggle: (Int) -> Unit,
    onTextOne: (Int) -> Unit,
    onTextMany: (List<Int>) -> Unit,
    onDismiss: () -> Unit,
) {
    val c = Theme.colors
    var search by remember { mutableStateOf("") }
    val filtered = if (search.isBlank()) colleagues else colleagues.filter { it.second.contains(search, true) }
    val textableSelected = selected.filter { cellFor(it) != null }
    val textableAll = colleagues.map { it.first }.filter { cellFor(it) != null }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Give it to") },
        text = {
            Column {
                Row(
                    Modifier.fillMaxWidth().clickable(onClick = onEveryone).padding(vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text("Everyone who can work it", color = c.ink, modifier = Modifier.weight(1f))
                    if (everyone) Text("✓", color = c.accent, fontWeight = FontWeight.Bold)
                }
                Text(
                    "Offer it to everyone eligible — anyone free that day can pick it up.",
                    fontSize = 11.sp, color = c.muted,
                )
                HorizontalDivider(color = c.line, modifier = Modifier.padding(vertical = 6.dp))
                SectionLabel("Or pick one or more (who can take it)")
                OutlinedTextField(
                    value = search, onValueChange = { search = it },
                    placeholder = { Text("Search colleagues") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                LazyColumn(Modifier.fillMaxWidth().height(240.dp)) {
                    items(filtered.size, key = { filtered[it].first }) { i ->
                        val (emp, name) = filtered[i]
                        Row(
                            Modifier.fillMaxWidth().clickable { onToggle(emp) }.padding(vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(if (emp in selected) "☑" else "☐", color = if (emp in selected) c.accent else c.muted)
                            Box(Modifier.size(8.dp))
                            Text(name, color = c.ink, modifier = Modifier.weight(1f))
                            if (cellFor(emp) != null) {
                                TextButton(onClick = { onTextOne(emp) }) { Text("💬") }
                            }
                        }
                    }
                    if (filtered.isEmpty()) {
                        item {
                            Text(
                                "No one is free to take this shift.",
                                fontSize = 13.sp, color = c.muted, modifier = Modifier.padding(vertical = 12.dp),
                            )
                        }
                    }
                }
                // The two group-text actions (distinct from the per-person 💬 above).
                if (textableSelected.isNotEmpty() || textableAll.isNotEmpty()) SectionLabel("Text to ask")
                if (textableSelected.isNotEmpty()) {
                    TextButton(onClick = { onTextMany(textableSelected) }) {
                        Text("Text selected (${textableSelected.size})", color = c.accent)
                    }
                }
                if (textableAll.isNotEmpty()) {
                    TextButton(onClick = { onTextMany(textableAll) }) {
                        Text("Text everyone who can work it (${textableAll.size})", color = c.accent)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}
