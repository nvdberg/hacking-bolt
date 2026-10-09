package com.nvdberg.workingbolt.model

/** Where a colleague stands on the date of the shift I want to trade away. */
sealed interface SwapStatus {
    data object Free : SwapStatus
    /** They're on the roster that day as non-clinical (time off / vacation / admin) — a soft ⚠️, not a block. */
    data class Off(val label: String) : SwapStatus
}

/** One viable swap: a colleague + a specific future shift of theirs I could take (they can take mine too). */
data class SwapOption(
    val emp: Int,
    val name: String,
    val cell: String? = null,
    val statusOnMyDate: SwapStatus,
    val returnShift: Assignment,
) {
    val id: String get() = "$emp|${returnShift.date}|${returnShift.unit.name}|${returnShift.start}"
    val firstName: String get() = name.split(" ").firstOrNull() ?: name
}
