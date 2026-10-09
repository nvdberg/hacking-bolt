package com.nvdberg.workingbolt.data

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.net.HttpURLConnection
import java.net.URL

/**
 * Minimal Supabase (PostgREST) client over HttpURLConnection — no SDK dependency. Uses the project's PUBLIC
 * publishable key (safe to ship). The backend holds only shift logistics (no patient data).
 *
 * Mirrors SupabaseClient.swift, minus the device/push registration (Android has no push by decision).
 */
object Supabase {
    private const val BASE = "https://qbtnxkzpddexczhcvxre.supabase.co/rest/v1"
    private const val KEY = "sb_publishable_uqqWXuhGAPqd85yXC4rLsA_q7RX1zAQ"   // publishable/anon key — public by design

    // explicitNulls off: an absent reason/note is omitted from the upsert (as on iOS), never written as null.
    @OptIn(ExperimentalSerializationApi::class)
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true; explicitNulls = false }

    @Serializable
    data class OfferNote(
        val slot_id: Int,
        val note: String? = null,
        val reason: String? = null,
        val by_emp: Int? = null,
    )

    @Serializable
    data class Pickup(
        val slot_id: Int,
        val date: String? = null,
        val unit: String? = null,
        val giver_emp: Int? = null,
        val giver: String? = null,
        val taker_emp: Int? = null,
        val taker: String? = null,
        val kind: String? = null,
        val picked_up_at: String? = null,
    )

    @Serializable
    data class CalSub(val emp_id: Int, val token: String, val enabled: Boolean? = null)

    /** A cal_subs lookup: [ok] false = the read FAILED (distinct from "no row yet"). */
    data class CalSubResult(val ok: Boolean, val sub: CalSub?)

    private data class Response(val ok: Boolean, val body: String?)

    private suspend fun send(
        path: String, method: String = "GET", body: String? = null, prefer: String? = null,
    ): Response = withContext(Dispatchers.IO) {
        var conn: HttpURLConnection? = null
        try {
            conn = (URL(BASE + path).openConnection() as HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = 12_000
                readTimeout = 12_000
                setRequestProperty("apikey", KEY)
                setRequestProperty("Authorization", "Bearer $KEY")
                setRequestProperty("Content-Type", "application/json")
                if (prefer != null) setRequestProperty("Prefer", prefer)
                if (body != null) {
                    doOutput = true
                    outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                }
            }
            val code = conn.responseCode
            val ok = code in 200..299
            val text = runCatching {
                (if (ok) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() }
            }.getOrNull()
            Response(ok, text)
        } catch (e: Exception) {
            Log.i(WB_LOG, "supabase $method ${path.substringBefore('?')}: ${e.message}")
            Response(false, null)
        } finally {
            conn?.disconnect()
        }
    }

    private inline fun <reified T> decode(body: String?): T? =
        body?.let { runCatching { json.decodeFromString<T>(it) }.getOrNull() }

    /** Attach/replace the note on a give-away (upsert on slot_id) — powers group-offer notes LB can't store. */
    suspend fun putOfferNote(slotID: Int, note: String, reason: String?, byEmp: Int?): Boolean {
        val body = json.encodeToString(listOf(OfferNote(slotID, note, reason, byEmp)))
        return send(
            "/offer_notes?on_conflict=slot_id", "POST", body, "resolution=merge-duplicates,return=minimal",
        ).ok
    }

    /** All notes I've attached to my offers (slot_id → note) — labels my pending posts as swaps vs give-aways. */
    suspend fun myOfferNotes(byEmp: Int): Map<Int, String>? {
        val r = send("/offer_notes?by_emp=eq.$byEmp&select=slot_id,note")
        if (!r.ok) return null
        val rows = decode<List<OfferNote>>(r.body) ?: return null
        val out = LinkedHashMap<Int, String>()
        for (n in rows) { val t = n.note ?: continue; if (n.slot_id !in out) out[n.slot_id] = t }
        return out
    }

    /** Every swap-tagged offer (reason "swap:…" / "swapback:…") — pairs the two halves of a two-way swap. */
    suspend fun swapNotes(): List<OfferNote>? {
        val r = send("/offer_notes?reason=like.swap*&select=slot_id,note,reason,by_emp")
        if (!r.ok) return null
        return decode(r.body)
    }

    /** Read the note for a slot (shown in the Pool next to the offer). */
    suspend fun offerNote(slotID: Int): OfferNote? {
        val r = send("/offer_notes?slot_id=eq.$slotID&select=*")
        if (!r.ok) return null
        return decode<List<OfferNote>>(r.body)?.firstOrNull()
    }

    /** Shifts I posted that got picked up (kept current by the poller) — "My posts → Picked up". Newest first. */
    suspend fun pickups(giverEmp: Int): List<Pickup>? {
        val r = send("/pickups?giver_emp=eq.$giverEmp&select=*&order=picked_up_at.desc")
        if (!r.ok) return null
        return decode(r.body)
    }

    /**
     * Every shift that changed hands since [sinceLocal] ("YYYY-MM-DDTHH:MM:SS", Regina) — the Pool's
     * "Recently taken" list. Only date/unit/kind/time (+ emp numbers, to drop my own) are read, never names.
     */
    suspend fun recentPickups(sinceLocal: String): List<Pickup>? {
        val r = send(
            "/pickups?picked_up_at=gte.$sinceLocal&select=slot_id,date,unit,kind,giver_emp,taker_emp,picked_up_at" +
                "&order=picked_up_at.desc&limit=40",
        )
        if (!r.ok) return null
        return decode(r.body)
    }

    // MARK: Calendar sync (live subscribable feed)

    /** Public URL of a subscriber's live .ics — the poller regenerates the file at this path every few minutes. */
    fun calendarURL(token: String): String =
        "https://qbtnxkzpddexczhcvxre.supabase.co/storage/v1/object/public/calendars/$token.ics"

    /**
     * My existing calendar-feed row (stable token + on/off), keyed on emp_id. `ok == false` means the lookup
     * FAILED — distinct from "no row yet", so a caller never mints a fresh token (and breaks an existing
     * subscription) just because the read didn't go through.
     */
    suspend fun calSub(emp: Int): CalSubResult {
        val r = send("/cal_subs?emp_id=eq.$emp&select=emp_id,token,enabled")
        if (!r.ok) return CalSubResult(false, null)
        val rows = decode<List<CalSub>>(r.body) ?: return CalSubResult(false, null)
        return CalSubResult(true, rows.firstOrNull())
    }

    /** Turn my live calendar feed on/off (upsert on emp_id). The token stays stable so the URL never changes. */
    suspend fun enrollCalendar(emp: Int, token: String, enabled: Boolean): Boolean {
        val body = json.encodeToString(listOf(CalSub(emp, token, enabled)))
        return send("/cal_subs?on_conflict=emp_id", "POST", body, "resolution=merge-duplicates,return=minimal").ok
    }

    // MARK: Doctors on call + cafeteria (captured on the Unit Board; the app only reads them)

    /** One `oncall_roster` row: role is day / oncall (ICUs, CCU) or stemi_day / stemi_oncall / consults / ccu (CCU). */
    @Serializable
    data class RosterRow(val date: String, val unit: String, val role: String, val name: String? = null)

    /** The doctor roster between two ISO dates. Null = the read failed (keep what we have). */
    suspend fun oncallRoster(from: String, to: String): List<RosterRow>? {
        val r = send("/oncall_roster?date=gte.$from&date=lte.$to&select=date,unit,role,name&limit=5000")
        if (!r.ok) return null
        return decode(r.body)
    }

    @Serializable data class MenuItem(val name: String? = null, val price: String? = null)
    @Serializable data class MenuSection(val label: String? = null, val items: List<MenuItem>? = null)
    @Serializable data class MenuDay(val date: String? = null, val weekday: String? = null, val sections: List<MenuSection>? = null)
    @Serializable data class MenuPage(val site: String, val page: Int, val first_date: String? = null, val days: List<MenuDay>? = null)

    /** Every captured cafeteria menu page (RGH + PH rotations). Null = the read failed. */
    suspend fun cafeteriaMenus(): List<MenuPage>? {
        val r = send("/cafeteria_menu?select=site,page,first_date,days&order=site,page")
        if (!r.ok) return null
        return decode(r.body)
    }
}
