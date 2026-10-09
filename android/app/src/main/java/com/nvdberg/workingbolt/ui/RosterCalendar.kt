package com.nvdberg.workingbolt.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.model.ConflictEngine
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.UnitKey
import com.nvdberg.workingbolt.model.Units
import java.time.LocalDate
import java.util.Locale
import kotlin.math.roundToInt

// Port of the web My-Shifts calendar (stage2/site/calendar.html): a month grid with coloured shift
// blocks, and 24h/overnight calls fusing into a lighter "post-call" block the next morning.

/** Violet — a shift I've posted and that's still waiting for a taker (iOS `Theme.posted`). */
private val POSTED_LIGHT = Color(0xFF7C5CFC)
private val POSTED_DARK = Color(0xFF9F87FF)

/** kind: 0 = spacer, 1 = call, 2 = post-call. */
internal data class Blk(val id: Int, val kind: Int, val unit: UnitKey?)

internal data class DayD(
    val day: Int, val iso: String, val today: Boolean, val past: Boolean,
    val fuseCall: Set<Int>, val fuseEndPC: Boolean, val blocks: List<Blk>,
)

/**
 * A month's *header* only — deliberately no day cells. Building cells for every month 2022→next-year
 * (~50 months) up front cost noticeable lag on every open; now each month builds its own cells the
 * first time it scrolls into view. Mirrors the iOS build-58 fix.
 */
internal data class MonthD(
    val id: String, val title: String, val stat: String, val breakdown: String,
    val leading: Int, val days: Int, val year: Int, val month: Int,
)

/** What a day cell needs beyond its own data — bundled so the month/day composables stay readable. */
private class CellEnv(
    val openDates: Set<String>,
    val postedDates: Set<String>,
    val busyDays: Map<String, String>,
    val markedISO: String?,
    val pickMode: Boolean,
    val onBusyEdit: (String) -> Unit,
    val onBusyClear: (String) -> Unit,
    val onOpenTap: (String) -> Unit,
    val onShiftTap: (String) -> Unit,
    val onDayPick: (String) -> Unit,
    val blockH: Dp, val cellMinH: Dp,
    val daySize: TextUnit, val blkSize: TextUnit, val dowSize: TextUnit,
    val landscape: Boolean,
)

/**
 * The month grid used by My Shifts.
 *
 * @param scrollTick  bump to re-center on the current month ("This Month" / tapping the tab)
 * @param jumpToYM    set by the year-month picker → scroll to that month
 * @param openDates   dates with an open shift in the pool → amber corner marker (its own tap target)
 * @param postedDates dates I've posted a shift still awaiting pickup → violet corner marker
 * @param busyDays    days I marked busy (date → note) → a quiet dashed tag in the cell
 * @param onBusyEdit  long-press → mark / edit busy
 * @param onOpenTap   tapping the amber square (or an open-pool day I don't work) → that shift in the Pool
 * @param onShiftTap  tapping one of MY shift days → swap / give-away (handled by the parent)
 * @param markedISO   the day the floating Who's On panel is showing → accent outline
 * @param pickMode    panel open → a single tap just retargets it (no give-away / pool jump)
 * @param onDayPick   double-tap (or a tap while the panel's open) → show who's on that day
 */
@Composable
fun RosterCalendar(
    shifts: List<MyShift>,
    userName: String,
    landscape: Boolean = false,
    scrollTick: Int = 0,
    jumpToYM: String = "",
    openDates: Set<String> = emptySet(),
    onOpenTap: (String) -> Unit = {},
    onShiftTap: (String) -> Unit = {},
    postedDates: Set<String> = emptySet(),
    busyDays: Map<String, String> = emptyMap(),
    onBusyEdit: (String) -> Unit = {},
    onBusyClear: (String) -> Unit = {},
    markedISO: String? = null,
    pickMode: Boolean = false,
    onDayPick: (String) -> Unit = {},
) {
    val c = Theme.colors
    val today = AppViewModel.todayRegina()
    val weekStart = Prefs.get(LocalContext.current).weekStart   // 0 = Sunday (default), 1 = Monday

    // Rebuild the month model only when the shift log (or the week start) actually changed — keeps switching
    // tabs snappy.
    val built = remember(shifts, userName, weekStart) { buildMonths(shifts, userName, weekStart) }
    val months = built.months
    val listState = rememberLazyListState()

    val curYM = today.take(7)
    // Center the current month in view (first open + "This Month" + tapping the My Shifts tab).
    // The first landing is instant (no long scroll through the history for a touch to interrupt); later ones glide.
    var landed by remember { mutableStateOf(false) }
    LaunchedEffect(scrollTick, months.size) {
        if (months.isEmpty()) return@LaunchedEffect
        val idx = months.indexOfFirst { it.id == curYM }.takeIf { it >= 0 } ?: months.lastIndex
        // +1: the subtitle occupies item 0
        if (landed) listState.animateScrollToItem(idx + 1) else listState.scrollToItem(idx + 1)
        landed = true
    }
    LaunchedEffect(jumpToYM) {
        if (jumpToYM.isEmpty()) return@LaunchedEffect
        val idx = months.indexOfFirst { it.id == jumpToYM }
        if (idx >= 0) listState.animateScrollToItem(idx + 1)
    }

    // Landscape gets larger metrics (glasses-friendly); portrait keeps the compact grid.
    val env = CellEnv(
        openDates = openDates, postedDates = postedDates, busyDays = busyDays,
        markedISO = markedISO, pickMode = pickMode,
        onBusyEdit = onBusyEdit, onBusyClear = onBusyClear,
        onOpenTap = onOpenTap, onShiftTap = onShiftTap, onDayPick = onDayPick,
        blockH = if (landscape) 27.dp else 20.dp,
        cellMinH = if (landscape) 86.dp else 62.dp,
        daySize = fixedSp(if (landscape) 13f else 10f),
        blkSize = fixedSp(if (landscape) 12.5f else 9f),
        dowSize = fixedSp(if (landscape) 12f else 9f),
        landscape = landscape,
    )

    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxWidth().background(c.bg),
        contentPadding = PaddingValues(14.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item { Text(built.subtitle, fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(horizontal = 2.dp)) }
        items(months.size, key = { months[it].id }) { i ->
            MonthSection(m = months[i], built = built, today = today, weekStart = weekStart, env = env)
        }
        item {
            Text(
                "24h calls run 08:00 → 08:00; the faint block next morning is post-call.  ⚡ Working-Bolt",
                fontSize = 10.sp, color = c.muted, modifier = Modifier.padding(top = 4.dp, start = 2.dp),
            )
        }
    }
}

@Composable
private fun MonthSection(m: MonthD, built: BuiltMonths, today: String, weekStart: Int, env: CellEnv) {
    val c = Theme.colors
    // The day cells for THIS month only, built on first appearance and kept while it stays composed.
    val cells = remember(m.id, built, today, weekStart) {
        buildCells(m, built.byDate, built.postcall, today, weekStart)
    }
    // Fixed week-rows (leading pads + days, padded to whole weeks) so month heights measure exactly.
    val slots: List<DayD?> = List(m.leading) { null } + cells
    val padded = slots + List((7 - slots.size % 7) % 7) { null }

    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(m.title, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = c.ink)
        Row(Modifier.fillMaxWidth().padding(bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(m.stat, fontSize = 12.sp, color = c.muted)
            Box(Modifier.weight(1f))
            if (m.breakdown.isNotEmpty()) {
                Text(m.breakdown, fontSize = 11.sp, fontWeight = FontWeight.Medium, color = c.accent)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            dowLetters(weekStart).forEach { d ->
                Text(
                    d, fontSize = env.dowSize, fontWeight = FontWeight.SemiBold, color = c.muted,
                    modifier = Modifier.weight(1f),
                )
            }
        }
        padded.chunked(7).forEach { week ->
            Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                week.forEach { d ->
                    if (d == null) Box(Modifier.weight(1f).height(env.cellMinH))
                    else DayCell(d = d, env = env, modifier = Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun DayCell(d: DayD, env: CellEnv, modifier: Modifier = Modifier) {
    val c = Theme.colors
    val isOpen = env.openDates.contains(d.iso)
    val busy = env.busyDays[d.iso]
    val marked = env.markedISO == d.iso
    var menu by remember { mutableStateOf(false) }      // long-press menu: mark the day busy (STARS, a course…)
    // The gesture block below outlives a recomposition, so it reads the latest callbacks through this.
    val live by rememberUpdatedState(env)
    val shape = RoundedCornerShape(8.dp)

    Box(
        modifier
            .defaultMinSize(minHeight = env.cellMinH)
            .clip(shape)
            .background(c.panel)
            .border(
                when { marked -> 2.2.dp; d.today -> 1.5.dp; else -> 1.dp },
                when { marked -> c.accent.copy(alpha = 0.85f); d.today -> c.accent; else -> c.line },
                shape,
            )
            // Tap timing. A double-tap opens the Who's On panel; because of that a single tap (my shift →
            // swap/give-away; open-pool day → Pool) is held for the double-tap window, so the dialog / tab
            // switch never lands under the 2nd tap. While the panel is open a single tap just retargets it,
            // at once. Long-press → the busy menu (not for days already gone).
            .pointerInput(d, env.pickMode) {
                detectTapGestures(
                    onTap = {
                        val e = live
                        when {
                            e.pickMode -> e.onDayPick(d.iso)
                            d.blocks.any { it.kind == 1 } -> e.onShiftTap(d.iso)       // my shift (not post-call)
                            e.openDates.contains(d.iso) -> e.onOpenTap(d.iso)          // open-pool day → the Pool
                        }
                    },
                    onDoubleTap = if (env.pickMode) null else { _ -> live.onDayPick(d.iso) },
                    onLongPress = if (d.past) null else { _ -> menu = true },
                )
            },
    ) {
        Column(
            Modifier.padding(4.dp).fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            // Tight line height (Material's default is 24 sp): the blocks sit right under the number, as on iOS,
            // which leaves the bottom-right corner free for the amber open-shift square.
            Text(
                d.day.toString(),
                fontSize = env.daySize,
                lineHeight = env.daySize * 1.25f,
                fontWeight = if (d.today) FontWeight.ExtraBold else FontWeight.SemiBold,
                color = when {
                    d.today -> c.accent
                    d.past -> c.muted.copy(alpha = 0.6f)
                    else -> c.muted
                },
            )
            d.blocks.forEach { b -> ShiftBlock(b, d, env.blockH, env.blkSize) }
            if (busy != null) BusyTag(busy.ifEmpty { "Busy" }, d.past, env.blockH, env.blkSize)
        }
        // Amber marker (same look as the mini-calendar) on days with an open shift in the pool — its OWN tap
        // target so, even on a day you work, tapping the square jumps to that shift in the Pool. It sits on
        // top of the cell's gesture, so a hit here goes to the Pool while the rest of the cell still gives away.
        if (isOpen) {
            Box(
                Modifier.align(Alignment.BottomEnd)
                    // A long-press here still opens the busy menu — only a plain tap goes to the Pool.
                    .pointerInput(d, env.pickMode) {
                        detectTapGestures(
                            onTap = { val e = live; if (e.pickMode) e.onDayPick(d.iso) else e.onOpenTap(d.iso) },
                            onLongPress = if (d.past) null else { _ -> menu = true },
                        )
                    }
                    .padding(8.dp)                              // bigger, easier-to-hit tap zone around the square
                    .size(if (env.landscape) 13.dp else 10.dp)
                    .border(1.6.dp, c.available, RoundedCornerShape(3.dp))
            )
        }
        // Violet filled square (bottom-left) on days I've posted a shift still waiting for pickup — an
        // indicator only (the cell tap still opens give-away/swap for my own shift there).
        if (env.postedDates.contains(d.iso)) {
            Box(
                Modifier.align(Alignment.BottomStart).padding(5.dp)
                    .size(if (env.landscape) 11.dp else 8.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(if (isSystemInDarkTheme()) POSTED_DARK else POSTED_LIGHT)
            )
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(
                text = { Text(if (busy == null) "Mark busy…" else "Edit busy note…") },
                onClick = { menu = false; env.onBusyEdit(d.iso) },
            )
            if (busy != null) {
                DropdownMenuItem(
                    text = { Text("Clear busy", color = MaterialTheme.colorScheme.error) },
                    onClick = { menu = false; env.onBusyClear(d.iso) },
                )
            }
        }
    }
}

/** A day I marked busy: grey dashed tag, so it never reads as a shift. */
@Composable
private fun BusyTag(note: String, past: Boolean, blockH: Dp, blkSize: TextUnit) {
    val c = Theme.colors
    val stroke = c.muted.copy(alpha = 0.7f)
    Box(
        Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = blockH)
            .alpha(if (past) 0.5f else 1f)
            .drawBehind {
                drawRoundRect(
                    color = stroke,
                    cornerRadius = CornerRadius(6.dp.toPx()),
                    style = Stroke(
                        width = 1.dp.toPx(),
                        pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.dp.toPx())),
                    ),
                )
            }
            .padding(horizontal = 5.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        Text(
            note, fontSize = blkSize, fontWeight = FontWeight.SemiBold, color = c.muted,
            lineHeight = blkSize * 1.15f, maxLines = 2, overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun ShiftBlock(
    b: Blk,
    d: DayD,
    blockH: Dp,
    blkSize: TextUnit,
) {
    if (b.kind == 0) { Box(Modifier.height(blockH)); return }
    val unit = b.unit ?: return
    val info = Units.info[unit] ?: return
    val isCall = b.kind == 1
    val fuse = if (isCall) d.fuseCall.contains(b.id) else d.fuseEndPC
    Text(
        info.short,
        fontSize = blkSize, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis,
        color = if (isCall) Color.White else info.color,
        modifier = Modifier
            .fillMaxWidth()
            .height(blockH)
            .alpha(if (d.past) 0.5f else 1f)          // completed shifts sit a touch lighter
            .clip(blockShape(isCall, fuse))
            .background(if (isCall) info.color else info.color.copy(alpha = 0.24f))
            .padding(horizontal = 5.dp),
    )
}

private fun blockShape(isCall: Boolean, fuse: Boolean): RoundedCornerShape {
    if (!fuse) return RoundedCornerShape(6.dp)
    return if (isCall) RoundedCornerShape(topStart = 6.dp, bottomStart = 6.dp)        // cont-start
    else RoundedCornerShape(topEnd = 6.dp, bottomEnd = 6.dp)                          // cont-end
}

// ── build ────────────────────────────────────────────────────────────────────

internal data class BuiltMonths(
    val months: List<MonthD>,
    val present: List<UnitKey>,
    val subtitle: String,
    /** Shared inputs the per-month cell build reads lazily — see [buildCells]. */
    val byDate: Map<String, List<MyShift>> = emptyMap(),
    val postcall: Map<String, Pair<UnitKey, Int>> = emptyMap(),
)

/**
 * Builds only the month *headers* (title, stats, leading weekday, length). Day cells are built per
 * month, on demand, by [buildCells] — see the note on [MonthD].
 */
private fun buildMonths(shifts: List<MyShift>, userName: String, weekStart: Int): BuiltMonths {
    val name = userName.ifEmpty { "My roster" }
    val clinical = shifts.filter { Units.info[it.unit] != null }
    if (clinical.isEmpty()) return BuiltMonths(emptyList(), emptyList(), name)

    val byDate = clinical.groupBy { it.date }
        .mapValues { (_, v) -> v.sortedBy { ConflictEngine.toMin(it.start) } }
    val dates = byDate.keys.sorted()

    // post-call map (day after an overnight), with srcIndex so it aligns with its source row
    val postcall = HashMap<String, Pair<UnitKey, Int>>()
    for (d in dates) {
        val top = postcall[d]?.second?.plus(1) ?: 0
        byDate[d].orEmpty().forEachIndexed { i, s ->
            if (s.overnight) postcall[ConflictEngine.addDay(d)] = s.unit to (top + i)
        }
    }

    val units = clinical.mapTo(HashSet()) { it.unit }
    val present = UnitKey.entries.filter { it in units }
    // One pass over the roster instead of a filter per month (years of history = many months).
    val byMonth = clinical.groupBy { it.date.take(7) }

    val first = dates.first()
    val last = dates.last()
    // Guard the parsing so a single malformed cached date can't crash the My Shifts tab.
    val fy: Int = first.take(4).toIntOrNull() ?: return BuiltMonths(emptyList(), present, name)
    val fm: Int = first.substring(5, 7).toIntOrNull() ?: return BuiltMonths(emptyList(), present, name)
    val ly: Int = last.take(4).toIntOrNull() ?: return BuiltMonths(emptyList(), present, name)
    val lmRaw: Int = last.substring(5, 7).toIntOrNull() ?: return BuiltMonths(emptyList(), present, name)

    val months = ArrayList<MonthD>()
    var y = fy
    var m = fm
    while (y < ly || (y == ly && m <= lmRaw)) {
        val firstDate = LocalDate.of(y, m, 1)
        val leading = weekCol(firstDate, weekStart)          // leading pad under the chosen week start
        val days = firstDate.lengthOfMonth()
        val ym = String.format(Locale.ROOT, "%04d-%02d", y, m)

        val st = monthStats(byMonth[ym].orEmpty())
        months.add(
            MonthD(
                id = ym,
                title = "${monthName(m)} $y",
                stat = "${st.shifts} shift${if (st.shifts == 1) "" else "s"} · ${st.hours.roundToInt()} h",
                breakdown = breakdown(st),
                leading = leading,
                days = days,
                year = y,
                month = m,
            )
        )
        m++; if (m > 12) { m = 1; y++ }
    }

    return BuiltMonths(months, present, "$name · through ${monthName(lmRaw)} $ly", byDate, postcall)
}

/** The day cells for one month — called from [MonthSection] the first time that month is composed. */
private fun buildCells(
    m: MonthD,
    byDate: Map<String, List<MyShift>>,
    postcall: Map<String, Pair<UnitKey, Int>>,
    today: String,
    weekStart: Int,
): List<DayD> {
    val cells = ArrayList<DayD>(m.days)
    for (dd in 1..m.days) {
        val iso = String.format(Locale.ROOT, "%s-%02d", m.id, dd)
        val col = weekCol(LocalDate.of(m.year, m.month, dd), weekStart)   // column within the week row
        val blocks = ArrayList<Blk>()
        var bid = 0
        val fuseCall = HashSet<Int>()
        var fuseEndPC = false
        postcall[iso]?.let { (unit, srcIndex) ->
            repeat(srcIndex) { blocks.add(Blk(bid++, 0, null)) }
            fuseEndPC = col > 0          // don't bleed into the first column of a week row
            blocks.add(Blk(bid++, 2, unit))
        }
        for (s in byDate[iso].orEmpty()) {
            if (s.overnight && col < 6) fuseCall.add(bid)   // don't bleed past the last column
            blocks.add(Blk(bid++, 1, s.unit))
        }
        cells.add(DayD(dd, iso, iso == today, iso < today, fuseCall, fuseEndPC, blocks))
    }
    return cells
}

private data class RS(
    var shifts: Int = 0, var hours: Double = 0.0, var full24: Int = 0,
    var rr9: Int = 0, var msu: Int = 0, var half: Int = 0,
)

private fun hrs(s: MyShift): Double {
    val iv = ConflictEngine.interval(s.date, s.start, s.end, s.overnight)
    return (iv.e - iv.s) / 60.0
}

private fun std(k: UnitKey): Double = when (k) {
    UnitKey.RR, UnitKey.PRR -> 9.0
    UnitKey.MSU -> 15.0
    else -> 24.0
}

private fun monthStats(shifts: List<MyShift>): RS {
    val st = RS()
    val byDate = shifts.groupBy { it.date }
    val consumed = HashSet<MyShift>()
    var combos = 0
    for ((_, day) in byDate) {
        val p = day.firstOrNull { it.unit == UnitKey.PRR }
        val m = day.firstOrNull { it.unit == UnitKey.MSU }
        if (p != null && m != null) { combos++; consumed.add(p); consumed.add(m) }
    }
    st.full24 += combos
    for (s in shifts) {
        st.hours += hrs(s)
        if (s in consumed) continue
        if (hrs(s) < std(s.unit) - 1.0) { st.half++; continue }
        when (s.unit) {
            UnitKey.MICU, UnitKey.SICU, UnitKey.CCU, UnitKey.PHICU -> st.full24++
            UnitKey.RR, UnitKey.PRR -> st.rr9++
            UnitKey.MSU -> st.msu++
        }
    }
    st.shifts = shifts.size - combos
    return st
}

private fun breakdown(st: RS): String {
    val p = ArrayList<String>()
    if (st.full24 > 0) p.add("24h ×${st.full24}")
    if (st.rr9 > 0) p.add("9h ×${st.rr9}")
    if (st.msu > 0) p.add("15h ×${st.msu}")
    if (st.half > 0) p.add("half ×${st.half}")
    return p.joinToString("    ")
}

private fun monthName(m: Int): String = listOf(
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
)[(m - 1).coerceIn(0, 11)]
