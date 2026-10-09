package com.nvdberg.workingbolt.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.time.LocalDate

/**
 * Bird's-eye mini month grid (like the web pool sidebar): my shifts in unit colour, post-call days
 * lighter, open-shift days ringed in amber, today outlined.
 */
@Composable
fun MiniMonth(
    year: Int,
    month: Int,                       // 1..12
    fill: Map<Int, Color>,            // day-of-month -> shift colour
    post: Map<Int, Color>,            // day-of-month -> post-call (lighter)
    open: Set<Int>,                   // day-of-month with an open shift
    todayDay: Int?,                   // day-of-month if today falls in this month
    fuseStart: Set<Int> = emptySet(), // on-call days that fuse into the next (post-call) day
    fuseEnd: Set<Int> = emptySet(),   // post-call days that continue from the previous day
) {
    val c = Theme.colors
    val first = LocalDate.of(year, month, 1)
    val weekStart = Prefs.get(LocalContext.current).weekStart   // 0 = Sunday, 1 = Monday
    val firstWeekday = weekCol(first, weekStart)        // leading pad under the chosen week start
    val days = first.lengthOfMonth()
    val dow = dowLetters(weekStart)

    Column(
        modifier = Modifier
            .width(176.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(c.panel)
            .padding(9.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(
            "${fmt(first.toString(), "MMM")} $year",
            fontSize = 11.sp, fontWeight = FontWeight.Bold, color = c.ink,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            dow.forEach { d ->
                Text(d, fontSize = fixedSp(8f), color = c.muted, modifier = Modifier.weight(1f))
            }
        }
        // Fixed week rows — a plain Column of Rows measures exactly, unlike a lazy grid.
        val slots: List<Int?> = List(firstWeekday) { null } + (1..days).toList()
        val padded = slots + List((7 - slots.size % 7) % 7) { null }
        padded.chunked(7).forEach { week ->
            Row(horizontalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.fillMaxWidth()) {
                week.forEach { d ->
                    if (d == null) {
                        Box(Modifier.weight(1f).height(17.dp))
                    } else {
                        // Never fuse across a week-row break: the caller's sets assume a Sunday start.
                        val col = (firstWeekday + d - 1) % 7
                        MiniDay(
                            day = d, filled = fill[d], postColor = post[d], isOpen = d in open,
                            isToday = todayDay == d,
                            fuseRight = d in fuseStart && col < 6, fuseLeft = d in fuseEnd && col > 0,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun MiniDay(
    day: Int,
    filled: Color?,
    postColor: Color?,
    isOpen: Boolean,
    isToday: Boolean,
    fuseRight: Boolean,
    fuseLeft: Boolean,
    modifier: Modifier = Modifier,
) {
    val c = Theme.colors
    Box(modifier.height(17.dp), contentAlignment = Alignment.Center) {
        when {
            // on-call bleeds right to meet post-call
            filled != null -> Box(
                Modifier.matchParentSizeSafe()
                    .clip(cornerShape(fuseRight = fuseRight))
                    .background(filled)
            )
            // post-call: square left edge, no bleed (avoids overlap)
            postColor != null -> Box(
                Modifier.matchParentSizeSafe()
                    .clip(cornerShape(fuseLeft = fuseLeft))
                    .background(postColor.copy(alpha = 0.30f))
            )
        }
        if (isOpen) {
            Box(Modifier.matchParentSizeSafe().border(1.6.dp, c.available, RoundedCornerShape(4.dp)))
        }
        if (isToday) {
            Box(Modifier.matchParentSizeSafe().border(1.6.dp, c.accent, RoundedCornerShape(4.dp)))
        }
        Text(
            day.toString(),
            fontSize = fixedSp(9f),
            fontWeight = if (filled != null) FontWeight.Bold else FontWeight.Normal,
            color = if (filled != null) Color.White else c.muted,
        )
    }
}

private fun cornerShape(fuseLeft: Boolean = false, fuseRight: Boolean = false) = RoundedCornerShape(
    topStart = if (fuseLeft) 0.dp else 4.dp,
    bottomStart = if (fuseLeft) 0.dp else 4.dp,
    topEnd = if (fuseRight) 0.dp else 4.dp,
    bottomEnd = if (fuseRight) 0.dp else 4.dp,
)

/** `matchParentSize` is only available inside a BoxScope; this keeps the call sites readable. */
private fun Modifier.matchParentSizeSafe(): Modifier = this.then(Modifier.fillMaxWidth().height(17.dp))
