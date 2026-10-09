package com.nvdberg.workingbolt.data

import com.nvdberg.workingbolt.model.ConflictEngine
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.UnitKey
import com.nvdberg.workingbolt.model.Units
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Exports the roster as an .ics (iCalendar) file for Google or Apple Calendar. Each shift is one event
 * titled with a coloured-square emoji + unit ("🟥 CCU") — no time in the title, since the event's own
 * start/end carries it. A 24h call runs 08:00 → 08:00 so it folds into the post-call morning (no separate
 * block); a Pasqua Rapid + MSU day merges into one 24h "Pasqua". Times are the shift's own, emitted in UTC
 * (Saskatchewan is UTC-6 year-round, no DST). Stable UIDs → re-exporting updates events instead of
 * duplicating. Mirrors `ICSExporter` in CalendarExport.swift.
 */
object ICSExporter {
    /** What the share sheet (and the calendar app that receives it) sees as the file name. */
    const val FILE_NAME = "Working-Bolt-shifts.ics"

    val emoji: Map<UnitKey, String> = mapOf(
        UnitKey.MICU to "🟩", UnitKey.SICU to "🟦", UnitKey.CCU to "🟥", UnitKey.PHICU to "🟢",
        UnitKey.RR to "🟧", UnitKey.PRR to "🟪", UnitKey.MSU to "🟪",
    )

    private val reginaTZ: ZoneId = runCatching { ZoneId.of("America/Regina") }.getOrDefault(ZoneOffset.UTC)
    private val utcFmt: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyyMMdd'T'HHmmss'Z'", Locale.US).withZone(ZoneOffset.UTC)

    /** Regina-local date+time → UTC "yyyyMMddThhmmssZ". */
    private fun utc(date: String, time: String): String {
        val instant = runCatching {
            // Hours/minutes are added rather than parsed as a LocalTime, so a "24:00" end still lands right.
            LocalDate.parse(date).atStartOfDay(reginaTZ)
                .plusHours(time.take(2).toLong()).plusMinutes(time.takeLast(2).toLong()).toInstant()
        }.getOrElse { Instant.now() }
        return utcFmt.format(instant)
    }

    private fun esc(s: String): String =
        s.replace("\\", "\\\\").replace(";", "\\;").replace(",", "\\,").replace("\n", "\\n")

    private fun vevent(
        date: String, start: String, end: String, overnight: Boolean, title: String, uid: String, stamp: String,
    ): List<String> {
        val endDate = if (overnight) ConflictEngine.addDay(date) else date
        return listOf(
            "BEGIN:VEVENT", "UID:$uid@working-bolt", "DTSTAMP:$stamp",
            "DTSTART:${utc(date, start)}", "DTEND:${utc(endDate, end)}",
            "SUMMARY:${esc(title)}", "END:VEVENT",
        )
    }

    fun ics(shifts: List<MyShift>): String {
        val stamp = utcFmt.format(Instant.now())
        val lines = arrayListOf(
            "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Working-Bolt//Shifts//EN",
            "CALSCALE:GREGORIAN", "METHOD:PUBLISH", "X-WR-CALNAME:Working-Bolt shifts",
        )
        val byDate = shifts.groupBy { it.date }
        val pasquaDone = HashSet<String>()
        for (s in shifts.sortedWith(compareBy({ it.date }, { it.start }))) {
            // Pasqua Rapid + MSU on the same day → one 24h "Pasqua"
            if (s.unit == UnitKey.PRR || s.unit == UnitKey.MSU) {
                val day = byDate[s.date].orEmpty()
                if (day.any { it.unit == UnitKey.PRR } && day.any { it.unit == UnitKey.MSU }) {
                    if (!pasquaDone.add(s.date)) continue
                    lines += vevent(
                        s.date, "08:00", "08:00", overnight = true,
                        title = "🟪 Pasqua-Rapid/MSU", uid = "wb-pasqua-${s.date}", stamp = stamp,
                    )
                    continue
                }
            }
            val e = emoji[s.unit] ?: "⚪️"
            val uid = s.slotID?.let { "wb-$it-${s.date}-${s.unit.name}" }
                ?: "wb-0-${s.date}-${s.unit.name}-${s.start.replace(":", "")}"   // split parts w/o a slot id stay distinct
            lines += vevent(
                s.date, s.start, s.end, s.overnight,
                title = "$e ${Units.short(s.unit)}", uid = uid, stamp = stamp,
            )
        }
        lines.add("END:VCALENDAR")
        return lines.joinToString("\r\n")
    }
}
