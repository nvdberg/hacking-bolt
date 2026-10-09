package com.nvdberg.workingbolt.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.KingBed
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.nvdberg.workingbolt.data.Supabase
import com.nvdberg.workingbolt.model.UnitKey
import com.nvdberg.workingbolt.model.Units
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.time.LocalDate

// ── Doctors on call (Who's On → stethoscope toggle) ───────────────────────────
//
// Intensivists come from PetalMD, cardiology from the monthly RGH PDF — both captured on the Unit Board from the
// hospital network into Supabase `oncall_roster` (date, unit, role, name). The app only reads it. Names are
// never hard-coded or logged here (public repo); demo mode uses made-up tree names.

/** Night-time accent for the on-call bits (SwiftUI's indigo). */
val Indigo = Color(0xFF5E5CE6)

/** Read-through cache of `oncall_roster`, kept on disk so the card still shows the last good read offline. */
object DoctorRoster {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    var byDate by mutableStateOf<Map<String, List<Supabase.RosterRow>>>(emptyMap())
        private set
    private val fetchedAt = HashMap<String, Long>()      // month "YYYY-MM" → when this run last read it (re-read after 10 min)
    private val inflight = HashMap<String, Job>()           // month → the read in progress (rows join it)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var file: File? = null
    private var demoLoaded = false

    private fun open(context: Context) {
        if (file != null) return
        val f = File(context.applicationContext.cacheDir, "wb_oncall.json")
        file = f
        runCatching { json.decodeFromString<List<Supabase.RosterRow>>(f.readText()) }.getOrNull()
            ?.let { rows -> if (rows.isNotEmpty()) byDate = rows.groupBy { it.date } }
    }

    /**
     * Make sure the month around [iso] is loaded (± a week, so the "in CCU" Friday is there too). One read per
     * month per 10 min, however many rows ask. A failed read keeps whatever we had.
     */
    suspend fun ensure(context: Context, iso: String, demo: Boolean) {
        if (demo) {
            // Sample mode never touches the disk cache or the network; start from a clean, invented roster.
            val base = if (demoLoaded) byDate else emptyMap()
            demoLoaded = true
            val day = isoDate(iso) ?: return
            val add = (-7L..7L).map { day.plusDays(it).toString() }.filter { it !in base }
            if (add.isNotEmpty() || base !== byDate) byDate = base + add.associateWith { demoRows(it) }
            return
        }
        if (demoLoaded) { demoLoaded = false; byDate = emptyMap(); file = null }   // left sample mode → drop the invented names
        open(context)
        val month = iso.take(7)
        inflight[month]?.let { it.join(); return }
        fetchedAt[month]?.let { if (System.currentTimeMillis() - it < 600_000) return }
        val first = isoDate("$month-01") ?: return
        // The read runs in the roster's own scope, not the row's: a row that scrolls away or a quick stethoscope
        // off/on cancels its LaunchedEffect, and a cancelled read used to leave every other row waiting on nothing.
        val job = scope.launch {
            try {
                val rows = Supabase.oncallRoster(first.minusDays(7).toString(), first.plusDays(38).toString()) ?: return@launch
                fetchedAt[month] = System.currentTimeMillis()
                byDate = byDate + rows.groupBy { it.date }            // only dates the server returned
                val all = byDate.values.flatten()
                val f = file
                if (f != null) withContext(Dispatchers.IO) { runCatching { f.writeText(json.encodeToString(all)) } }
            } finally {
                inflight.remove(month)
            }
        }
        inflight[month] = job
        job.join()
    }

    val icuUnits = listOf("SICU", "MICU", "PHICU")

    class Night(val name: String, val home: String?, val second: List<String>)

    /**
     * Tonight's intensivist: ONE person covers all the ICUs overnight (the name on most on-call rows); any other
     * on-call name is 2nd call (mass event only). `home` = the unit that person works by day, if any.
     */
    fun night(iso: String): Night? {
        val order = ArrayList<String>()
        val count = HashMap<String, Int>()
        for (u in icuUnits) {
            val n = name(iso, u, "oncall") ?: continue
            if (n !in count) order.add(n)
            count[n] = (count[n] ?: 0) + 1
        }
        val ranked = order.withIndex().sortedWith(compareBy({ -(count[it.value] ?: 0) }, { it.index })).map { it.value }
        val top = ranked.firstOrNull() ?: return null
        return Night(top, icuUnits.firstOrNull { name(iso, it, "day") == top }, ranked.drop(1))
    }

    /**
     * The cardiologist physically in CCU: an explicit `ccu` row if the board ever stores one, else the cardiologist
     * on the Friday that starts this Fri → Thu week.
     */
    fun inCCU(iso: String): String? {
        name(iso, "CCU", "ccu")?.let { return it }
        val d = isoDate(iso) ?: return null
        val dow = d.dayOfWeek.value % 7 + 1                      // 1 = Sunday … 6 = Friday
        return name(d.minusDays(((dow + 1) % 7).toLong()).toString(), "CCU", "day")
    }

    fun name(iso: String, unit: String, role: String): String? =
        byDate[iso]?.firstOrNull { it.unit == unit && it.role == role }?.name?.takeIf { it.isNotBlank() }

    fun has(iso: String, unit: String): Boolean = byDate[iso]?.any { it.unit == unit } ?: false

    // Sample data for the no-login preview — invented names only.
    private fun demoRows(iso: String): List<Supabase.RosterRow> {
        val trees = listOf("Maple", "Birch", "Cedar", "Aspen", "Willow", "Rowan", "Alder", "Spruce", "Larch", "Poplar")
        val n = (isoDate(iso) ?: LocalDate.now()).dayOfYear
        fun t(k: Int) = trees[(n + k) % trees.size]
        fun r(unit: String, role: String, k: Int) = Supabase.RosterRow(iso, unit, role, t(k))
        return listOf(
            r("SICU", "day", 0), r("SICU", "oncall", 1),
            r("MICU", "day", 1), r("MICU", "oncall", 1),
            r("PHICU", "day", 2), r("PHICU", "oncall", 8),
            r("CCU", "day", 4), r("CCU", "oncall", 4),
            r("CCU", "stemi_day", 5), r("CCU", "stemi_oncall", 6),
            r("CCU", "consults", 7),
        )
    }
}

/** The doctor shown beside a unit's first CCA row (Who's On, stethoscope toggle on). */
class DocTag(
    val name: String,
    val sub: String,          // the on-call intensivist's number, or "in CCU"
    val night: Boolean,       // this intensivist is also on call tonight for all the ICUs
) {
    companion object {
        // On-call intensivist numbers, per ICU.
        val phones = mapOf(UnitKey.SICU to "4268", UnitKey.MICU to "4265", UnitKey.PHICU to "4249")
        // The units' own desk numbers, and the CCA call rooms (one bar under the title while the toggle is on).
        val unitPhones = mapOf(UnitKey.SICU to "3990", UnitKey.MICU to "4291", UnitKey.CCU to "4266", UnitKey.PHICU to "8555")
        val callRooms = mapOf(UnitKey.SICU to "3971", UnitKey.MICU to "4823", UnitKey.CCU to "4241", UnitKey.PHICU to "8556")
        const val wardsRoom = "2417"           // Pasqua wards CCA call room

        /** The tag for [unit]'s first row on [day]: that day's intensivist (ICUs) or who's in CCU this week. */
        fun of(day: String, unit: UnitKey, withPhone: Boolean = true): DocTag? {
            if (unit == UnitKey.CCU) return DoctorRoster.inCCU(day)?.let { DocTag(it, "in CCU", false) }
            val phone = phones[unit] ?: return null
            val n = DoctorRoster.name(day, unit.name, "day") ?: return null
            return DocTag(n, if (withPhone) phone else "", DoctorRoster.night(day)?.name == n)
        }
    }
}

/**
 * The units' desk numbers with the CCA call room under each, once, under the Who's On title while the stethoscope
 * toggle is on — they don't change by day, so they stay out of the roster rows.
 */
@Composable
fun UnitPhonesBar(unitOrder: List<UnitKey>) {
    val c = Theme.colors
    val shape = RoundedCornerShape(14.dp)
    Row(
        Modifier.padding(start = 14.dp, end = 14.dp, top = 4.dp, bottom = 6.dp)
            .fillMaxWidth().clip(shape).background(c.panel).border(1.dp, c.line, shape)
            .padding(6.dp)
            .semantics(mergeDescendants = true) { contentDescription = "Unit phone numbers and CCA call rooms" },
        verticalAlignment = Alignment.Top,
    ) {
        unitOrder.filter { it in DocTag.unitPhones }.forEach { u ->
            val info = Units.info[u]
            PhoneColumn(info?.short ?: u.name, info?.color ?: Color.Gray, DocTag.unitPhones[u], DocTag.callRooms[u], Modifier.weight(1f))
        }
        PhoneColumn("Wards", Units.info[UnitKey.PRR]?.color ?: Color(0xFF41A00E), null, DocTag.wardsRoom, Modifier.weight(1f))
    }
}

/** Unit + desk number on top; the call room (bed) underneath, smaller. */
@Composable
private fun PhoneColumn(label: String, tint: Color, desk: String?, room: String?, modifier: Modifier) {
    val c = Theme.colors
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(label, fontSize = fixedSp(11f), fontWeight = FontWeight.Bold, color = tint, maxLines = 1)
            if (desk != null) {
                Text(desk, fontSize = fixedSp(11f), fontWeight = FontWeight.Medium, color = c.ink.copy(alpha = 0.7f), maxLines = 1)
            }
        }
        if (room != null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                Icon(Icons.Filled.KingBed, contentDescription = "Call room", tint = c.muted, modifier = Modifier.size(10.dp))
                Text(room, fontSize = fixedSp(10f), fontWeight = FontWeight.Medium, color = c.muted, maxLines = 1)
            }
        }
    }
}

/**
 * Closes each day in Who's On when the stethoscope toggle is on: who's on call overnight. One intensivist covers
 * every ICU after 17:00; cardiology lists the daytime name, then the evening one circled.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun OnCallStrip(day: String, isToday: Boolean) {
    val c = Theme.colors
    val night = DoctorRoster.night(day)
    val hasCCU = DoctorRoster.has(day, "CCU")
    if (night == null && !hasCCU) return
    val ccu = Units.info[UnitKey.CCU]?.color ?: Color.Red
    val shape = RoundedCornerShape(11.dp)

    Column(
        Modifier.fillMaxWidth().alpha(if (isToday) 1f else 0.85f)
            .clip(shape).background(Indigo.copy(alpha = if (isToday) 0.10f else 0.04f)).border(1.dp, c.line, shape)
            .padding(vertical = 9.dp, horizontal = 12.dp),
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        if (night != null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                // Icon only — the moon / heart carry the meaning and leave the width to the names.
                Icon(Icons.Filled.Bedtime, contentDescription = "ICU tonight", tint = Indigo, modifier = Modifier.size(14.dp))
                Circled(night.name, Indigo)
                if (night.second.isNotEmpty()) {
                    Text(
                        "2nd " + night.second.joinToString(", "), fontSize = 11.sp, color = c.muted,
                        maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        if (hasCCU) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Icon(
                    Icons.Filled.Favorite, contentDescription = "Cardiology", tint = ccu,
                    modifier = Modifier.padding(top = 2.dp).size(14.dp),
                )
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    // ♥ = who's in the CCU unit this week (Fri → Thu), then the 8–5 consults.
                    val inCCU = DoctorRoster.inCCU(day)
                    val consult = DoctorRoster.name(day, "CCU", "consults")
                    if (inCCU != null || consult != null) {
                        FlowRow(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            if (inCCU != null) DocName(inCCU)                  // the ♥ says "in CCU"
                            if (consult != null) Tagged("Consults 8–5", ccu) { DocName(consult) }
                        }
                    }
                    // RGH cardiology on call — second line (wraps to two when the surnames are long).
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Tagged("On call", ccu) {
                            DocPair(DoctorRoster.name(day, "CCU", "day"), DoctorRoster.name(day, "CCU", "oncall"), ccu)
                        }
                        Tagged("STEMI", ccu) {
                            DocPair(DoctorRoster.name(day, "CCU", "stemi_day"), DoctorRoster.name(day, "CCU", "stemi_oncall"), ccu)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Tagged(tag: String, tint: Color, content: @Composable () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(tag, fontSize = 11.sp, fontWeight = FontWeight.Bold, color = tint, maxLines = 1)
        content()
    }
}

/** Daytime name, then the evening (17:00 →) name circled; one circled name when it's the same person. */
@Composable
private fun DocPair(day: String?, night: String?, tint: Color) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        if (day != null && day != night) DocName(day)
        if (night != null) Circled(night, tint)
        if (day == null && night == null) Text("—", fontSize = 13.sp, color = Theme.colors.muted)
    }
}

@Composable
private fun DocName(s: String) {
    Text(s, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Theme.colors.ink, maxLines = 1)
}

@Composable
private fun Circled(s: String, tint: Color) {
    Row(Modifier.border(1.3.dp, tint, RoundedCornerShape(50)).padding(horizontal = 5.dp, vertical = 1.dp)) { DocName(s) }
}
