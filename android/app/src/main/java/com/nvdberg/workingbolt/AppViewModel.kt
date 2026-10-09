package com.nvdberg.workingbolt

import android.app.Application
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.nvdberg.workingbolt.data.DemoData
import com.nvdberg.workingbolt.data.GroupSnapshot
import com.nvdberg.workingbolt.data.LBCreds
import com.nvdberg.workingbolt.data.LBWebSource
import com.nvdberg.workingbolt.data.LogSnapshot
import com.nvdberg.workingbolt.data.OpenShiftBuilder
import com.nvdberg.workingbolt.data.RawSlot
import com.nvdberg.workingbolt.data.Snapshot
import com.nvdberg.workingbolt.data.Store
import com.nvdberg.workingbolt.data.Supabase
import com.nvdberg.workingbolt.data.WB_LOG
import com.nvdberg.workingbolt.model.Assignment
import com.nvdberg.workingbolt.model.ConflictEngine
import com.nvdberg.workingbolt.model.Contact
import com.nvdberg.workingbolt.model.MyScheduleModel
import com.nvdberg.workingbolt.model.MyPost
import com.nvdberg.workingbolt.model.MyShift
import com.nvdberg.workingbolt.model.OpenShift
import com.nvdberg.workingbolt.model.RecentTake
import com.nvdberg.workingbolt.model.SwapOption
import com.nvdberg.workingbolt.model.SwapStatus
import com.nvdberg.workingbolt.model.TimeOffRequest
import com.nvdberg.workingbolt.model.UnitKey
import com.nvdberg.workingbolt.model.Units
import com.nvdberg.workingbolt.ui.Prefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * The app's single state holder — the Android counterpart of AppModel in HackingBoltApp.swift.
 * Cached data is published immediately on construction; the live Lightning Bolt read happens in the
 * background once a session is detected.
 */
class AppViewModel(app: Application) : AndroidViewModel(app) {

    companion object {
        const val HISTORY_START = "20220101"       // the group's data on Lightning Bolt begins in 2022
        private const val GROUP_MAX_AGE = 12 * 3600_000L   // full group re-read at most every 12h; between, the window

        fun todayRegina(): String = LBWebSource.todayRegina()

        /**
         * Collapse a day's assignments so a Pasqua Rapid Response (day) + Pasqua-MSU (night) worked by the
         * SAME doctor become ONE 24h "Pasqua" shift (08:00→08:00, overnight).
         */
        fun mergePasqua(asgs: List<Assignment>): List<Assignment> {
            val out = ArrayList<Assignment>(asgs.size)
            for ((_, g) in asgs.groupBy { "${it.doc}|${it.date}" }) {
                val p = g.firstOrNull { it.unit == UnitKey.PRR }
                val m = g.firstOrNull { it.unit == UnitKey.MSU }
                if (p != null && m != null) {
                    out.add(p.copy(end = m.end, overnight = true, slotID = p.slotID, slotID2 = m.slotID))
                    out.addAll(g.filter { it.unit != UnitKey.PRR && it.unit != UnitKey.MSU })
                } else {
                    out.addAll(g)
                }
            }
            return out
        }

        private val REGINA: ZoneId = ZoneId.of("America/Regina")

        /** True while a shift on [date] starting at [start] ("HH:mm") hasn't begun yet (Regina time). */
        fun notStarted(date: String, start: String): Boolean {
            val today = todayRegina()
            if (date != today) return date > today
            return start > LocalDateTime.now(REGINA).format(DateTimeFormatter.ofPattern("HH:mm"))
        }

        /** The tag that pairs the two halves of a swap (stored as the offer note's `reason`). */
        fun swapTagString(back: Boolean, toEmp: Int, slots: List<Int>): String =
            "${if (back) "swapback" else "swap"}:$toEmp:${slots.joinToString(",")}"

        fun parseSwapTag(reason: String?): SwapTag? {
            val p = (reason ?: return null).split(":")
            if (p.size != 3 || (p[0] != "swap" && p[0] != "swapback")) return null
            val to = p[1].toIntOrNull() ?: return null
            val slots = p[2].split(",").mapNotNull { it.toIntOrNull() }
            if (slots.isEmpty()) return null
            return SwapTag(p[0] == "swapback", to, slots)
        }
    }

    /** `swap:<toEmp>:<slots I get back>` on the first half, `swapback:<toEmp>:<slots they took>` on the return. */
    data class SwapTag(val back: Boolean, val toEmp: Int, val slots: List<Int>)

    /** A swap a colleague sent me: their shift (offered to me) for one of mine. */
    data class IncomingSwap(
        val slot: Int, val fromEmp: Int, val from: String,
        val theirsDate: String, val theirsUnit: UnitKey,
        val mine: MyShift,
        val taken: Boolean,          // I already hold their shift — only my half is left to send back
        val acceptURL: String?,
    )

    /** A swap I sent that was declined or cancelled (my shift came back to me). */
    data class DeclinedSwap(val slot: Int, val mine: MyShift, val to: String)

    val source = LBWebSource(app)
    private val store = Store(app)
    private val prefs = Prefs.get(app)
    private val json = Json { ignoreUnknownKeys = true }
    private val stringMap = MapSerializer(String.serializer(), String.serializer())

    /** Set by the activity: shows the fingerprint / face prompt (the view model has no window to show it in). */
    var biometricPrompt: (suspend (String) -> Boolean)? = null

    // ── published state ──────────────────────────────────────────────────────
    var openShifts by mutableStateOf<List<OpenShift>>(emptyList()); private set
    var myShifts by mutableStateOf<List<MyShift>>(emptyList()); private set
    var assignments by mutableStateOf<List<Assignment>>(emptyList()); private set   // live-window fallback
    var shiftLog by mutableStateOf<List<MyShift>>(emptyList()); private set         // durable: my past + future
    var groupLog by mutableStateOf<List<Assignment>>(emptyList()); private set      // whole group's history
    var roster by mutableStateOf<Map<Int, String>>(emptyMap()); private set         // emp_id → display name
    var directory by mutableStateOf<Map<Int, Contact>>(emptyMap()); private set
    var whoByDay by mutableStateOf<Map<String, List<Assignment>>>(emptyMap()); private set
    var whoDays by mutableStateOf<List<String>>(emptyList()); private set
    /** Non-clinical roster entries (time off / vacation / admin): date → doctor → the raw LB label. */
    var offByDay by mutableStateOf<Map<String, Map<String, String>>>(emptyMap()); private set

    var userName by mutableStateOf(""); private set
    var userEmp by mutableStateOf(""); private set
    var loggedIn by mutableStateOf(false); private set
    var loading by mutableStateOf(false); private set
    var syncing by mutableStateOf(false); private set
    var groupScanning by mutableStateOf(false); private set
    var lastUpdated by mutableStateOf<Long?>(null); private set
    var showLogin by mutableStateOf(false); private set
    var demo by mutableStateOf(false); private set
    var selectedTab by mutableStateOf(0)
    var poolJumpDate by mutableStateOf<String?>(null)

    /** Shifts that left the pool in the last 2 days (no names) — the Pool's "Recently taken". */
    var recentlyTaken by mutableStateOf<List<RecentTake>>(emptyList()); private set
    /** My posts that were picked up (from the shared backend). */
    var pickedUp by mutableStateOf<List<MyPost>>(emptyList()); private set
    private var myPostNotes by mutableStateOf<Map<Int, String>>(emptyMap())
    private var demoPosts by mutableStateOf<List<MyPost>>(emptyList())
    var myRequests by mutableStateOf<List<TimeOffRequest>>(emptyList()); private set
    var requestsLoading by mutableStateOf(false); private set
    /** Days I marked busy (date → note). Stored on this device only — never sent anywhere. */
    var busyDays by mutableStateOf<Map<String, String>>(emptyMap()); private set
    private var swapNotes by mutableStateOf<List<Supabase.OfferNote>>(emptyList())
    private var swapSeen by mutableStateOf(prefs.getIntSet("wb_swap_seen"))
    private var swapSettled by mutableStateOf(prefs.getIntSet("wb_swap_settled"))
    private var swapDismissed by mutableStateOf(prefs.getIntSet("wb_swap_dismissed"))

    val hasData: Boolean get() = openShifts.isNotEmpty() || myShifts.isNotEmpty()

    /** Full history if loaded, else the live window. */
    val whoData: List<Assignment> get() = if (groupLog.isEmpty()) assignments else groupLog

    private var started = false
    private var historyLoadedAt: Long? = null
    private var groupLoadedAt: Long? = null
    private var directoryLoadedAt: Long? = null
    private var poolRefreshing = false
    private var rosterLatest = mutableMapOf<Int, String>()   // emp_id → latest shift date seen
    private var periodic: Job? = null
    private var didFirstActivate = false
    private var triedAutoLogin = false
    private var requestsLoadedAt: Long? = null

    init {
        busyDays = prefs.getString("wb_busy_days")
            ?.let { runCatching { json.decodeFromString(stringMap, it) }.getOrNull() } ?: emptyMap()
        // Show last-known data + durable logs instantly, before any network work.
        viewModelScope.launch {
            store.loadLog()?.let { s ->
                shiftLog = s.shifts
                userEmp = s.owner
                historyLoadedAt = if (s.startUsed == HISTORY_START) s.historyAt else null
            }
            store.loadCache()?.let { s ->
                openShifts = s.open; myShifts = s.mine; userName = s.me
                lastUpdated = s.updated.takeIf { it > 0 }; assignments = s.assigns
            }
            store.loadGroup()?.let { s ->
                if (userEmp.isEmpty() || s.owner == userEmp) { groupLog = s.assigns; groupLoadedAt = s.loadedAt }
            }
            store.loadRequests()?.let { myRequests = it }
            rebuildWho()
        }
    }

    /** Runs once when the UI appears: cached data is already on screen; log in + refresh in the background. */
    fun start() {
        if (started) return
        started = true
        source.loadLogin()
        viewModelScope.launch { detectLoginLoop() }
    }

    /**
     * Poll the hidden web view for a live session; refresh when found. If not signed in and there's no
     * cached data, reveal the login screen. (With a persisted session this flips to logged-in in ~1–2s.)
     */
    private suspend fun detectLoginLoop() {
        var i = 0
        while (viewModelScope.isActive) {
            if (demo) return                       // in sample-data mode there's no session to wait for
            if (source.isLoggedIn()) {
                loggedIn = true
                showLogin = false
                prefs.signedOut = false
                triedAutoLogin = false
                refresh()
                // Preload the per-year API backfills so the full roster + whole-group data (Who's On, Crew)
                // are ready before those tabs are opened.
                viewModelScope.launch { loadHistory() }
                viewModelScope.launch { loadGroupHistory() }
                return
            }
            if (i == 6) {                                  // ~3s with no session
                if (!triedAutoLogin && !prefs.signedOut) {
                    triedAutoLogin = true
                    if (autoLoginAndLoad()) return         // kept credentials signed us back in
                }
                if (!hasData) showLogin = true             // nothing cached → must sign in
            }
            i++
            // Poll fast while auto-restoring a session; once the login screen is up (waiting on the user),
            // back off so we're not evaluating JS in the web view twice a second forever (battery).
            delay(if (showLogin) 2_500 else 500)
        }
    }

    /**
     * Auto-login (opt-in; credentials encrypted on this device — see [LBCreds]). Two modes: biometric (prompts a
     * fingerprint / face check) or "Keep me signed in" (silent). Fills + submits LB's own login form, waits for
     * the session, loads data. Returns true if signed in; false if neither mode is on / the user cancels.
     */
    suspend fun autoLoginAndLoad(): Boolean {
        if (demo) return false
        val ctx = getApplication<Application>()
        val bio = prefs.biometricLogin && LBCreds.biometricsAvailable(ctx)
        // After an explicit sign-out, silent "keep me signed in" must not log the previous person back in on a
        // shared phone — only a biometric match (tapped "Sign in") may.
        val plain = prefs.keepSignedIn && !prefs.signedOut
        if (!bio && !plain) return false
        if (!LBCreds.isEnabled(ctx)) return false
        if (bio && biometricPrompt?.invoke("Sign in to Lightning Bolt") != true) return false
        val c = LBCreds.load(ctx) ?: return false
        if (!source.autoSignIn(c.first, c.second)) return false
        repeat(12) {                                       // wait up to ~12s for the submitted login to take
            delay(1_000)
            if (source.isLoggedIn()) {
                loggedIn = true; showLogin = false; triedAutoLogin = false
                prefs.signedOut = false
                refresh()
                viewModelScope.launch { loadHistory() }
                viewModelScope.launch { loadGroupHistory() }
                return true
            }
        }
        return false
    }

    fun signIn() {
        viewModelScope.launch { if (!autoLoginAndLoad()) showLogin = true }
    }

    /**
     * Enter the no-login preview: fill every screen with deterministic sample data and drop straight into
     * the app. Nothing hits the network (refresh/history all bail while [demo] is set).
     */
    fun enterDemo() {
        val data = DemoData.build(todayRegina())
        demo = true
        userName = DemoData.ME
        userEmp = "demo"
        shiftLog = data.mine
        myShifts = data.mine
        groupLog = data.group
        assignments = data.group
        openShifts = data.open
        demoPosts = DemoData.posts(todayRegina())
        myRequests = DemoData.requests(todayRegina())
        if (prefs.selectedDocs.isEmpty()) prefs.updateSelectedDocs(DemoData.others.take(4).joinToString("\n"))
        roster = DemoData.roster()
        directory = DemoData.roster().mapValues { Contact("", "") }
        lastUpdated = System.currentTimeMillis()
        loggedIn = false
        syncing = false
        showLogin = false
        rebuildWho()
    }

    /**
     * Sign out of Lightning Bolt and wipe this device's cached data, so the next person to log in gets
     * their own roster loaded fresh (handy for demos on a shared phone).
     */
    fun signOut() {
        source.signOut()
        shiftLog = emptyList(); groupLog = emptyList()
        myShifts = emptyList(); openShifts = emptyList(); assignments = emptyList()
        whoByDay = emptyMap(); whoDays = emptyList(); roster = emptyMap(); directory = emptyMap()
        userName = ""; userEmp = ""; demo = false
        historyLoadedAt = null; groupLoadedAt = null; directoryLoadedAt = null; lastUpdated = null
        loggedIn = false; showLogin = true
        // An explicit sign-out stays signed out: no silent auto-login for the next person on this phone.
        triedAutoLogin = true
        prefs.signedOut = true
        periodic?.cancel(); periodic = null
        rosterLatest = mutableMapOf(); offByDay = emptyMap()
        pickedUp = emptyList(); myPostNotes = emptyMap(); demoPosts = emptyList(); recentlyTaken = emptyList()
        myRequests = emptyList(); requestsLoadedAt = null; swapNotes = emptyList()
        prefs.putString("wb_offer_targets", null)
        prefs.updateSelectedDocs("")
        startPeriodic()
        viewModelScope.launch {
            store.clearAll()
            source.loadLogin()
            detectLoginLoop()   // watch for the next sign-in and load their data
        }
    }

    // MARK: - Keeping data current (foreground + periodic)

    /**
     * Called when the app comes to the foreground. The very first activation is handled by [start];
     * after that, re-scrape when the data is stale so the pool is current whenever you open the app.
     */
    fun onForeground() {
        if (!didFirstActivate) { didFirstActivate = true; startPeriodic(); return }
        if (loggedIn) {
            viewModelScope.launch {
                if (isStale) {
                    // Been away long enough that the ~1h LB token may have expired: proactively re-capture the
                    // session AND refresh the group data (Who's On / Crew / the swap engine) BEFORE any tab is
                    // opened, so you never land on a stale screen. This is the prevention for "opened it and
                    // last week's roster showed".
                    refresh()                       // reloads the web view → fresh token + pool + my shifts
                    // who's-on / crew, current: while the full history is still within its normal age, re-read
                    // just the next 3 months (a fraction of the multi-MB full read); otherwise re-read it all.
                    val t = groupLoadedAt
                    val windowOK = t != null && System.currentTimeMillis() - t < GROUP_MAX_AGE && refreshGroupWindow()
                    if (!windowOK) loadGroupHistory(force = true)
                } else {
                    // Recently active: just a light pool refresh — unless it failed (token expired), then
                    // escalate to a full re-capture.
                    if (!refreshOpenShifts()) refresh()
                }
            }
        }
        startPeriodic()
    }

    fun onBackground() { periodic?.cancel(); periodic = null }

    private val isStale: Boolean
        get() {
            val t = lastUpdated ?: return true
            // The light pool fetch on every foreground keeps open shifts current; only escalate to the heavy
            // full harvest when the data is genuinely old, so reopening the app stays snappy.
            return System.currentTimeMillis() - t > 20 * 60 * 1000
        }

    /**
     * While the app is open: a LIGHT pool refresh every 2 min (so newly-posted shifts appear quickly),
     * and a FULL harvest every ~30 min (roster + who's on) — the light fetch covers the pool between them.
     */
    private fun startPeriodic() {
        if (periodic != null) return
        periodic = viewModelScope.launch {
            var tick = 0
            while (isActive) {
                delay(2 * 60 * 1000)
                if (!loggedIn) continue
                val ok = refreshOpenShifts()
                tick++
                // full harvest every ~30 min, OR right away if the pool fetch failed (recover the expired token)
                if (!ok || tick % 15 == 0) refresh()
            }
        }
    }

    suspend fun refresh() {
        if (demo) return                                        // sample-data mode: never overwrite with a live fetch
        if (loading || groupScanning || poolRefreshing) return  // don't fight a pool refresh / deep scan for the web view
        loading = true; syncing = true
        try {
            Log.i(WB_LOG, "refresh: begin")
            val raw = source.harvest() ?: return
            // don't wipe good cached data if a read came back empty (e.g. session dropped mid-harvest)
            if (raw.mine.isEmpty() && raw.pending.isEmpty()) { Log.i(WB_LOG, "refresh: empty — keeping cache"); return }
            if (raw.me.isNotEmpty()) userName = raw.me
            raw.emp?.takeIf { it.isNotEmpty() }?.let { e ->
                if (userEmp.isNotEmpty() && userEmp != e) {     // different person → fresh logs
                    shiftLog = emptyList(); historyLoadedAt = null
                    groupLog = emptyList(); groupLoadedAt = null
                }
                userEmp = e
            }
            // harvest's `mine` deterministically covers Jan 1 this year → Dec 31 next year. REPLACE that whole
            // window with the fresh result — so a shift you gave away disappears — but KEEP everything outside
            // it (past years: historical, never change).
            if (raw.mine.isNotEmpty()) {
                val fresh = OpenShiftBuilder.roster(raw.mine)
                val lo = currentYearStartISO()
                val hi = nextYearEndISO()
                myShifts = (myShifts.filter { it.date < lo || it.date > hi } + fresh).sortedBy { it.date }
            }
            mergeFuture(myShifts)                     // refresh the durable log's present+future (past is kept)
            if (groupLog.isEmpty()) rebuildWho()      // until the group backfill lands, Who's On uses cached assignments
            // A failed open-offer read keeps the cached pool (never wipe it to empty).
            if (raw.offersOK) openShifts = OpenShiftBuilder.build(raw.pending, MyScheduleModel(myShifts), todayRegina())
            lastUpdated = System.currentTimeMillis()
            saveCache()
            Log.i(WB_LOG, "refresh DONE: open=${openShifts.size} mine=${myShifts.size}")
        } finally {
            loading = false; syncing = false
        }
    }

    /**
     * A fast, lightweight pool refresh: re-fetch ONLY the open-offer list (one light API call) and rebuild
     * the pool. Returns false when the live fetch FAILED (e.g. the ~1h token expired) — the caller then
     * triggers a full [refresh], which reloads the web view and re-captures a fresh token. On failure we keep
     * the current pool (never wipe it to empty).
     */
    suspend fun refreshOpenShifts(): Boolean {
        if (demo || !loggedIn || loading || groupScanning || poolRefreshing) return true
        poolRefreshing = true
        try {
            val pending = source.fetchOpenOffers() ?: run {
                Log.i(WB_LOG, "pool refresh: live fetch failed (token expired?) — keeping pool")
                return false
            }
            // Slots worth watching: my own open offers + either half of a swap that involves me. When one of
            // them leaves the pool, a shift changed hands → re-read my roster right away.
            val me = userEmp.toIntOrNull()
            val swapSlots = swapNotes.filter { n ->
                val t = parseSwapTag(n.reason)
                t != null && me != null && (t.toEmp == me || n.by_emp == me)
            }.map { it.slot_id }.toSet()
            val myOffers = openShifts.filter { me != null && it.offererEmp == me }.mapNotNull { it.id.toIntOrNull() }.toSet()
            val watched = (myOffers + swapSlots).intersect(openSlotIDs)

            openShifts = OpenShiftBuilder.build(pending, MyScheduleModel(myShifts), todayRegina())
            lastUpdated = System.currentTimeMillis()
            saveCache()
            Log.i(WB_LOG, "pool refresh: ${openShifts.size} open")

            val nowOpen = openSlotIDs
            val mySwaps = mySwapProposals.map { it.first }.toSet()
            val back = mySwaps.intersect(nowOpen)
            if (!swapSeen.containsAll(back)) {             // a swap of mine is pending again → track it afresh
                swapSeen = swapSeen + back; swapSettled = swapSettled - back; swapDismissed = swapDismissed - back
                saveSwapSets()
            }
            val left = mySwaps.intersect(swapSeen) - nowOpen - swapSettled
            if ((watched - nowOpen).isNotEmpty() || left.isNotEmpty()) {
                viewModelScope.launch {
                    refreshWhenIdle()
                    if (left.isNotEmpty()) { swapSettled = swapSettled + left; saveSwapSets() }
                }
            }
            viewModelScope.launch { loadSwapNotes() }
            return true
        } finally {
            poolRefreshing = false
        }
    }

    // MARK: - Durable shift log

    private fun logKey(s: MyShift) = "${s.date}|${s.unit.name}|${s.start}"

    /** Refresh the present+future of the log from the live roster; the recorded past is never touched. */
    private fun mergeFuture(fresh: List<MyShift>) {
        if (fresh.isEmpty()) return
        val today = todayRegina()
        val byKey = LinkedHashMap<String, MyShift>()
        for (s in shiftLog) if (s.date < today) byKey[logKey(s)] = s   // keep the past, always
        for (s in fresh) byKey[logKey(s)] = s                          // fresh owns today + future (dynamic)
        shiftLog = byKey.values.sortedBy { it.date }
        saveLog()
    }

    /** Union freshly-fetched history into the log — the past is authoritative and permanent. */
    private fun mergePast(history: List<MyShift>) {
        if (history.isEmpty()) return
        val byKey = LinkedHashMap<String, MyShift>()
        for (s in shiftLog) byKey[logKey(s)] = s     // everything already on file stays
        for (s in history) byKey[logKey(s)] = s      // add anything new
        shiftLog = byKey.values.sortedBy { it.date }
        saveLog()
    }

    /** Backfill the log from 2022 → today (once, then cached). Called lazily when My Shifts opens. */
    suspend fun loadHistory(force: Boolean = false) {
        if (demo) return
        if (!force) {
            val t = historyLoadedAt
            if (t != null && System.currentTimeMillis() - t < 12 * 3600 * 1000 && shiftLog.isNotEmpty()) return
        }
        if (!loggedIn) return
        var tries = 0                                                     // wait out any live web-view work first
        while ((loading || poolRefreshing || groupScanning) && tries < 30) { delay(500); tries++ }
        if (loading || poolRefreshing || groupScanning) return
        // require a non-empty result before marking it done, so a partial/early fetch keeps retrying next open
        val raw = source.fetchMyShifts(HISTORY_START)?.takeIf { it.isNotEmpty() } ?: return
        mergePast(OpenShiftBuilder.roster(raw))
        historyLoadedAt = System.currentTimeMillis()
        saveLog()
    }

    /**
     * Backfill the whole group's history (2022 → next year) via schedule/range with no emp filter — a few
     * fast API calls. Cached; re-runs only when stale.
     */
    suspend fun loadGroupHistory(force: Boolean = false) {
        if (!loggedIn || demo) return
        // Who's On / Crew history rarely changes for past days → cache 12h.
        val t = groupLoadedAt
        if (!force && t != null && System.currentTimeMillis() - t < GROUP_MAX_AGE && groupLog.isNotEmpty() && roster.isNotEmpty()) return
        // WAIT for any in-flight harvest rather than bailing — bailing here leaves the colleague roster empty.
        var tries = 0
        while ((loading || groupScanning) && tries < 60) { delay(500); tries++ }
        if (groupScanning) return
        groupScanning = true
        try {
            var years = yearsToFetch()
            var got = source.fetchGroupShifts(years)
            if (got == null || got.shifts.isEmpty()) {
                // Fetch came back empty → the ~1h Lightning Bolt token likely expired, which leaves Who's On /
                // Crew stuck on stale data (today missing from the range). Re-capture the token and retry once so
                // it self-heals without a manual sign-out/in (matches loadDirectory).
                groupScanning = false                    // release: refresh() guards on this flag
                refresh()
                groupScanning = true
                years = yearsToFetch()
                got = source.fetchGroupShifts(years)
            }
            if (got == null || got.shifts.isEmpty()) {
                Log.i(WB_LOG, "group history: fetch failed even after refresh — token not ready?")
                return
            }
            val shifts = got.shifts
            val failed = got.failedYears
            mergeRoster(shifts)          // colleagues emp_id → name, for the give-away picker
            buildOffRoster(shifts)       // non-clinical entries (time off) → offByDay
            val myEmp = userEmp
            val fetched = years.toSet() - failed
            val old = groupLog
            // The heavy parse — tens of thousands of slots → assignments — off the main thread. Years that were
            // not (or not successfully) fetched keep their cached entries.
            val merged = withContext(Dispatchers.Default) {
                val asgs = OpenShiftBuilder.assignments(shifts, myEmp)
                if (asgs.isEmpty()) emptyList()
                else (asgs + old.filter { (it.date.take(4).toIntOrNull() ?: 0) !in fetched }).sortedBy { it.date }
            }
            if (merged.isNotEmpty()) {
                groupLog = merged
                if (failed.isEmpty()) groupLoadedAt = System.currentTimeMillis()
                saveGroup()
                rebuildWho()
            }
        } finally {
            groupScanning = false
        }
    }

    /**
     * Coming back to the app after a while: re-read only the group roster from a week ago to 3 months ahead —
     * where swaps and pickups actually happen — and splice it into the cached history. The full read stays on
     * its normal 12h schedule. Lands only on a complete, non-empty read; anything else returns false so the
     * caller falls back to the full read. Never touches entries outside the window.
     */
    suspend fun refreshGroupWindow(): Boolean {
        if (!loggedIn || demo || groupLog.isEmpty() || roster.isEmpty() || loading || groupScanning) return false
        groupScanning = true
        try {
            val today = LocalDate.now(REGINA)
            val lo = today.minusDays(7).toString()
            val hi = today.plusDays(90).toString()
            val shifts = source.fetchGroupRange(lo, hi)?.takeIf { it.isNotEmpty() } ?: run {
                Log.i(WB_LOG, "group window $lo…$hi failed → full read")
                return false
            }
            val inWindow = { d: String -> d >= lo && d <= hi }
            val myEmp = userEmp
            val old = groupLog
            val merged = withContext(Dispatchers.Default) {
                val asgs = OpenShiftBuilder.assignments(shifts, myEmp)
                if (asgs.isEmpty()) null else (asgs + old.filter { !inWindow(it.date) }).sortedBy { it.date }
            } ?: return false
            groupLog = merged
            saveGroup()                  // groupLoadedAt untouched — the full read keeps its own schedule
            mergeRoster(shifts)
            val off = HashMap<String, MutableMap<String, String>>()
            for ((d, m) in offByDay) if (!inWindow(d)) off[d] = m.toMutableMap()   // outside the window stays
            addOffEntries(shifts, off)
            offByDay = off
            Log.i(WB_LOG, "group window $lo…$hi: ${shifts.size} slots")
            rebuildWho()
            return true
        } finally {
            groupScanning = false
        }
    }

    /**
     * Which years the group fetch needs: past years never change, so once they're on file only the live years
     * (this year + next; last year too during January) are re-read.
     */
    private fun yearsToFetch(): List<Int> {
        val now = LocalDate.now(REGINA)
        val liveFrom = if (now.monthValue == 1) now.year - 1 else now.year
        val have = groupLog.mapNotNull { it.date.take(4).toIntOrNull() }.toSet()
        return (2022..now.year + 1).filter { it >= liveFrom || it !in have }
    }

    private fun mergeRoster(slots: List<RawSlot>) {
        // Only people who work a CLINICAL unit — keeps non-physician/other-dept entries out. Track each doc's
        // latest shift date (for the active filter) and skip LB's "EMPTY" vacancy placeholder (emp 4).
        val r = roster.toMutableMap()
        for (s in slots) {
            if (Units.key(s.unit) == null) continue
            val e = s.emp?.toIntOrNull() ?: continue
            if (e == 4) continue
            val n = s.offerer?.takeIf { it.isNotEmpty() } ?: continue
            r[e] = n
            val d = s.date
            if (d != null && d > (rosterLatest[e] ?: "")) rosterLatest[e] = d
        }
        roster = r
    }

    /**
     * Non-clinical roster entries = a doctor is on the schedule that day but NOT doing clinical work — time
     * off / vacation / admin. Captured separately (date → name → the raw LB label) to flag "requested off".
     */
    private fun buildOffRoster(slots: List<RawSlot>) {
        val off = HashMap<String, MutableMap<String, String>>()
        val years = slots.mapNotNull { it.date?.take(4) }.toSet()
        for ((d, m) in offByDay) if (d.take(4) !in years) off[d] = m.toMutableMap()   // years not re-read stay
        addOffEntries(slots, off)
        offByDay = off
    }

    private fun addOffEntries(slots: List<RawSlot>, off: HashMap<String, MutableMap<String, String>>) {
        for (s in slots) {
            val raw = s.unit?.takeIf { it.isNotEmpty() } ?: continue
            if (Units.key(raw) != null) continue                       // non-clinical only
            val name = s.offerer?.takeIf { it.isNotEmpty() } ?: continue
            val d = s.date?.takeIf { it.isNotEmpty() } ?: continue
            if (s.emp?.toIntOrNull() == 4) continue                    // skip EMPTY vacancy
            off.getOrPut(d) { HashMap() }[name] = raw
        }
    }

    /**
     * Pull the group directory (cell/email per emp) from LB /personnel — lazily, cached a day. Best-effort:
     * if the token isn't ready the contact actions just stay disabled.
     */
    suspend fun loadDirectory() {
        if (!loggedIn || demo) return
        val t = directoryLoadedAt
        if (t != null && System.currentTimeMillis() - t < 24 * 3600_000L && directory.isNotEmpty()) return
        var people = source.fetchDirectory()
        if (people.isNullOrEmpty()) {          // /personnel came back empty → the ~1h LB token likely expired;
            refresh()                          // a full refresh reloads the web view + re-captures a fresh token,
            people = source.fetchDirectory()   // then retry — so the roster self-heals without a manual re-login.
        }
        val ppl = people?.takeIf { it.isNotEmpty() } ?: return
        val d = HashMap<Int, Contact>()
        val r = roster.toMutableMap()
        for (p in ppl) {
            val e = p.emp.toIntOrNull() ?: continue
            d[e] = Contact(p.cell, p.email)
            if (p.name.isNotEmpty()) r[e] = p.name   // emp→name from /personnel — small + reliable
        }
        directory = d
        roster = r
        directoryLoadedAt = System.currentTimeMillis()
    }

    /**
     * Recompute the grouped Who's On / Crew data ONCE per data change (not per view render — keeps
     * scrolling smooth over 4+ years of history).
     */
    private var whoGen = 0

    fun rebuildWho() {
        val src = whoData
        val gen = ++whoGen
        viewModelScope.launch {
            val (byDay, days) = withContext(Dispatchers.Default) {
                val grouped = src.groupBy { it.date }
                val lo = src.minOfOrNull { it.date }
                val hi = src.maxOfOrNull { it.date }
                val list = ArrayList<String>()
                if (lo != null && hi != null) {
                    var d = LocalDate.parse(lo)
                    val end = LocalDate.parse(hi)
                    var guard = 0
                    while (!d.isAfter(end) && guard < 3000) { list.add(d.toString()); d = d.plusDays(1); guard++ }
                }
                grouped to list
            }
            if (gen != whoGen) return@launch       // a newer rebuild started meanwhile → let it publish
            whoByDay = byDay
            whoDays = days
        }
    }

    // MARK: - Colleagues + give-away

    /** Colleagues available as give-away recipients (emp_id → name), excluding me, sorted by name. */
    val colleagues: List<Pair<Int, String>>
        get() {
            val mine = userEmp.toIntOrNull()
            // Active = has a clinical shift THIS YEAR. Former docs only have old shifts; the EMPTY vacancy
            // (emp 4) and non-doctors drop out.
            val cutoff = "${LocalDate.now().year}-01-01"
            val activeNames = whoData.filter { it.date >= cutoff }.map { it.doc }.toHashSet()
            return roster.filter { (emp, name) ->
                emp != mine && emp != 4 && name.isNotEmpty() &&
                    (activeNames.contains(name) || (rosterLatest[emp] ?: "") >= cutoff)
            }.map { it.key to it.value }.sortedBy { it.second.lowercase() }
        }

    /**
     * Colleagues who can genuinely take [shift] — only surface people who are actually free to pick it up:
     * not already scheduled that day, not post-call (24h/night the day before), not pre-call (24h/night the
     * day after), not already working the next day if this shift is a 24h/night, and SICU competency when
     * it's a SICU shift.
     */
    fun eligibleColleagues(shift: MyShift): List<Pair<Int, String>> {
        val d = shift.date
        val busy = (whoByDay[d] ?: emptyList()).map { it.doc }.toHashSet()
        val postCall = (whoByDay[ConflictEngine.addDays(d, -1)] ?: emptyList()).filter { it.overnight }.map { it.doc }.toHashSet()
        val preCall = (whoByDay[ConflictEngine.addDays(d, 1)] ?: emptyList()).filter { it.overnight }.map { it.doc }.toHashSet()
        val nextDayBusy = if (shift.overnight) (whoByDay[ConflictEngine.addDays(d, 1)] ?: emptyList()).map { it.doc }.toHashSet() else hashSetOf()
        val sicuDocs = whoData.filter { it.unit == UnitKey.SICU && it.date < todayRegina() }.map { it.doc }.toHashSet()
        return colleagues.filter { (_, name) ->
            if (name in busy || name in postCall || name in preCall || name in nextDayBusy) return@filter false
            if (shift.unit == UnitKey.SICU && name !in sicuDocs) return@filter false   // SICU needs prior SICU experience
            true
        }
    }

    /**
     * The Swap Finder engine. Given a shift I want to trade away, return every viable swap OPTION — a
     * colleague's FUTURE shift (today onward) that I could take, where BOTH sides genuinely work:
     *   • THEY can take my shift: free that day, not pre/post-call, and competent for my shift's unit
     *   • I can take THEIR shift: free that day, not pre/post-call, and competent for their unit
     * Time off on my date is a soft ⚠️ flag (they could still work), not a hard exclusion.
     */
    fun swapOptions(shift: MyShift): List<SwapOption> {
        val myDate = shift.date
        val myUnit = shift.unit
        val today = todayRegina()

        // --- can THEY take my shift? ---
        val postCall = (whoByDay[ConflictEngine.addDays(myDate, -1)] ?: emptyList())
            .filter { it.overnight }.map { it.doc }.toHashSet()          // 24h call day before → post-call
        val preCall = (whoByDay[ConflictEngine.addDays(myDate, 1)] ?: emptyList())
            .filter { it.overnight }.map { it.doc }.toHashSet()          // 24h call day after → pre-call
        // If MY shift is a 24h/night, whoever takes it can't already work the next day.
        val takerBusyNextDay = if (shift.overnight) {
            (whoByDay[ConflictEngine.addDays(myDate, 1)] ?: emptyList()).map { it.doc }.toHashSet()
        } else hashSetOf()
        val offMyDate = offByDay[myDate] ?: emptyMap()
        // Competency ONLY matters for SICU — everyone works the other units. A doctor "does SICU" once they've
        // actually worked a SICU shift before today: self-updating, no hardcoded lists.
        val sicuDocs = whoData.filter { it.unit == UnitKey.SICU && it.date < today }.map { it.doc }.toHashSet()
        val iDoSICU = userName in sicuDocs

        fun theyCanTakeMine(name: String): Boolean {
            if (name in postCall || name in preCall || name in takerBusyNextDay) return false
            if (myUnit == UnitKey.SICU && name !in sicuDocs) return false
            return true
        }

        // --- what can I take? ---
        val myBusy = myShifts.map { it.date }.toHashSet()                          // every day I already work
        val myNights = myShifts.filter { it.overnight }.map { it.date }.toHashSet() // my shifts running into the next morning

        fun iCanTake(a: Assignment): Boolean {
            val d = a.date
            if (d in myBusy) return false                                              // I already work that day
            if (ConflictEngine.addDays(d, -1) in myNights) return false                 // post-call into d
            if (ConflictEngine.addDays(d, 1) in myNights) return false                  // pre-call: my night the next day
            if (a.overnight && ConflictEngine.addDays(d, 1) in myBusy) return false     // their 24h runs into d+1
            return true
        }

        val empByName = colleagues.associate { (emp, name) -> name to emp }
        val out = ArrayList<SwapOption>()
        fun add(name: String, rs: Assignment, status: SwapStatus) {
            val emp = empByName[name] ?: return
            out.add(SwapOption(emp, name, directory[emp]?.cell, status, rs))
        }

        // ── SAME-DAY swaps: colleagues working a DIFFERENT unit on my own shift's date — we trade units for the
        // day. They're already scheduled on myDate (so free/rested there); I just need to be able to take THEIR
        // unit and they need to be able to take MINE.
        for (rs in mergePasqua(whoByDay[myDate] ?: emptyList())) {
            if (rs.doc == userName || rs.unit == myUnit) continue
            if (rs.unit == UnitKey.SICU && !iDoSICU) continue                                  // I can only take SICU if I do SICU
            if (ConflictEngine.addDays(myDate, -1) in myNights) continue                        // I'm post-call into myDate
            if (ConflictEngine.addDays(myDate, 1) in myNights) continue                         // pre-call: my night the next day
            if (rs.overnight && ConflictEngine.addDays(myDate, 1) in myBusy) continue           // their 24h runs into myDate+1
            if (!theyCanTakeMine(rs.doc)) continue
            add(rs.doc, rs, SwapStatus.Free)                                                   // scheduled that day ⇒ clearly available
        }

        // ── DIFFERENT-DAY swaps: I take a colleague's shift on another day (they take mine on myDate).
        val busyMyDate = (whoByDay[myDate] ?: emptyList()).map { it.doc }.toHashSet()
        val future = mergePasqua(whoData.filter { it.date >= today && notStarted(it.date, it.start) }).filter { iCanTake(it) }
        val byDoc = future.groupBy { it.doc }
        for ((emp, name) in colleagues) {
            if (name in busyMyDate || !theyCanTakeMine(name)) continue
            val theirs = byDoc[name] ?: continue
            val status = offMyDate[name]?.let { SwapStatus.Off(it) } ?: SwapStatus.Free
            for (rs in theirs) {
                if (rs.unit == UnitKey.SICU && !iDoSICU) continue     // I can only take a SICU shift if I do SICU
                add(name, rs, status)
            }
        }
        return out.sortedBy { it.returnShift.date }
    }

    /**
     * Give away PART of ANY shift (day or 24h/overnight). LB has no one-step partial give-away, so: split the
     * shift into segments (all stay MINE), re-harvest to get the give-segment's fresh slot_id, then offer just
     * that segment. [giveStartISO]/[giveEndISO] = full "yyyy-MM-ddTHH:mm:00" timestamps of the portion to hand off.
     */
    suspend fun giveAwayPart(
        shift: MyShift,
        giveStartISO: String,
        giveEndISO: String,
        toEmp: Int?,
        everyone: Boolean,
        note: String,
    ): LBWebSource.WriteOutcome {
        val slot = shift.slotID
            ?: return LBWebSource.WriteOutcome(false, "This shift has no id — pull to refresh and retry.")
        val myEmp = userEmp.toIntOrNull()
            ?: return LBWebSource.WriteOutcome(false, "This shift has no id — pull to refresh and retry.")
        if (demo) return LBWebSource.WriteOutcome(false, "Sample data — nothing is posted in the preview.")
        val shiftStartISO = "${shift.date}T${shift.start}:00"
        val shiftEndISO =
            "${if (shift.overnight) ConflictEngine.addDays(shift.date, 1) else shift.date}T${shift.end}:00"
        if (giveStartISO < shiftStartISO || giveEndISO > shiftEndISO || giveStartISO >= giveEndISO) {
            return LBWebSource.WriteOutcome(false, "Pick a time range inside your shift.")
        }
        val parts = ArrayList<Triple<String, String, Int>>()
        if (giveStartISO > shiftStartISO) parts.add(Triple(shiftStartISO, giveStartISO, myEmp))  // keep the earlier bit
        parts.add(Triple(giveStartISO, giveEndISO, myEmp))                                        // the part to give away
        if (giveEndISO < shiftEndISO) parts.add(Triple(giveEndISO, shiftEndISO, myEmp))           // keep the later bit

        val splitOut = source.splitShift(slot, parts, note)
        if (!splitOut.ok) return LBWebSource.WriteOutcome(false, splitOut.message ?: "Couldn't split the shift.")
        delay(1_500)                                     // let LB apply the split
        refreshWhenIdle()                                     // re-harvest → new segments get slot_ids

        val gDate = giveStartISO.take(10)
        val gStart = giveStartISO.substring(11, 16)
        val gEnd = giveEndISO.substring(11, 16)
        val part = myShifts.firstOrNull {
            (it.date == gDate || it.date == shift.date) && it.start == gStart && it.end == gEnd && it.slotID != null
        } ?: return LBWebSource.WriteOutcome(
            false,
            "The shift was split, but I couldn't find the new part to offer — give that part away from My Shifts.",
        )
        return when {
            everyone -> giveAwayToGroup(part, eligibleColleagues(part).map { it.first }, note, null)
            toEmp != null -> giveAway(part, toEmp, note, null)
            else -> LBWebSource.WriteOutcome(false, "No recipient chosen.")
        }
    }

    /**
     * Offer one of my shifts to a colleague, with a note. Returns LB's own outcome. [reason] is the optional
     * swap tag that pairs the two halves of a swap (see [swapTagString]).
     */
    suspend fun giveAway(shift: MyShift, toEmp: Int, note: String, reason: String? = null): LBWebSource.WriteOutcome {
        if (demo) return LBWebSource.WriteOutcome(false, "Sample data — nothing is posted in the preview.")
        val slot = shift.slotID
            ?: return LBWebSource.WriteOutcome(false, "This shift has no id — pull to refresh and retry.")
        val me = userEmp.toIntOrNull()
        val out = source.offerToPerson(slot, toEmp, note, shift.templateID ?: 6)
        if (!out.ok) return out
        rememberOfferTarget(slot, toEmp)
        if (note.isNotEmpty() || reason != null) Supabase.putOfferNote(slot, note, reason, me)
        // Pasqua Rapid+MSU trade as one 24h shift → move the second half too.
        val slot2 = shift.slotID2 ?: return out
        val out2 = source.offerToPerson(slot2, toEmp, note, shift.templateID ?: 6)
        if (!out2.ok) {
            refreshWhenIdle()
            return LBWebSource.WriteOutcome(
                false,
                "Only the Rapid half was offered — the MSU half failed (${out2.message ?: "no reason given"}). " +
                    "Cancel the Rapid half from My Posts, then try again.",
                partial = true,
            )
        }
        rememberOfferTarget(slot2, toEmp)   // the note/tag lives on the first half only (one swap = one entry)
        return out
    }

    /**
     * Post a shift to the pool for several colleagues (whoever's eligible can grab it). LB carries no note on a
     * group offer, so the note lives only in the shared backend (shown in the Pool).
     */
    suspend fun giveAwayToGroup(shift: MyShift, toEmps: List<Int>, note: String, reason: String? = null): LBWebSource.WriteOutcome {
        if (demo) return LBWebSource.WriteOutcome(false, "Sample data — nothing is posted in the preview.")
        val slot = shift.slotID
            ?: return LBWebSource.WriteOutcome(false, "This shift has no id — pull to refresh and retry.")
        if (toEmps.isEmpty()) return LBWebSource.WriteOutcome(false, "No one is free to take this shift.")
        val me = userEmp.toIntOrNull()
        val out = source.offerToGroup(slot, toEmps)
        if (!out.ok) return out
        rememberOfferTarget(slot, toEmps.firstOrNull() ?: -1)
        if (note.isNotEmpty() || reason != null) Supabase.putOfferNote(slot, note, reason, me)
        val slot2 = shift.slotID2 ?: return out
        val out2 = source.offerToGroup(slot2, toEmps)
        if (!out2.ok) {
            refreshWhenIdle()
            return LBWebSource.WriteOutcome(
                false,
                "Only the Rapid half was posted — the MSU half failed (${out2.message ?: "no reason given"}). " +
                    "Cancel the Rapid half from My Posts, then try again.",
                partial = true,
            )
        }
        rememberOfferTarget(slot2, toEmps.firstOrNull() ?: -1)
        return out
    }

    /** Withdraw a pending offer I made (before the colleague accepts). */
    suspend fun cancelGiveAway(slotID: Int, toEmp: Int): Boolean {
        if (demo) return false
        return source.cancelOffer(slotID, toEmp).ok
    }

    /** A full refresh that WAITS for the web view to be free instead of silently skipping. */
    suspend fun refreshWhenIdle() {
        var tries = 0
        while ((loading || groupScanning || poolRefreshing) && tries < 60) { delay(500); tries++ }
        refresh()
    }

    // MARK: - Pool filters, busy days

    private val meEmp: Int? get() = userEmp.toIntOrNull()

    /** What the Pool lists: open posts, plus offers aimed at ME. Offers aimed at someone else stay private. */
    val poolShifts: List<OpenShift>
        get() { val me = meEmp; return openShifts.filter { it.directedTo == null || it.directedTo == me } }

    /** Days with a shift genuinely open to all (not a swap / direct offer, not my own post) — calendar dots. */
    val openForAllDates: Set<String>
        get() { val me = meEmp; return openShifts.filter { it.directedTo == null && (me == null || it.offererEmp != me) }.map { it.iso }.toSet() }

    /** Days where I have a post still waiting for a taker — the violet "Posted" marker. */
    val postedPendingDates: Set<String>
        get() = myPosts.filter { it.status == MyPost.Status.Pending }.map { it.iso }.toSet()

    fun setBusy(iso: String, note: String?) {
        busyDays = if (note == null) busyDays - iso else busyDays + (iso to note.trim().take(24))
        prefs.putString("wb_busy_days", json.encodeToString(stringMap, busyDays))
    }

    /** Why I can't take a shift that day: my own busy note, or a pending/approved time-off request. */
    fun busyNote(iso: String): String? {
        busyDays[iso]?.let { return it.ifEmpty { "Busy" } }
        return myRequests.firstOrNull { it.date == iso && it.status.lowercase() in setOf("pending", "approved") }?.kind
    }

    fun isPickable(o: OpenShift): Boolean = !o.conflict && busyNote(o.iso) == null

    /** "Recently taken" under For me: only shifts I could have picked up. */
    val recentlyTakenForMe: List<RecentTake>
        get() {
            val sched = MyScheduleModel(myShifts)
            return recentlyTaken.filter { !it.swap && !it.mine && sched.flag(it.iso, it.unit) == null && busyNote(it.iso) == null }
        }

    val showMyPostsTab: Boolean
        get() = when (prefs.myPostsMode) {
            "always" -> true
            "pending" -> myPosts.any { it.status == MyPost.Status.Pending }
            else -> myPosts.isNotEmpty()
        }

    // MARK: - My posts

    /** Everything I've posted: still-pending offers (from the live pool) + the ones that were picked up. */
    val myPosts: List<MyPost>
        get() {
            if (demo) return demoPosts
            val me = meEmp ?: return pickedUp
            val pending = openShifts.filter { it.offererEmp == me }.map { o ->
                val sid = o.id.toIntOrNull()
                val note = sid?.let { myPostNotes[it] }
                var isSwap = note?.contains("swap", ignoreCase = true) == true
                var label = note
                val to = o.directedTo
                if (to != null) {
                    val who = o.pendingName ?: "a colleague"
                    val back = openShifts.firstOrNull { it.offererEmp == to && it.directedTo == me }
                    if (back != null) {
                        isSwap = true
                        if (label.isNullOrEmpty()) label = "Swap with $who for ${Units.short(back.unit)} ${shortDate(back.iso)} — waiting for a reply"
                    } else if (label.isNullOrEmpty()) {
                        label = "Offered to $who — waiting for a reply"
                    }
                }
                MyPost(
                    id = "p-${o.id}", iso = o.iso, unit = o.unit, hoursLabel = o.hoursLabel,
                    kind = if (isSwap) MyPost.Kind.Swap else MyPost.Kind.Giveaway, status = MyPost.Status.Pending,
                    slotID = sid, note = label,
                )
            }
            return pending + pickedUp
        }

    private fun shortDate(iso: String): String =
        runCatching { LocalDate.parse(iso).format(DateTimeFormatter.ofPattern("MMM d", Locale.ENGLISH)) }.getOrDefault(iso)

    /** My posts that were picked up (kept current by the poller) + the Pool's "Recently taken". */
    suspend fun loadPickups() {
        loadRecentlyTaken()
        if (demo) return
        val me = meEmp ?: return
        val rows = Supabase.pickups(me) ?: return          // failed read keeps what's shown
        pickedUp = rows.mapNotNull { r ->
            val d = r.date ?: return@mapNotNull null
            MyPost(
                id = "u-${r.slot_id}", iso = d,
                unit = r.unit?.let { u -> runCatching { UnitKey.valueOf(u) }.getOrNull() } ?: UnitKey.MICU,
                hoursLabel = "",
                kind = if (r.kind == "swap") MyPost.Kind.Swap else MyPost.Kind.Giveaway,
                status = MyPost.Status.Completed, counterparty = r.taker, whenAt = r.picked_up_at, slotID = r.slot_id,
            )
        }
    }

    suspend fun loadRecentlyTaken() {
        if (demo) return
        val since = LocalDateTime.now(REGINA).minusHours(48).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss"))
        val rows = Supabase.recentPickups(since) ?: return
        val today = todayRegina()
        val me = meEmp
        val seen = HashSet<String>()
        val out = ArrayList<RecentTake>()
        for (r in rows) {
            val d = r.date ?: continue
            if (d < today) continue
            val u = r.unit?.let { runCatching { UnitKey.valueOf(it) }.getOrNull() } ?: continue
            val at = r.picked_up_at?.take(19)?.let { runCatching { LocalDateTime.parse(it) }.getOrNull() } ?: continue
            // the two halves of a Pasqua 24h count as one
            if (!seen.add("$d|${if (u == UnitKey.MSU || u == UnitKey.PRR) "PASQ" else u.name}")) continue
            out.add(
                RecentTake(
                    r.slot_id, d, u, at.atZone(REGINA).toInstant().toEpochMilli(),
                    swap = r.kind == "swap", mine = me != null && (r.giver_emp == me || r.taker_emp == me),
                )
            )
        }
        recentlyTaken = out
    }

    suspend fun loadMyPostNotes() {
        if (demo) return
        val me = meEmp ?: return
        Supabase.myOfferNotes(me)?.let { myPostNotes = it }
    }

    private fun offerTargets(): Map<String, String> =
        prefs.getString("wb_offer_targets")?.let { runCatching { json.decodeFromString(stringMap, it) }.getOrNull() } ?: emptyMap()

    /** Remember who an offer was sent to, so it can be withdrawn later (LB needs the target emp to cancel). */
    private fun rememberOfferTarget(slot: Int, toEmp: Int) {
        prefs.putString("wb_offer_targets", json.encodeToString(stringMap, offerTargets() + (slot.toString() to toEmp.toString())))
    }

    private fun offerTarget(slot: Int): Int? = offerTargets()[slot.toString()]?.toIntOrNull()

    /** Withdraw one of my pending posts. */
    suspend fun cancelPost(post: MyPost): Boolean {
        if (demo) return false
        val sid = post.slotID ?: return false
        val to = offerTarget(sid) ?: openShifts.firstOrNull { it.id == sid.toString() }?.pendingEmp ?: meEmp ?: 0
        val ok = cancelGiveAway(sid, to)
        if (ok) { refreshWhenIdle(); loadMyPostNotes() }   // slot leaves the pool → entry disappears
        return ok
    }

    // MARK: - Two-way swaps (two plain offers paired by the offer-note tag)

    private fun saveSwapSets() {
        prefs.putIntSet("wb_swap_seen", swapSeen)
        prefs.putIntSet("wb_swap_settled", swapSettled)
        prefs.putIntSet("wb_swap_dismissed", swapDismissed)
    }

    suspend fun loadSwapNotes() {
        if (demo) return
        Supabase.swapNotes()?.let { swapNotes = it }       // a failed read keeps the existing pairing
    }

    val openSlotIDs: Set<Int> get() = openShifts.mapNotNull { it.id.toIntOrNull() }.toSet()

    private val mySlotIDs: Set<Int>
        get() = (shiftLog + myShifts).flatMap { listOfNotNull(it.slotID, it.slotID2) }.toSet()

    private fun myShift(slot: Int): MyShift? =
        myShifts.firstOrNull { it.slotID == slot } ?: shiftLog.firstOrNull { it.slotID == slot }

    /** Swaps I proposed: (my offered slot, its tag). */
    private val mySwapProposals: List<Pair<Int, SwapTag>>
        get() {
            val me = meEmp ?: return emptyList()
            return swapNotes.mapNotNull { n ->
                val t = parseSwapTag(n.reason) ?: return@mapNotNull null
                if (n.by_emp != me || t.back) null else n.slot_id to t
            }
        }

    /** Swaps I sent that didn't go through — the shift is back with me and I got nothing in return. */
    val declinedSwaps: List<DeclinedSwap>
        get() {
            val open = openSlotIDs
            val current = myShifts.flatMap { listOfNotNull(it.slotID, it.slotID2) }.toSet()
            return mySwapProposals.mapNotNull { (slot, tag) ->
                if (slot !in swapSeen || slot !in swapSettled || slot in swapDismissed || slot in open) return@mapNotNull null
                if (slot !in current || tag.slots.any { it in current }) return@mapNotNull null
                val mine = myShift(slot) ?: return@mapNotNull null
                if (!notStarted(mine.date, mine.start)) return@mapNotNull null
                DeclinedSwap(slot, mine, roster[tag.toEmp] ?: "your colleague")
            }
        }

    fun dismissDeclinedSwap(slot: Int) { swapDismissed = swapDismissed + slot; saveSwapSets() }

    /** Swaps colleagues sent me that still need me: accept theirs, or (already taken) send mine back. */
    val incomingSwaps: List<IncomingSwap>
        get() {
            val me = meEmp ?: return emptyList()
            val open = openSlotIDs
            val mine = mySlotIDs
            val sentBack = swapNotes.filter { n -> n.by_emp == me && parseSwapTag(n.reason)?.back == true }.map { it.slot_id }.toSet()
            val out = ArrayList<IncomingSwap>()
            for (n in swapNotes) {
                val tag = parseSwapTag(n.reason) ?: continue
                val from = n.by_emp ?: continue
                if (tag.back || tag.toEmp != me || from == me) continue
                val rid = tag.slots.first()
                val ret = myShift(rid) ?: continue
                if (ret.slotID == null || !notStarted(ret.date, ret.start)) continue
                val name = roster[from] ?: "A colleague"
                val o = openShifts.firstOrNull { it.id == n.slot_id.toString() && it.offererEmp == from }
                if (o != null) {
                    out.add(IncomingSwap(n.slot_id, from, name, o.iso, o.unit, ret, taken = false, acceptURL = o.acceptURL))
                } else if (n.slot_id in mine && rid !in sentBack && rid !in open) {
                    val t = myShift(n.slot_id) ?: continue
                    out.add(IncomingSwap(n.slot_id, from, name, t.date, t.unit, ret, taken = true, acceptURL = null))
                }
            }
            return out.sortedBy { it.theirsDate }
        }

    /** The return half of a swap I sent: the colleague took my shift and offered theirs back to me. */
    val swapReturnsForMe: List<OpenShift>
        get() {
            val me = meEmp ?: return emptyList()
            val open = openSlotIDs
            val mine = mySlotIDs
            val props = mySwapProposals
            return openShifts.filter { o ->
                val r = o.id.toIntOrNull() ?: return@filter false
                o.directedTo == me && props.any { (s, t) -> t.toEmp == o.offererEmp && r in t.slots && s !in open && s !in mine }
            }
        }

    /** Send a swap: offer my shift to one colleague, tagged with the shift of theirs I want back. */
    suspend fun requestSwap(mine: MyShift, theirs: Assignment, toEmp: Int, note: String): LBWebSource.WriteOutcome {
        if (demo) return LBWebSource.WriteOutcome(false, "Sample data — nothing is sent in the preview.")
        val t1 = theirs.slotID
            ?: return LBWebSource.WriteOutcome(false, "Their shift has no id yet — pull to refresh and retry.")
        val tag = swapTagString(false, toEmp, listOfNotNull(t1, theirs.slotID2))
        val out = giveAway(mine, toEmp, note, tag)
        if (out.ok) { loadSwapNotes(); refreshWhenIdle() }
        return out
    }

    /**
     * The return half of a swap someone sent me. Sending a swap is that person's approval of exactly this trade,
     * so once I hold their shift, mine goes back to the same person — nothing else is ever offered or accepted.
     */
    suspend fun sendSwapBack(s: IncomingSwap): LBWebSource.WriteOutcome {
        if (demo) return LBWebSource.WriteOutcome(false, "Sample data — nothing is sent in the preview.")
        val tag = swapTagString(true, s.fromEmp, listOf(s.slot))
        val note = "Swap: my ${Units.short(s.mine.unit)} on ${shortDate(s.mine.date)} for your ${Units.short(s.theirsUnit)} on ${shortDate(s.theirsDate)}."
        val out = giveAway(s.mine, s.fromEmp, note, tag)
        if (out.ok) { loadSwapNotes(); refreshWhenIdle() }
        return out
    }

    /**
     * The accept page just closed: reconcile the pool, and if that shift left it (I took it, or it was
     * withdrawn) re-read my roster right away instead of waiting for the ~30-min full harvest.
     */
    suspend fun afterAcceptAttempt(url: String) {
        if (demo) return
        val slot = url.substringAfter("swop/", "").substringBefore("/").toIntOrNull()
        val wasOpen = slot != null && slot in openSlotIDs
        var tries = 0
        while (poolRefreshing && tries < 20) { delay(500); tries++ }
        if (refreshOpenShifts() && wasOpen && slot != null && slot !in openSlotIDs) refreshWhenIdle()
    }

    /** After LB's accept page closes on an incoming swap: if I now hold their shift, send mine back right away. */
    suspend fun finishIncomingSwap(slot: Int): LBWebSource.WriteOutcome? {
        if (demo) return null
        refreshWhenIdle(); loadSwapNotes()
        val s = incomingSwaps.firstOrNull { it.slot == slot && it.taken } ?: return null
        return sendSwapBack(s)
    }

    // MARK: - Time off requests

    suspend fun loadRequests() {
        if (demo || !loggedIn || requestsLoading) return
        requestsLoading = true
        try {
            var tries = 0
            while ((loading || groupScanning || poolRefreshing) && tries < 30) { delay(500); tries++ }
            val fmt = DateTimeFormatter.ofPattern("yyyyMMdd")
            val now = LocalDate.now(REGINA)
            val raw = source.fetchMyRequests(now.minusDays(60).format(fmt), now.plusMonths(18).format(fmt))
                ?: return                                   // failed read keeps the cached list
            myRequests = raw.filter { it.date.isNotEmpty() }.map {
                TimeOffRequest(
                    it.id, it.date, it.status ?: "pending", it.kind ?: "Time Off", it.note ?: "", it.submitted, it.decision,
                )
            }.sortedBy { it.date }
            requestsLoadedAt = System.currentTimeMillis()
            store.saveRequests(myRequests)
        } finally {
            requestsLoading = false
        }
    }

    suspend fun submitTimeOff(kind: LBWebSource.RequestKind, dates: List<String>, note: String): LBWebSource.WriteOutcome {
        if (demo) return LBWebSource.WriteOutcome(false, "Sample data — nothing is sent in the preview.")
        val emp = meEmp ?: return LBWebSource.WriteOutcome(false, "Still signing you in — try again in a moment.")
        val days = dates.distinct().sorted()
        if (days.isEmpty()) return LBWebSource.WriteOutcome(false, "No dates chosen.")
        if (days.first() < todayRegina()) return LBWebSource.WriteOutcome(false, "Requests can only be for today or later.")
        val out = source.submitRequests(kind, days, note, emp)
        loadRequests()          // show exactly what LB now has (also surfaces a half-applied multi-day submit)
        return out
    }

    suspend fun cancelRequests(ids: List<Int>): LBWebSource.WriteOutcome {
        if (demo) return LBWebSource.WriteOutcome(false, "Sample data — nothing is sent in the preview.")
        val mine = myRequests.filter { it.isPending }.map { it.id }.toSet()
        val ok = ids.filter { it in mine }
        if (ok.isEmpty()) return LBWebSource.WriteOutcome(false, "That request isn't in your list — pull to refresh.")
        val out = source.deleteRequests(ok)
        loadRequests()
        return out
    }

    // MARK: - persistence helpers

    private fun saveCache() {
        val s = Snapshot(openShifts, myShifts, userName, lastUpdated ?: System.currentTimeMillis(), assignments)
        viewModelScope.launch { store.saveCache(s) }
    }

    private fun saveLog() {
        val s = LogSnapshot(shiftLog, userEmp, historyLoadedAt, HISTORY_START)
        viewModelScope.launch { store.saveLog(s) }
    }

    private fun saveGroup() {
        val s = GroupSnapshot(groupLog, userEmp, groupLoadedAt)
        viewModelScope.launch { store.saveGroup(s) }
    }

    // The my-shifts fetch covers Jan 1 this year → Dec 31 next year — used by refresh() to replace exactly
    // that span so given-away shifts clear without wiping past years.
    private fun currentYearStartISO() = todayRegina().take(4) + "-01-01"
    private fun nextYearEndISO() = ((todayRegina().take(4).toIntOrNull() ?: 9998) + 1).toString() + "-12-31"
}
