import SwiftUI

@main
struct HackingBoltApp: App {
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
    @Published var groupScanning = false             // the group-history fetch is running (background)
    @Published var whoByDay: [String: [Assignment]] = [:]   // Who's On / Crew source, grouped (precomputed for scroll perf)
    @Published var whoDays: [String] = []                   // contiguous day list across the full history range
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

    init() { loadCache(); loadLog(); loadGroupLog(); rebuildWho() }   // show last-known data + durable logs instantly

    /// Runs once when the UI appears: cached data is already on screen; log in + refresh in the background.
    func start() async {
        guard !started else { return }
        started = true
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
                await refresh()
                return
            }
            if i == 6 && !hasData { showLogin = true }   // ~3s, nothing cached → must sign in
            i += 1
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func signIn() { showLogin = true }

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
        lastUpdated = Date()
        loggedIn = false
        syncing = false
        showLogin = false
        rebuildWho()
    }

    /// Sign out of Lightning Bolt and wipe this device's cached data, so the next person to log in gets
    /// their own roster/stats loaded fresh (handy for demos on a shared phone).
    func signOut() {
        source.signOut()
        shiftLog = []; groupLog = []; myShifts = []; openShifts = []; assignments = []
        whoByDay = [:]; whoDays = []
        userName = ""; userEmp = ""; isOwner = false; demo = false
        historyLoadedAt = nil; groupLoadedAt = nil; lastUpdated = nil
        try? FileManager.default.removeItem(at: cacheURL)
        try? FileManager.default.removeItem(at: logURL)
        try? FileManager.default.removeItem(at: groupLogURL)
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
            let needFull = isStale
            Task { await refreshOpenShifts(); if needFull { await refresh() } }   // open → latest pool now; full harvest if stale
        }
        startPeriodic()
    }
    func onBackground() { periodic?.cancel(); periodic = nil }

    private var isStale: Bool {
        guard let t = lastUpdated else { return true }
        return Date().timeIntervalSince(t) > 180        // older than 3 min
    }

    /// While the app is open: a LIGHT pool refresh every 2 min (so newly-posted shifts appear quickly),
    /// and a FULL harvest every ~10 min (roster + who's on).
    private func startPeriodic() {
        guard periodic == nil else { return }
        periodic = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2 * 60 * 1_000_000_000)   // 2 min
                if Task.isCancelled { break }
                guard let self else { break }
                if self.loggedIn {
                    await self.refreshOpenShifts()
                    tick += 1
                    if tick % 5 == 0 { await self.refresh() }                 // ~every 10 min
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
            if !userEmp.isEmpty && userEmp != e { shiftLog = []; historyLoadedAt = nil; groupLog = []; groupLoadedAt = nil }   // different person → fresh logs
            userEmp = e
            isOwner = (e == Self.ownerEmpID)
        }
        let newMine = OpenShiftBuilder.roster(from: raw.mine)
        // The scan pages every slot across a contiguous date range; [lo…hi] is exactly what it covered.
        // REPLACE that range with the fresh result (so a shift you gave away / that was withdrawn disappears),
        // but KEEP anything outside it — past months the scan doesn't reach, and future weeks a throttled
        // partial scan didn't get to (so we never wipe good coverage).
        let allDates = (raw.all ?? []).compactMap { $0.date }
        if let lo = allDates.min(), let hi = allDates.max() {
            myShifts = (myShifts.filter { $0.date < lo || $0.date > hi } + newMine)
                .sorted { $0.date < $1.date }
            let fresh = OpenShiftBuilder.assignments(from: raw.all ?? [], myEmp: raw.emp)
            assignments = (assignments.filter { $0.date < lo || $0.date > hi } + fresh)
                .sorted { $0.date == $1.date ? $0.unit.rawValue < $1.unit.rawValue : $0.date < $1.date }
        } else {
            // no coverage info — fall back to union-merge so nothing is lost
            var byKey: [String: MyShift] = [:]
            for s in myShifts { byKey["\(s.date)|\(s.unit.rawValue)|\(s.start)"] = s }
            for s in newMine  { byKey["\(s.date)|\(s.unit.rawValue)|\(s.start)"] = s }
            myShifts = byKey.values.sorted { $0.date < $1.date }
        }
        mergeFuture(myShifts)                                    // refresh the durable log's present+future (past is kept)
        if groupLog.isEmpty { rebuildWho() }                     // until the group history loads, Who's On uses the live window
        let schedule = MyScheduleModel(myShifts)
        // raw.pending is now the COMPLETE open-offer list (schedule/range?only_pending — every unit, whole
        // roster, each already carrying its slot_id), so build the pool straight from it. No stale feed:
        // the dashboard SWAPORTUNITY feed lagged (listing offers already taken) and missed Rapid Response.
        openShifts = OpenShiftBuilder.build(pending: raw.pending, schedule: schedule, today: Self.todayRegina())
        lastUpdated = Date()
        saveCache()
        hbLog.log("refresh DONE: open=\(self.openShifts.count, privacy: .public) mine=\(self.myShifts.count, privacy: .public)")
    }

    /// A fast, lightweight pool refresh: re-fetch ONLY the open-offer list (one light API call — no full
    /// roster harvest) and rebuild the pool. Runs on foreground / Pool-tab / a short timer so a newly-posted
    /// shift shows up quickly, without the cost of the full harvest.
    private var poolRefreshing = false
    func refreshOpenShifts() async {
        guard !demo, loggedIn, !loading, !groupScanning, !poolRefreshing else { return }
        poolRefreshing = true; defer { poolRefreshing = false }
        guard let pending = await source.fetchOpenOffers() else { return }   // token not ready → keep the current pool
        let schedule = MyScheduleModel(myShifts)
        openShifts = OpenShiftBuilder.build(pending: pending, schedule: schedule, today: Self.todayRegina())
        lastUpdated = Date()
        saveCache()
        hbLog.log("pool refresh: \(self.openShifts.count, privacy: .public) open")
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
        let s = Snapshot(open: openShifts, mine: myShifts, me: userName, updated: lastUpdated ?? Date(), owner: isOwner, assigns: assignments)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: cacheURL) }
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
        if !force, let t = groupLoadedAt, Date().timeIntervalSince(t) < 12 * 3600, !groupLog.isEmpty { return }
        var tries = 0
        while loading && tries < 30 { try? await Task.sleep(nanoseconds: 500_000_000); tries += 1 }
        guard !loading, !groupScanning else { return }
        groupScanning = true; defer { groupScanning = false }
        guard let raw = await source.fetchGroupShifts(since: Self.historyStart), !raw.isEmpty else { return }
        let asgs = OpenShiftBuilder.assignments(from: raw, myEmp: userEmp)
        if !asgs.isEmpty {                                   // fresh full history (2022 → next-year roster) → replace
            groupLog = asgs.sorted { $0.date < $1.date }
            groupLoadedAt = Date()
            saveGroupLog()
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
        let s = GroupSnapshot(assigns: groupLog, owner: userEmp)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: groupLogURL) }
    }

    /// Recompute the grouped Who's On / Crew data ONCE per data change (not per view render — keeps
    /// scrolling smooth over 4+ years of history).
    func rebuildWho() {
        let src = whoData
        whoByDay = Dictionary(grouping: src) { $0.date }
        let dates = src.map(\.date)
        guard let lo = dates.min(), let hi = dates.max() else { whoDays = []; return }
        var out: [String] = []; var d = isoToDate(lo); let end = isoToDate(hi); let cal = Calendar.current; var g = 0
        while d <= end && g < 3000 { out.append(dateToISO(d)); d = cal.date(byAdding: .day, value: 1, to: d) ?? end; g += 1 }
        whoDays = out
    }

    // MARK: - helpers
    static func todayRegina() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "America/Regina")
        return f.string(from: Date())
    }
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
