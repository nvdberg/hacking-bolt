package com.nvdberg.workingbolt.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.MedicalServices
import androidx.compose.material.icons.filled.Phone
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.model.Assignment
import com.nvdberg.workingbolt.model.UnitKey
import com.nvdberg.workingbolt.model.Units
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Portrait: a vertical day-timeline (scroll up = earlier, down = later).
 * Shared by Who's Working and Crew — Crew just passes a filtered [byDay].
 * [onMine] (date, unit, giveAway): long-press one of MY OWN upcoming shifts → swap / give-away. Null = no menu.
 */
@Composable
fun WhoDayTimeline(
    days: List<String>,
    byDay: Map<String, List<Assignment>>,
    todayISO: String,
    scrollTo: String,
    scrollTick: Int,
    unitOrder: List<UnitKey>,
    onMine: ((String, UnitKey, Boolean) -> Unit)? = null,
    doctors: Boolean = false,          // stethoscope toggle → intensivist / cardiology column + on-call strip
    demo: Boolean = false,
) {
    val listState = rememberLazyListState()

    LaunchedEffect(scrollTo, scrollTick, days.size) {
        val idx = days.indexOf(scrollTo)
        if (idx >= 0) listState.scrollToItem(idx)
    }

    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(14.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        items(days.size, key = { days[it] }) { i ->
            DaySection(days[i], byDay[days[i]].orEmpty(), days[i] == todayISO, unitOrder, onMine, doctors, demo)
        }
    }
}

/** The long-press menu on my own upcoming shift — the same two choices as tapping a shift in My Shifts. */
@Composable
private fun MineMenu(expanded: Boolean, onDismiss: () -> Unit, onPick: (Boolean) -> Unit) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(text = { Text("Find a swap") }, onClick = { onDismiss(); onPick(false) })
        DropdownMenuItem(text = { Text("Give it away") }, onClick = { onDismiss(); onPick(true) })
    }
}

@Composable
private fun DaySection(
    day: String,
    rowsIn: List<Assignment>,
    isToday: Boolean,
    unitOrder: List<UnitKey>,
    onMine: ((String, UnitKey, Boolean) -> Unit)?,
    doctors: Boolean,
    demo: Boolean,
) {
    val c = Theme.colors
    val context = LocalContext.current
    fun order(u: UnitKey) = unitOrder.indexOf(u).takeIf { it >= 0 } ?: 99
    val rows = rowsIn.sortedWith(compareBy({ order(it.unit) }, { it.start }))
    if (doctors) LaunchedEffect(day, demo) { DoctorRoster.ensure(context, day, demo) }

    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                weekday(day), fontSize = 14.sp, fontWeight = FontWeight.ExtraBold,
                color = if (isToday) c.accent else c.ink.copy(alpha = 0.7f),
            )
            Text(longDate(day), fontSize = 14.sp, color = c.muted)
            if (isToday) {
                Text(
                    "TODAY", fontSize = 9.sp, fontWeight = FontWeight.ExtraBold, color = Color.White,
                    modifier = Modifier.clip(RoundedCornerShape(50)).background(c.accent)
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                )
            }
        }
        if (rows.isEmpty()) {
            Text("No one scheduled", fontSize = 12.sp, color = c.muted, modifier = Modifier.padding(start = 2.dp))
        } else {
            // The doctor goes beside the first CCA row of each unit only — later rows of the same unit leave it blank.
            val seen = HashSet<UnitKey>()
            rows.forEach { a ->
                val doc = if (doctors && seen.add(a.unit)) DocTag.of(day, a.unit) else null
                if (onMine != null && a.isMe && AppViewModel.notStarted(day, a.start)) {   // my own upcoming shift → long-press to act
                    key(a.unit, a.start) {
                        var menu by remember { mutableStateOf(false) }
                        Box {
                            PersonRow(a, isToday, doctors, doc, onLongPress = { menu = true })
                            MineMenu(menu, { menu = false }) { giveAway -> onMine(day, a.unit, giveAway) }
                        }
                    }
                } else {
                    PersonRow(a, isToday, doctors, doc)
                }
            }
        }
        if (doctors) OnCallStrip(day, isToday)
    }
}

/**
 * Same tier principle as the landscape grid: you = white on the SOLID unit colour (stands out most),
 * today = bright on a stronger fill, surrounding days = unit colour on a faint fill.
 */
@Composable
private fun PersonRow(
    a: Assignment, isToday: Boolean, doctors: Boolean = false, doc: DocTag? = null, onLongPress: (() -> Unit)? = null,
) {
    val c = Theme.colors
    val haptics = LocalHapticFeedback.current
    val info = Units.info[a.unit]
    val color = info?.color ?: Color.Gray
    val fillOp = if (a.isMe) 1.0f else if (isToday) 0.26f else 0.07f
    val nameColor = if (a.isMe) Color.White else if (isToday) c.ink else c.ink.copy(alpha = 0.72f)
    val unitColor = if (a.isMe) Color.White.copy(alpha = 0.92f) else color.copy(alpha = if (isToday) 1f else 0.68f)

    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(11.dp))
            .background(color.copy(alpha = fillOp))
            .border(
                1.dp,
                color.copy(alpha = if (a.isMe) 0f else if (isToday) 0.4f else 0.14f),
                RoundedCornerShape(11.dp),
            )
            // A plain tap does nothing, so browsing can never trip a stray prompt.
            .then(
                if (onLongPress == null) Modifier else Modifier.pointerInput(onLongPress) {
                    detectTapGestures(onLongPress = {
                        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                        onLongPress()
                    })
                }
            )
            .padding(vertical = 9.dp, horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            info?.short ?: a.unit.name, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = unitColor,
            modifier = Modifier.width(if (doctors) 84.dp else 96.dp), maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                a.doc, fontSize = 14.sp,
                fontWeight = if (a.isMe || isToday) FontWeight.Bold else FontWeight.SemiBold,
                color = nameColor, maxLines = if (doctors) 1 else Int.MAX_VALUE, overflow = TextOverflow.Ellipsis,
            )
            Text(
                "${a.start}–${a.end}", fontSize = 11.sp,
                color = if (a.isMe) Color.White.copy(alpha = 0.75f) else c.ink.copy(alpha = 0.55f),
            )
        }
        if (a.isMe) {
            Text(
                "you", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = Color.White,
                modifier = Modifier.clip(RoundedCornerShape(50)).background(Color.White.copy(alpha = 0.22f))
                    .padding(horizontal = 7.dp, vertical = 2.dp),
            )
        }
        if (doc != null) {
            val subColor = if (a.isMe) Color.White.copy(alpha = 0.75f) else c.ink.copy(alpha = 0.55f)
            Box(Modifier.width(1.dp).height(28.dp).background(if (a.isMe) Color.White.copy(alpha = 0.35f) else color.copy(alpha = 0.3f)))
            Column(Modifier.width(78.dp), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    if (doc.night) {
                        Icon(
                            Icons.Filled.Bedtime, contentDescription = "On call tonight",
                            tint = if (a.isMe) Color.White else Indigo, modifier = Modifier.size(10.dp),
                        )
                    }
                    Text(
                        doc.name, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = nameColor,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                    if (doc.sub != "in CCU") {
                        Icon(Icons.Filled.Phone, contentDescription = "On-call number", tint = subColor, modifier = Modifier.size(9.dp))
                    }
                    Text(doc.sub, fontSize = 11.sp, color = subColor, maxLines = 1)
                }
            }
        }
    }
}

/**
 * Landscape: a week grid — units anchored down the left, days across the top, doctors in the cells.
 * [onVisibleMonth] reports the leading column's month so the caller can anchor it in the title.
 * [onMine] (date, unit, giveAway): long-press my own upcoming cell → swap / give-away. Null = no menu.
 */
@Composable
fun WhoWeekGrid(
    days: List<String>,
    byDay: Map<String, List<Assignment>>,
    todayISO: String,
    scrollTo: String,
    scrollTick: Int,
    availHeight: Dp,
    unitOrder: List<UnitKey>,
    onVisibleMonth: (String) -> Unit = {},
    bottomInset: Dp = 84.dp,
    onMine: ((String, UnitKey, Boolean) -> Unit)? = null,
    doctors: Boolean = false,          // stethoscope toggle → doctor line per ICU + an "On call tonight" row
    demo: Boolean = false,
) {
    val c = Theme.colors
    val unitColW = 92.dp
    val colW = 134.dp
    val headerH = 34.dp
    val rowCount = unitOrder.size + if (doctors) 1 else 0
    // Fit all units on screen: divide the leftover height across the rows (no vertical scroll).
    val rowH = max(28f, (availHeight - headerH - bottomInset).value / rowCount.coerceAtLeast(1)).dp
    val gridH = headerH + rowH * rowCount

    val listState = rememberLazyListState()
    LaunchedEffect(scrollTo, scrollTick, days.size) {
        val idx = days.indexOf(scrollTo)
        if (idx >= 0) listState.scrollToItem(idx)
    }
    LaunchedEffect(listState.firstVisibleItemIndex, days.size) {
        days.getOrNull(listState.firstVisibleItemIndex)?.let { onVisibleMonth(monthLabelFull(it)) }
    }
    // Back to portrait → restore the normal title.
    val clearMonth by rememberUpdatedState(onVisibleMonth)
    DisposableEffect(Unit) { onDispose { clearMonth("") } }

    Row(Modifier.fillMaxWidth().height(gridH).padding(top = 4.dp)) {
        // Fixed unit column on the left.
        Column(Modifier.width(unitColW).height(gridH).background(c.panel)) {
            Box(Modifier.height(headerH))
            unitOrder.forEach { u ->
                val info = Units.info[u]
                Row(
                    Modifier.width(unitColW).height(rowH).padding(start = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    Box(
                        Modifier.width(5.dp).height(26.dp)
                            .clip(RoundedCornerShape(2.dp))
                            .background(info?.color ?: Color.Gray)
                    )
                    Text(
                        info?.short ?: u.name, fontSize = fixedSp(12.5f), fontWeight = FontWeight.Bold, color = c.ink,
                        maxLines = 2, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (doctors) {
                Row(
                    Modifier.width(unitColW).height(rowH).padding(start = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Icon(Icons.Filled.Bedtime, contentDescription = null, tint = Indigo, modifier = Modifier.size(12.dp))
                    Text(
                        "On call\ntonight", fontSize = fixedSp(12f), lineHeight = fixedSp(14f), fontWeight = FontWeight.Bold,
                        color = c.ink, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        Box(Modifier.width(1.dp).height(gridH).background(c.line))

        // Day columns — scroll horizontally.
        LazyRow(state = listState, modifier = Modifier.fillMaxSize()) {
            items(days.size, key = { days[it] }) { i ->
                DayColumn(
                    days[i], byDay[days[i]].orEmpty(), days[i] == todayISO, unitOrder, colW, headerH, rowH, gridH,
                    mineActionable = days[i] >= todayISO, onMine = onMine, doctors = doctors, demo = demo,
                )
            }
        }
    }
}

@Composable
private fun DayColumn(
    day: String,
    people: List<Assignment>,
    isToday: Boolean,
    unitOrder: List<UnitKey>,
    colW: Dp, headerH: Dp, rowH: Dp, gridH: Dp,
    mineActionable: Boolean,
    onMine: ((String, UnitKey, Boolean) -> Unit)?,
    doctors: Boolean,
    demo: Boolean,
) {
    val c = Theme.colors
    val context = LocalContext.current
    val byUnit = people.groupBy { it.unit }
    if (doctors) LaunchedEffect(day, demo) { DoctorRoster.ensure(context, day, demo) }
    Column(
        Modifier.width(colW).height(gridH)
            .background(if (isToday) c.accent.copy(alpha = 0.14f) else Color.Transparent),
    ) {
        Column(
            Modifier.width(colW).height(headerH - 4.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(if (isToday) c.accent else c.panel.copy(alpha = 0.5f)),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            val fg = if (isToday) Color.White else c.ink.copy(alpha = 0.7f)
            Text(weekday(day), fontSize = fixedSp(10.5f), fontWeight = FontWeight.SemiBold, color = fg)
            Text(dayNum(day), fontSize = fixedSp(17f), fontWeight = FontWeight.ExtraBold, color = fg)
        }
        Box(Modifier.height(4.dp))
        unitOrder.forEach { u ->
            val d = if (doctors) DocTag.of(day, u, withPhone = false) else null
            Column(Modifier.width(colW).height(rowH - 1.dp)) {
                GridCell(
                    byUnit[u].orEmpty(), u, isToday, Modifier.fillMaxWidth().weight(1f),
                    onMine = if (mineActionable && onMine != null) { giveAway -> onMine(day, u, giveAway) } else null,
                )
                if (d != null) {
                    Row(
                        Modifier.fillMaxWidth().height(15.dp).padding(bottom = 2.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(3.dp, Alignment.CenterHorizontally),
                    ) {
                        Icon(
                            if (d.night) Icons.Filled.Bedtime else Icons.Filled.MedicalServices, contentDescription = null,
                            tint = if (d.night) Indigo else c.muted, modifier = Modifier.size(9.dp),
                        )
                        Text(
                            d.name, fontSize = fixedSp(10.5f), lineHeight = fixedSp(12f), fontWeight = FontWeight.SemiBold,
                            color = if (isToday) c.ink else c.ink.copy(alpha = 0.65f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
            Box(Modifier.width(colW).height(1.dp).background(c.line))
        }
        if (doctors) NightCell(day, isToday, Modifier.width(colW).height(rowH))
    }
}

/** Bottom row with the toggle on: tonight's intensivist (all ICUs) over tonight's cardiologist on call. */
@Composable
private fun NightCell(day: String, isToday: Boolean, modifier: Modifier) {
    val c = Theme.colors
    val ink = if (isToday) c.ink else c.ink.copy(alpha = 0.7f)
    Column(
        modifier.background(Indigo.copy(alpha = if (isToday) 0.14f else 0.05f)),
        verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        DoctorRoster.night(day)?.let { n ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                Icon(Icons.Filled.Bedtime, contentDescription = "ICU tonight", tint = Indigo, modifier = Modifier.size(10.dp))
                Text(
                    n.name, fontSize = fixedSp(12f), lineHeight = fixedSp(14f), fontWeight = FontWeight.Bold, color = ink,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
        DoctorRoster.name(day, "CCU", "oncall")?.let { n ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                Icon(
                    Icons.Filled.Favorite, contentDescription = "Cardiology on call",
                    tint = Units.info[UnitKey.CCU]?.color ?: Color.Red, modifier = Modifier.size(9.dp),
                )
                Text(
                    n, fontSize = fixedSp(11f), lineHeight = fixedSp(13f), fontWeight = FontWeight.SemiBold, color = ink,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun GridCell(
    people: List<Assignment>,
    unit: UnitKey,
    isToday: Boolean,
    modifier: Modifier,
    onMine: ((Boolean) -> Unit)?,
) {
    val haptics = LocalHapticFeedback.current
    val info = Units.info[unit]
    val color = info?.color ?: Color.Gray
    // Collapse a doctor's day/night segments to one name (kills "Du Toit / Du Toit" and the shrinking).
    val seen = HashSet<String>()
    val names = ArrayList<Pair<String, Boolean>>()
    for (a in people.sortedBy { it.start }) {
        val nm = surname(a.doc)
        if (seen.add(nm)) names.add(nm to a.isMe)
    }
    if (names.isEmpty()) { Box(modifier); return }

    Column(
        modifier.padding(horizontal = 4.dp, vertical = 3.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        // Names SHARE the row height equally so a cell with two or three doctors never spills into the row below.
        names.forEach { (name, isMe) ->
            val actionable = isMe && onMine != null          // long-press my own upcoming cell → act
            var menu by remember(name) { mutableStateOf(false) }
            Box(
                Modifier.fillMaxWidth().weight(1f)
                    .clip(RoundedCornerShape(5.dp))
                    .background(if (isMe) color else color.copy(alpha = if (isToday) 0.46f else 0.14f))
                    .then(
                        if (!actionable) Modifier else Modifier.pointerInput(Unit) {
                            detectTapGestures(onLongPress = {
                                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                                menu = true
                            })
                        }
                    ),
                contentAlignment = Alignment.Center,
            ) {
                if (actionable) MineMenu(menu, { menu = false }) { giveAway -> onMine?.invoke(giveAway) }
                Text(
                    name,
                    fontSize = fixedSp(if (isToday) 14.5f else 13f),
                    fontWeight = if (isMe) FontWeight.ExtraBold else if (isToday) FontWeight.Bold else FontWeight.SemiBold,
                    color = if (isMe || isToday) Color.White else color,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
                )
            }
        }
    }
}

// ── Floating day panel (My Shifts → double-tap a date) ────────────────────────

/** Where the panel was last dragged to — kept while the app is open, so it reopens in the same spot. */
private var lastPanelOffset = Offset.Zero

/**
 * A small draggable card over My Shifts showing who's working one day — sized to its content so the calendar
 * stays visible underneath. Drag the header to move it; pass another [iso] (while open) to retarget it.
 *
 * Put it LAST inside the Box that holds the calendar: it fills that Box (touches outside the card fall through
 * to the calendar) and keeps the card clamped inside it, starting at the bottom centre.
 */
@Composable
fun WhoDayPanel(
    vm: AppViewModel,
    iso: String,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    unitOrder: List<UnitKey>? = null,      // null → the saved "Who's On order"
) {
    val c = Theme.colors
    val context = LocalContext.current
    val order = unitOrder ?: Prefs.get(context).unitOrder
    val isToday = iso == AppViewModel.todayRegina()
    val byDay = vm.whoByDay
    val rows = remember(byDay, iso, order) {
        fun ord(u: UnitKey) = order.indexOf(u).takeIf { it >= 0 } ?: 99
        byDay[iso].orEmpty().sortedWith(compareBy({ ord(it.unit) }, { it.start }))
    }
    var offset by remember { mutableStateOf(lastPanelOffset) }   // from bottom-centre, in px
    var size by remember { mutableStateOf(IntSize.Zero) }
    val shape = RoundedCornerShape(14.dp)

    LaunchedEffect(byDay.isEmpty()) { if (byDay.isEmpty()) vm.loadGroupHistory() }

    BoxWithConstraints(modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        val boundsW = constraints.maxWidth.toFloat()
        val boundsH = constraints.maxHeight.toFloat()
        val width = minOf(if (maxWidth > maxHeight) 340.dp else 300.dp, maxWidth - 24.dp)
        val maxRowsH = maxOf(120.dp, maxHeight * 0.55f - 64.dp)     // ~55% of the screen incl. header
        val sidePx = with(LocalDensity.current) { 8.dp.toPx() }
        val topPx = sidePx * 3

        // Keep the card inside the calendar area: x within the side margins, y between the bottom and the top.
        fun clamp(o: Offset): Offset {
            val maxX = max(0f, (boundsW - size.width) / 2 - sidePx)
            val maxUp = max(0f, boundsH - size.height - topPx)
            return Offset(o.x.coerceIn(-maxX, maxX), o.y.coerceIn(-maxUp, 0f))
        }

        Column(
            Modifier.padding(bottom = 12.dp)
                .offset { clamp(offset).let { IntOffset(it.x.roundToInt(), it.y.roundToInt()) } }
                .width(width)
                .onSizeChanged { size = it }
                .shadow(16.dp, shape)
                .clip(shape)
                .background(c.panel)
                .border(1.dp, c.line, shape)
                .pointerInput(Unit) { detectTapGestures { } }       // taps on the card never reach the calendar beneath
                .padding(start = 12.dp, end = 12.dp, top = 6.dp, bottom = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Grab bar + date + close. The whole header is the drag handle.
            Column(
                Modifier.fillMaxWidth().pointerInput(boundsW, boundsH) {
                    detectDragGestures(
                        onDragEnd = { offset = clamp(offset); lastPanelOffset = offset },
                        onDragCancel = { offset = clamp(offset); lastPanelOffset = offset },
                    ) { change, drag ->
                        change.consume()
                        offset = clamp(offset + drag)
                    }
                },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Box(Modifier.width(34.dp).height(4.dp).clip(RoundedCornerShape(50)).background(c.muted.copy(alpha = 0.35f)))
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        weekday(iso), fontSize = 14.sp, fontWeight = FontWeight.ExtraBold,
                        color = if (isToday) c.accent else c.ink,
                    )
                    Text(fmt(iso, "d MMM"), fontSize = 14.sp, color = c.muted)
                    if (isToday) {
                        Text(
                            "TODAY", fontSize = 9.sp, fontWeight = FontWeight.ExtraBold, color = Color.White,
                            modifier = Modifier.clip(RoundedCornerShape(50)).background(c.accent)
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
                    Box(Modifier.weight(1f))
                    Box(
                        Modifier.size(26.dp).clip(CircleShape).background(c.muted.copy(alpha = 0.18f))
                            .pointerInput(Unit) { detectTapGestures { onClose() } }
                            .semantics { contentDescription = "Close" },
                        contentAlignment = Alignment.Center,
                    ) { Text("✕", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = c.muted) }
                }
            }

            when {
                byDay.isEmpty() -> Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    CircularProgressIndicator(Modifier.size(14.dp), color = c.accent, strokeWidth = 2.dp)
                    Text("Loading who's on…", fontSize = 12.sp, color = c.muted)
                }
                rows.isEmpty() -> Text("No one scheduled", fontSize = 12.sp, color = c.muted)
                // The card hugs its rows; past the cap the same rows scroll inside it.
                else -> Column(
                    Modifier.heightIn(max = maxRowsH).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(5.dp),
                ) { rows.forEach { PanelRow(it) } }
            }
        }
    }
}

/** Compact version of the Who's On row: unit, name, hours; my own shift on the solid unit colour. */
@Composable
private fun PanelRow(a: Assignment) {
    val c = Theme.colors
    val info = Units.info[a.unit]
    val color = info?.color ?: Color.Gray
    Row(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(9.dp))
            .background(color.copy(alpha = if (a.isMe) 1f else 0.12f))
            .padding(vertical = 6.dp, horizontal = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            info?.short ?: a.unit.name, fontSize = 11.sp, fontWeight = FontWeight.Bold,
            color = if (a.isMe) Color.White.copy(alpha = 0.92f) else color,
            modifier = Modifier.width(78.dp), maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        Text(
            a.doc, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
            color = if (a.isMe) Color.White else c.ink,
            modifier = Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
        Text(
            "${a.start}–${a.end}", fontSize = 11.sp, maxLines = 1,
            color = if (a.isMe) Color.White.copy(alpha = 0.8f) else c.muted,
        )
    }
}
