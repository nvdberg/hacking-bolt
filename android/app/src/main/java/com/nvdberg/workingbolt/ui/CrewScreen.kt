package com.nvdberg.workingbolt.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nvdberg.workingbolt.AppViewModel

/**
 * Crew — pick a few doctors and see when they're working, in the exact Who's On format, but only your
 * chosen people appear in the cells. Handy for spotting shared off-days to plan time away together.
 */
@Composable
fun CrewScreen(vm: AppViewModel, prefs: Prefs) {
    val c = Theme.colors
    val todayISO = AppViewModel.todayRegina()
    var selectedISO by remember { mutableStateOf(todayISO) }
    var scrollTick by remember { mutableIntStateOf(0) }
    var visibleMonth by remember { mutableStateOf("") }
    var showPicker by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { vm.loadGroupHistory() }   // full group history (2022 →) powers Crew too

    val selected = prefs.selectedDocs.split("\n").filter { it.isNotBlank() }
    val chosen = selected.sortedBy { surname(it).lowercase() }

    // Active doctors only: worked a shift THIS YEAR. Drops LB's "EMPTY" vacancy, the "NO MRI" placeholder,
    // and former docs who only have old shifts in the history.
    val allDocs = remember(vm.whoData, todayISO) {
        val cutoff = todayISO.take(4) + "-01-01"
        vm.whoData.filter { it.date >= cutoff }.map { it.doc }.distinct()
            .filter { n ->
                val u = n.uppercase()
                n.isNotEmpty() && u != "EMPTY" && n != "—" && !u.contains("NO MRI")
            }
            .sortedBy { surname(it).lowercase() }
    }

    // Same shape as Who's On, but only the chosen doctors — memoized so scrolling doesn't re-filter history.
    val byDay = remember(prefs.selectedDocs, vm.whoData) {
        val sel = selected.toHashSet()
        vm.whoData.filter { it.doc in sel }.groupBy { it.date }
    }
    val days = vm.whoDays

    DayScaffold(
        title = visibleMonth.ifEmpty { "Crew" },
        days = if (selected.isEmpty()) emptyList() else days,   // no date jump / Today until someone is picked
        selectedISO = selectedISO,
        onSelect = { selectedISO = it; scrollTick++ },
        onToday = { selectedISO = todayISO; scrollTick++ },
        todayEnabled = days.contains(todayISO) && selected.isNotEmpty(),
    ) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp), horizontalArrangement = Arrangement.End) {
                Text(
                    "you can thank Pieter",     // feature credit 🙂
                    fontSize = 10.sp, fontStyle = FontStyle.Italic, color = c.muted,
                )
            }
            // Chips bar
            Row(
                Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 9.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    if (selected.isEmpty()) "+ Choose doctors" else "+ Add",
                    fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = c.accent,
                    modifier = Modifier.clip(RoundedCornerShape(50))
                        .background(c.accent.copy(alpha = 0.14f))
                        .clickable { showPicker = true }
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                )
                chosen.forEach { doc ->
                    Row(
                        Modifier.clip(RoundedCornerShape(50))
                            .background(c.panel)
                            .border(1.dp, c.line, RoundedCornerShape(50))
                            .clickable { prefs.updateSelectedDocs(selected.filter { it != doc }.joinToString("\n")) }
                            .padding(horizontal = 11.dp, vertical = 7.dp),
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            if (doc == vm.userName) "You" else doc,
                            fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = c.ink, maxLines = 1,
                        )
                        Text("✕", fontSize = 11.sp, color = c.muted)
                    }
                }
            }
            HorizontalDivider(color = c.line)

            val cfg = LocalConfiguration.current
            val landscape = cfg.screenWidthDp > cfg.screenHeightDp
            when {
                selected.isEmpty() -> Column(
                    Modifier.fillMaxSize().padding(30.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        "Pick a few doctors to see when they're working",
                        fontSize = 14.sp, color = c.ink, textAlign = TextAlign.Center,
                    )
                    Box(Modifier.padding(4.dp))
                    Text(
                        "Their shifts show in the grid; blank means off — handy for finding shared days away.",
                        fontSize = 12.sp, color = c.muted, textAlign = TextAlign.Center,
                    )
                    TextButton(onClick = { showPicker = true }) { Text("Choose doctors", color = c.accent) }
                }
                landscape -> WhoWeekGrid(
                    days = days, byDay = byDay, todayISO = todayISO,
                    scrollTo = selectedISO, scrollTick = scrollTick,
                    availHeight = (cfg.screenHeightDp - 52).dp, unitOrder = prefs.unitOrder,
                    onVisibleMonth = { visibleMonth = it },
                )
                else -> WhoDayTimeline(
                    days = days, byDay = byDay, todayISO = todayISO,
                    scrollTo = selectedISO, scrollTick = scrollTick, unitOrder = prefs.unitOrder,
                )
            }
        }
    }

    if (showPicker) {
        DocPicker(
            allDocs = allDocs,
            myName = vm.userName,
            selected = selected.toSet(),
            onToggle = { doc ->
                val s = selected.toMutableSet()
                if (!s.remove(doc)) s.add(doc)
                prefs.updateSelectedDocs(s.sorted().joinToString("\n"))
            },
            onClear = { prefs.updateSelectedDocs("") },
            onDismiss = { showPicker = false },
        )
    }
}

@Composable
private fun DocPicker(
    allDocs: List<String>,
    myName: String,
    selected: Set<String>,
    onToggle: (String) -> Unit,
    onClear: () -> Unit,
    onDismiss: () -> Unit,
) {
    val c = Theme.colors
    var search by remember { mutableStateOf("") }
    val filtered = if (search.isBlank()) allDocs else allDocs.filter { it.contains(search, ignoreCase = true) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Doctors") },
        text = {
            Column {
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    label = { Text("Search doctors") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                LazyColumn(Modifier.fillMaxWidth()) {
                    items(filtered.size, key = { filtered[it] }) { i ->
                        val doc = filtered[i]
                        Row(
                            Modifier.fillMaxWidth().clickable { onToggle(doc) }.padding(vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                if (doc == myName) "$doc (you)" else doc,
                                color = c.ink, modifier = Modifier.weight(1f),
                            )
                            if (doc in selected) Text("✓", color = c.accent, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        dismissButton = {
            if (selected.isNotEmpty()) TextButton(onClick = onClear) { Text("Clear", color = c.muted) }
        },
    )
}
