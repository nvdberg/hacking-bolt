package com.nvdberg.workingbolt.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nvdberg.workingbolt.AppViewModel
import com.nvdberg.workingbolt.model.ConflictEngine
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.UnitKey
import com.nvdberg.workingbolt.model.Units
import java.time.LocalDate
import java.util.Locale

/**
 * A one-month, tappable calendar used by the Swap screen: my own shifts as coloured blocks (post-call
 * faded, matching the My Shifts grid), plus optional small squares marking units I could swap into.
 * Future-only — past months can't be paged to.
 */
@Composable
fun SwapCalendar(
    offset: Int,
    onOffset: (Int) -> Unit,
    months: Int,
    myShifts: List<MyShift>,
    availByDay: Map<String, List<UnitKey>>,
    selectedISO: String?,
    tappable: (String) -> Boolean,
    onTap: (String) -> Unit,
) {
    val c = Theme.colors
    val weekStart = Prefs.get(LocalContext.current).weekStart   // Sunday/Monday, same as the other month grids
    val today = AppViewModel.todayRegina()
    val base = LocalDate.parse("${today.take(7)}-01").plusMonths(offset.toLong())
    val key = String.format(Locale.ROOT, "%04d-%02d", base.year, base.monthValue)   // ASCII digits on any locale
    val firstWeekday = weekCol(base, weekStart)
    val days = base.lengthOfMonth()

    // My shifts for this month: bright on the worked day, faded on the post-call morning after (one pass).
    val (fill, post) = remember(myShifts, key) {
        val fill = HashMap<Int, Color>()
        val post = HashMap<Int, Color>()
        fun dayOf(iso: String) = iso.takeLast(2).toIntOrNull()
        for (s in myShifts) {
            if (s.date.startsWith(key)) dayOf(s.date)?.let { fill[it] = Units.color(s.unit) }
            if (s.overnight) {
                val nd = ConflictEngine.addDay(s.date)
                if (nd.startsWith(key)) dayOf(nd)?.let { post[it] = Units.color(s.unit) }
            }
        }
        fill to post
    }

    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { onOffset(offset - 1) }, enabled = offset > 0) { Text("‹") }
            Text(
                monthLabelFull("$key-01"),
                fontSize = 14.sp, fontWeight = FontWeight.Bold, color = c.ink,
                modifier = Modifier.weight(1f), textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
            TextButton(onClick = { onOffset(offset + 1) }, enabled = offset < months - 1) { Text("›") }
        }
        Row {
            dowLetters(weekStart).forEach { d ->
                Text(d, fontSize = fixedSp(9f), color = c.muted, modifier = Modifier.weight(1f),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }
        }
        val slots: List<Int?> = List(firstWeekday) { null } + (1..days).toList()
        val padded = slots + List((7 - slots.size % 7) % 7) { null }
        padded.chunked(7).forEach { week ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                week.forEach { d ->
                    if (d == null) {
                        Box(Modifier.weight(1f).height(40.dp))
                    } else {
                        val iso = String.format(Locale.ROOT, "%s-%02d", key, d)
                        SwapDayCell(
                            day = d, iso = iso,
                            fill = fill[d], post = post[d],
                            avail = availByDay[iso].orEmpty(),
                            selected = selectedISO == iso,
                            enabled = tappable(iso),
                            onTap = { onTap(iso) },
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun SwapDayCell(
    day: Int,
    iso: String,
    fill: Color?,
    post: Color?,
    avail: List<UnitKey>,
    selected: Boolean,
    enabled: Boolean,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val c = Theme.colors
    Column(
        modifier
            .height(40.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(
                when {
                    fill != null -> fill
                    post != null -> post.copy(alpha = 0.30f)
                    else -> Color.Transparent
                }
            )
            .border(
                if (selected) 2.dp else 1.dp,
                if (selected) c.accent else c.line,
                RoundedCornerShape(6.dp),
            )
            .clickable(enabled = enabled, onClick = onTap)
            .padding(2.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        Text(
            "$day",
            fontSize = fixedSp(10f),
            fontWeight = if (fill != null || avail.isNotEmpty()) FontWeight.Bold else FontWeight.Normal,
            color = when {
                fill != null -> Color.White
                avail.isNotEmpty() -> c.accent      // a teal number = swaps available here
                else -> c.muted
            },
        )
        // Small squares: the distinct units I could swap into that day.
        Row(horizontalArrangement = Arrangement.spacedBy(1.5.dp)) {
            avail.take(4).forEach { u ->
                Box(Modifier.size(5.dp).clip(RoundedCornerShape(1.dp)).background(Units.color(u)))
            }
        }
    }
}
