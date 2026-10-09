package com.nvdberg.workingbolt.data

import com.nvdberg.workingbolt.model.Assignment
import com.nvdberg.workingbolt.model.ConflictEngine
import com.nvdberg.workingbolt.model.MinInterval
import com.nvdberg.workingbolt.model.MyScheduleModel
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.OpenShift
import com.nvdberg.workingbolt.model.UnitKey
import com.nvdberg.workingbolt.model.Units
import kotlin.math.roundToInt

/**
 * Turns raw pending slots into OpenShifts with exact hours, conflict flags and accept links.
 * Mirrors the assembly in stage2/run.mjs (exact-hours + split handling).
 */
object OpenShiftBuilder {

    fun acceptURL(slotID: Int): String =
        // The in-app web view is ALREADY logged in, so go straight to the dashboard SPA's swop route.
        "https://lblite.lightning-bolt.com/dashboard/#/swop/$slotID/accept"

    data class Hours(val label: String, val iv: MinInterval, val iso: String)

    /** -> ("12:30–15:30 · 3h", interval, iso date) from ISO start/stop. */
    fun hours(start: String, stop: String): Hours? {
        if (start.length < 16 || stop.length < 16) return null
        val iso = start.substring(0, 10)
        val sh = start.substring(11, 16)
        val eh = stop.substring(11, 16)
        val overnight = stop.substring(0, 10) > iso
        val iv = ConflictEngine.interval(iso, sh, eh, overnight)
        val h = ((iv.e - iv.s) / 60.0).roundToInt()
        return Hours("$sh–$eh · ${h}h", iv, iso)
    }

    fun build(pending: List<RawSlot>, schedule: MyScheduleModel, today: String): List<OpenShift> {
        // count segments per (date|unit|offerer) so we can flag splits
        fun groupKey(s: RawSlot, k: UnitKey) =
            "${s.date ?: ""}|${k.name}|${(s.offerer ?: "").lowercase()}"

        val counts = HashMap<String, Int>()
        for (s in pending) {
            val k = Units.key(s.unit) ?: continue
            counts[groupKey(s, k)] = (counts[groupKey(s, k)] ?: 0) + 1
        }

        val out = ArrayList<OpenShift>()
        for (s in pending) {
            val id = s.slot_id ?: continue
            val k = Units.key(s.unit) ?: continue
            val start = s.start ?: continue
            val stop = s.stop ?: continue
            val h = hours(start, stop) ?: continue
            if (h.iso < today) continue
            val flag = schedule.flag(h.iso, k, h.iv)
            out.add(
                OpenShift(
                    id = id.toString(), iso = h.iso, unit = k, offerer = s.offerer ?: "—",
                    hoursLabel = h.label, flag = flag ?: "Available", conflict = flag != null,
                    acceptURL = acceptURL(id), hasDirect = true,
                    isSplit = (counts[groupKey(s, k)] ?: 0) > 1,
                    offererEmp = s.emp?.toIntOrNull(),
                    pendingEmp = s.pending_emp?.toIntOrNull(),
                    pendingName = s.pending_name?.takeIf { it.isNotEmpty() },
                )
            )
        }
        return out.sortedWith(compareBy({ it.iso }, { it.hoursLabel }))
    }

    /** Everyone's assignments -> Assignment, clinical units only, de-duped. Powers the Who's Working view. */
    fun assignments(all: List<RawSlot>, myEmp: String?): List<Assignment> {
        val seen = HashSet<String>()
        val out = ArrayList<Assignment>()
        for (s in all) {
            val k = Units.key(s.unit) ?: continue          // clinical only ("Time Off" etc. → null)
            val date = s.date ?: continue
            val start = s.start ?: continue
            val stop = s.stop ?: continue
            if (start.length < 16 || stop.length < 16) continue
            val sh = start.substring(11, 16)
            val eh = stop.substring(11, 16)
            val overnight = stop.substring(0, 10) > start.substring(0, 10)
            val doc = if (s.offerer.isNullOrEmpty()) "—" else s.offerer
            if (!seen.add("$date|${k.name}|$doc|$sh")) continue
            val isMe = !myEmp.isNullOrEmpty() && s.emp == myEmp
            out.add(Assignment(date, k, doc, sh, eh, overnight, isMe, slotID = s.slot_id))
        }
        return out.sortedWith(compareBy({ it.date }, { it.unit.name }))
    }

    /** My roster: raw slots (emp_id == me) -> MyShift, de-duped. */
    fun roster(mine: List<RawSlot>): List<MyShift> {
        val seen = HashSet<String>()
        val out = ArrayList<MyShift>()
        for (s in mine) {
            val k = Units.key(s.unit) ?: continue
            val start = s.start ?: continue
            val stop = s.stop ?: continue
            val h = hours(start, stop) ?: continue
            if (!seen.add("${h.iso}|${k.name}|$start")) continue
            val sh = start.substring(11, 16)
            val eh = stop.substring(11, 16)
            val overnight = stop.substring(0, 10) > h.iso
            out.add(
                MyShift(
                    date = h.iso, unit = k, start = sh, end = eh, overnight = overnight,
                    slotID = s.slot_id, templateID = s.template_id,
                )
            )
        }
        return out.sortedBy { it.date }
    }
}
