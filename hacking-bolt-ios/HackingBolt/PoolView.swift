import SwiftUI
import WebKit

struct PoolView: View {
    @EnvironmentObject var model: AppModel
    @State private var onlyPickable = false     // false = all posted shifts (default), true = only what I can take
    private var pickable: Int { model.openShifts.filter { !$0.conflict }.count }
    private var shownShifts: [OpenShift] { onlyPickable ? model.openShifts.filter { !$0.conflict } : model.openShifts }

    /// Continuous "YYYY-MM" months from the current month through the last month with an open shift.
    private var calMonths: [String] {
        let cur = String(AppModel.todayRegina().prefix(7))
        // span the whole roster: current month → last month that has any of my shifts or an open shift
        let all = model.openShifts.map { String($0.iso.prefix(7)) } + model.myShifts.map { String($0.date.prefix(7)) }
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
        }
    }

    // Portrait: calendars in a horizontal strip on top, list scrolling below.
    @ViewBuilder private var portraitLayout: some View {
        if !calMonths.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) { ForEach(calMonths, id: \.self) { miniMonth($0) } }
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
            if !calMonths.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(calMonths, id: \.self) { miniMonth($0) }
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
        let d = maps(forMonth: key)
        MiniMonth(year: d.y, month: d.mo, fill: d.fill, post: d.post, open: d.open,
                  todayDay: d.today, fuseStart: d.fuseStart, fuseEnd: d.fuseEnd)
    }

    private var shiftList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if !model.openShifts.isEmpty {
                        HStack(spacing: 8) {
                            Picker("", selection: $onlyPickable) {
                                Text("All \(model.openShifts.count)").tag(false)
                                Text("For me \(pickable)").tag(true)
                            }
                            .pickerStyle(.segmented)
                            if let t = model.lastUpdated { Text(t, style: .time).font(.caption2).foregroundStyle(Theme.muted) }
                        }.padding(.horizontal, 2).padding(.bottom, 2)
                    }
                    ForEach(shownShifts) { s in OpenShiftCard(shift: s).id(s.id) }
                    if shownShifts.isEmpty && !model.loading {
                        Text(onlyPickable ? "Nothing open for you to pick up right now." : "No open shifts right now. 🎉")
                            .foregroundStyle(Theme.muted).padding(.top, 40)
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
        onlyPickable = false                                   // ensure it's visible (not filtered out)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let target = model.openShifts.first(where: { $0.iso == date }) {
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target.id, anchor: .top) }
            }
            model.poolJumpDate = nil                           // consume the signal
        }
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
        for u in model.myShifts.map(\.unit) + model.openShifts.map(\.unit) where seen.insert(u).inserted { out.append(u) }
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
        }
        .padding(.horizontal, 14).padding(.top, 5).padding(.bottom, 3)
    }

    private func maps(forMonth key: String) -> (y: Int, mo: Int, fill: [Int: Color], post: [Int: Color], open: Set<Int>, today: Int?, fuseStart: Set<Int>, fuseEnd: Set<Int>) {
        let (y, mo) = ym(key)
        var fill: [Int: Color] = [:], post: [Int: Color] = [:], open: Set<Int> = []
        var fuseStart: Set<Int> = [], fuseEnd: Set<Int> = []
        let cal = Calendar(identifier: .gregorian)
        func day(_ iso: String) -> Int? { Int(iso.suffix(2)) }
        for s in model.myShifts where s.date.hasPrefix(key) {
            if let d = day(s.date), let c = Units.info[s.unit]?.color { fill[d] = c }
        }
        for s in model.myShifts where s.overnight {
            let nd = ConflictEngine.addDay(s.date)
            if nd.hasPrefix(key), let d = day(nd), let c = Units.info[s.unit]?.color { post[d] = c }
            // fuse the on-call day into its post-call next day, unless the call falls on a Saturday (week break)
            if s.date.hasPrefix(key), let cd = day(s.date), let nday = day(nd), nd.hasPrefix(key) {
                var comp = DateComponents(); comp.year = y; comp.month = mo; comp.day = cd
                let wd = cal.date(from: comp).map { cal.component(.weekday, from: $0) - 1 } ?? 0
                if wd < 6 { fuseStart.insert(cd); fuseEnd.insert(nday) }
            }
        }
        for o in model.openShifts where o.iso.hasPrefix(key) { if let d = day(o.iso) { open.insert(d) } }
        let todayIso = AppModel.todayRegina()
        return (y, mo, fill, post, open, todayIso.hasPrefix(key) ? day(todayIso) : nil, fuseStart, fuseEnd)
    }
}

struct OpenShiftCard: View {
    let shift: OpenShift
    @State private var showAccept = false
    @State private var showConfirm = false            // guard against an accidental tap opening the accept flow
    private var info: UnitInfo { Units.info[shift.unit] ?? UnitInfo(short: shift.unit.rawValue, full: "", color: .gray) }
    private var free: Bool { !shift.conflict }

    // date parts for the card's date column
    private var dateParts: (dow: String, day: String, mon: String) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: shift.iso) else { return ("", "", "") }
        let g = DateFormatter(); g.timeZone = TimeZone(identifier: "UTC")
        g.dateFormat = "EEE"; let dow = g.string(from: d)
        g.dateFormat = "d";   let day = g.string(from: d)
        g.dateFormat = "MMM"; let mon = g.string(from: d)
        return (dow, day, mon)
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(info.color).frame(width: 5)
            VStack(spacing: 0) {                      // date column
                Text(dateParts.dow).font(.caption2).foregroundStyle(Theme.muted)
                Text(dateParts.day).font(.title3.weight(.heavy)).foregroundStyle(free ? info.color : Theme.muted)
                Text(dateParts.mon.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
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
            Button("Continue") { showAccept = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(info.full) · \(fmt(shift.iso, "EEE, MMM d, yyyy")) · \(shift.hoursLabel)\nOffered by \(shift.offerer). You'll still confirm on the scheduler's own screen.")
        }
        .sheet(isPresented: $showAccept) {
            if let url = shift.acceptURL { AcceptSheet(url: url) }
        }
    }
}

/// Opens a Lightning Bolt accept link INSIDE the app, in a web view that shares the app's already-logged-in
/// session — so there's no external-Safari login bounce (which was dropping the shift and dumping the user on
/// the dashboard). The user still confirms the swap on Lightning Bolt's own screen; the app never accepts for them.
struct AcceptSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            AuthWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Pick up shift")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct AuthWebView: UIViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()               // same cookie store as the harvester
        cfg.processPool = LBWebSource.sharedPool        // + same live session
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.load(URLRequest(url: url))                    // cold-load dashboard/#/swop/<id>/accept → openSwop fires on boot
        context.coordinator.start(wv, target: url)
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// Poll the page: once the Accept/Decline modal is up we're done; if we get stuck on the plain dashboard
    /// (session had expired and login stripped the swop hash), re-load the accept URL once now that we're signed
    /// in. Waits through a manual re-login too.
    final class Coordinator {
        private var reloaded = false, dashHits = 0, ticks = 0
        func start(_ wv: WKWebView, target: URL) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.poll(wv, target: target) }
        }
        private func poll(_ wv: WKWebView, target: URL) {
            guard ticks < 100 else { return }; ticks += 1
            let js = """
            (function(){ var t = document.body.innerText || '';
              if (/OPENING SWAPORTUNITY|SUBMIT/i.test(t)) return 'accept';
              if (/Sign in to access|Forgot your password/i.test(t)) return 'login';
              if (/NEXT 3 DAYS|SWAPORTUNITY FEED/i.test(t)) return 'dash';
              return 'wait'; })();
            """
            wv.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self else { return }
                switch result as? String {
                case "accept": return                                   // modal is open — done
                case "dash":
                    self.dashHits += 1
                    if self.dashHits >= 4 && !self.reloaded {           // stuck ~2s → login stripped the swop, retry once
                        self.reloaded = true; self.dashHits = 0
                        wv.load(URLRequest(url: target))
                    }
                default: self.dashHits = 0                              // login / still loading → keep waiting
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.poll(wv, target: target) }
            }
        }
    }
}
