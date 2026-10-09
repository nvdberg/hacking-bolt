package com.nvdberg.workingbolt.data

import com.nvdberg.workingbolt.model.Assignment
import com.nvdberg.workingbolt.model.MyPost
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.OpenShift
import com.nvdberg.workingbolt.model.TimeOffRequest
import com.nvdberg.workingbolt.model.UnitKey
import java.time.LocalDate

/**
 * Sample data for the no-login "Explore" mode. Lets a reviewer (or a curious colleague) walk the whole
 * app — Pool, My Shifts, Who's On, Crew — without ever signing in. Fully in-memory and deterministic,
 * so it looks the same on every launch and never touches the network.
 */
object DemoData {
    const val ME = "Demo User"
    val others = listOf(
        "Aivars Berzins", "Sarah Chen", "James Okafor", "Maria Santos", "David Kim",
        "Emily Novak", "Raj Patel", "Lena Fischer", "Tom Wright", "Anna Kowalski",
    )
    private val units = listOf(
        UnitKey.SICU, UnitKey.MICU, UnitKey.CCU, UnitKey.PHICU, UnitKey.RR, UnitKey.PRR, UnitKey.MSU,
    )

    /** Stable fake emp_ids for the sample colleagues, so demo mode has a roster. */
    fun roster(): Map<Int, String> = others.withIndex().associate { (i, n) -> 9000 + i to n }

    /** Realistic hours per unit: 24h ICU calls (08:00→08:00), 9h day rapid-response, MSU overnight. */
    private fun times(u: UnitKey): Triple<String, String, Boolean> = when (u) {
        UnitKey.RR, UnitKey.PRR -> Triple("08:00", "17:00", false)
        UnitKey.MSU -> Triple("17:00", "08:00", true)
        else -> Triple("08:00", "08:00", true)   // 24h ICU units
    }

    data class Bundle(val mine: List<MyShift>, val group: List<Assignment>, val open: List<OpenShift>)

    /**
     * Builds a couple of years of history (2024 → ~2 months ahead): every unit covered every day by some
     * doctor, with "Demo User" holding roughly one shift every five days.
     */
    fun build(today: String): Bundle {
        val mine = ArrayList<MyShift>()
        val group = ArrayList<Assignment>()
        var d = LocalDate.parse("2024-01-01")
        val end = LocalDate.parse(today).plusDays(60)
        var dayIdx = 0
        while (!d.isAfter(end)) {
            val iso = d.toString()
            units.forEachIndexed { ui, u ->
                val (s, e, ov) = times(u)
                val mineSlot = (dayIdx % 5 == 0) && (ui == (dayIdx / 5) % units.size)   // ~1 shift / 5 days
                if (mineSlot) {
                    group.add(Assignment(iso, u, ME, s, e, ov, isMe = true))
                    // A fake slotID makes future shifts tradeable in the UI (no network in demo, so it's inert).
                    mine.add(MyShift(iso, u, s, e, ov, slotID = 800000 + dayIdx * 10 + ui, templateID = 6))
                } else {
                    group.add(Assignment(iso, u, others[(dayIdx + ui) % others.size], s, e, ov, isMe = false))
                }
            }
            d = d.plusDays(1)
            dayIdx++
        }
        return Bundle(mine.sortedBy { it.date }, group.sortedBy { it.date }, buildOpen(today))
    }

    /** A handful of upcoming open offers for the Pool tab (no accept URL — read-only in demo). */
    private fun buildOpen(today: String): List<OpenShift> {
        val base = LocalDate.parse(today)
        val offers = listOf(
            Triple(2, UnitKey.RR, "Sarah Chen"),
            Triple(4, UnitKey.SICU, "James Okafor"),
            Triple(5, UnitKey.PRR, "Maria Santos"),
            Triple(8, UnitKey.MICU, "David Kim"),
            Triple(11, UnitKey.CCU, "Emily Novak"),
            Triple(14, UnitKey.MSU, "Raj Patel"),
        )
        return offers.mapIndexed { i, (days, unit, who) ->
            val iso = base.plusDays(days.toLong()).toString()
            val (s, e, ov) = times(unit)
            val hours = if (ov || e <= s) 24 else 9
            OpenShift(
                id = "demo-$i", iso = iso, unit = unit, offerer = who,
                hoursLabel = "$s–$e · ${hours}h", flag = "Available", conflict = false,
                acceptURL = null, hasDirect = false, isSplit = false,
            )
        }
    }

    /** Sample "My posts": a few pending offers + some picked up this month and last. */
    fun posts(today: String): List<MyPost> {
        val base = LocalDate.parse(today)
        fun iso(days: Int) = base.plusDays(days.toLong()).toString()
        fun stamp(days: Int) = iso(days) + "T14:30:00"
        val g = MyPost.Kind.Giveaway; val sw = MyPost.Kind.Swap
        val p = MyPost.Status.Pending; val c = MyPost.Status.Completed
        return listOf(
            // Pending — still out there waiting for a taker
            MyPost("d-p1", iso(3), UnitKey.SICU, "08:00–08:00 · 24h", g, p),
            MyPost("d-p2", iso(9), UnitKey.RR, "08:00–17:00 · 9h", g, p),
            MyPost("d-p3", iso(12), UnitKey.MICU, "08:00–08:00 · 24h", sw, p, counterparty = "Sarah Chen",
                note = "Swap? I'll take your PICU on the 27th if you take my MICU."),
            // Completed — this month
            MyPost("d-c1", iso(-4), UnitKey.CCU, "08:00–08:00 · 24h", g, c, "James Okafor", stamp(-3)),
            MyPost("d-c2", iso(-11), UnitKey.PRR, "08:00–17:00 · 9h", sw, c, "Maria Santos", stamp(-10)),
            // Completed — last month
            MyPost("d-c3", iso(-38), UnitKey.MICU, "08:00–08:00 · 24h", g, c, "David Kim", stamp(-37)),
            MyPost("d-c4", iso(-45), UnitKey.MSU, "17:00–08:00 · 15h", g, c, "Emily Novak", stamp(-44)),
        )
    }

    /** Sample time-off requests: a pending 3-day block, a pending night off, an approved one, and a past one. */
    fun requests(today: String): List<TimeOffRequest> {
        val base = LocalDate.parse(today)
        fun iso(days: Int) = base.plusDays(days.toLong()).toString()
        val sub = iso(-5) + "T16:18:21"
        return listOf(
            TimeOffRequest(-1, iso(40), "pending", "Time Off", "Family visit", sub),
            TimeOffRequest(-2, iso(41), "pending", "Time Off", "Family visit", sub),
            TimeOffRequest(-3, iso(42), "pending", "Time Off", "Family visit", sub),
            TimeOffRequest(-4, iso(18), "pending", "Night Off", "Kids' concert", sub),
            TimeOffRequest(-5, iso(25), "approved", "Time Off", "Conference", iso(-30) + "T09:02:00"),
            TimeOffRequest(-6, iso(-12), "approved", "Time Off", "", iso(-50) + "T09:02:00"),
        ).sortedBy { it.date }
    }
}
