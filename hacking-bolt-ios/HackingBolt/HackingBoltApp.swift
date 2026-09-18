import SwiftUI
import UIKit
import UserNotifications

@main
struct HackingBoltApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model) }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var openShifts: [OpenShift] = []
    @Published var myShifts: [MyShift] = []
    @Published var assignments: [Assignment] = []   // everyone's shifts (Who's Working)
    @Published var shiftLog: [MyShift] = []          // durable log: my worked (past) + scheduled (future) shifts
    @Published var groupLog: [Assignment] = []       // the whole group's history (2022 →), per-device cache
    @Published var swapLog: [SwapEvent] = []         // owner-only: shifts that changed hands (Shift pickups card)
    @Published var demoPosts: [MyPost] = []          // sample "My Posts" entries for the no-login preview only
    @Published var pickedUp: [MyPost] = []           // my posted shifts that got picked up (shared backend; all crew)
    @Published var myPostNotes: [Int: String] = [:]  // slot_id → my offer note (labels a pending post as a swap)
    @Published var poolShowMine = false              // a "picked up" push asks the Pool to open on My Posts
    @Published var swapDebug = ""                    // owner-only diagnostic shown when the pickups list is empty
    @Published var groupScanning = false             // the group-history fetch is running (background)
    @Published var roster: [Int: String] = [:]              // emp_id → display name (colleagues, for the give-away recipient picker)
    @Published var whoByDay: [String: [Assignment]] = [:]   // Who's On / Crew source, grouped (precomputed for scroll perf)
    @Published var whoDays: [String] = []                   // contiguous day list across the full history range
    /// Non-clinical roster entries (time off / vacation / admin) → date → doctorName → the raw LB label.
    /// Powers the Swap Finder's ⚠️ "requested off" flag; built alongside the group history.
    @Published var offByDay: [String: [String: String]] = [:]
    /// Diagnostic: distinct non-clinical roster labels seen (label → count), so we can lock onto the exact
    /// string Lightning Bolt uses for a "requested time off" entry.
    @Published var offRosterLabels: [String: Int] = [:]
    /// emp_id → contact (cell/email) from LB's /personnel, loaded lazily for the Swap Finder "text" action.
    @Published var directory: [Int: Contact] = [:]
    /// Owner-only diagnostic for the Swap Finder (why a search returned what it did).
    @Published var swapFindDebug = ""
    @Published var groupFetchDebug = ""
    var whoData: [Assignment] { groupLog.isEmpty ? assignments : groupLog }  // full history if loaded, else the live window
    @Published var userName = ""
    @Published var loggedIn = false
    @Published var loading = false
    @Published var syncing = false            // a harvest is running (first-run shows the setup screen)
    @Published var lastUpdated: Date?
    @Published var showLogin = false          // reveal Lightning Bolt's login web view
    @Published var isOwner = false            // only Nicolaas (emp 20147) gets the witty-line editor
    @Published var demo = false               // no-login "Explore with sample data" mode (for reviewers / previews)
    @Published var selectedTab = 0            // drives the TabView, so a calendar tap can jump to the Pool
    @Published var poolJumpDate: String?      // when set, the Pool scrolls to the open shift on this date

    static let ownerEmpID = "20147"

    let source = LBWebSource()
    private var started = false

    var hasData: Bool { !openShifts.isEmpty || !myShifts.isEmpty }

    private(set) var userEmp = ""              // the logged-in person's emp_id — the log/stats belong to them

    init() { loadCache(); loadLog(); loadGroupLog(); loadSwapLog(); rebuildWho() }   // show last-known data + durable logs instantly

    /// Runs once when the UI appears: cached data is already on screen; log in + refresh in the background.
    func start() async {
        guard !started else { return }
        started = true
        #if DEBUG
        // Screenshot/preview hook: launch with `-demoShot` (+ optional DEMO_TAB env) to drop straight
        // into sample-data mode on a chosen tab. Inert in Release; the arg is never passed in production.
        if CommandLine.arguments.contains("-demoShot") {
            enterDemo()
            if let t = ProcessInfo.processInfo.environment["DEMO_TAB"], let n = Int(t) { selectedTab = n }
            if let w = ProcessInfo.processInfo.environment["DEMO_WEEK"], let n = Int(w) { UserDefaults.standard.set(n, forKey: "hb_week_start") }
            return
        }
        #endif
        source.loadLogin()
        await detectLoginLoop()
    }

    /// Poll the hidden web view for a live session; refresh when found. If not signed in and there's no
    /// cached data, reveal the login screen. (With a persisted session this flips to logged-in in ~1–2s.)
    private func detectLoginLoop() async {
        var i = 0
        while !Task.isCancelled {               // keep watching for sign-in as long as the app is open (never give up)
            if demo { return }                  // in sample-data mode there's no session to wait for
            if await source.isLoggedIn() {
                loggedIn = true
                showLogin = false
                triedAutoLogin = false                   // fresh session → allow auto-login again if it later expires
                await refresh()
                // Preload the per-year API backfills so the full roster + the whole-group data (Who's On, Crew,
                // give-away roster) are ready before those tabs are opened. `refresh()` now harvests only the
                // personal live window, so `loadGroupHistory()` is what populates `groupLog`/`assignments`/roster.
                Task { await loadHistory() }
                Task { await loadGroupHistory() }
                return
            }
            if i == 6 {                                   // ~3s and still not signed in
                if !triedAutoLogin {                      // owner Face ID auto-login (opt-in) — try once
                    triedAutoLogin = true
                    if await autoLoginAndLoad() { return }
                }
                if !hasData { showLogin = true }          // nothing cached and no auto-login → must sign in manually
            }
            i += 1
            // Poll fast (0.5s) while auto-restoring a session; once the login screen is up (waiting on the user),
            // back off to 2.5s so we're not evaluating JS in the web view twice a second forever (battery).
            try? await Task.sleep(nanoseconds: showLogin ? 2_500_000_000 : 500_000_000)
        }
    }

    private var triedAutoLogin = false

    /// Auto-login (opt-in, credentials in the device Keychain — see LBCreds). Two modes: Face ID (prompts a
    /// biometric check) or "Keep me signed in" (silent). Fills + submits LB's own login form, waits for the
    /// session, loads data. Returns true if signed in; no-op (false) if neither mode is enabled / user cancels.
    func autoLoginAndLoad() async -> Bool {
        guard !demo else { return false }
        let bio = UserDefaults.standard.bool(forKey: "hb_faceid_login") && LBCreds.biometricsAvailable
        let plain = UserDefaults.standard.bool(forKey: "hb_keep_signed_in")
        guard bio || plain else { return false }
        guard let c = await LBCreds.load(reason: bio ? "Sign in to Lightning Bolt with Face ID" : "") else { return false }
        guard await source.autoSignIn(username: c.username, password: c.password) else { return false }
        for _ in 0..<12 {                                 // wait up to ~12s for the submitted login to take
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await source.isLoggedIn() {
                loggedIn = true; showLogin = false; triedAutoLogin = false
                await refresh(); Task { await loadHistory() }; Task { await loadGroupHistory() }
                return true
            }
        }
        return false
    }

    /// Tapped "sign in" (or the session expired mid-use): try Face ID auto-login first; else reveal LB's login.
    func signIn() {
        Task {
            if await autoLoginAndLoad() { return }
            showLogin = true
        }
    }

    /// Enter the no-login preview: fill every screen with deterministic sample data and drop straight into
    /// the app. Nothing hits the network (refresh/history all bail while `demo` is set), so the sample data
    /// stays put. Used by App Review (no hospital credentials) and for quick demos.
    func enterDemo() {
        let data = DemoData.build(today: Self.todayRegina())
        demo = true
        userName = DemoData.me
        userEmp = "demo"
        isOwner = false
        shiftLog = data.mine
        myShifts = data.mine
        groupLog = data.group
        assignments = data.group
        openShifts = data.open
        demoPosts = DemoData.posts(today: Self.todayRegina())        // sample My Posts entries for the preview
        roster = DemoData.roster()                                   // the Swap Finder / give-away picker needs a roster
        directory = Dictionary(uniqueKeysWithValues: DemoData.roster().map { ($0.key, Contact(cell: "", email: "")) })
        lastUpdated = Date()
        loggedIn = false
        syncing = false
        showLogin = false
        // Pre-seed the Crew tab with a few colleagues so it's not an empty prompt in the preview.
        if UserDefaults.standard.string(forKey: "hb_selectedDocs")?.isEmpty ?? true {
            UserDefaults.standard.set(DemoData.others.prefix(4).joined(separator: "\n"), forKey: "hb_selectedDocs")
        }
        rebuildWho()
    }

    // MARK: - My Posts (shifts I've put up for pickup / swap)

    /// Every shift I've posted: still-pending offers from the open pool (mine), plus completed ones that
    /// changed hands (from the owner-only history today; the backend poller will feed everyone in Phase 2).
    /// In demo mode it's the deterministic sample set so the whole tab can be previewed without posting.
    var myPosts: [MyPost] {
        if demo { return demoPosts }
        var out: [MyPost] = []
        if let me = Int(userEmp) {
            for o in openShifts where o.offererEmp == me {
                let sid = Int(o.id)
                let note = sid.flatMap { myPostNotes[$0] }
                let isSwap = note?.lowercased().contains("swap") ?? false   // app writes swap notes ("Swap? …")
                out.append(MyPost(id: "p-\(o.id)", iso: o.iso, unit: o.unit, hoursLabel: o.hoursLabel,
                                  kind: isSwap ? .swap : .giveaway, status: .pending,
                                  counterparty: nil, when: nil, slotID: sid, note: note))
            }
        }
        out.append(contentsOf: pickedUp)              // completed: from the shared backend (works for everyone)
        return out
    }

    /// Refresh the "picked up" list from the shared backend — the poller records every shift that changed
    /// hands, so this works for all crew, not just the owner (whose group-history scan powers the admin card).
    func loadPickups() async {
        guard !demo, let me = Int(userEmp) else { return }
        guard let rows = await Supabase.pickups(giverEmp: me) else { return }
        pickedUp = rows.map { r in
            MyPost(id: "u-\(r.slot_id)", iso: r.date ?? "",
                   unit: UnitKey(rawValue: r.unit ?? "") ?? .MICU, hoursLabel: "",
                   kind: (r.kind == "swap") ? .swap : .giveaway, status: .completed,
                   counterparty: r.taker, when: r.picked_up_at)
        }
    }

    /// Load my offer notes so a pending post shows as a swap (with its note) vs a plain give-away.
    func loadMyPostNotes() async {
        guard !demo, let me = Int(userEmp) else { return }
        if let notes = await Supabase.myOfferNotes(byEmp: me) { myPostNotes = notes }
    }

    // Remember who I offered a slot to (local, per-device) so My Posts can cancel it — the open pool doesn't
    // carry the target, and LB's "delete swap" needs it (same emp the give-away flow passes).
    private func rememberOfferTarget(slot: Int, toEmp: Int) {
        var m = (UserDefaults.standard.dictionary(forKey: "hb_offer_targets") as? [String: Int]) ?? [:]
        m[String(slot)] = toEmp
        UserDefaults.standard.set(m, forKey: "hb_offer_targets")
    }
    private func offerTarget(slot: Int) -> Int? {
        (UserDefaults.standard.dictionary(forKey: "hb_offer_targets") as? [String: Int])?[String(slot)]
    }

    /// Cancel one of my pending posts (give-away or swap) — withdraws the LB offer, then refreshes so it clears.
    func cancelPost(_ post: MyPost) async -> Bool {
        guard !demo, let sid = post.slotID else { return false }
        let toEmp = offerTarget(slot: sid) ?? Int(userEmp) ?? 0      // stored target, else owner as a fallback
        let ok = await cancelGiveAway(slotID: sid, toEmp: toEmp)
        if ok { await refresh(); await loadMyPostNotes() }           // slot leaves the pool → entry disappears
        return ok
    }

    /// Days with a shift I've posted that's still waiting for pickup — drives the violet My Shifts marker.
    var postedPendingDates: Set<String> { Set(myPosts.filter { $0.status == .pending }.map(\.iso)) }

    /// Whether the Pool's "My posts" segment shows, per the Advanced setting (hb_myposts_mode):
    /// auto = when I have any posts · always = pinned on · pending = only while something's awaiting pickup.
    var showMyPostsTab: Bool {
        switch UserDefaults.standard.string(forKey: "hb_myposts_mode") ?? "auto" {
        case "always":  return true
        case "pending": return myPosts.contains { $0.status == .pending }
        default:        return !myPosts.isEmpty
        }
    }

    /// Sign out of Lightning Bolt and wipe this device's cached data, so the next person to log in gets
    /// their own roster/stats loaded fresh (handy for demos on a shared phone).
    func signOut() {
        source.signOut()
        shiftLog = []; groupLog = []; swapLog = []; myShifts = []; openShifts = []; assignments = []
        whoByDay = [:]; whoDays = []
        userName = ""; userEmp = ""; isOwner = false; demo = false
        historyLoadedAt = nil; groupLoadedAt = nil; lastUpdated = nil
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: groupLogURL)
        try? FileManager.default.removeItem(at: swapLogURL)
        loggedIn = false; showLogin = true
        source.loadLogin()
        Task { await detectLoginLoop() }   // watch for the next sign-in and load their data
    }

    // MARK: - Keeping data current (foreground + periodic)

    private var didFirstActivate = false
    private var periodic: Task<Void, Never>?

    /// Called when the app comes to the foreground. The very first activation is handled by start();
    /// after that, re-scrape when the data is stale so the pool is current whenever you open the app.
    func onForeground() {
        if !didFirstActivate { didFirstActivate = true; startPeriodic(); return }
        if loggedIn {
            Task {
                if isStale {
                    // Been away long enough that the ~1h LB token may have expired: proactively re-capture the
                    // session AND refresh the group data (Who's On / Crew / pickups) BEFORE any tab is opened, so
                    // you never land on a stale screen. This is the prevention for the "opened it and nothing showed".
                    await refresh()                        // reloads the web view → fresh token + pool + my shifts
                    await loadGroupHistory(force: true)     // who's-on / crew / shift-pickups, current
                } else {
                    let ok = await refreshOpenShifts()      // recently active: just a light pool refresh
                    if !ok { await refresh() }              // …unless it failed (token expired) → full re-capture
                }
            }
        }
        startPeriodic()
    }
    func onBackground() { periodic?.cancel(); periodic = nil }

    private var isStale: Bool {
        guard let t = lastUpdated else { return true }
        // The light pool fetch on every foreground keeps open shifts current; only escalate to the heavy full
        // harvest (roster + who's on) when the data is genuinely old, so reopening the app stays snappy.
        return Date().timeIntervalSince(t) > 20 * 60   // older than 20 min
    }

    /// While the app is open: a LIGHT pool refresh every 2 min (so newly-posted shifts appear quickly),
    /// and a FULL harvest every ~30 min (roster + who's on) — the light fetch covers the pool between them.
    private func startPeriodic() {
        guard periodic == nil else { return }
        periodic = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2 * 60 * 1_000_000_000)   // 2 min
                if Task.isCancelled { break }
                guard let self else { break }
                if self.loggedIn {
                    let ok = await self.refreshOpenShifts()
                    tick += 1
                    // full harvest every ~30 min, OR right away if the pool fetch failed (recover the expired token)
                    if !ok || tick % 15 == 0 { await self.refresh() }
                }
            }
        }
    }

    func refresh() async {
        guard !demo else { return }                                    // sample-data mode: never overwrite with a live fetch
        guard !loading, !groupScanning, !poolRefreshing else { return }   // don't fight a pool refresh / deep scan for the web view
        loading = true; syncing = true; defer { loading = false; syncing = false }
        hbLog.log("refresh: begin")
        guard let raw = try? await source.harvest() else { return }   // one-shot AJAX paging (viewer loaded once, no per-week nav)
        // don't wipe good cached data if a read came back empty (e.g. session dropped mid-harvest)
        guard !raw.mine.isEmpty || !raw.pending.isEmpty else { hbLog.log("refresh: empty — keeping cache"); return }
        if !raw.me.isEmpty { userName = raw.me }
        if let e = raw.emp, !e.isEmpty {
            if !userEmp.isEmpty && userEmp != e { shiftLog = []; historyLoadedAt = nil; groupLog = []; swapLog = []; groupLoadedAt = nil }   // different person → fresh logs
            userEmp = e
            isOwner = (e == Self.ownerEmpID)
        }
        let newMine = OpenShiftBuilder.roster(from: raw.mine)
        // harvest's `mine` deterministically covers Jan 1 this year → Dec 31 next year (the fetchMyShifts
        // window). REPLACE that whole window with the fresh result — so a shift you gave away / that was
        // withdrawn disappears — but KEEP everything outside it (past years: historical, never change).
        // Guard on a non-empty read so a transient empty harvest (token not captured yet) never wipes the window.
        if !raw.mine.isEmpty {
            let lo = Self.currentYearStartISO, hi = Self.nextYearEndISO
            myShifts = (myShifts.filter { $0.date < lo || $0.date > hi } + newMine)
                .sorted { $0.date < $1.date }
        }
        mergeFuture(myShifts)                                    // refresh the durable log's present+future (past is kept)
        // Who's On assignments + the colleague roster now come from the group backfill (loadGroupHistory,
        // preloaded after login); harvest no longer scrapes the whole group, so refresh only maintains the
        // personal window here. `assignments` stays as the cached pre-backfill fallback (whoData prefers groupLog).
        if groupLog.isEmpty { rebuildWho() }                     // until the group backfill lands, Who's On uses cached assignments
        let schedule = MyScheduleModel(myShifts)
        // raw.pending is now the COMPLETE open-offer list (schedule/range?only_pending — every unit, whole
        // roster, each already carrying its slot_id), so build the pool straight from it. No stale feed:
        // the dashboard SWAPORTUNITY feed lagged (listing offers already taken) and missed Rapid Response.
        openShifts = OpenShiftBuilder.build(pending: raw.pending, schedule: schedule, today: Self.todayRegina())
        lastUpdated = Date()
        saveCache()
        enablePush()   // once we know who's logged in, register this device for shift-alert push
        hbLog.log("refresh DONE: open=\(self.openShifts.count, privacy: .public) mine=\(self.myShifts.count, privacy: .public)")
    }

    // MARK: Push registration (Option 2 — new-open-shift alerts)
    private var pushRequested = false
    /// Ask for notification permission (once), register for APNs, and upsert this device to Supabase so the
    /// poller can alert it. Safe to call repeatedly — guards keep it a no-op after the first grant.
    func enablePush() {
        guard !demo, !userEmp.isEmpty else { return }
        PushCenter.shared.onToken = { [weak self] in Task { @MainActor in self?.syncDevice() } }
        if PushCenter.shared.deviceTokenHex != nil { syncDevice() }   // token already in hand → just (re)upsert
        guard !pushRequested else { return }
        pushRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    /// Upsert this device's APNs token + emp_id into Supabase (keyed on the token). Needs both a token and a
    /// known emp_id; skipped in demo mode.
    private func syncDevice() {
        guard !demo, let token = PushCenter.shared.deviceTokenHex, !userEmp.isEmpty else { return }
        let emp = Int(userEmp)
        Task { _ = await Supabase.registerDevice(empID: emp, token: token) }
    }

    // MARK: Give-away (Option 3) — real schedule mutation, behind an explicit confirm; reversible via cancel.
    /// Colleagues available as give-away recipients (emp_id → name), excluding me, sorted by name.
    private var rosterLatest: [Int: String] = [:]   // emp_id → latest shift date seen → drop former/inactive docs
    var colleagues: [(emp: Int, name: String)] {
        let mine = Int(userEmp)
        // Active = has a clinical shift THIS YEAR. Former docs (Herman Barnard, Jaco Slabbert…) only have old
        // shifts; the EMPTY vacancy (emp 4) and non-doctors drop out. "Active this year" comes from the cached
        // calendar (whoData, matched by name) — reliable — OR rosterLatest when the live group fetch succeeded.
        let cutoff = "\(Calendar.current.component(.year, from: Date()))-01-01"
        let activeNames = Set(whoData.filter { $0.date >= cutoff }.map { $0.doc })
        return roster.filter { $0.key != mine && $0.key != 4 && !$0.value.isEmpty
                               && (activeNames.contains($0.value) || (rosterLatest[$0.key] ?? "") >= cutoff) }
            .map { (emp: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private func mergeRoster(_ slots: [RawSlot]) {
        // Only people who work a CLINICAL unit — keeps non-physician/other-dept entries out. Track each doc's
        // latest shift date (for the active filter) and skip LB's "EMPTY" vacancy placeholder (emp 4).
        for s in slots where Units.key(fromRaw: s.unit ?? "") != nil {
            guard let e = s.emp.flatMap({ Int($0) }), e != 4, let n = s.offerer, !n.isEmpty else { continue }
            roster[e] = n
            if let d = s.date, d > (rosterLatest[e] ?? "") { rosterLatest[e] = d }
        }
    }

    // MARK: - Swap Finder (Robin's ask): find who could trade a shift with me

    /// Non-clinical roster entries = a doctor is on the schedule that day but NOT doing clinical work — time
    /// off / vacation / admin. LB shows these right on the roster; we filter them out of the clinical pipelines,
    /// so here we capture them separately (date → name → the raw LB label) to flag "requested off" candidates,
    /// plus a label histogram so we can see exactly what LB calls a time-off entry.
    private func buildOffRoster(_ slots: [RawSlot]) {
        var off: [String: [String: String]] = [:]
        var labels: [String: Int] = [:]
        for s in slots {
            guard let raw = s.unit, !raw.isEmpty, Units.key(fromRaw: raw) == nil else { continue }   // non-clinical only
            guard let name = s.offerer, !name.isEmpty, let d = s.date, !d.isEmpty else { continue }
            if let e = s.emp.flatMap({ Int($0) }), e == 4 { continue }                                // skip EMPTY vacancy
            off[d, default: [:]][name] = raw
            labels[raw, default: 0] += 1
        }
        offByDay = off
        offRosterLabels = labels
    }

    private var directoryLoadedAt: Date?
    /// Pull the group directory (cell/email per emp) from LB /personnel — lazily, cached a day. Powers the
    /// Swap Finder "text them" action. Best-effort: if the token isn't ready the text buttons just stay disabled.
    func loadDirectory() async {
        guard loggedIn, !demo else { return }
        if let t = directoryLoadedAt, Date().timeIntervalSince(t) < 24 * 3600, !directory.isEmpty { return }
        var people = await source.fetchDirectory()
        if people?.isEmpty ?? true {                    // /personnel came back empty → the ~1h LB token likely expired;
            await refresh()                             // a full refresh reloads the web view + re-captures a fresh token,
            people = await source.fetchDirectory()      // then retry — so the roster self-heals without a manual re-login.
        }
        guard let ppl = people, !ppl.isEmpty else { return }
        var d: [Int: Contact] = [:]
        for p in ppl { if let e = Int(p.emp) {
            d[e] = Contact(cell: p.cell, email: p.email)
            if !p.name.isEmpty { roster[e] = p.name }   // emp→name from /personnel — small + reliable, unlike the
        } }                                             // multi-year group fetch (9 MB/yr) which is too big to load on device
        directory = d
        directoryLoadedAt = Date()
    }

    /// The Swap Finder engine. Given a shift I want to trade away, return every viable swap OPTION — a colleague's
    /// FUTURE shift (today onward) that I could take, where BOTH sides genuinely work:
    ///   • THEY can take my shift: free that day, not pre/post-call, and have worked my shift's unit before
    ///   • I can take THEIR shift: free that day, not pre/post-call, and have worked their unit before
    /// Time off on my date is a soft ⚠️ flag (they could still work), not a hard exclusion.
    func swapOptions(for shift: MyShift) -> [SwapOption] {
        let myDate = shift.date, myUnit = shift.unit
        let today = Self.todayRegina()
        // --- can THEY take my shift? ---
        let postCall = Set((whoByDay[Self.addDays(myDate, -1)] ?? []).filter { $0.overnight }.map { $0.doc })  // 24h call day before → post-call
        let preCall  = Set((whoByDay[Self.addDays(myDate,  1)] ?? []).filter { $0.overnight }.map { $0.doc })  // 24h call day after → pre-call
        // If MY shift is a 24h/night (runs into the next morning), whoever takes it can't already work the next day.
        let takerBusyNextDay = shift.overnight ? Set((whoByDay[Self.addDays(myDate, 1)] ?? []).map { $0.doc }) : Set<String>()
        let offMyDate = offByDay[myDate] ?? [:]
        // Competency ONLY matters for SICU — everyone works the other units. A doctor "does SICU" once they've
        // actually worked a SICU shift before today: self-updating, covers the no-SICU docs (Aivars/Ishaan/Jane/
        // Berto) AND new CCAs who become eligible the day after their first oriented SICU lands — no hardcoded lists.
        let sicuDocs = Set(whoData.filter { $0.unit == .SICU && $0.date < today }.map { $0.doc })
        let iDoSICU = sicuDocs.contains(userName)
        // A colleague can take MY shift (rest-wise): not post/pre-call, not already working the next day if mine
        // runs overnight, and SICU competency if mine is SICU. (busyMyDate is handled per-path below.)
        func theyCanTakeMine(_ name: String) -> Bool {
            if postCall.contains(name) || preCall.contains(name) || takerBusyNextDay.contains(name) { return false }
            if myUnit == .SICU && !sicuDocs.contains(name) { return false }
            return true
        }
        // --- what can I take? ---
        let myBusy = Set(myShifts.map { $0.date })                                   // every day I already work (any shift)
        let myNights = Set(myShifts.filter { $0.overnight }.map { $0.date })         // my 24h/20:00-night shifts (run into the next morning)
        // Can I take a colleague's shift `a`? Free that day, not post/pre-call, AND — if the shift is a 24h/night
        // that runs into the next morning — I can't already be working the next day at all (Nicolaas's rule).
        func iCanTake(_ a: Assignment) -> Bool {
            let d = a.date
            if myBusy.contains(d) { return false }                                   // I already work that day
            if myNights.contains(Self.addDays(d, -1)) { return false }               // post-call: my 24h/night the day before runs into d
            if myNights.contains(Self.addDays(d,  1)) { return false }               // pre-call: my 24h/night the next day
            if a.overnight && myBusy.contains(Self.addDays(d, 1)) { return false }   // a 24h/night shift runs into d+1 → can't if I work d+1
            return true
        }
        let empByName = Dictionary(colleagues.map { ($0.name, $0.emp) }, uniquingKeysWith: { a, _ in a })
        var out: [SwapOption] = []
        func add(_ name: String, _ rs: Assignment, _ status: SwapStatus) {
            guard let emp = empByName[name] else { return }
            out.append(SwapOption(emp: emp, name: name, cell: directory[emp]?.cell, statusOnMyDate: status, returnShift: rs))
        }

        // ── SAME-DAY swaps: colleagues working a DIFFERENT unit on my own shift's date — we trade units for the day.
        // They're already scheduled on myDate (so free/rested there); I just need to be able to take THEIR unit and
        // they need to be able to take MINE. Pasqua Rapid+MSU worked together = one 24h "Pasqua" shift.
        for rs in Self.mergePasqua(whoByDay[myDate] ?? []) where rs.doc != userName && rs.unit != myUnit {
            guard rs.unit != .SICU || iDoSICU else { continue }                       // I can only take SICU if I do SICU
            if myNights.contains(Self.addDays(myDate, -1)) { continue }               // I'm post-call into myDate from a real prior night
            if myNights.contains(Self.addDays(myDate,  1)) { continue }               // pre-call: my night the next day
            if rs.overnight && myBusy.contains(Self.addDays(myDate, 1)) { continue }  // their 24h runs into myDate+1 and I work it
            guard theyCanTakeMine(rs.doc) else { continue }
            add(rs.doc, rs, .free)                                                     // scheduled that day ⇒ clearly available
        }

        // ── DIFFERENT-DAY swaps: I take a colleague's shift on another day (they take mine on myDate).
        let busyMyDate = Set((whoByDay[myDate] ?? []).map { $0.doc })
        let future = Self.mergePasqua(whoData.filter { $0.date >= today }).filter { iCanTake($0) }
        let byDoc = Dictionary(grouping: future) { $0.doc }
        for c in colleagues where !busyMyDate.contains(c.name) && theyCanTakeMine(c.name) {
            guard let theirs = byDoc[c.name] else { continue }
            let status: SwapStatus = offMyDate[c.name].map { .off($0) } ?? .free
            for rs in theirs where (rs.unit != .SICU || iDoSICU) { add(c.name, rs, status) }  // I can only take a SICU shift if I do SICU
        }
        swapFindDebug = "whoData \(whoData.count) · cols \(colleagues.count) · options \(out.count)"
        return out.sorted { $0.returnShift.date < $1.returnShift.date }
    }

    /// Collapse a day's assignments so a Pasqua Rapid Response (day) + Pasqua-MSU (night) worked by the SAME doctor
    /// become ONE 24h "Pasqua" shift (08:00→08:00, overnight) — mirrors the Stats/MonthGrid combo rule. A doctor
    /// doing only one half keeps that half as-is.
    static func mergePasqua(_ asgs: [Assignment]) -> [Assignment] {
        var out: [Assignment] = []
        for (_, g) in Dictionary(grouping: asgs, by: { "\($0.doc)|\($0.date)" }) {
            if let p = g.first(where: { $0.unit == .PRR }), let m = g.first(where: { $0.unit == .MSU }) {
                out.append(Assignment(date: p.date, unit: .PRR, doc: p.doc, start: p.start, end: m.end, overnight: true, isMe: p.isMe))
                out.append(contentsOf: g.filter { $0.unit != .PRR && $0.unit != .MSU })
            } else {
                out.append(contentsOf: g)
            }
        }
        return out
    }

    /// Offer one of my shifts to a colleague, with a note. Writes the note to LB (its own field) AND to Supabase
    /// (so it shows in the Pool even for LB flows that drop notes). Returns true on success.
    func giveAway(shift: MyShift, toEmp: Int, note: String, reason: String?) async -> LBWebSource.WriteOutcome {
        guard let slot = shift.slotID else { return .init(ok: false, message: "This shift has no id — pull to refresh and retry.") }
        let out = await source.offerToPerson(slotID: slot, empID: toEmp, note: note, templateID: shift.templateID ?? 6)
        if out.ok {
            rememberOfferTarget(slot: slot, toEmp: toEmp)   // so My Posts can cancel it later
            if !note.isEmpty { _ = await Supabase.putOfferNote(slotID: slot, note: note, reason: reason, byEmp: Int(userEmp)) }
        }
        // Pasqua Rapid+MSU trade as one 24h shift → move the second half too.
        if out.ok, let slot2 = shift.slotID2 {
            _ = await source.offerToPerson(slotID: slot2, empID: toEmp, note: note, templateID: shift.templateID ?? 6)
            rememberOfferTarget(slot: slot2, toEmp: toEmp)
        }
        return out
    }

    /// Post a shift to the pool for several colleagues (whoever's eligible can grab it). LB carries no note on a
    /// group offer, so the note lives only in Supabase (shown in the Pool).
    func giveAwayToGroup(shift: MyShift, toEmps: [Int], note: String, reason: String?) async -> LBWebSource.WriteOutcome {
        guard let slot = shift.slotID, !toEmps.isEmpty else { return .init(ok: false, message: "No one is free to take this shift.") }
        let out = await source.offerToGroup(slotID: slot, empIDs: toEmps)
        if out.ok {
            rememberOfferTarget(slot: slot, toEmp: toEmps.first ?? -1)   // best-effort target for a My Posts cancel
            if !note.isEmpty { _ = await Supabase.putOfferNote(slotID: slot, note: note, reason: reason, byEmp: Int(userEmp)) }
        }
        // Pasqua Rapid+MSU posted as one 24h shift → post the second half too.
        if out.ok, let slot2 = shift.slotID2 {
            _ = await source.offerToGroup(slotID: slot2, empIDs: toEmps)
            rememberOfferTarget(slot: slot2, toEmp: toEmps.first ?? -1)
        }
        return out
    }

    /// yyyy-MM-dd + n days (UTC, date-only) — for building overnight-shift timestamps.
    static func addDays(_ iso: String, _ n: Int) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: iso) else { return iso }
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        return f.string(from: c.date(byAdding: .day, value: n, to: d) ?? d)
    }

    /// Give away PART of ANY shift (day or 24h/overnight). LB has no one-step partial give-away, so: split the shift
    /// into segments (all stay MINE), re-harvest to get the give-segment's fresh slot_id, then offer just that
    /// segment. `giveStartISO`/`giveEndISO` = full "yyyy-MM-ddTHH:mm:00" timestamps of the portion to hand off.
    func giveAwayPart(shift: MyShift, giveStartISO: String, giveEndISO: String, toEmp: Int?, everyone: Bool, note: String) async -> LBWebSource.WriteOutcome {
        guard let slot = shift.slotID, let myEmp = Int(userEmp) else { return .init(ok: false, message: "This shift has no id — pull to refresh and retry.") }
        let shiftStartISO = "\(shift.date)T\(shift.start):00"
        let shiftEndISO   = "\(shift.overnight ? Self.addDays(shift.date, 1) : shift.date)T\(shift.end):00"
        guard giveStartISO >= shiftStartISO, giveEndISO <= shiftEndISO, giveStartISO < giveEndISO else {
            return .init(ok: false, message: "Pick a time range inside your shift.")
        }
        var parts: [(start: String, end: String, empID: Int)] = []
        if giveStartISO > shiftStartISO { parts.append((shiftStartISO, giveStartISO, myEmp)) }   // keep the earlier bit
        parts.append((giveStartISO, giveEndISO, myEmp))                                           // the part to give away
        if giveEndISO < shiftEndISO { parts.append((giveEndISO, shiftEndISO, myEmp)) }            // keep the later bit
        let splitOut = await source.splitShift(slotID: slot, parts: parts, note: note)
        guard splitOut.ok else { return .init(ok: false, message: splitOut.message ?? "Couldn't split the shift.") }
        try? await Task.sleep(nanoseconds: 1_500_000_000)                                         // let LB apply the split
        await refresh()                                                                          // re-harvest → new segments get slot_ids
        let gDate = String(giveStartISO.prefix(10)), gStart = String(giveStartISO.dropFirst(11).prefix(5)), gEnd = String(giveEndISO.dropFirst(11).prefix(5))
        guard let part = myShifts.first(where: { ($0.date == gDate || $0.date == shift.date) && $0.start == gStart && $0.end == gEnd && $0.slotID != nil }) else {
            return .init(ok: false, message: "The shift was split, but I couldn't find the new part to offer — give that part away from My Shifts.")
        }
        if everyone { return await giveAwayToGroup(shift: part, toEmps: eligibleColleagues(for: part).map { $0.emp }, note: note, reason: nil) }
        if let emp = toEmp { return await giveAway(shift: part, toEmp: emp, note: note, reason: nil) }
        return .init(ok: false, message: "No recipient chosen.")
    }

    /// Withdraw a pending offer I made (before the colleague accepts).
    func cancelGiveAway(slotID: Int, toEmp: Int) async -> Bool {
        await source.cancelOffer(slotID: slotID, empID: toEmp).ok
    }

    /// Owner diagnostic: LB's raw status + response body from the last give-away write.
    var lastGiveAwayInfo: String { source.lastWriteInfo }

    /// Colleagues who can genuinely take `shift` — the SAME rest/competency rules as the Swap engine's "they can
    /// take mine" side (CJ's ask: only surface people who are actually free to pick it up): not already scheduled
    /// that day, not post-call (24h/night the day before), not pre-call (24h/night the day after), not already
    /// working the next day if this shift is a 24h/night, and SICU competency when it's a SICU shift.
    func eligibleColleagues(for shift: MyShift) -> [(emp: Int, name: String)] {
        let d = shift.date
        let busy     = Set((whoByDay[d] ?? []).map { $0.doc })
        let postCall = Set((whoByDay[Self.addDays(d, -1)] ?? []).filter { $0.overnight }.map { $0.doc })
        let preCall  = Set((whoByDay[Self.addDays(d,  1)] ?? []).filter { $0.overnight }.map { $0.doc })
        let nextDayBusy = shift.overnight ? Set((whoByDay[Self.addDays(d, 1)] ?? []).map { $0.doc }) : Set<String>()
        let sicuDocs = Set(whoData.filter { $0.unit == .SICU && $0.date < Self.todayRegina() }.map { $0.doc })
        return colleagues.filter { c in
            if busy.contains(c.name) || postCall.contains(c.name) || preCall.contains(c.name) || nextDayBusy.contains(c.name) { return false }
            if shift.unit == .SICU && !sicuDocs.contains(c.name) { return false }   // SICU needs prior SICU experience
            return true
        }
    }

    /// A fast, lightweight pool refresh: re-fetch ONLY the open-offer list (one light API call — no full
    /// roster harvest) and rebuild the pool. Runs on foreground / Pool-tab / a short timer so a newly-posted
    /// shift shows up quickly, without the cost of the full harvest.
    private var poolRefreshing = false
    /// Light pool-only refresh. Returns false when the live fetch FAILED (e.g. the ~1h token expired and every
    /// request 401'd) — the caller then triggers a full `refresh()`, which reloads the web view and re-captures a
    /// fresh token. On failure we keep the current pool (never wipe it to empty). Returns true when there's nothing
    /// to recover (busy / not logged in) or the fetch succeeded (even with genuinely zero open shifts).
    @discardableResult
    func refreshOpenShifts() async -> Bool {
        guard !demo, loggedIn, !loading, !groupScanning, !poolRefreshing else { return true }
        poolRefreshing = true; defer { poolRefreshing = false }
        guard let pending = await source.fetchOpenOffers() else {
            hbLog.log("pool refresh: live fetch failed (token expired?) — keeping pool, will recover via full refresh")
            return false
        }
        let schedule = MyScheduleModel(myShifts)
        openShifts = OpenShiftBuilder.build(pending: pending, schedule: schedule, today: Self.todayRegina())
        lastUpdated = Date()
        saveCache()
        hbLog.log("pool refresh: \(self.openShifts.count, privacy: .public) open")
        return true
    }

    // MARK: - Disk cache (so startup shows the previous data immediately)

    // NOTE: new fields must be Optional so older cached snapshots still decode (a non-optional
    // addition makes the whole cache fail to load and bounces the app to the login screen).
    private struct Snapshot: Codable { var open: [OpenShift]; var mine: [MyShift]; var me: String; var updated: Date; var owner: Bool?; var assigns: [Assignment]? }
    private var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("hb_cache.json")
    }
    private func loadCache() {
        guard let d = try? Data(contentsOf: cacheURL), let s = try? JSONDecoder().decode(Snapshot.self, from: d) else { return }
        openShifts = s.open; myShifts = s.mine; userName = s.me; lastUpdated = s.updated; isOwner = s.owner ?? false
        assignments = s.assigns ?? []
    }
    private func saveCache() {
        // Snapshot the values on the main actor, then encode + write off-thread so the recurring 2-min pool
        // refresh never stalls the UI re-encoding the (large) all-doctor `assignments` array.
        let s = Snapshot(open: openShifts, mine: myShifts, me: userName, updated: lastUpdated ?? Date(), owner: isOwner, assigns: assignments)
        let url = cacheURL
        Task.detached(priority: .utility) {
            if let d = try? JSONEncoder().encode(s) { try? d.write(to: url) }
        }
    }

    // MARK: - Durable shift log (the on-file record of shifts the logged-in person has worked / will work)
    //
    // The log accumulates: PAST shifts (date < today) are kept forever — even if Lightning Bolt later
    // stops returning old data — while today + future are refreshed live each harvest, so a shift you give
    // away disappears and one you pick up appears. Stored in Application Support (not the purgeable cache).

    private var historyLoadedAt: Date?
    static let historyStart = "20220101"        // the group's data on Lightning Bolt begins in 2022
    static let firstYear = 2022

    private func logKey(_ s: MyShift) -> String { "\(s.date)|\(s.unit.rawValue)|\(s.start)" }

    /// Refresh the present+future of the log from the live roster; the recorded past is never touched.
    private func mergeFuture(_ fresh: [MyShift]) {
        guard !fresh.isEmpty else { return }
        let today = Self.todayRegina()
        var byKey: [String: MyShift] = [:]
        for s in shiftLog where s.date < today { byKey[logKey(s)] = s }   // keep the past, always
        for s in fresh { byKey[logKey(s)] = s }                           // fresh owns today + future (dynamic)
        shiftLog = byKey.values.sorted { $0.date < $1.date }
        saveLog()
    }

    /// Union freshly-fetched history into the log — the past is authoritative and permanent.
    private func mergePast(_ history: [MyShift]) {
        guard !history.isEmpty else { return }
        var byKey: [String: MyShift] = [:]
        for s in shiftLog  { byKey[logKey(s)] = s }     // everything already on file stays
        for s in history   { byKey[logKey(s)] = s }     // add anything new
        shiftLog = byKey.values.sorted { $0.date < $1.date }
        saveLog()
    }

    /// Backfill the log from 2022 → today (once, then cached). Called lazily when My Stats / My Shifts opens.
    func loadHistory(force: Bool = false) async {
        if !force, let t = historyLoadedAt, Date().timeIntervalSince(t) < 12 * 3600, !shiftLog.isEmpty { return }
        guard loggedIn else { return }
        var tries = 0                                                        // wait out any live web-view work first
        while (loading || poolRefreshing || groupScanning) && tries < 30 { try? await Task.sleep(nanoseconds: 500_000_000); tries += 1 }
        guard !loading, !poolRefreshing, !groupScanning else { return }
        // require a non-empty result before marking it done, so a partial/early fetch keeps retrying next open
        guard let raw = await source.fetchMyShifts(since: Self.historyStart), !raw.isEmpty else { return }
        mergePast(OpenShiftBuilder.roster(from: raw))
        historyLoadedAt = Date()
        saveLog()
    }

    private struct LogSnapshot: Codable { var shifts: [MyShift]; var owner: String; var historyAt: Date?; var startUsed: String? }
    private var logURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hb_shiftlog.json")
    }
    private func loadLog() {
        guard let d = try? Data(contentsOf: logURL), let s = try? JSONDecoder().decode(LogSnapshot.self, from: d) else { return }
        shiftLog = s.shifts; userEmp = s.owner
        historyLoadedAt = (s.startUsed == Self.historyStart) ? s.historyAt : nil   // start changed → force a re-backfill
    }
    private func saveLog() {
        let s = LogSnapshot(shifts: shiftLog, owner: userEmp, historyAt: historyLoadedAt, startUsed: Self.historyStart)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: logURL) }
    }

    // MARK: - Admin group log (owner-only): the whole group's shifts, backfilled ONCE then cumulative.
    // Deep-scanned back to Jan 2025 a single time (in the background), written to file; thereafter each
    // normal refresh just replaces the recent window and the stored past stays put — never re-scanned.

    private var groupLoadedAt: Date?

    /// Backfill the whole group's history (Jan 2025 → now) via schedule/range with no emp filter — a few
    /// fast API calls. Cached; re-runs only if the log doesn't reach Jan 2025 or it's >12h stale.
    func loadGroupHistory(force: Bool = false) async {
        guard loggedIn else { return }                       // available to everyone — powers Who's On / Crew history
        // Skip the re-fetch only if the roster is fresh AND (for the owner) the swap log is already built —
        // otherwise a returning owner whose swapLog is empty (e.g. first launch after a swap-feature update)
        // would never backfill it.
        let swapsReady = !isOwner || !swapLog.isEmpty
        // Who's On / Crew history (all users) rarely changes for past days → cache 12h. But the owner's
        // Shift-pickups card must stay current as shifts change hands → re-scan hourly for the owner.
        let maxAge: TimeInterval = isOwner ? 3600 : 12 * 3600
        if !force, let t = groupLoadedAt, Date().timeIntervalSince(t) < maxAge, !groupLog.isEmpty, swapsReady { return }
        // WAIT for any in-flight harvest/refresh to finish rather than bailing — bailing here left the colleague
        // roster empty (build 39 stopped rebuilding it during harvest, so this is now the ONLY thing that fills it).
        var tries = 0
        while (loading || groupScanning) && tries < 60 { try? await Task.sleep(nanoseconds: 500_000_000); tries += 1 }
        guard !groupScanning else { groupFetchDebug = "bail · another group scan running"; return }
        groupScanning = true; defer { groupScanning = false }
        var res = await source.fetchGroupShifts(since: Self.historyStart)
        if res == nil || (res?.shifts.isEmpty ?? true) {
            // Fetch came back empty → the ~1h Lightning Bolt token likely expired, leaving Who's On / Crew stuck on
            // stale data (today missing from the range). Re-capture the token and retry once, so it self-heals
            // without a manual sign-out/in (matches loadDirectory).
            groupScanning = false                               // release so refresh() (which guards on it) can run
            await refresh()
            groupScanning = true
            res = await source.fetchGroupShifts(since: Self.historyStart)
        }
        guard let res, !res.shifts.isEmpty else {
            groupFetchDebug = "fetch failed even after refresh — token not ready?"; return
        }
        mergeRoster(res.shifts)                                  // colleagues emp_id → name, for the give-away picker
        buildOffRoster(res.shifts)                               // non-clinical entries (time off) → offByDay + label diagnostic
        groupFetchDebug = "ok · \(res.shifts.count) slots → roster \(roster.count)"
        let owner = isOwner, myEmp = userEmp, shifts = res.shifts, rawSwaps = res.swaps
        // The heavy parse — 31k slots → ~14k assignments (+ owner swap events) — off the main actor.
        let (asgs, swaps) = await Task.detached(priority: .userInitiated) { () -> ([Assignment], [SwapEvent]) in
            let a = OpenShiftBuilder.assignments(from: shifts, myEmp: myEmp).sorted { $0.date < $1.date }
            let s = owner ? SwapBuilder.build(from: rawSwaps, myEmp: myEmp) : []
            return (a, s)
        }.value
        if !asgs.isEmpty {                                   // fresh full history (2022 → next-year roster) → replace
            groupLog = asgs
            groupLoadedAt = Date()
            saveGroupLog()
            if owner {                                       // the Shift-pickups card is owner-only
                swapLog = swaps
                swapDebug = "roster changed-hands \(rawSwaps.count) · kept \(swaps.count) · pickups \(swaps.filter { $0.isPickup }.count)"
                saveSwapLog()
            }
            rebuildWho()
        }
    }

    private struct GroupSnapshot: Codable { var assigns: [Assignment]; var owner: String }
    private var groupLogURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hb_grouplog.json")
    }
    private func loadGroupLog() {
        guard let d = try? Data(contentsOf: groupLogURL), let s = try? JSONDecoder().decode(GroupSnapshot.self, from: d) else { return }
        if userEmp.isEmpty || s.owner == userEmp { groupLog = s.assigns }
    }
    private func saveGroupLog() {
        let s = GroupSnapshot(assigns: groupLog, owner: userEmp); let url = groupLogURL
        Task.detached(priority: .utility) { if let d = try? JSONEncoder().encode(s) { try? d.write(to: url) } }   // encode 14k off-main
    }

    private struct SwapSnapshot: Codable { var swaps: [SwapEvent]; var owner: String }
    private var swapLogURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hb_swaplog.json")
    }
    private func loadSwapLog() {
        guard let d = try? Data(contentsOf: swapLogURL), let s = try? JSONDecoder().decode(SwapSnapshot.self, from: d) else { return }
        if userEmp.isEmpty || s.owner == userEmp { swapLog = s.swaps }
    }
    private func saveSwapLog() {
        let s = SwapSnapshot(swaps: swapLog, owner: userEmp); let url = swapLogURL
        Task.detached(priority: .utility) { if let d = try? JSONEncoder().encode(s) { try? d.write(to: url) } }
    }

    /// Recompute the grouped Who's On / Crew data ONCE per data change (not per view render — keeps
    /// scrolling smooth over 4+ years of history).
    func rebuildWho() {
        let src = whoData
        // Grouping the full history (14k+ assignments) + walking the day range is enough to hitch the UI the moment
        // group data lands — do it off the main actor, then publish the results back.
        Task.detached(priority: .userInitiated) {
            let byDay = Dictionary(grouping: src) { $0.date }
            let dates = src.map(\.date)
            var days: [String] = []
            if let lo = dates.min(), let hi = dates.max() {
                var d = isoToDate(lo); let end = isoToDate(hi); let cal = Calendar.current; var g = 0
                while d <= end && g < 3000 { days.append(dateToISO(d)); d = cal.date(byAdding: .day, value: 1, to: d) ?? end; g += 1 }
            }
            await MainActor.run { self.whoByDay = byDay; self.whoDays = days }
        }
    }

    // MARK: - helpers
    private static let reginaDayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "America/Regina"); return f
    }()
    static func todayRegina() -> String { reginaDayFmt.string(from: Date()) }
    // The deterministic window harvest's my-shifts fetch covers (Jan 1 this year → Dec 31 next year) —
    // used by refresh() to replace exactly that span so given-away shifts clear without wiping past years.
    static var currentYearStartISO: String { String(todayRegina().prefix(4)) + "-01-01" }
    static var nextYearEndISO: String { (Int(todayRegina().prefix(4)).map { String($0 + 1) } ?? "9999") + "-12-31" }
    static func weeks(fromToday count: Int) -> [String] {
        var cal = Calendar(identifier: .iso8601); cal.timeZone = TimeZone(identifier: "America/Regina")!
        // Start at the Monday of the week containing the 1st of THIS month, so the current month is complete
        // (Lightning Bolt often doesn't populate the current partial week, and early-month days would be missed).
        let firstOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: firstOfMonth)) ?? firstOfMonth
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.timeZone = cal.timeZone
        return (0..<count).compactMap { i in cal.date(byAdding: .day, value: i * 7, to: start).map { f.string(from: $0) } }
    }
}
