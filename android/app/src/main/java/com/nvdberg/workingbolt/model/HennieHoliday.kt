package com.nvdberg.workingbolt.model

import java.time.LocalDate

/** A run of consecutive days off. */
data class HolidayRun(val start: String, val end: String, val days: Int)

/**
 * Your next run of 4+ days off in a row, from today to the end of the loaded roster. You know the one.
 * Mirrors `nextHennieHoliday` in Quips.swift.
 */
fun nextHennieHoliday(shifts: List<MyShift>, today: String): HolidayRun? {
    val worked = shifts.map { it.date }.toHashSet()
    val start = runCatching { LocalDate.parse(today) }.getOrNull() ?: return null
    val lastShift = shifts.maxOfOrNull { it.date } ?: return null
    val last = runCatching { LocalDate.parse(lastShift) }.getOrNull() ?: return null
    if (start.isAfter(last)) return null

    var runStart: LocalDate? = null
    var d = start
    while (!d.isAfter(last)) {
        if (d.toString() in worked) {
            runStart?.let { rs ->
                val days = (d.toEpochDay() - rs.toEpochDay()).toInt()    // rs ..< d
                if (days >= 4) return HolidayRun(rs.toString(), d.minusDays(1).toString(), days)
            }
            runStart = null
        } else if (runStart == null) {
            runStart = d
        }
        d = d.plusDays(1)
    }
    return null
}
