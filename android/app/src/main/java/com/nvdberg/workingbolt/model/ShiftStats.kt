package com.nvdberg.workingbolt.model

import androidx.compose.ui.graphics.Color
import java.time.LocalDate
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * A tally of the logged-in person's shifts over a date range: totals, per-month averages, and the
 * breakdown by shift length (24h / 12h / 9h / …) and by unit (CCU / SICU / …). Computed from the
 * durable shift log (`AppViewModel.shiftLog`), which keeps past shifts on file permanently.
 */
data class ShiftStats(
    val count: Int,
    val totalHours: Double,
    val months: Double,
    val byLength: List<LenBucket>,   // sorted longest → shortest
    val byUnit: List<UnitBucket>,    // sorted most → least
    val nights: Int,                 // overnight shifts
    val weekends: Int,               // shifts starting on Sat/Sun
) {
    val avgShiftsPerMonth: Double get() = if (months > 0) count / months else 0.0
    val avgHoursPerMonth: Double get() = if (months > 0) totalHours / months else 0.0

    data class LenBucket(val hours: Int, val count: Int, val totalHours: Double) {
        val label: String get() = "${hours}h"
    }

    data class UnitBucket(val name: String, val color: Color, val count: Int, val hours: Double)

    companion object {
        fun hours(s: MyShift): Double {
            val iv = ConflictEngine.interval(s.date, s.start, s.end, s.overnight)
            return (iv.e - iv.s) / 60.0
        }

        fun isWeekend(iso: String): Boolean {
            val d = runCatching { LocalDate.parse(iso) }.getOrNull() ?: return false
            return d.dayOfWeek.value >= 6      // 6 = Saturday, 7 = Sunday
        }

        /** Rounded hours, the way every card prints them. */
        fun hoursStr(h: Double): String = h.roundToInt().toString()

        fun compute(shifts: List<MyShift>, from: String, to: String): ShiftStats {
            val inRange = shifts.filter { it.date in from..to }
            var total = 0.0
            var nights = 0
            var weekends = 0
            var count = 0
            val lenMap = HashMap<Int, Pair<Int, Double>>()
            val unitMap = LinkedHashMap<String, UnitBucket>()

            fun addLen(hr: Int, h: Double) {
                val v = lenMap[hr] ?: (0 to 0.0)
                lenMap[hr] = (v.first + 1) to (v.second + h)
            }

            fun addUnit(key: String, name: String, color: Color, h: Double) {
                val v = unitMap[key] ?: UnitBucket(name, color, 0, 0.0)
                unitMap[key] = v.copy(count = v.count + 1, hours = v.hours + h)
            }

            // Process per day so a Pasqua Rapid Response (day) + Pasqua-MSU (night) on the SAME day counts
            // as ONE combined 24h shift ("Pasqua Rapid+MSU"), not two short ones.
            for ((d, dayShifts) in inRange.groupBy { it.date }) {
                val remaining = dayShifts.toMutableList()
                val prr = remaining.firstOrNull { it.unit == UnitKey.PRR }
                val msu = remaining.firstOrNull { it.unit == UnitKey.MSU }
                if (prr != null && msu != null) {
                    remaining.remove(prr)
                    remaining.remove(msu)
                    val h = hours(prr) + hours(msu)
                    count++; total += h; nights++
                    if (isWeekend(d)) weekends++
                    addLen(24, h)                                                    // one combined 24h shift
                    addUnit("PRR+MSU", "Pasqua Rapid+MSU", Units.color(UnitKey.PRR), h)
                }
                for (s in remaining) {
                    val h = hours(s)
                    count++; total += h
                    if (s.overnight) nights++
                    if (isWeekend(d)) weekends++
                    addLen(h.roundToInt(), h)
                    addUnit(s.unit.name, Units.short(s.unit), Units.color(s.unit), h)
                }
            }

            val startOrd = ConflictEngine.ordinal(from)
            val endOrd = ConflictEngine.ordinal(to)
            val months = max(1.0, (endOrd - startOrd + 1) / 30.4375)

            val byLength = lenMap.map { (hr, v) -> LenBucket(hr, v.first, v.second) }
                .sortedByDescending { it.hours }
            val byUnit = unitMap.values.sortedWith(
                compareByDescending<UnitBucket> { it.count }.thenByDescending { it.hours }
            )
            return ShiftStats(count, total, months, byLength, byUnit, nights, weekends)
        }
    }
}

/** "Brian Arnold" -> "B. Arnold" — disambiguates doctors who share a surname. */
fun initialSurname(name: String): String {
    val parts = name.split(" ").filter { it.isNotBlank() }
    if (parts.size < 2) return name
    return "${parts.first().first()}. ${parts.drop(1).joinToString(" ")}"
}
