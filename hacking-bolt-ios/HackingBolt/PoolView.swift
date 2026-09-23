import SwiftUI
import WebKit

struct PoolView: View {
    @EnvironmentObject var model: AppModel
    private enum PoolTab: Hashable { case all, forMe, mine }
    @State private var tab: PoolTab = .all      // All posted shifts (default) / For me / My posts
    @AppStorage("hb_pool_forme") private var poolForMeDefault = false   // Advanced: open the Pool on "For me"
    @AppStorage("hb_week_start") private var weekStartRaw = 0            // 0 = Sunday, 1 = Monday (mini-calendars)
    private var mondayFirst: Bool { weekStartRaw == 1 }
    @State private var appliedPoolDefault = false
    private var pickable: Int { model.openShifts.filter { !$0.conflict }.count }
    private var shownShifts: [OpenShift] { tab == .forMe ? model.openShifts.filter { !$0.conflict } : model.openShifts }
    private var myPostsPending: Int { model.myPosts.filter { $0.status == .pending }.count }
    // Fall back to "All" if the My-posts segment vanished (posts cleared) while it was selected.
    private var effectiveTab: PoolTab { (tab == .mine && !model.showMyPostsTab) ? .all : tab }

    // Mini-calendar data, precomputed once per data change (was recomputed for every month on every render).
    private struct MonthMap {
        let y: Int, mo: Int
        let fill: [Int: Color], post: [Int: Color], open: Set<Int>
        let today: Int?, fuseStart: Set<Int>, fuseEnd: Set<Int>
    }
    @State private var monthKeys: [String] = []
    @State private var monthMaps: [String: MonthMap] = [:]
    @State private var monthSig = ""
    // The accept sheet lives HERE, not on the row: a pool refresh drops a just-taken shift's row, which used to
    // tear the sheet (and its "no longer available" banner) down mid-read.
    @State private var accepting: AcceptTarget?
    // Full roster (2022 → next-year), same source the My Shifts calendar uses — so future months populate.
    // Falls back to the live window until the durable log has loaded.
    private var mySched: [MyShift] { model.shiftLog.isEmpty ? model.myShifts : model.shiftLog }
    private var poolDataSig: String { "\(model.openVersion)|\(model.mineVersion)|\(AppModel.todayRegina())|\(weekStartRaw)" }
    private func rebuildMonths() {
        guard monthSig != poolDataSig else { return }
        let keys = computeCalMonths()
        var maps: [String: MonthMap] = [:]
        for k in keys { maps[k] = computeMonthMap(k) }
        monthKeys = keys; monthMaps = maps; monthSig = poolDataSig
    }

    /// Continuous "YYYY-MM" months from the current month through the last month with an open shift.
    private func computeCalMonths() -> [String] {
        let cur = String(AppModel.todayRegina().prefix(7))
        let all = model.openShifts.map { String($0.iso.prefix(7)) } + mySched.map { String($0.date.prefix(7)) }
        let hi = all.max() ?? cur
        var out: [String] = []
        var (y, m) = ym(min(cur, hi)); let (ey, em) = ym(max(cur, hi)); var guardN = 0
        while (y < ey || (y == ey && m <= em)) && guardN < 24 {
            out.append(String(format: "%04d-%02d", y, m)); m += 1; if m > 12 { m = 1; y += 1 }; guardN += 1
        }
        return out
    }
    private func ym(_ k: String) -> (Int, Int) {
        let p = k.split(separator: "-").compactMap { Int($0) }; return (p.first ?? 2026, p.count > 1 ? p[1] : 1)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                VStack(spacing: 0) {
                    if !model.loggedIn && model.hasData { signInBanner }
                    if landscape { landscapeLayout } else { portraitLayout }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.bg.ignoresSafeArea())
            }
            .navigationTitle("Shift Pool")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if model.loading && !model.hasData {
                    ProgressView("Reading your roster…").tint(Theme.accent)
                }
            }
            .onAppear {
                rebuildMonths()
                if !appliedPoolDefault { appliedPoolDefault = true; if poolForMeDefault { tab = .forMe } }
                #if DEBUG
                if ProcessInfo.processInfo.environment["DEMO_POOL"] == "mine" { tab = .mine }   // screenshot hook
                #endif
                if model.poolShowMine { tab = .mine; model.poolShowMine = false }   // cold-launched from a pickup push
            }
            .onChange(of: poolDataSig) { _, _ in rebuildMonths() }
            .sheet(item: $accepting) { AcceptSheet(url: $0.url) }
            .onChange(of: model.poolShowMine) { _, show in if show { tab = .mine; model.poolShowMine = false } }
            .task { await model.loadHistory() }   // backfill the full roster so the mini-calendar shows future months
            .task { await model.loadPickups() }   // My Posts → "picked up" (shared backend)
            .task { await model.loadMyPostNotes() }   // label pending posts as swaps (their notes)
        }
    }

    // Portrait: calendars in a horizontal strip on top, list scrolling below.
    @ViewBuilder private var portraitLayout: some View {
        if !monthKeys.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) { ForEach(monthKeys, id: \.self) { miniMonth($0) } }
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
            legend
            Divider().overlay(Theme.line)
        }
        shiftList
    }

    // Landscape: calendars in a left panel (scrolls vertically), list on the right — independent scrolls.
    @ViewBuilder private var landscapeLayout: some View {
        HStack(spacing: 0) {
            if !monthKeys.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(monthKeys, id: \.self) { miniMonth($0) }
                        legend.padding(.top, 2)
                    }
                    .padding(.vertical, 12).padding(.horizontal, 10)
                }
                .frame(width: 200)
                Divider().overlay(Theme.line)
            }
            shiftList
        }
    }

    @ViewBuilder private func miniMonth(_ key: String) -> some View {
        if let d = monthMaps[key] {
            MiniMonth(year: d.y, month: d.mo, fill: d.fill, post: d.post, open: d.open,
                      todayDay: d.today, fuseStart: d.fuseStart, fuseEnd: d.fuseEnd)
        }
    }

    private var shiftList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if !model.openShifts.isEmpty || model.showMyPostsTab {
                        HStack(spacing: 8) {
                            Picker("", selection: $tab) {
                                Text("All \(model.openShifts.count)").tag(PoolTab.all)
                                Text("For me \(pickable)").tag(PoolTab.forMe)
                                if model.showMyPostsTab {
                                    Text(myPostsPending > 0 ? "My posts \(myPostsPending)" : "My posts").tag(PoolTab.mine)
                                }
                            }
                            .pickerStyle(.segmented)
                            if let t = model.lastUpdated { Text(poolUpdatedLabel(t)).font(.caption2).foregroundStyle(Theme.muted) }
                        }.padding(.horizontal, 2).padding(.bottom, 2)
                    }
                    if effectiveTab == .mine {
                        MyPostsList(posts: model.myPosts)
                    } else {
                        ForEach(shownShifts) { s in OpenShiftCard(shift: s) { accepting = AcceptTarget(url: $0) }.id(s.id) }
                        if shownShifts.isEmpty && !model.loading {
                            Text(effectiveTab == .forMe ? "Nothing open for you to pick up right now." : "No open shifts right now. 🎉")
                                .foregroundStyle(Theme.muted).padding(.top, 40)
                        }
                    }
                }
                .padding(14)
            }
            .refreshable { await model.refresh() }
            .onChange(of: model.poolJumpDate) { _, date in jumpToDate(proxy, date) }
            .onAppear { jumpToDate(proxy, model.poolJumpDate) }
        }
    }

    // Arriving from a My Shifts calendar tap: show all shifts, then scroll to the open shift on that date.
    private func jumpToDate(_ proxy: ScrollViewProxy, _ date: String?) {
        guard let date else { return }
        tab = .all                                             // ensure it's visible (not filtered out)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let target = model.openShifts.first(where: { $0.iso == date }) {
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target.id, anchor: .top) }
            }
            model.poolJumpDate = nil                           // consume the signal
        }
    }

    // Show the time for a same-day update, but include the date when it's older — so a stale snapshot
    // (e.g. last night's) reads as stale instead of looking current.
    private func poolUpdatedLabel(_ t: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(t) ? "HH:mm" : "MMM d, HH:mm"
        return f.string(from: t)
    }

    private var signInBanner: some View {
        Button { model.signIn() } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                Text("Showing saved shifts — tap to sign in and update").font(.caption.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(Theme.accent).padding(.horizontal, 14).padding(.vertical, 9)
            .background(Theme.accent.opacity(0.10))
        }
    }

    /// The units actually present in the current data — keeps the key short and relevant.
    private var legendUnits: [UnitKey] {
        var seen = Set<UnitKey>(); var out: [UnitKey] = []
        for u in mySched.map(\.unit) + model.openShifts.map(\.unit) where seen.insert(u).inserted { out.append(u) }
        return out.sorted { $0.rawValue < $1.rawValue }
    }

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 10)], alignment: .leading, spacing: 4) {
            ForEach(legendUnits, id: \.self) { u in
                if let i = Units.info[u] {
                    HStack(spacing: 4) {
                        Circle().fill(i.color).frame(width: 7, height: 7)
                        Text(i.short).font(.system(size: 9.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
            }
            HStack(spacing: 4) {                                     // the open-shift marker used on the calendars
                Circle().strokeBorder(Theme.available, lineWidth: 1.5).frame(width: 7, height: 7)
                Text("Open").font(.system(size: 9.5)).foregroundStyle(Theme.muted)
            }
            if !model.postedPendingDates.isEmpty {                   // a shift I've posted, still waiting (My Shifts marker)
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.posted).frame(width: 7, height: 7)
                    Text("Posted").font(.system(size: 9.5)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 5).padding(.bottom, 3)
    }

    private func computeMonthMap(_ key: String) -> MonthMap {
        let (y, mo) = ym(key)
        var fill: [Int: Color] = [:], post: [Int: Color] = [:], open: Set<Int> = []
        var fuseStart: Set<Int> = [], fuseEnd: Set<Int> = []
        let cal = Calendar(identifier: .gregorian)
        func day(_ iso: String) -> Int? { Int(iso.suffix(2)) }
        for s in mySched where s.date.hasPrefix(key) {
            if let d = day(s.date), let c = Units.info[s.unit]?.color { fill[d] = c }
        }
        for s in mySched where s.overnight {
            let nd = ConflictEngine.addDay(s.date)
            if nd.hasPrefix(key), let d = day(nd), let c = Units.info[s.unit]?.color { post[d] = c }
            // fuse the on-call day into its post-call next day, unless the call is the last column of a week row
            if s.date.hasPrefix(key), let cd = day(s.date), let nday = day(nd), nd.hasPrefix(key) {
                var comp = DateComponents(); comp.year = y; comp.month = mo; comp.day = cd
                let wd = cal.date(from: comp).map { cal.component(.weekday, from: $0) - 1 } ?? 0
                let wcol = mondayFirst ? (wd + 6) % 7 : wd
                if wcol < 6 { fuseStart.insert(cd); fuseEnd.insert(nday) }
            }
        }
        for o in model.openShifts where o.iso.hasPrefix(key) { if let d = day(o.iso) { open.insert(d) } }
        let todayIso = AppModel.todayRegina()
        return MonthMap(y: y, mo: mo, fill: fill, post: post, open: open,
                        today: todayIso.hasPrefix(key) ? day(todayIso) : nil, fuseStart: fuseStart, fuseEnd: fuseEnd)
    }
}

struct AcceptTarget: Identifiable { let id = UUID(); let url: URL }

struct OpenShiftCard: View {
    let shift: OpenShift
    var onAccept: (URL) -> Void = { _ in }
    @State private var showConfirm = false            // guard against an accidental tap opening the accept flow
    private var info: UnitInfo { Units.info[shift.unit] ?? UnitInfo(short: shift.unit.rawValue, full: "", color: .gray) }
    private var free: Bool { !shift.conflict }

    // Cached formatters (allocating a DateFormatter per card render was ~12 allocs/card while scrolling the pool).
    private static let isoF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f }()
    private static let dowF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; f.timeZone = TimeZone(identifier: "UTC"); return f }()
    private static let dayF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d";   f.timeZone = TimeZone(identifier: "UTC"); return f }()
    private static let monF: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM"; f.timeZone = TimeZone(identifier: "UTC"); return f }()

    // date parts for the card's date column
    private var dateParts: (dow: String, day: String, mon: String) {
        guard let d = Self.isoF.date(from: shift.iso) else { return ("", "", "") }
        return (Self.dowF.string(from: d), Self.dayF.string(from: d), Self.monF.string(from: d))
    }

    var body: some View {
        let parts = dateParts               // compute once (body reads dow/day/mon)
        return HStack(spacing: 0) {
            Rectangle().fill(info.color).frame(width: 5)
            VStack(spacing: 0) {                      // date column
                Text(parts.dow).font(.caption2).foregroundStyle(Theme.muted)
                Text(parts.day).font(.title3.weight(.heavy)).foregroundStyle(free ? info.color : Theme.muted)
                Text(parts.mon.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .frame(width: 46).padding(.leading, 8)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(info.short).font(.caption2).bold()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(info.color.opacity(0.16)).foregroundStyle(info.color).clipShape(Capsule())
                    Text(info.full).font(.subheadline.bold()).foregroundStyle(Theme.ink)
                    if shift.isSplit {
                        Text("SPLIT").font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(Theme.muted).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Theme.line).clipShape(Capsule())
                    }
                }
                Text(shift.hoursLabel).font(.caption).foregroundStyle(Theme.muted)
                Text("Offered by \(shift.offerer)").font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 12).padding(.leading, 12)
            Spacer(minLength: 8)
            Group {
                if free {
                    HStack(spacing: 3) { Text("Available"); Image(systemName: "arrow.up.forward") }
                        .font(.caption.bold()).foregroundStyle(Theme.available)
                } else {
                    Text(shift.flag).font(.caption2).foregroundStyle(Theme.muted).multilineTextAlignment(.trailing)
                }
            }
            .padding(.trailing, 12).frame(maxWidth: 108, alignment: .trailing)
        }
        .background(free ? Theme.panel : info.color.opacity(0.13))   // non-pickable → lighter shade of the unit colour
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(free ? 0.06 : 0.03), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture { if free, shift.acceptURL != nil { showConfirm = true } }
        .confirmationDialog("Pick up this shift?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Continue") { if let url = shift.acceptURL { onAccept(url) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(info.full) · \(fmt(shift.iso, "EEE, MMM d, yyyy")) · \(shift.hoursLabel)\nOffered by \(shift.offerer). You'll still confirm on the scheduler's own screen.")
        }
    }
}

/// Opens a Lightning Bolt accept link INSIDE the app, in a web view that shares the app's already-logged-in
/// session — so there's no external-Safari login bounce (which was dropping the shift and dumping the user on
/// the dashboard). The user still confirms the swap on Lightning Bolt's own screen; the app never accepts for them.
struct AcceptSheet: View {
    let url: URL
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var gone = false        // LB reported the offer no longer exists (withdrawn / taken)
    var body: some View {
        NavigationStack {
            ZStack {
                AuthWebView(url: url, onGone: handleGone)
                    .ignoresSafeArea(edges: .bottom)
                if gone { goneBanner.transition(.opacity) }
            }
            .navigationTitle("Pick up shift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        // Reconcile the pool after any attempt — a taken/withdrawn shift drops off right away.
        .onDisappear { Task { await model.refreshOpenShifts() } }
    }

    // LB's own accept page threw "Preswap no longer exists" — swap its scary red error for a calm
    // explanation and refresh the pool so the dead row disappears.
    private func handleGone() {
        guard !gone else { return }
        withAnimation(.easeInOut(duration: 0.25)) { gone = true }
        Task { await model.refreshOpenShifts() }
    }

    private var goneBanner: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 46)).foregroundStyle(Theme.accent)
                Text("Shift no longer available").font(.title3.bold()).foregroundStyle(Theme.ink)
                Text("This one was just withdrawn or picked up by someone else. Nothing changed on your schedule — the pool's been refreshed.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                Button { dismiss() } label: {
                    Text("Back to pool").font(.headline)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .background(Theme.accent).foregroundStyle(.white).clipShape(Capsule())
                }.padding(.top, 4)
            }
        }
    }
}

private struct AuthWebView: UIViewRepresentable {
    let url: URL
    var onGone: () -> Void = {}                          // LB rejected the accept: offer no longer exists
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()               // same cookie store as the harvester
        cfg.processPool = LBWebSource.sharedPool        // + same live session
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.load(URLRequest(url: url))                    // cold-load dashboard/#/swop/<id>/accept → openSwop fires on boot
        context.coordinator.onGone = onGone
        context.coordinator.start(wv, target: url)
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// Poll the page: surface LB's "Preswap no longer exists" as a friendly banner; once the Accept/Decline modal
    /// is up we keep watching (the error only appears AFTER Submit); if we get stuck on the plain dashboard
    /// (session had expired and login stripped the swop hash), re-load the accept URL once now that we're signed
    /// in. Waits through a manual re-login too.
    final class Coordinator {
        var onGone: () -> Void = {}
        private var reloaded = false, dashHits = 0, ticks = 0, fired = false
        func start(_ wv: WKWebView, target: URL) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.poll(wv, target: target) }
        }
        private func poll(_ wv: WKWebView, target: URL) {
            guard ticks < 200 else { return }; ticks += 1     // ~100s: covers the read-modal-then-Submit window
            let js = """
            (function(){ var t = document.body.innerText || '';
              if (/no longer exists|REQUEST HAD ERRORS/i.test(t)) return 'gone';
              if (/OPENING SWAPORTUNITY|SUBMIT/i.test(t)) return 'accept';
              if (/Sign in to access|Forgot your password/i.test(t)) return 'login';
              if (/NEXT 3 DAYS|SWAPORTUNITY FEED/i.test(t)) return 'dash';
              return 'wait'; })();
            """
            wv.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self else { return }
                switch result as? String {
                case "gone":                                            // LB: offer already withdrawn/taken
                    if !self.fired { self.fired = true; DispatchQueue.main.async { self.onGone() } }
                    return                                              // stop — the sheet now shows the banner
                case "dash":
                    self.dashHits += 1
                    if self.dashHits >= 4 && !self.reloaded {           // stuck ~2s → login stripped the swop, retry once
                        self.reloaded = true; self.dashHits = 0
                        wv.load(URLRequest(url: target))
                    }
                default: self.dashHits = 0                              // accept modal / login / loading → keep watching
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.poll(wv, target: target) }
            }
        }
    }
}
