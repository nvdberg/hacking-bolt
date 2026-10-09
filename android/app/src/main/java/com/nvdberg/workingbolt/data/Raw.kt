package com.nvdberg.workingbolt.data

import kotlinx.serialization.Serializable

/** Raw slot as read from the Lightning Bolt schedule API (see the JS in LBWebSource). */
@Serializable
data class RawSlot(
    val slot_id: Int? = null,
    val date: String? = null,          // "YYYY-MM-DD"
    val start: String? = null,         // "YYYY-MM-DDTHH:MM:SS"
    val stop: String? = null,
    val unit: String? = null,          // assign_display_name
    val offerer: String? = null,       // display_name (assigned doctor, or the offerer for a pending slot)
    val emp: String? = null,           // emp_id (to flag "me" in the Who's-Working view)
    val template_id: Int? = null,      // the LB schedule/template the slot belongs to — needed to give it away
    val pending_emp: String? = null,   // pending offers only: who it's aimed at (== emp for an open post)
    val pending_name: String? = null,
)

/** A raw "changed hands" slot from the group schedule — original holder != current. */
@Serializable
data class RawSwap(
    val slot_id: Int? = null,
    val date: String? = null,
    val start: String? = null,
    val stop: String? = null,
    val unit: String? = null,
    val toName: String? = null,     // current holder (taker) display name
    val toEmp: String? = null,      // current emp_id
    val fromEmp: String? = null,    // original_emp_id
    val fromName: String? = null,   // resolved from the group's emp_id → name map
    val whenAt: String? = null,     // modified_date (approval time) — `when` is a Kotlin keyword
    val hist: String? = null,       // slot_history[0].text
)

/** A person from LB's /personnel directory (emp_id → contact), for the Swap Finder's "text them" action. */
@Serializable
data class RawPerson(
    val emp: String = "",
    val name: String = "",
    val cell: String = "",
    val email: String = "",
)

/** One page-load's harvest: offered slots + my own roster slots + my name. */
data class HarvestResult(
    val pending: List<RawSlot>,   // the complete schedule/range?only_pending list
    val mine: List<RawSlot>,
    val me: String,
    val emp: String? = null,      // my emp_id — used to tell "me" apart from colleagues in the roster
    val offersOK: Boolean = true, // false = the open-offer read failed → keep the cached pool
)

/** The group fetch: merged slots plus the years that failed (their cached entries are kept). */
data class GroupFetch(val shifts: List<RawSlot>, val failedYears: Set<Int>)

/** One day of a request as LB lists it (`GET /request/range/`). Times are Regina local, no zone. */
@Serializable
data class RawRequest(
    val id: Int,
    val date: String = "",
    val status: String? = null,
    val kind: String? = null,
    val note: String? = null,
    val submitted: String? = null,
    val decision: String? = null,
)

@Serializable
data class RequestsResult(val ok: Boolean = false, val requests: List<RawRequest> = emptyList())

// --- JSON envelopes returned by the injected JS ---

@Serializable
data class Identity(val emp: String = "", val me: String = "")

@Serializable
data class OpenOffersResult(val ok: Boolean = false, val pending: List<RawSlot> = emptyList())

@Serializable
data class MyShiftsResult(val ok: Boolean = false, val all: Boolean? = null, val shifts: List<RawSlot> = emptyList())

@Serializable
data class GroupShiftsResult(
    val ok: Boolean = false,
    val shifts: List<RawSlot> = emptyList(),
    val swaps: List<RawSwap> = emptyList(),
)

@Serializable
data class DirectoryResult(val ok: Boolean = false, val people: List<RawPerson> = emptyList())

@Serializable
data class WriteResult(val ok: Boolean = false, val status: Int = 0, val body: String? = null)
