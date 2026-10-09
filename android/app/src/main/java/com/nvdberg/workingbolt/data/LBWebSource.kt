package com.nvdberg.workingbolt.data

import android.annotation.SuppressLint
import android.content.Context
import android.util.Log
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

const val WB_LOG = "WorkingBolt"

/**
 * Owns a single WebView. The user logs in on Lightning Bolt's real page (we never see the password);
 * afterwards we drive the same web view (its session cookies persist) to read window.LbsAppData —
 * exactly the object the scraper reads. No token handling, no server.
 *
 * Android differences from the iOS original:
 *  • there is no `callAsyncJavaScript`, so async JS bodies resolve through a `@JavascriptInterface`
 *    bridge ([Bridge]) that streams the result back in chunks — the group-year payloads are megabytes
 *    and would be truncated by a single bridge string;
 *  • the document-start hook uses `WebViewCompat.addDocumentStartJavaScript` where the installed
 *    WebView supports it, and falls back to injecting in `onPageStarted`.
 */
class LBWebSource(context: Context) {

    companion object {
        const val LOGIN_URL = "https://lblite.lightning-bolt.com/dashboard/"
        private val REGINA: ZoneId = ZoneId.of("America/Regina")
        private const val CHUNK = 262_144           // 256 KB per bridge hop

        fun viewerURL(dt: String) = "https://lblite.lightning-bolt.com/viewer/?dt=$dt"

        /** yyyyMM01 for the current month, Regina time — the viewer's start date. */
        fun currentMonthDt(): String = LocalDate.now(REGINA).let { String.format(Locale.ROOT, "%04d%02d01", it.year, it.monthValue) }

        /**
         * Jan 1 of the current year (Regina) — the start of harvest's live my-shifts window
         * (fetchMyShifts serves whole years, start-year → next year, so this covers this year + next).
         */
        fun currentYearDt(): String = "${LocalDate.now(REGINA).year}0101"

        fun todayRegina(): String = LocalDate.now(REGINA).toString()

        /**
         * Injected at document start: wrap XHR/fetch so the Bearer the SPA sends to lbapi is captured into
         * window.__lbAuth. That lets us call the same only_pending endpoint the "posted shifts" widget uses,
         * which lists EVERY open swaportunity — Rapid Response included — each with its slot_id. Never leaves
         * the web view; used only to read the user's own authorised data.
         */
        val TOKEN_CAPTURE_JS = """
            (function(){
              if (window.__lbAuthHook) return; window.__lbAuthHook = 1; window.__lbAuth = '';
              try {
                var os = XMLHttpRequest.prototype.setRequestHeader;
                XMLHttpRequest.prototype.setRequestHeader = function(k, v){
                  try { if (/^authorization${'$'}/i.test(k) && /bearer/i.test(v)) window.__lbAuth = v; } catch(e){}
                  return os.apply(this, arguments);
                };
                if (window.fetch) { var of = window.fetch; window.fetch = function(input, init){
                  try { var h = init && init.headers; if (h){ var a=(h.get&&h.get('authorization'))||h['Authorization']||h['authorization']; if(a && /bearer/i.test(a)) window.__lbAuth=a; } } catch(e){}
                  return of.apply(this, arguments);
                }; }
              } catch(e){}
            })();
        """.trimIndent()
    }

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val appContext = context.applicationContext

    private val pending = ConcurrentHashMap<String, CompletableDeferred<String>>()
    private val buffers = ConcurrentHashMap<String, StringBuilder>()
    private var navDone: CompletableDeferred<Unit>? = null

    /** Diagnostic: LB's raw status + response body from the last write (logged, never shown in the UI). */
    @Volatile var lastWriteInfo: String = ""
        private set

    @SuppressLint("SetJavaScriptEnabled", "JavascriptInterface")
    val webView: WebView = WebView(appContext).apply {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.databaseEnabled = true
        settings.loadWithOverviewMode = true
        settings.useWideViewPort = true
        settings.setSupportZoom(false)
        settings.javaScriptCanOpenWindowsAutomatically = true
        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
        addJavascriptInterface(Bridge(), "WBBridge")
        webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                // Fallback hook for WebView builds without DOCUMENT_START_SCRIPT — close enough to
                // document-start that it lands before the SPA bundle issues its first authed request.
                if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                    view?.evaluateJavascript(TOKEN_CAPTURE_JS, null)
                }
            }
            override fun onPageFinished(view: WebView?, url: String?) {
                CookieManager.getInstance().flush()
                navDone?.complete(Unit)
                navDone = null
            }
            override fun onReceivedError(
                view: WebView?, request: android.webkit.WebResourceRequest?,
                error: android.webkit.WebResourceError?,
            ) {
                if (request?.isForMainFrame == true) { navDone?.complete(Unit); navDone = null }
            }
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(
                this, TOKEN_CAPTURE_JS, setOf("https://lblite.lightning-bolt.com"),
            )
        }
    }

    /** Streams an async JS result back in chunks — a single bridge string truncates on the big payloads. */
    inner class Bridge {
        @JavascriptInterface
        fun chunk(id: String, part: String) {
            buffers.getOrPut(id) { StringBuilder() }.append(part)
        }

        @JavascriptInterface
        fun done(id: String, ok: Boolean, err: String?) {
            val d = pending.remove(id) ?: return
            val buf = buffers.remove(id)
            if (ok) d.complete(buf?.toString() ?: "")
            else d.completeExceptionally(RuntimeException(err ?: "js error"))
        }
    }

    fun loadLogin() = load(LOGIN_URL)

    private fun load(url: String) {
        webView.post { webView.loadUrl(url) }
    }

    /**
     * Opt-in auto-login: fill LB's own login form with the credentials the user chose to keep on this device
     * and submit it. Generic selectors so it survives minor markup changes. The password is embedded as a safely
     * escaped JS string literal — it lives only in the web view, same as a manual login, and is never logged.
     */
    suspend fun autoSignIn(username: String, password: String): Boolean {
        val js = AUTO_LOGIN_JS.replace("__USER__", jsString(username)).replace("__PASS__", jsString(password))
        val r = evalString(js)
        Log.i(WB_LOG, "autoSignIn: ${r ?: "null"}")
        return r == "submitted"
    }

    /**
     * Clear the Lightning Bolt session (cookies + storage + captured token) so the login screen returns
     * for a fresh user — used by Sign out (e.g. to let a colleague log in and load their own data).
     */
    fun signOut() {
        webView.post {
            CookieManager.getInstance().removeAllCookies(null)
            CookieManager.getInstance().flush()
            WebStorage.getInstance().deleteAllData()
            webView.clearCache(true)
            webView.clearHistory()
            webView.evaluateJavascript("try{window.__lbAuth='';}catch(e){}", null)
        }
    }

    /** True once the dashboard/app shows a logged-in state (not the sign-in screen). */
    suspend fun isLoggedIn(): Boolean {
        val js = "(/SWAPORTUNITY|Sign out/i.test(document.body.innerText) && !/Sign in to access/i.test(document.body.innerText))"
        return evalRaw(js) == "true"
    }

    // MARK: - Harvest

    /**
     * Load the viewer ONCE (which fires the SPA's authed lbapi call, captured into window.__lbAuth), then
     * read the live window entirely from the fast per-year API paths: my roster via [fetchMyShifts], the
     * complete cross-department open-offer pool via [fetchOpenOffers]. Identity (emp_id + name) comes straight
     * from LbsAppData. No week-by-week SPA paging, no per-week timeouts — one navigation plus two API reads,
     * side by side.
     */
    suspend fun harvest(): HarvestResult? {
        loadAndWait(viewerURL(currentMonthDt()))     // start at the 1st of the current month
        waitForSlots()                               // the viewer's data load fires the authed lbapi fetch…
        waitForToken()                               // …which the documentStart hook captures into __lbAuth

        var me = ""
        var emp: String? = null
        evalAsync(IDENTITY_JS)?.let { raw ->
            decode<Identity>(raw)?.let { id ->
                me = id.me
                if (id.emp.isNotEmpty()) emp = id.emp
            }
        }
        // My roster and the open pool are independent reads — run them together (the bridge keys each call
        // by its own id). requireAll: a year that failed must not look like "those shifts are gone" (the
        // caller replaces the window).
        val (mineRead, offers) = coroutineScope {
            val m = async { fetchMyShifts(currentYearDt(), requireAll = true) }
            val o = async { fetchOpenOffers() }
            m.await() to o.await()
        }
        val mine = mineRead ?: emptyList()
        val pendingSlots = offers ?: emptyList()
        if (emp == null) emp = mine.firstOrNull()?.emp                    // fallbacks if LbsAppData.User was sparse
        if (me.isEmpty()) me = mine.firstOrNull()?.offerer ?: ""
        Log.i(WB_LOG, "harvest DONE (api): pending=${pendingSlots.size} mine=${mine.size} me='$me'")
        return HarvestResult(pending = pendingSlots, mine = mine, me = me, emp = emp, offersOK = offers != null)
    }

    /**
     * The complete open-offer list from lbapi schedule/range?only_pending — every live swaportunity
     * (all units, whole roster) already carrying its slot_id. Needs the captured Bearer + logged-in emp_id.
     * Returns null if either isn't ready yet, so the caller keeps its current pool.
     */
    suspend fun fetchOpenOffers(): List<RawSlot>? {
        // Start at the current REGINA month — the UTC month skipped this month after 6 pm on its last day.
        val raw = evalAsync(OPEN_OFFERS_JS.replace("__YM__", currentMonthDt().take(6)))
        val r = raw?.let { decode<OpenOffersResult>(it) }
        if (r == null || !r.ok) {
            Log.i(WB_LOG, "openOffers: unavailable (token/emp not ready)")
            return null
        }
        Log.i(WB_LOG, "openOffers: ${r.pending.size} live pending (cross-department)")
        return r.pending
    }

    /** The group directory (name, cell, email per emp_id) from lbapi /personnel, via the captured Bearer. */
    suspend fun fetchDirectory(): List<RawPerson>? {
        val r = evalAsync(DIRECTORY_JS)?.let { decode<DirectoryResult>(it) }
        if (r == null || !r.ok) { Log.i(WB_LOG, "directory: unavailable (token not ready)"); return null }
        Log.i(WB_LOG, "directory: ${r.people.size} people")
        return r.people
    }

    /**
     * My own worked/scheduled shifts from [sinceYYYYMM01] onward, via the same schedule/range endpoint
     * (no only_pending → my roster), filtered to my emp_id. ONE call per year.
     */
    suspend fun fetchMyShifts(sinceYYYYMM01: String, requireAll: Boolean = false): List<RawSlot>? {
        val endY = LocalDate.now(REGINA).year + 1                       // Regina year + 1 (next year's roster)
        val js = MY_SHIFTS_JS.replace("__SINCE__", sinceYYYYMM01).replace("__ENDY__", endY.toString())
        val r = evalAsync(js)?.let { decode<MyShiftsResult>(it) }
        if (r == null || !r.ok) { Log.i(WB_LOG, "myShifts history: unavailable (token/emp not ready)"); return null }
        if (requireAll && r.all == false) { Log.i(WB_LOG, "myShifts: a year failed — partial read discarded"); return null }
        Log.i(WB_LOG, "myShifts history: ${r.shifts.size} slots since $sinceYYYYMM01")
        return r.shifts
    }

    /**
     * The whole group's roster, powering Who's On and Crew. Fetched ONE YEAR AT A TIME and merged here —
     * the whole-group year payload is ~9 MB, so pulling all years in a single JS call overflowed on device.
     *
     * The injected JS is kept verbatim with iOS and therefore still reports changed-hands slots
     * (`swaps`), but this app has no owner/admin surface by design, so they are decoded and dropped
     * here rather than being built into events or written to disk.
     */
    suspend fun fetchGroupShifts(years: List<Int>): GroupFetch? {
        val shifts = ArrayList<RawSlot>()
        val seen = HashSet<Int>()
        val failed = HashSet<Int>()
        var anyOK = false
        for (y in years) {
            val r = fetchGroupYear(y)
            if (r == null || !r.ok) { failed.add(y); continue }
            anyOK = true
            for (s in r.shifts) { val id = s.slot_id ?: continue; if (seen.add(id)) shifts.add(s) }
        }
        if (!anyOK) { Log.i(WB_LOG, "group shifts: every year failed (token not ready?)"); return null }
        Log.i(WB_LOG, "group shifts (chunked): ${shifts.size} slots, failed years ${failed.size}")
        return GroupFetch(shifts, failed)
    }

    private suspend fun fetchGroupYear(y: Int): GroupShiftsResult? =
        fetchGroupRanges(listOf("${y}0101" to "${y}1231"), "group year $y")

    /**
     * The whole group between two Regina dates ("yyyy-MM-dd", inclusive) — the "next 3 months" catch-up on
     * reopening the app. Split at New Year (the endpoint is otherwise always read a year at a time).
     * Null unless every part read cleanly — the caller then falls back to the full read. Swaps are
     * dropped, as in [fetchGroupShifts].
     */
    suspend fun fetchGroupRange(lo: String, hi: String): List<RawSlot>? {
        val ly = lo.take(4).toIntOrNull() ?: return null
        val hy = hi.take(4).toIntOrNull() ?: return null
        if (hy < ly || hy - ly > 1) return null
        val compact = { s: String -> s.replace("-", "") }
        val parts = (ly..hy).map { y -> (if (y == ly) compact(lo) else "${y}0101") to (if (y == hy) compact(hi) else "${y}1231") }
        val r = fetchGroupRanges(parts, "group window $lo…$hi")
        if (r == null || !r.ok) return null
        Log.i(WB_LOG, "group window: ${r.shifts.size} slots")
        return r.shifts
    }

    private suspend fun fetchGroupRanges(parts: List<Pair<String, String>>, label: String): GroupShiftsResult? {
        val ranges = parts.joinToString(",", "[", "]") { "[\"${it.first}\",\"${it.second}\"]" }
        val raw = evalAsync(GROUP_RANGE_JS.replace("__RANGES__", ranges), timeoutMs = 120_000)
        // A year is ~9 MB of JSON — decode it off the main thread so the UI doesn't hitch while it lands.
        val r = raw?.let { withContext(Dispatchers.Default) { decode<GroupShiftsResult>(it) } }
        if (r == null) Log.i(WB_LOG, "$label: fetch/decode failed")
        return r
    }

    // MARK: - Give-away writes (REAL schedule mutations — payloads captured 2026-07-30)
    // These POST to Lightning Bolt using the app's own logged-in web-view token (window.__lbAuth) — no stored
    // creds. Every offer is reversible via cancelOffer(). Nothing here runs unless called from an explicit confirm.

    /**
     * Result of a give-away write. [ok] is TRUE only when LB actually applied it — a 200 can carry a `warnings`
     * array (e.g. "Assignment 'MICU' is incompatible with 'Rapid Response RGH'") meaning the offer was declined.
     */
    data class WriteOutcome(
        val ok: Boolean,
        val message: String?,
        val partial: Boolean = false,   // something DID change on LB even though the whole write didn't finish
    )

    /** Split a shift into parts (each `emp_ids` = who keeps that part). `POST /schedule/split`. */
    suspend fun splitShift(slotID: Int, parts: List<Triple<String, String, Int>>, note: String): WriteOutcome {
        val payload = buildJsonObject {
            put("slot_id", JsonPrimitive(slotID))
            put("splits", buildJsonArray {
                parts.forEach { (start, end, empID) ->
                    add(buildJsonObject {
                        put("start_time", JsonPrimitive(start))
                        put("end_time", JsonPrimitive(end))
                        put("emp_ids", buildJsonArray { add(JsonPrimitive(empID)) })
                    })
                }
            })
            put("note", JsonPrimitive(note))
        }
        return lbPost("https://lbapi.lightning-bolt.com/schedule/split", payload)
    }

    /**
     * Offer a shift to ONE person (a pending replace; carries a note; reversible until accepted).
     * `POST /schedule/update`. [templateID] = the slot's own LB schedule/template (RR is template 6, like ICU).
     */
    suspend fun offerToPerson(slotID: Int, empID: Int, note: String, templateID: Int): WriteOutcome {
        val payload = buildJsonArray {
            add(buildJsonObject {
                put("slot_id", JsonPrimitive(slotID))
                put("emp_id", JsonPrimitive(empID))
                put("note", JsonPrimitive(note))
                put("template_id", JsonPrimitive(templateID))
                put("type", JsonPrimitive("replace personnel"))
            })
        }
        return lbPost("https://lbapi.lightning-bolt.com/schedule/update", payload)
    }

    /** Offer a shift to everyone eligible (classic swaportunity broadcast; LB carries NO note here). */
    suspend fun offerToGroup(slotID: Int, empIDs: List<Int>): WriteOutcome {
        val payload = buildJsonArray {
            add(buildJsonObject {
                put("slot_id", JsonPrimitive(slotID))
                put("emp_ids", buildJsonArray { empIDs.forEach { add(JsonPrimitive(it)) } })
                put("type", JsonPrimitive("preswap_create"))
            })
        }
        return lbPost("https://lbapi.lightning-bolt.com/schedule/preswap", payload)
    }

    /** Withdraw/cancel a pending offer. `POST /schedule/update` with "delete swap". */
    suspend fun cancelOffer(slotID: Int, empID: Int): WriteOutcome {
        val payload = buildJsonArray {
            add(buildJsonObject {
                put("type", JsonPrimitive("delete swap"))
                put("slot_id", JsonPrimitive(slotID))
                put("emp_id", JsonPrimitive(empID))
                put("decision_note", JsonNull)
            })
        }
        return lbPost("https://lbapi.lightning-bolt.com/schedule/update", payload)
    }

    // MARK: - Time-off requests — the signed-in user's OWN requests only; never approve/deny.

    /** LB's request type ids (template 6 = Critical Care). "Default" time only. */
    enum class RequestKind(val label: String, val assignID: Int, val structureID: Int) {
        TimeOff("Time Off", 20248, 343),
        NightOff("Night Off", 20251, 346),
    }

    /**
     * My requests between two YYYYMMDD dates. null = the read failed (no token / every call errored) → the
     * caller keeps its cached list. Tries the whole span in one call, falls back to month-by-month.
     */
    suspend fun fetchMyRequests(startYYYYMMDD: String, endYYYYMMDD: String): List<RawRequest>? {
        val js = "const s = ${jsString(startYYYYMMDD)}, e = ${jsString(endYYYYMMDD)};\n" + REQUESTS_JS
        val r = evalAsync(js)?.let { decode<RequestsResult>(it) }
        if (r == null || !r.ok) { Log.i(WB_LOG, "requests: unavailable (token/emp not ready or all calls failed)"); return null }
        Log.i(WB_LOG, "requests: ${r.requests.size} of mine")
        return r.requests
    }

    /**
     * Submit a time-off / night-off request — one element per day, exactly as LB's own UI sends. `POST /request`.
     * [dates] are "YYYY-MM-DD". Reversible with [deleteRequests] while pending.
     */
    suspend fun submitRequests(kind: RequestKind, dates: List<String>, note: String, empID: Int): WriteOutcome {
        if (dates.isEmpty()) return WriteOutcome(false, "No dates chosen.")
        val payload = buildJsonArray {
            dates.forEach { d ->
                add(buildJsonObject {
                    put("type", JsonPrimitive("new"))
                    put("emp_id", JsonPrimitive(empID))
                    put("date", JsonPrimitive(d + "T00:00:00"))
                    put("assign_id", JsonPrimitive(kind.assignID))
                    put("assign_structure_id", JsonPrimitive(kind.structureID))
                    put("assign_name", JsonPrimitive(kind.label))
                    put("template_id", JsonPrimitive(6))
                    put("command_type", JsonPrimitive(0))
                    put("note", JsonPrimitive(note))
                    put("start_date", JsonNull)
                    put("end_date", JsonNull)
                })
            }
        }
        return lbPost("https://lbapi.lightning-bolt.com/request", payload)
    }

    /** Cancel my own request days (one request_id per day). `POST /request` with type "delete". */
    suspend fun deleteRequests(ids: List<Int>): WriteOutcome {
        if (ids.isEmpty()) return WriteOutcome(false, "Nothing to cancel.")
        val payload = buildJsonArray {
            ids.forEach { id ->
                add(buildJsonObject {
                    put("type", JsonPrimitive("delete"))
                    put("request_id", JsonPrimitive(id))
                    put("decision_note", JsonNull)
                })
            }
        }
        return lbPost("https://lbapi.lightning-bolt.com/request", payload)
    }

    /** POST [payload] to an lbapi endpoint with the captured Bearer, and interpret LB's response. */
    private suspend fun lbPost(url: String, payload: JsonElement): WriteOutcome {
        val bodyLiteral = json.encodeToString(JsonElement.serializer(), payload)
        val js = """
            const auth = window.__lbAuth || '';
            if (!auth) return JSON.stringify({ ok:false, status:0, body:'no-auth' });
            const url = ${jsString(url)};
            const body = ${jsString(bodyLiteral)};
            try {
              const r = await fetch(url, { method:'POST', headers:{ 'Authorization': auth, 'Content-Type':'application/json' }, body: body });
              const t = await r.text();
              return JSON.stringify({ ok: r.ok, status: r.status, body: t.slice(0,400) });
            } catch(e) { return JSON.stringify({ ok:false, status:-1, body: String(e) }); }
        """.trimIndent()

        val r = evalAsync(js)?.let { decode<WriteResult>(it) }
        if (r == null) {
            Log.i(WB_LOG, "LB write $url: failed (token/eval)")
            lastWriteInfo = "eval failed (no token?)"
            return WriteOutcome(false, "Couldn't reach Lightning Bolt. Try again in the app.")
        }
        Log.i(WB_LOG, "LB write $url: ok=${r.ok} status=${r.status}")
        lastWriteInfo = "status ${r.status} · ${r.body ?: ""}"
        // A 200 can still carry a warning/error meaning LB declined it → real success is HTTP-ok AND no message.
        val msg = lbMessage(r.body)
        return WriteOutcome(
            ok = r.ok && msg == null,
            message = if (r.ok) msg else (msg ?: "Lightning Bolt rejected it (status ${r.status})."),
        )
    }

    /** Pull the first human message out of LB's `errors`/`warnings` (object or array-of-objects response). */
    private fun lbMessage(body: String?): String? {
        if (body.isNullOrEmpty()) return null
        val root = runCatching { json.parseToJsonElement(body) }.getOrNull() ?: return null
        val obj: JsonObject? = when (root) {
            is JsonObject -> root
            is JsonArray -> root.firstOrNull() as? JsonObject
            else -> null
        }
        fun firstMsg(any: JsonElement?): String? = (any as? JsonArray)
            ?.mapNotNull { (it as? JsonObject)?.get("message")?.jsonPrimitive?.contentOrNullSafe() }
            ?.firstOrNull { it.isNotEmpty() }
        return firstMsg(obj?.get("errors")) ?: firstMsg(obj?.get("warnings"))
    }

    private fun JsonPrimitive.contentOrNullSafe(): String? = runCatching { content }.getOrNull()

    // MARK: - WebView helpers

    private suspend fun loadAndWait(url: String) {
        val d = CompletableDeferred<Unit>()
        withContext(Dispatchers.Main) {
            navDone = d
            webView.loadUrl(url)
        }
        withTimeoutOrNull(30_000) { d.await() }
        navDone = null
    }

    /**
     * Poll until LbsAppData.Slots is populated (the viewer's data load is async). Returns as soon as the
     * Slots collection has models OR is a stable empty array (the week loaded but nobody's scheduled).
     */
    private suspend fun waitForSlots(): Boolean {
        val js = "((window.LbsAppData && window.LbsAppData.Slots && Array.isArray(window.LbsAppData.Slots.models)) ? window.LbsAppData.Slots.models.length : -1)"
        var emptyStable = 0
        repeat(14) { i ->                                    // up to ~7s (real weeks load in <2s)
            val n = evalRaw(js)?.toIntOrNull() ?: -1
            if (n > 0) return true                           // has shifts
            if (n == 0) { emptyStable++; if (emptyStable >= 2 && i >= 2) return false }
            else emptyStable = 0                             // -1: not loaded yet, keep waiting
            delay(500)
        }
        return false
    }

    /** Poll until the SPA's Bearer has been captured into window.__lbAuth (up to ~6s). */
    private suspend fun waitForToken(): Boolean {
        repeat(24) {
            val t = evalString("window.__lbAuth || ''")
            if (!t.isNullOrEmpty()) return true
            delay(250)
        }
        return false
    }

    /** Evaluate a synchronous expression; returns the raw JSON encoding WebView hands back ("true", "\"x\"", "null"). */
    private suspend fun evalRaw(js: String): String? = withContext(Dispatchers.Main) {
        val d = CompletableDeferred<String?>()
        webView.evaluateJavascript(js) { d.complete(it) }
        withTimeoutOrNull(10_000) { d.await() }
    }

    /** Same, decoded to a Kotlin String when the expression yields a string. */
    private suspend fun evalString(js: String): String? {
        val raw = evalRaw(js) ?: return null
        if (raw == "null") return null
        return runCatching { json.parseToJsonElement(raw).jsonPrimitive.content }.getOrNull() ?: raw
    }

    /**
     * Runs [body] as an async function body and awaits its returned promise — the Android stand-in for
     * WKWebView's `callAsyncJavaScript`. The result streams back through [Bridge] in 256 KB chunks.
     */
    private suspend fun evalAsync(body: String, timeoutMs: Long = 60_000): String? {
        val id = UUID.randomUUID().toString()
        val d = CompletableDeferred<String>()
        pending[id] = d
        val wrapper = """
            (function(){
              var __id = ${jsString(id)};
              (async function(){ $body })().then(function(r){
                try {
                  var s = (r === null || r === undefined) ? '' : String(r);
                  for (var i = 0; i < s.length; i += $CHUNK) { WBBridge.chunk(__id, s.substr(i, $CHUNK)); }
                  WBBridge.done(__id, true, null);
                } catch(e) { WBBridge.done(__id, false, String(e)); }
              }, function(e){ WBBridge.done(__id, false, String(e)); });
            })();
        """.trimIndent()
        withContext(Dispatchers.Main) { webView.evaluateJavascript(wrapper, null) }
        val out = withTimeoutOrNull(timeoutMs) { runCatching { d.await() }.getOrNull() }
        pending.remove(id); buffers.remove(id)
        return out?.takeIf { it.isNotEmpty() }
    }

    private inline fun <reified T> decode(raw: String): T? =
        runCatching { json.decodeFromString<T>(raw) }.getOrElse {
            Log.w(WB_LOG, "decode ${T::class.simpleName} failed: ${it.message}")
            null
        }

    /** Safely embed a Kotlin string as a JS string literal. */
    private fun jsString(s: String): String = json.encodeToString(JsonPrimitive.serializer(), JsonPrimitive(s))
}

// ─────────────────────────────────────────────────────────────────────────────
// The injected JavaScript. Kept verbatim from the iOS app so both clients read
// Lightning Bolt exactly the same way.
// ─────────────────────────────────────────────────────────────────────────────

/** Reads my emp_id + display name directly from LbsAppData (no paging). */
private val IDENTITY_JS = """
    const D = window.LbsAppData;
    function emp(){ try {
      if (D.User && D.User.emp_id) return D.User.emp_id;
      if (D.User && D.User.attributes && D.User.attributes.emp_id) return D.User.attributes.emp_id;
      if (D.MyPersonnel && D.MyPersonnel.models && D.MyPersonnel.models[0]) return D.MyPersonnel.models[0].attributes.emp_id;
    } catch(e){} return null; }
    function nm(){ try {
      if (D.MyPersonnel && D.MyPersonnel.models && D.MyPersonnel.models[0]){ var a=D.MyPersonnel.models[0].attributes; return a.display_name || ((a.first_name||'')+' '+(a.last_name||'')).trim(); }
      if (D.User && D.User.attributes && D.User.attributes.display_name) return D.User.attributes.display_name;
    } catch(e){} return ''; }
    var e = emp();
    return JSON.stringify({ emp: (e!=null?(''+e):''), me: nm() });
""".trimIndent()

/**
 * A few requests in flight at once (results kept in order) — 14 one-after-another month reads were the
 * slowest part of every pool refresh. getRows = the page's rows, or null if that read failed.
 */
private val POOL_JS = """
    async function inPool(n, items, fn){ const res = new Array(items.length); let next = 0;
      async function worker(){ while (next < items.length){ const k = next++; res[k] = await fn(items[k]); } }
      await Promise.all(Array.from({ length: Math.min(n, items.length) }, worker)); return res; }
    async function getRows(url, auth){ try {
        const r = await fetch(url, { headers: { Authorization: auth } }); if (!r.ok) return null;
        const j = await r.json(); return Array.isArray(j) ? j : (j.data || j.slots || []);
      } catch(e){ return null; } }
""".trimIndent() + "\n"

/**
 * One fetch per month across the roster (4 at a time); dedup by slot_id. Same query the human-icon widget
 * makes. Starts at the current REGINA month (__YM__ from Kotlin).
 */
private val OPEN_OFFERS_JS = POOL_JS + """
    const D = window.LbsAppData;
    let emp = '';
    try { emp = (D && D.User && (D.User.emp_id || (D.User.attributes && D.User.attributes.emp_id))) || ''; } catch(e){}
    const auth = window.__lbAuth || '';
    if (!emp || !auth) return JSON.stringify({ ok:false, pending:[] });
    function endOf(y,m){ return new Date(Date.UTC(y, m, 0)).getUTCDate(); }
    const out = [], seen = {};
    let anyOk = false;   // did ANY request succeed? if not (e.g. expired token) report failure so the pool isn't wiped
    const S = '__YM__';
    let y = parseInt(S.slice(0,4), 10), m = parseInt(S.slice(4,6), 10);
    if (!(y > 2000) || !(m >= 1 && m <= 12)) { const now = new Date(); y = now.getUTCFullYear(); m = now.getUTCMonth()+1; }
    const months = [];
    for (let i=0;i<14;i++){ months.push([y, m]); m++; if (m>12){ m=1; y++; } }
    const pages = await inPool(4, months, function(ym){
      const mm = ('0'+ym[1]).slice(-2), dd = ('0'+endOf(ym[0],ym[1])).slice(-2);
      return getRows('https://lbapi.lightning-bolt.com/schedule/range/?start_date='+ym[0]+mm+'01&end_date='+ym[0]+mm+dd+'&listed=true&emp_id='+emp+'&only_pending=true', auth);
    });
    for (let p=0;p<pages.length;p++){ const arr = pages[p]; if (!arr) continue;
      anyOk = true;
      for (let k=0;k<arr.length;k++){ const a = arr[k];
        if (a && a.is_pending && a.slot_id && !seen[a.slot_id]) { seen[a.slot_id]=1;
          out.push({ slot_id:a.slot_id, date:a.slot_date, start:a.start_time, stop:a.stop_time,
                     unit:a.assign_display_name||a.assign_compact_name||'', offerer:a.display_name||'',
                     emp:(a.emp_id!=null?(''+a.emp_id):''), template_id:a.template_id,
                     pending_emp:(a.pending_emp_id!=null?(''+a.pending_emp_id):null), pending_name:(a.pending_display_name||null) }); } }
    }
    return JSON.stringify({ ok: anyOk, pending: out });
""".trimIndent()

/** One authed call to /personnel; map each person → emp_id + name + cell + email (robust field fallbacks). */
private val DIRECTORY_JS = """
    const auth = window.__lbAuth || '';
    if (!auth) return JSON.stringify({ ok:false, people:[] });
    const out = [];
    try {
      const r = await fetch('https://lbapi.lightning-bolt.com/personnel/', { headers: { Authorization: auth } });
      if (!r.ok) return JSON.stringify({ ok:false, people:[] });
      const j = await r.json();
      const arr = Array.isArray(j) ? j : (j.data || j.personnel || j.people || []);
      for (let i=0;i<arr.length;i++){ const a = arr[i]; if (!a || a.emp_id==null) continue;
        const nm = a.display_name || ((a.first_name||'')+' '+(a.last_name||'')).trim() || '';
        const cell = a.phone_cell || a.cell || a.phone_mobile || a.mobile || a.phone || '';
        out.push({ emp:(''+a.emp_id), name:nm, cell:(''+cell), email:(a.email||'') }); }
      return JSON.stringify({ ok:true, people: out });
    } catch(e){ return JSON.stringify({ ok:false, people:[] }); }
""".trimIndent()

/**
 * ONE call per year (the endpoint serves a whole year at once, 3 years in flight), start-year → next
 * year (to catch the future roster; __ENDY__ = Regina year + 1 from Kotlin). Fast even over several years.
 */
private val MY_SHIFTS_JS = POOL_JS + """
    const D = window.LbsAppData;
    let emp = '';
    try { emp = (D && D.User && (D.User.emp_id || (D.User.attributes && D.User.attributes.emp_id))) || ''; } catch(e){}
    const auth = window.__lbAuth || '';
    if (!emp || !auth) return JSON.stringify({ ok:false, shifts:[] });
    const startY = parseInt('__SINCE__'.slice(0,4), 10);
    let endY = parseInt('__ENDY__', 10);
    if (!(endY > 2000)) endY = new Date().getUTCFullYear() + 1;
    const out = [], seen = {}, years = [];
    for (let y = startY; y <= endY; y++) years.push(y);
    let anyOk = false, allOk = true;
    const pages = await inPool(3, years, function(y){
      return getRows('https://lbapi.lightning-bolt.com/schedule/range/?start_date='+y+'0101&end_date='+y+'1231&listed=true&emp_id='+emp, auth);
    });
    for (let p=0;p<pages.length;p++){ const arr = pages[p];
      if (!arr) { allOk = false; continue; }
      anyOk = true;
      for (let k=0;k<arr.length;k++){ const a = arr[k];
        if (a && a.slot_id && (''+a.emp_id) === (''+emp) && !seen[a.slot_id]) { seen[a.slot_id]=1;
          out.push({ slot_id:a.slot_id, date:a.slot_date, start:a.start_time, stop:a.stop_time,
                     unit:a.assign_display_name||a.assign_compact_name||'', offerer:a.display_name||'',
                     emp:(''+a.emp_id), template_id:a.template_id }); } }
    }
    return JSON.stringify({ ok: anyOk, all: allOk, shifts: out });
""".trimIndent()

/**
 * The whole group (no emp filter) over date ranges (__RANGES__ = [[startYYYYMMDD, endYYYYMMDD], …] — one
 * whole year, or the near window): slots + changed-hands swaps, giver resolved within what was read.
 * ok only when EVERY range read and parsed — a half-read must never replace cached history.
 */
private val GROUP_RANGE_JS = """
    const auth = window.__lbAuth || '';
    if (!auth) return JSON.stringify({ ok:false, shifts:[], swaps:[] });
    const R = __RANGES__;
    const out = [], seen = {}, empName = {}, swapSeen = {}, swaps = [];
    const pages = await Promise.all(R.map(async function(p){ try {
        const r = await fetch('https://lbapi.lightning-bolt.com/schedule/range/?start_date='+p[0]+'&end_date='+p[1]+'&listed=true', { headers: { Authorization: auth } });
        if (!r.ok) return null;
        const j = await r.json(); return Array.isArray(j) ? j : (j.data || j.slots || []);
      } catch(e){ return null; } }));
    const ok = pages.length > 0 && pages.every(function(a){ return a !== null; });
    if (ok) {
      for (let p=0;p<pages.length;p++){ const arr = pages[p];
        for (let k=0;k<arr.length;k++){ const a = arr[k];
          if (!a || !a.slot_id) continue;
          if (a.emp_id!=null && a.display_name) empName[''+a.emp_id] = a.display_name;
          if (!seen[a.slot_id]) { seen[a.slot_id]=1;
            out.push({ slot_id:a.slot_id, date:a.slot_date, start:a.start_time, stop:a.stop_time,
                       unit:a.assign_display_name||a.assign_compact_name||'', offerer:a.display_name||'',
                       emp:(a.emp_id!=null?(''+a.emp_id):'') }); }
          if (a.original_emp_id!=null && a.emp_id!=null && (''+a.original_emp_id)!==(''+a.emp_id) && !swapSeen[a.slot_id]) {
            swapSeen[a.slot_id]=1;
            const h = (a.slot_history && a.slot_history[0] && a.slot_history[0].text) || '';
            swaps.push({ slot_id:a.slot_id, date:a.slot_date, start:a.start_time, stop:a.stop_time,
                         unit:a.assign_display_name||a.assign_compact_name||'', toName:a.display_name||'',
                         toEmp:(''+a.emp_id), fromEmp:(''+a.original_emp_id), whenAt:a.modified_date||'', hist:h }); }
        }
      }
    }
    for (let i=0;i<swaps.length;i++){ swaps[i].fromName = empName[swaps[i].fromEmp] || ''; }
    return JSON.stringify({ ok: ok, shifts: out, swaps: swaps });
""".trimIndent()

/** My own time-off requests in [s, e] (YYYYMMDD, declared by the caller) — mine only. */
private val REQUESTS_JS = """
    const D = window.LbsAppData;
    let emp = '';
    try { emp = (D && D.User && (D.User.emp_id || (D.User.attributes && D.User.attributes.emp_id))) || ''; } catch(e){}
    const auth = window.__lbAuth || '';
    if (!emp || !auth) return JSON.stringify({ ok:false, requests:[] });
    const out = [], seen = {};
    function take(j){
      const arr = Array.isArray(j) ? j : (j.data || []);
      for (let k=0;k<arr.length;k++){ const a = arr[k];
        if (!a || a.request_id == null || seen[a.request_id]) continue;
        if (a.emp_id != null && (''+a.emp_id) !== (''+emp)) continue;          // mine only
        seen[a.request_id] = 1;
        out.push({ id:a.request_id, date:(a.request_date||'').slice(0,10), status:a.status||null,
                   kind:a.assign_display_name||null, note:a.message||null, submitted:a.timestamp||null,
                   decision:a.decision_msg||a.denial_reason_name||null });
      }
    }
    async function get(a,b){
      const url = 'https://lbapi.lightning-bolt.com/request/range/?start_date='+a+'&end_date='+b+'&listed=true&emp_id='+emp;
      try { const r = await fetch(url, { headers:{ Authorization: auth } }); if (!r.ok) return false; take(await r.json()); return true; }
      catch(e){ return false; }
    }
    if (await get(s, e)) return JSON.stringify({ ok:true, requests: out });
    // fallback: month by month (the LB UI's own paging)
    let y = +s.slice(0,4), m = +s.slice(4,6); const ey = +e.slice(0,4), em = +e.slice(4,6);
    let anyOk = false, g = 0;
    while ((y < ey || (y === ey && m <= em)) && g < 36) {
      const mm = ('0'+m).slice(-2), last = ('0'+new Date(Date.UTC(y, m, 0)).getUTCDate()).slice(-2);
      if (await get(''+y+mm+'01', ''+y+mm+last)) anyOk = true;
      m++; if (m>12){ m=1; y++; } g++;
    }
    return JSON.stringify({ ok:anyOk, requests: out });
""".trimIndent()

/** Fills + submits LB's own login form. __USER__ / __PASS__ are replaced with escaped JS string literals. */
private val AUTO_LOGIN_JS = """
    (function(){
      try {
        var pw = document.querySelector('input[type=password]');
        if(!pw) return 'no-form';
        var inputs = Array.prototype.slice.call(document.querySelectorAll('input'));
        var user = null;
        for (var i=0;i<inputs.length;i++){ var el=inputs[i]; if(el===pw) continue; var t=(el.type||'').toLowerCase();
          if(t==='text'||t==='email'|| /user|email|login|name/i.test((el.name||'')+' '+(el.id||''))){ user=el; break; } }
        var setVal = function(el, v){ var d=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;
          d.call(el, v); el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true})); };
        if(user) setVal(user, __USER__);
        setVal(pw, __PASS__);
        var btn = document.querySelector('button[type=submit], input[type=submit]');
        if(!btn && pw.form) btn = pw.form.querySelector('button');
        if(btn){ btn.click(); } else if(pw.form){ pw.form.submit(); } else { return 'no-submit'; }
        return 'submitted';
      } catch(e){ return 'err:'+e; }
    })()
""".trimIndent()
