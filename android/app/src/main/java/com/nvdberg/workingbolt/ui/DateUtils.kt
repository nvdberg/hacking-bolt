package com.nvdberg.workingbolt.ui

import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

// Dates are plain calendar strings everywhere in the app; these are the shared display helpers
// (the counterparts of the fmt()/weekday()/dayNum() functions in WhoView.swift).

private val cache = HashMap<String, DateTimeFormatter>()

private fun formatter(pattern: String): DateTimeFormatter =
    cache.getOrPut(pattern) { DateTimeFormatter.ofPattern(pattern, Locale.US) }

fun isoDate(iso: String): LocalDate? = runCatching { LocalDate.parse(iso) }.getOrNull()

fun fmt(iso: String, pattern: String): String =
    isoDate(iso)?.format(formatter(pattern)) ?: ""

fun weekday(iso: String): String = fmt(iso, "EEE")
fun dayNum(iso: String): String = fmt(iso, "d")
fun longDate(iso: String): String = fmt(iso, "MMM d")
fun monthLabelFull(iso: String): String = fmt(iso, "MMMM yyyy")

// Week start (More → Advanced): 0 = Sunday (default), 1 = Monday. Shared by My Shifts + the mini calendars.

/** Single-letter weekday header under the chosen week start. */
fun dowLetters(weekStart: Int): List<String> =
    if (weekStart == 1) listOf("M", "T", "W", "T", "F", "S", "S") else listOf("S", "M", "T", "W", "T", "F", "S")

/** Column index (0…6) of a 0=Sunday weekday under the chosen week start (drives leading pad + fuse edges). */
fun weekCol(dowSun0: Int, weekStart: Int): Int = if (weekStart == 1) (dowSun0 + 6) % 7 else dowSun0

/** Column (0…6) of a calendar date under the chosen week start. */
fun weekCol(date: LocalDate, weekStart: Int): Int = weekCol(date.dayOfWeek.value % 7, weekStart)

/** Last-name helper (drop the first name), shared with Who's On + Crew. */
fun surname(name: String): String {
    val parts = name.split(" ").filter { it.isNotBlank() }
    return if (parts.size > 1) parts.drop(1).joinToString(" ") else name
}
