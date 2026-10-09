package com.nvdberg.workingbolt.model

import androidx.compose.ui.graphics.Color
import kotlinx.serialization.Serializable

/** Unit taxonomy — mirrors the UNITS map in stage2/run.mjs (and Models.swift on iOS). */
@Serializable
enum class UnitKey { MICU, SICU, CCU, PHICU, RR, PRR, MSU }

data class UnitInfo(val short: String, val full: String, val color: Color)

object Units {
    val info: Map<UnitKey, UnitInfo> = mapOf(
        UnitKey.MICU to UnitInfo("MICU", "Medical ICU", Color(0xFF41A00E)),
        UnitKey.SICU to UnitInfo("SICU", "Surgical ICU", Color(0xFF3A70EE)),
        UnitKey.CCU to UnitInfo("CCU", "Coronary Care", Color(0xFFBF3654)),
        UnitKey.PHICU to UnitInfo("PICU", "Pasqua ICU", Color(0xFF0A7B71)),
        UnitKey.RR to UnitInfo("RGH-Rapid", "Rapid Response", Color(0xFFED8207)),
        UnitKey.PRR to UnitInfo("Pasqua-Rapid", "Pasqua Rapid Response", Color(0xFF14C28B)),
        UnitKey.MSU to UnitInfo("Pasqua-MSU", "Pasqua Medical Surveillance Unit", Color(0xFF14C28B)),
    )

    fun short(u: UnitKey) = info[u]?.short ?: u.name
    fun color(u: UnitKey) = info[u]?.color ?: Color.Gray

    /** Map a raw assignment/shift name (from the feed or LbsAppData) to a unit — mirrors unitKey() in run.mjs. */
    fun key(fromRaw: String?): UnitKey? {
        val r = (fromRaw ?: return null).uppercase()
        return when {
            r.contains("PASQUA RAPID") -> UnitKey.PRR
            r.contains("RAPID RESPONSE") -> UnitKey.RR
            r.startsWith("MSU") -> UnitKey.MSU
            r.startsWith("PHICU") || r.startsWith("PICU") -> UnitKey.PHICU
            r.startsWith("MICU") -> UnitKey.MICU
            r.startsWith("SICU") -> UnitKey.SICU
            r.startsWith("CCU") -> UnitKey.CCU
            else -> null   // unknown / non-clinical — skip
        }
    }
}

/** One of my own roster shifts. */
@Serializable
data class MyShift(
    val date: String,            // "YYYY-MM-DD"
    val unit: UnitKey,
    val start: String,           // "HH:MM"
    val end: String,             // "HH:MM"
    val overnight: Boolean,
    val slotID: Int? = null,     // Lightning Bolt slot_id — present for live-harvested shifts; enables give-away
    val slotID2: Int? = null,    // second slot for a Pasqua Rapid+MSU combo (both halves move together on a trade)
    val templateID: Int? = null, // the LB schedule/template this shift belongs to (for the give-away payload)
)

/** An offered (open) shift shown in the pool — a whole shift or one split segment. */
@Serializable
data class OpenShift(
    val id: String,          // slot_id, or a composite key when no exact slot matched
    val iso: String,         // "YYYY-MM-DD"
    val unit: UnitKey,
    val offerer: String,
    val hoursLabel: String,  // e.g. "12:30–15:30 · 3h"
    val flag: String,        // "Available" or a conflict label
    val conflict: Boolean,
    val acceptURL: String?,
    val hasDirect: Boolean,  // true when we have the exact slot_id -> one-tap accept
    val isSplit: Boolean,
    // Added with the build-90 sync — all defaulted so older cached snapshots still decode.
    val offererEmp: Int? = null,     // emp_id of the person offering it
    val pendingEmp: Int? = null,     // LB's pending_emp_id — who the offer is aimed at (== offerer for an open post)
    val pendingName: String? = null,
) {
    /** The ONE person this offer is aimed at (a direct offer / swap half); null when it's open to the pool. */
    val directedTo: Int? get() = if (pendingEmp != offererEmp) pendingEmp else null
}

/** One doctor's assignment on a unit for a day — powers the Who's Working view. */
@Serializable
data class Assignment(
    val date: String,        // "YYYY-MM-DD"
    val unit: UnitKey,
    val doc: String,         // doctor's display name
    val start: String,       // "HH:MM"
    val end: String,         // "HH:MM"
    val overnight: Boolean,
    val isMe: Boolean,
    val slotID: Int? = null,     // LB slot_id — lets a colleague's shift be named in a swap
    val slotID2: Int? = null,    // the MSU half when a Pasqua Rapid+MSU pair is merged
)

/** emp_id → contact, from LB's /personnel directory. */
@Serializable
data class Contact(val cell: String, val email: String)

/** A shift that left the pool in the last 2 days — shown without names ("Recently taken"). */
data class RecentTake(
    val id: Int,
    val iso: String,
    val unit: UnitKey,
    val whenMillis: Long,
    val swap: Boolean,
    val mine: Boolean,
)

/** A shift I've posted for pickup or swap — pending (still in the pool) or completed (picked up). */
data class MyPost(
    val id: String,
    val iso: String,
    val unit: UnitKey,
    val hoursLabel: String,
    val kind: Kind,
    val status: Status,
    val counterparty: String? = null,
    val whenAt: String? = null,      // "YYYY-MM-DDTHH:MM:SS" (Regina) — when it was picked up
    val slotID: Int? = null,
    val note: String? = null,
) {
    enum class Kind(val label: String) { Giveaway("Give-away"), Swap("Swap") }
    enum class Status { Pending, Completed }
}

/** One day of one of my time-off / night-off requests on Lightning Bolt. */
@Serializable
data class TimeOffRequest(
    val id: Int,                     // LB request_id (one per day)
    val date: String,                // "YYYY-MM-DD"
    val status: String = "pending",  // "pending" / "approved" / "denied" …
    val kind: String = "Time Off",   // "Time Off" / "Night Off"
    val note: String = "",
    val submitted: String? = null,   // "YYYY-MM-DDTHH:MM:SS" (Regina)
    val decision: String? = null,    // LB's decision / denial reason, if any
) {
    val isPending: Boolean get() = status.lowercase() == "pending"
}
