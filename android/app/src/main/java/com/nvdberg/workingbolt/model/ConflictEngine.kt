package com.nvdberg.workingbolt.model

import java.time.LocalDate

/** Absolute-minute interval (minutes since the Unix epoch, UTC) — matches interval() in run.mjs. */
data class MinInterval(val s: Int, val e: Int)

object ConflictEngine {

    fun toMin(hhmm: String): Int {
        val p = hhmm.split(":").mapNotNull { it.toIntOrNull() }
        return if (p.size == 2) p[0] * 60 + p[1] else 0
    }

    /** Whole days since epoch for "YYYY-MM-DD" (tz-independent, like ordinal() in run.mjs). */
    fun ordinal(iso: String): Int = parse(iso)?.toEpochDay()?.toInt() ?: 0

    fun addDay(iso: String): String = addDays(iso, 1)

    fun addDays(iso: String, n: Int): String = parse(iso)?.plusDays(n.toLong())?.toString() ?: iso

    private fun parse(iso: String): LocalDate? = runCatching { LocalDate.parse(iso) }.getOrNull()

    fun interval(iso: String, start: String, end: String, overnight: Boolean): MinInterval {
        val base = ordinal(iso) * 1440
        val s = toMin(start)
        val e = toMin(end)
        var upper = base + e
        if (overnight || e <= s) upper += 1440
        return MinInterval(base + s, upper)
    }

    /** Assumed window for an open shift when we don't have its exact hours — mirrors openInterval() in run.mjs. */
    fun openInterval(iso: String, k: UnitKey): MinInterval = when (k) {
        UnitKey.RR, UnitKey.PRR -> interval(iso, "08:00", "17:00", overnight = false)
        UnitKey.MSU -> interval(iso, "17:00", "08:00", overnight = true)     // Pasqua MSU 17:00→08:00
        else -> interval(iso, "08:00", "08:00", overnight = true)            // 24h units
    }
}

/** My schedule as intervals + the post-call (full rest-day) map. Mirrors the myIvs / myPost logic in run.mjs. */
class MyScheduleModel(mine: List<MyShift>) {

    private val intervals: List<Pair<MinInterval, String>>
    private val post: Map<String, String>   // date -> unit short (post-call = whole rest day, nothing pickable)

    init {
        val ivs = ArrayList<Pair<MinInterval, String>>(mine.size)
        val p = HashMap<String, String>()
        for (s in mine) {
            val iv = ConflictEngine.interval(s.date, s.start, s.end, s.overnight)
            val short = Units.short(s.unit)
            ivs.add(iv to short)
            if (s.overnight) p[ConflictEngine.addDay(s.date)] = short
        }
        intervals = ivs
        post = p
    }

    /** null = Available; otherwise a conflict label. Pass [exact] for a split/partial offer's real window. */
    fun flag(iso: String, unit: UnitKey, exact: MinInterval? = null): String? {
        post[iso]?.let { return "Post-call · off $it" }
        val o = exact ?: ConflictEngine.openInterval(iso, unit)
        var bestRank = 0
        var bestShort = ""
        for ((iv, short) in intervals) {
            if (iv.s > o.e || iv.e < o.s) continue
            val rank = if (iv.s < o.e && iv.e > o.s) 3 else if (iv.e == o.s) 2 else 1
            if (rank > bestRank) { bestRank = rank; bestShort = short }
        }
        return when (bestRank) {
            3 -> "You're on $bestShort"
            2 -> "Post-call · off $bestShort"
            1 -> "Pre-call · before $bestShort"
            else -> null
        }
    }
}
