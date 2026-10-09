package com.nvdberg.workingbolt.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.ShiftStats
import com.nvdberg.workingbolt.model.UnitKey
import com.nvdberg.workingbolt.model.Units
import java.time.LocalDate
import java.util.Locale

/**
 * The tally sections, shown in a user-reorderable order (saved per device).
 *
 * iOS also has `earnings`, `groupCompare`, `unitMix` and `shiftPickups` — all owner-gated there, and this
 * app has no owner/admin surface by design, so they are deliberately absent. See the README.
 */
enum class StatSection(val label: String) {
    PerMonth("Month by month"),
    MonthlyAvg("Monthly average"),
    ComingUp("Coming up"),
    Ytd("Year to date"),
    ByYear("By year"),
    Custom("Custom range");

    companion object {
        val defaultOrder = listOf(PerMonth, MonthlyAvg, ComingUp, Ytd, ByYear, Custom)
    }
}

@Composable
fun StatsScreen(vm: AppViewModel, prefs: Prefs) {
    val c = Theme.colors
    val today = AppViewModel.todayRegina()
    val year = today.take(4)
    val log = vm.shiftLog
    var loadingHistory by remember { mutableStateOf(false) }
    var reordering by remember { mutableStateOf(false) }
    val expanded = remember { mutableStateOf(setOf<String>()) }
    var yearSel by remember { mutableStateOf(0) }
    var rStart by remember { mutableStateOf(LocalDate.parse(today).minusDays(90).toString()) }
    var rEnd by remember { mutableStateOf(today) }

    LaunchedEffect(Unit) {
        loadingHistory = true
        vm.loadHistory()          // backfill the whole personal history (2022 →), then cached
        loadingHistory = false
    }

    if (log.isEmpty()) {
        Column(
            Modifier.fillMaxSize().background(c.bg).padding(top = 60.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (loadingHistory) {
                CircularProgressIndicator(color = c.accent)
                Text("Building your shift log…", fontSize = 14.sp, color = c.ink)
                Text("Reading your roster back to 2022 — just this once.", fontSize = 12.sp, color = c.muted)
            } else {
                Text("No shifts logged yet", color = c.muted)
            }
        }
        return
    }

    val allTimeStart = log.minOf { it.date }
    val order = remember(prefs.statsOrder) { readOrder(prefs.statsOrder) }

    Column(Modifier.fillMaxSize().background(c.bg)) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 12.dp),
            horizontalArrangement = Arrangement.End,
        ) {
            TextButton(onClick = { reordering = !reordering }) {
                Text(if (reordering) "Done" else "Reorder", fontSize = 13.sp, color = c.muted)
            }
        }
        LazyColumn(
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(order.size, key = { order[it].name }) { i ->
                val section = order[i]
                Column {
                    if (reordering) {
                        Row(
                            Modifier.fillMaxWidth().padding(bottom = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(section.label, fontSize = 12.sp, color = c.muted, modifier = Modifier.weight(1f))
                            TextButton(
                                onClick = { prefs.updateStatsOrder(moved(order, i, i - 1)) },
                                enabled = i > 0,
                            ) { Text("↑") }
                            TextButton(
                                onClick = { prefs.updateStatsOrder(moved(order, i, i + 1)) },
                                enabled = i < order.lastIndex,
                            ) { Text("↓") }
                        }
                    }
                    when (section) {
                        StatSection.PerMonth -> PerMonthCards(log, today, expanded)
                        StatSection.MonthlyAvg -> StatsCard(
                            title = "Monthly average",
                            subtitle = "since ${allTimeStart.take(4)}",
                            stats = ShiftStats.compute(log, allTimeStart, today),
                        )
                        StatSection.ComingUp -> ComingUpCard(log, today, year)
                        StatSection.Ytd -> StatsCard(
                            title = "Year to date",
                            subtitle = "Jan 1 $year – today",
                            stats = ShiftStats.compute(log, "$year-01-01", today),
                        )
                        StatSection.ByYear -> ByYearCard(log, year, yearSel) { yearSel = it }
                        StatSection.Custom -> CustomRangeCard(
                            log = log, rStart = rStart, rEnd = rEnd,
                            bounds = allTimeStart to (log.maxOf { it.date }.coerceAtLeast(today)),
                            onStart = { rStart = it }, onEnd = { rEnd = it },
                        )
                    }
                }
            }
            item {
                Text(
                    "Your shift log is saved on this device and remembers every shift you've worked since " +
                        "2022 — even ones no longer shown in the roster. Future shifts update automatically " +
                        "as you pick up or give away.",
                    fontSize = 10.sp, color = c.muted, textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                )
            }
        }
    }
}

private fun readOrder(raw: String): List<StatSection> {
    val saved = raw.split(",").mapNotNull { n -> StatSection.entries.firstOrNull { it.name == n } }
    // forward-compat: append any section not in the saved order yet
    return saved + StatSection.defaultOrder.filter { it !in saved }
}

private fun moved(order: List<StatSection>, from: Int, to: Int): String {
    val l = order.toMutableList()
    if (from !in l.indices || to !in l.indices) return order.joinToString(",") { it.name }
    l.add(to, l.removeAt(from))
    return l.joinToString(",") { it.name }
}

// ── cards ────────────────────────────────────────────────────────────────────

/** One card per month you actually worked, newest first. */
@Composable
private fun PerMonthCards(
    log: List<MyShift>,
    today: String,
    expanded: androidx.compose.runtime.MutableState<Set<String>>,
) {
    val months = remember(log, today) {
        log.map { it.date.take(7) }.distinct().filter { it <= today.take(7) }.sortedDescending()
    }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Month by month", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Theme.colors.ink)
        months.forEach { ym ->
            CollapsibleMonthCard(
                title = monthLabelFull("$ym-01"),
                stats = ShiftStats.compute(log, "$ym-01", monthEnd(ym)),
                expanded = ym in expanded.value,
                onToggle = {
                    expanded.value = if (ym in expanded.value) expanded.value - ym else expanded.value + ym
                },
            )
        }
    }
}

/** The canonical unit order for the per-unit chips (independent of the editable "Who's On order"). */
private val statsUnitOrder = listOf(
    UnitKey.SICU, UnitKey.MICU, UnitKey.CCU, UnitKey.RR, UnitKey.PHICU, UnitKey.PRR, UnitKey.MSU,
)

private fun monthEnd(ym: String): String {
    val p = ym.split("-").mapNotNull { it.toIntOrNull() }
    if (p.size != 2) return "$ym-28"
    return String.format(Locale.ROOT, "%s-%02d", ym, LocalDate.of(p[0], p[1], 1).lengthOfMonth())
}

/** Coming up — the dynamic future half of the log, over two horizons + a month-by-month breakdown. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ComingUpCard(log: List<MyShift>, today: String, year: String) {
    val c = Theme.colors
    val future = log.filter { it.date >= today }.sortedBy { it.date }
    val eoy = "$year-12-31"
    val toYear = future.filter { it.date <= eoy }
    val rosterEnd = log.maxOfOrNull { it.date } ?: today
    val toYearHours = toYear.sumOf { ShiftStats.hours(it) }
    val toRosterHours = future.sumOf { ShiftStats.hours(it) }
    val byMonth = future.groupBy { it.date.take(7) }
    // Count shifts the way every other card does (a Pasqua Rapid+MSU day is ONE shift, not two).
    val toYearCount = ShiftStats.compute(toYear, today, eoy).count
    val futureCount = ShiftStats.compute(future, today, rosterEnd).count

    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(c.accent.copy(alpha = 0.10f))
            .border(1.dp, c.accent.copy(alpha = 0.25f), RoundedCornerShape(16.dp))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Coming up", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = c.ink)
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ComingBlock("To end of $year", toYearCount, toYearHours, "by Dec 31", Modifier.weight(1f))
            ComingBlock(
                "To roster end", futureCount, toRosterHours,
                "ends ${fmt(rosterEnd, "MMM d, yyyy")}", Modifier.weight(1f),
            )
        }
        future.firstOrNull()?.let { n ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(8.dp).clip(CircleShape).background(Units.color(n.unit)))
                Text(
                    "Next: ${Units.short(n.unit)} · ${longDate(n.date)} · ${n.start}–${n.end}",
                    fontSize = 12.sp, color = c.muted,
                )
            }
        }
        if (byMonth.isNotEmpty()) {
            HorizontalDivider(color = c.line)
            Text("BY MONTH", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = c.muted)
            byMonth.keys.sorted().forEach { ym -> UpcomingMonthRow(ym, byMonth[ym].orEmpty(), log, today) }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun UpcomingMonthRow(ym: String, items: List<MyShift>, log: List<MyShift>, today: String) {
    val c = Theme.colors
    val counts = items.groupingBy { it.unit }.eachCount()
    val units = statsUnitOrder.filter { counts.containsKey(it) }
    val n = ShiftStats.compute(items, "$ym-01", monthEnd(ym)).count   // Pasqua Rapid+MSU day = one shift
    // The current month only lists what's still ahead — say so, next to the month's full total.
    val whole = if (ym == today.take(7)) ShiftStats.compute(log, "$ym-01", monthEnd(ym)).count else n
    Column(Modifier.padding(vertical = 2.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                monthLabelFull("$ym-01"), fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                color = c.ink, modifier = Modifier.weight(1f),
            )
            Text(
                if (whole > n) "$n left of $whole" else "$n shift${if (n == 1) "" else "s"}",
                fontSize = 12.sp, fontWeight = FontWeight.Medium, color = c.accent,
            )
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            units.forEach { u ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    Box(Modifier.size(8.dp).clip(CircleShape).background(Units.color(u)))
                    Text(Units.short(u), fontSize = 11.sp, color = c.muted)
                    Text("×${counts[u] ?: 0}", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = c.ink)
                }
            }
        }
    }
}

@Composable
private fun ComingBlock(title: String, shifts: Int, hours: Double, sub: String, modifier: Modifier = Modifier) {
    val c = Theme.colors
    Column(
        modifier.clip(RoundedCornerShape(12.dp)).background(c.bg).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Text(title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = c.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("$shifts", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = c.ink)
            Text("shifts", fontSize = 11.sp, color = c.muted)
        }
        Text("${ShiftStats.hoursStr(hours)} h", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.accent)
        Text(sub, fontSize = 11.sp, color = c.muted)
    }
}

/** A per-year card with tappable year chips (2025 / 2024 / 2023 …). */
@Composable
private fun ByYearCard(log: List<MyShift>, year: String, yearSel: Int, onSelect: (Int) -> Unit) {
    val c = Theme.colors
    val cur = year.toIntOrNull() ?: 2026
    val years = remember(log, cur) {
        log.mapNotNull { it.date.take(4).toIntOrNull() }.distinct()
            .filter { it < cur && it >= 2022 }.sortedDescending()
    }
    if (years.isEmpty()) return
    val sel = if (yearSel in years) yearSel else years.first()

    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(c.panel)
            .border(1.dp, c.line, RoundedCornerShape(16.dp))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("By year", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = c.ink)
        Row(
            Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            years.forEach { y ->
                val on = sel == y
                Text(
                    "$y",
                    fontSize = 14.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal,
                    color = if (on) c.accent else c.ink,
                    modifier = Modifier.clip(RoundedCornerShape(50))
                        .background(if (on) c.accent.copy(alpha = 0.16f) else c.bg)
                        .border(1.dp, if (on) c.accent.copy(alpha = 0.4f) else c.line, RoundedCornerShape(50))
                        .clickable { onSelect(y) }
                        .padding(horizontal = 13.dp, vertical = 6.dp),
                )
            }
        }
        StatsCard(
            title = "", subtitle = "$sel · full year",
            stats = ShiftStats.compute(log, "$sel-01-01", "$sel-12-31"), embedded = true,
        )
    }
}

@Composable
private fun CustomRangeCard(
    log: List<MyShift>,
    rStart: String,
    rEnd: String,
    bounds: Pair<String, String>,
    onStart: (String) -> Unit,
    onEnd: (String) -> Unit,
) {
    val c = Theme.colors
    var picking by remember { mutableStateOf<String?>(null) }   // "from" / "to"

    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(c.panel)
            .border(1.dp, c.line, RoundedCornerShape(16.dp))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Custom range", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = c.ink)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            RangeButton("From", rStart, Modifier.weight(1f)) { picking = "from" }
            RangeButton("To", rEnd, Modifier.weight(1f)) { picking = "to" }
        }
        HorizontalDivider(color = c.line)
        StatsCard(
            title = "", subtitle = "${longDate(rStart)} – ${longDate(rEnd)}",
            stats = ShiftStats.compute(log, minOf(rStart, rEnd), maxOf(rStart, rEnd)), embedded = true,
        )
    }

    picking?.let { which ->
        IsoDatePickerDialog(
            initial = if (which == "from") rStart else rEnd,
            min = bounds.first, max = bounds.second,
            onPick = { if (which == "from") onStart(it) else onEnd(it) },
            onDismiss = { picking = null },
        )
    }
}

@Composable
private fun RangeButton(label: String, value: String, modifier: Modifier, onClick: () -> Unit) {
    val c = Theme.colors
    Column(
        modifier.clip(RoundedCornerShape(12.dp)).background(c.bg).clickable(onClick = onClick).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(label, fontSize = 11.sp, color = c.muted)
        Text(longDate(value), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
    }
}

// ── reusable cards ───────────────────────────────────────────────────────────

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun StatsCard(
    title: String,
    subtitle: String,
    stats: ShiftStats,
    embedded: Boolean = false,
    showAverages: Boolean = true,
) {
    val c = Theme.colors
    val body: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (!embedded) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                    Text(title, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = c.ink, modifier = Modifier.weight(1f))
                    Text(subtitle, fontSize = 12.sp, color = c.muted)
                }
            } else if (subtitle.isNotEmpty()) {
                Text(subtitle, fontSize = 12.sp, color = c.muted)
            }

            // totals + per-month averages
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Metric("${stats.count}", "shifts", Modifier.weight(1f))
                Metric(ShiftStats.hoursStr(stats.totalHours), "hours", Modifier.weight(1f))
                if (showAverages) {
                    Metric("%.1f".format(stats.avgShiftsPerMonth), "shifts/mo", Modifier.weight(1f))
                    Metric(ShiftStats.hoursStr(stats.avgHoursPerMonth), "h/mo", Modifier.weight(1f))
                }
            }

            if (stats.count == 0) {
                Text("No shifts in this range.", fontSize = 12.sp, color = c.muted)
            } else {
                if (stats.byLength.isNotEmpty()) {
                    CardLabel("By length")
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        stats.byLength.forEach { b ->
                            Row(
                                Modifier.clip(RoundedCornerShape(50)).background(c.bg)
                                    .border(1.dp, c.line, RoundedCornerShape(50))
                                    .padding(horizontal = 10.dp, vertical = 6.dp),
                                horizontalArrangement = Arrangement.spacedBy(5.dp),
                            ) {
                                Text(b.label, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = c.ink)
                                Text("×${b.count}", fontSize = 12.sp, color = c.muted)
                            }
                        }
                    }
                }
                if (stats.byUnit.isNotEmpty()) {
                    CardLabel("By unit")
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        stats.byUnit.forEach { u ->
                            Row(
                                Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(7.dp),
                            ) {
                                Box(Modifier.size(9.dp).clip(CircleShape).background(u.color))
                                Text(u.name, fontSize = 14.sp, color = c.ink, modifier = Modifier.weight(1f), maxLines = 1)
                                Text("×${u.count}", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
                                if (showAverages) {
                                    Text("· %.1f/mo".format(u.count / stats.months), fontSize = 12.sp, color = c.muted)
                                }
                                Text("· ${ShiftStats.hoursStr(u.hours)}h", fontSize = 12.sp, color = c.muted)
                            }
                        }
                    }
                }
                if (stats.nights > 0 || stats.weekends > 0) {
                    Text(
                        "${stats.nights} overnight · ${stats.weekends} weekend day${if (stats.weekends == 1) "" else "s"}",
                        fontSize = 12.sp, color = c.muted,
                    )
                }
            }
        }
    }

    if (embedded) {
        body()
    } else {
        Box(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(c.panel)
                .border(1.dp, c.line, RoundedCornerShape(16.dp))
                .padding(16.dp),
        ) { body() }
    }
}

@Composable
private fun Metric(value: String, lbl: String, modifier: Modifier = Modifier) {
    val c = Theme.colors
    Column(
        modifier.clip(RoundedCornerShape(12.dp)).background(c.bg).padding(vertical = 10.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(value, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = c.ink, maxLines = 1)
        Text(lbl, fontSize = 10.sp, color = c.muted, maxLines = 1)
    }
}

@Composable
private fun CardLabel(t: String) {
    Text(
        t.uppercase(), fontSize = 10.sp, fontWeight = FontWeight.Bold, color = Theme.colors.muted,
        modifier = Modifier.padding(top = 2.dp),
    )
}

/** Month-by-month: tap to open the full breakdown. */
@Composable
private fun CollapsibleMonthCard(title: String, stats: ShiftStats, expanded: Boolean, onToggle: () -> Unit) {
    val c = Theme.colors
    val summary = buildList {
        add("${stats.count} · ${ShiftStats.hoursStr(stats.totalHours)}h")
        stats.byLength.firstOrNull { it.hours == 24 }?.let { add("24h ×${it.count}") }
        stats.byLength.firstOrNull { it.hours == 9 }?.let { add("9h ×${it.count}") }
    }.joinToString("  ·  ")

    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(c.panel)
            .border(1.dp, c.line, RoundedCornerShape(16.dp))
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(if (expanded) 12.dp else 0.dp),
    ) {
        Row(
            Modifier.fillMaxWidth().clickable(onClick = onToggle),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(title, fontSize = 16.sp, fontWeight = FontWeight.Bold, color = c.ink)
            Box(Modifier.weight(1f))
            if (!expanded) {
                Text(summary, fontSize = 12.sp, color = c.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text(if (expanded) "▲" else "▼", fontSize = 11.sp, color = c.muted)
        }
        AnimatedVisibility(visible = expanded) {
            StatsCard(title = "", subtitle = "", stats = stats, embedded = true, showAverages = false)
        }
    }
}
