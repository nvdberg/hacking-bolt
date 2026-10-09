import SwiftUI

/// The order units appear as rows in the Who's Working grid — editable in More → "Who's On order",
/// saved on-device. Defaults to RGH-Rapid on top.
@MainActor final class UnitOrderStore: ObservableObject {
    static let shared = UnitOrderStore()
    private let key = "hb_whoson_order"
    static let defaultOrder: [UnitKey] = [.RR, .SICU, .MICU, .CCU, .PHICU, .PRR, .MSU]

    @Published var order: [UnitKey] { didSet { save() } }

    private init() {
        if let raw = UserDefaults.standard.array(forKey: key) as? [String], !raw.isEmpty {
            let parsed = raw.compactMap { UnitKey(rawValue: $0) }
            // forward-compat: keep any unit that isn't in the saved order yet (appended in default position)
            order = parsed + UnitOrderStore.defaultOrder.filter { !parsed.contains($0) }
        } else {
            order = Self.defaultOrder
        }
    }
    private func save() { UserDefaults.standard.set(order.map(\.rawValue), forKey: key) }
    func move(from: IndexSet, to: Int) { order.move(fromOffsets: from, toOffset: to) }
    func reset() { order = Self.defaultOrder }
}

/// Who's Working — the whole group's coverage.
/// Portrait: a vertical day-timeline (scroll up = earlier, down = later) with a date picker + Today.
/// Landscape: a week grid — units anchored down the left, days across the top, doctors in the cells.
struct WhoView: View {
    @EnvironmentObject var model: AppModel
    var tabTick: Int = 0                        // MainTabs bumps this when Who's On is tapped → re-center on today
    @State private var selectedISO: String = WhoView.todayISO()
    @State private var scrollTick = 0          // bump to force a re-center even if the date didn't change
    @State private var visibleMonth = ""       // landscape: the month currently scrolled into view (anchored in the title)
    @State private var landedOnToday = false   // have we centered on today once real (current) data is present?
    // Long-press MY OWN shift → same swap / give-away flow as My Shifts (SwapView). A plain tap does nothing,
    // so browsing Who's On can never trip a stray prompt; the menu only exists on my own upcoming shifts.
    @State private var swapInitial: MyShift?
    @State private var swapGiveAway = false
    @State private var swapSheet = false
    @State private var pastAlert = false
    @AppStorage("hb_who_doctors") private var doctors = false   // stethoscope toggle → doctors-on-call column
    @State private var topTracker = WhoTopTracker()
    @ObservedObject private var roster = DoctorRoster.shared

    /// The stethoscope makes every day in the list taller or shorter. On the full history (2022 →) the list kept
    /// its scroll offset rather than its day, and slid weeks or months back. So: note the day at the top first,
    /// then put that day back at the top the same way the Today button does — never trust the offset.
    private func toggleDoctors() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let top = topTracker.top
        #if DEBUG
        NSLog("%@", "WHOTOP toggle→\(!doctors) top=\(top ?? "nil") seen=\(topTracker.minY.sorted { $0.value < $1.value }.map { "\($0.key)@\(Int($0.value))" })")
        #endif
        doctors.toggle()
        topTracker.anchor = top; topTracker.anchorAt = Date()
        if let top { selectedISO = top; scrollTick += 1 }
    }

    static let unitOrder: [UnitKey] = [.SICU, .MICU, .CCU, .RR, .PHICU, .PRR, .MSU]  // canonical default (Stats)

    /// Long-pressed one of my own shift cells → look up the live MyShift (real slot_id) and open the shared
    /// swap/give-away screen. No-op in demo; falls back to an alert if the shift isn't actually giveable.
    private func mineAction(_ iso: String, _ unit: UnitKey, _ giveAway: Bool) {
        guard !model.demo else { return }
        guard let s = model.myShifts.first(where: {
            $0.date == iso && $0.unit == unit && $0.slotID != nil && $0.date >= Self.todayISO()
        }) else { pastAlert = true; return }
        swapInitial = s; swapGiveAway = giveAway; swapSheet = true
    }

    // Full history (2022 →), precomputed in the model so scrolling stays smooth.
    private var days: [String] { model.whoDays }
    private var byDay: [String: [Assignment]] { model.whoByDay }

    private var selectedDate: Binding<Date> {
        Binding(get: {
            // Clamp into the loaded range — the DatePicker's `in:` bound crashes if the selection sits outside it
            // (e.g. today is past the roster end, or history hasn't reached the current month yet).
            guard let f = days.first, let l = days.last else { return isoToDate(selectedISO) }
            return min(max(isoToDate(selectedISO), isoToDate(f)), isoToDate(l))
        }, set: { selectedISO = dateToISO($0) })
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                Group {
                    if days.isEmpty {
                        empty
                    } else if landscape {
                        WhoWeekGrid(days: days, byDay: byDay, todayISO: Self.todayISO(),
                                    scrollTo: selectedISO, scrollTick: scrollTick, availHeight: geo.size.height,
                                    visibleMonth: $visibleMonth, bottomInset: 68, onMine: mineAction,
                                    doctors: doctors)
                    } else {
                        VStack(spacing: 0) {
                            if doctors { UnitPhonesBar().transition(.move(edge: .top).combined(with: .opacity)) }
                            WhoDayTimeline(days: days, byDay: byDay, todayISO: Self.todayISO(),
                                           scrollTo: $selectedISO, scrollTick: scrollTick, onMine: mineAction,
                                           doctors: doctors, tracker: topTracker, demo: model.demo)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.bg.ignoresSafeArea())
            }
            .navigationTitle(visibleMonth.isEmpty ? "Who's On" : visibleMonth)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !days.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        DatePicker("", selection: selectedDate,
                                   in: isoToDate(days.first!)...isoToDate(days.last!),
                                   displayedComponents: .date)
                            .labelsHidden().tint(Theme.muted)          // subtle grey, not accent
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            toggleDoctors()
                        } label: {
                            Image(systemName: doctors ? "stethoscope.circle.fill" : "stethoscope")
                                .font(.body.weight(.medium))
                        }
                        .tint(doctors ? Theme.accent : Theme.muted)
                        .accessibilityLabel(doctors ? "Hide doctors on call" : "Show doctors on call")
                    }
                    if #available(iOS 26, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }   // own glass bubble
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Today") { selectedISO = Self.todayISO(); scrollTick += 1 }
                            .font(.footnote.weight(.medium)).tint(Theme.muted)
                            .disabled(!days.contains(Self.todayISO()))
                    }
                }
            }
            .overlay {
                if (model.loading || model.groupScanning) && model.whoDays.isEmpty {
                    ProgressView("Reading your roster…").tint(Theme.accent)
                }
            }
            .sheet(isPresented: $swapSheet) {
                NavigationStack {
                    SwapView(initialShift: swapInitial, initialGiveAway: swapGiveAway).environmentObject(model)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { swapSheet = false } } }
                }
            }
            .alert("Can't do that one", isPresented: $pastAlert) {
                Button("OK", role: .cancel) {}
            } message: { Text("You can only swap or give away your own upcoming shifts.") }
        }
        .onAppear { selectedISO = Self.todayISO(); scrollTick += 1; if days.contains(Self.todayISO()) { landedOnToday = true } }
        #if DEBUG
        .onAppear {                                              // screenshot hook: DEMO_DOCTORS=1 on / 0 off
            switch ProcessInfo.processInfo.environment["DEMO_DOCTORS"] {
            case "1": doctors = true
            case "0": doctors = false
            case "flips":                                        // toggle every 5 s, 8 times (jump check);
                if let path = ProcessInfo.processInfo.environment["DEMO_START_DAY"] {   // optionally browse other days first
                    for (i, d) in path.split(separator: ",").enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i) * 0.9) { selectedISO = String(d); scrollTick += 1 }
                    }
                }
                for k in 1...8 { DispatchQueue.main.asyncAfter(deadline: .now() + 8 + Double(k) * 5) { toggleDoctors() } }
            case "flip":                                         // on → off → on, to check the doctors come back
                doctors = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 14) { toggleDoctors() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 18) { toggleDoctors() }
            default: break
            }
        }
        #endif
        .onChange(of: tabTick) { _, _ in selectedISO = Self.todayISO(); scrollTick += 1 }   // tapping the tab → re-center on today
        // Stale data (token expired) can open the tab stuck in the past with today missing. When fresh data arrives
        // and today shows up in the range, snap to it once — no more "sign out/in" to unstick it.
        .onChange(of: days) { _, newDays in
            if !landedOnToday, newDays.contains(Self.todayISO()) {
                landedOnToday = true; selectedISO = Self.todayISO(); scrollTick += 1
            }
        }
        .task { await model.loadGroupHistory() }                       // load the whole group's history (2022 →), cached
        // Read the doctors' month up front, stethoscope on or off: turning it on is then instant, and no rows grow
        // a second later (after the list has been put back on its day) when a network read lands.
        .task { await DoctorRoster.shared.ensure(Self.todayISO(), demo: model.demo) }
        // Doctor rows that land just after a toggle (a month not read yet) resize the days again → put the day back
        // once more. Only right after a toggle, so it never pulls the list away while someone is browsing.
        .onChange(of: roster.loading) { _, busy in
            if !busy, let a = topTracker.anchor, Date().timeIntervalSince(topTracker.anchorAt) < 3 { selectedISO = a; scrollTick += 1 }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.slash").font(.system(size: 34)).foregroundStyle(Theme.muted)
            Text("No coverage loaded yet").foregroundStyle(Theme.muted)
        }
    }

    static func todayISO() -> String { AppModel.todayRegina() }
}

// MARK: - Portrait: day timeline

/// Where each on-screen day section starts, in the list's own coordinates. A plain reference box: it changes on
/// every scroll frame, so it must not be published (that would re-render the whole list while scrolling).
struct WhoDayTopKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) { value.merge(nextValue()) { $1 } }
}

final class WhoTopTracker {
    static let space = "whoTimeline"
    var minY: [String: CGFloat] = [:]
    var anchor: String?                         // the day a stethoscope toggle put back at the top, and when
    var anchorAt = Date.distantPast
    /// The day showing at the top of the list: the last section that starts at or above the top edge (a little
    /// slack for the header), else the first one below it.
    var top: String? {
        let above = minY.filter { $0.value <= 24 }
        if let d = above.max(by: { $0.value < $1.value })?.key { return d }
        return minY.min(by: { $0.value < $1.value })?.key
    }
}

struct WhoDayTimeline: View {
    let days: [String]
    let byDay: [String: [Assignment]]
    let todayISO: String
    @Binding var scrollTo: String
    let scrollTick: Int
    var onMine: (String, UnitKey, Bool) -> Void = { _, _, _ in }
    var doctors = false                                                  // stethoscope toggle → intensivist / cardiology column
    var tracker: WhoTopTracker? = nil                                    // where each on-screen day sits (stethoscope re-anchor)
    var demo = false                                                     // passed in, not the whole model: every model change re-drew the list
    @ObservedObject private var unitStore = UnitOrderStore.shared
    @ObservedObject private var roster = DoctorRoster.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(days, id: \.self) { day in
                        daySection(day).id(day)
                    }
                }
                .padding(14)
                // Rebuilt from the sections that are actually laid out on every pass, so a day that scrolled away
                // can't linger (per-row appear/disappear bookkeeping did: Mar 1 still "at the top" on Mar 14).
                .onPreferenceChange(WhoDayTopKey.self) { tracker?.minY = $0 }
            }
            .coordinateSpace(.named(WhoTopTracker.space))
            .onAppear { recenter(proxy) }
            .onChange(of: scrollTo) { _, _ in recenter(proxy) }
            .onChange(of: scrollTick) { _, _ in recenter(proxy) }
        }
    }

    // Defer the scroll so the lazy list is laid out first — otherwise it lands at the top (late June) instead of today.
    private func recenter(_ proxy: ScrollViewProxy) {
        // Two passes: a quick hop materializes the lazy rows around the target day, then an animated hop
        // centers it precisely. A single deferred scroll only landed centered ~2-in-3 tries (the lazy row
        // wasn't laid out yet when the first scroll fired).
        // Anchored to the TOP: a day section is about a screen tall (taller with the doctors on), so centring it
        // left today's header at the bottom edge.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { proxy.scrollTo(scrollTo, anchor: .top) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(scrollTo, anchor: .top) }
        }
    }

    @ViewBuilder private func daySection(_ day: String) -> some View {
        let isToday = day == todayISO
        let rows = (byDay[day] ?? []).sorted {
            order($0.unit) == order($1.unit) ? $0.start < $1.start : order($0.unit) < order($1.unit)
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(weekday(day)).font(.subheadline.weight(.heavy)).foregroundStyle(isToday ? Theme.accent : Theme.ink.opacity(0.7))
                Text(longDate(day)).font(.subheadline).foregroundStyle(Theme.muted)
                if isToday {
                    Text("TODAY").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent).clipShape(Capsule())
                }
                Spacer()
            }
            if rows.isEmpty {
                Text("No one scheduled").font(.caption).foregroundStyle(Theme.muted).padding(.leading, 2)
            } else {
                let firsts = Self.firstPerUnit(rows)
                let nightName = doctors ? roster.night(day)?.name : nil         // once per day, not once per unit
                ForEach(rows) { a in
                    let doc = doctors && firsts.contains(a.id) ? docTag(day, a.unit, nightName) : nil
                    if a.isMe && AppModel.notStarted(day, a.start) {                    // my own upcoming shift → long-press to act
                        personRow(a, isToday: isToday, doc: doc).contextMenu {
                            Button { onMine(day, a.unit, false) } label: { Label("Find a swap", systemImage: "arrow.triangle.2.circlepath") }
                            Button { onMine(day, a.unit, true)  } label: { Label("Give it away", systemImage: "arrow.up.forward") }
                        }
                    } else {
                        personRow(a, isToday: isToday, doc: doc)
                    }
                }
            }
            if doctors { OnCallStrip(day: day, isToday: isToday) }
        }
        .padding(.bottom, 2)
        .background(GeometryReader { g in
            Color.clear.preference(key: WhoDayTopKey.self, value: [day: g.frame(in: .named(WhoTopTracker.space)).minY])
        })
        .task(id: doctors ? day : "") { if doctors { await roster.ensure(day, demo: demo) } }
    }

    /// The doctor goes beside the first CCA row of each unit only — later rows of the same unit leave it blank.
    private static func firstPerUnit(_ rows: [Assignment]) -> Set<Assignment.ID> {
        var seen = Set<UnitKey>(), ids = Set<Assignment.ID>()
        for a in rows where seen.insert(a.unit).inserted { ids.insert(a.id) }
        return ids
    }

    private func docTag(_ day: String, _ unit: UnitKey, _ nightName: String?) -> DocTag? {
        if unit == .CCU { return roster.inCCU(day).map { DocTag(name: $0, sub: "in CCU", night: false) } }
        guard let phone = DocTag.phones[unit], let n = roster.name(day, unit.rawValue, "day") else { return nil }
        return DocTag(name: n, sub: phone, night: nightName == n)
    }

    // Same tier principle as the landscape grid: you = white on the SOLID unit colour (stands out most),
    // today = bright white on a stronger fill, surrounding days = unit colour on a faint/translucent fill.
    private func personRow(_ a: Assignment, isToday: Bool, doc: DocTag? = nil) -> some View {
        let info = Units.info[a.unit] ?? UnitInfo(short: a.unit.rawValue, full: "", color: .gray)
        let fillOp: Double = a.isMe ? 1.0 : (isToday ? 0.26 : 0.07)         // surrounding days more faded
        let nameColor: Color = a.isMe ? .white : (isToday ? Theme.ink : Theme.ink.opacity(0.72))
        let unitColor: Color = a.isMe ? .white.opacity(0.92) : info.color.opacity(isToday ? 1 : 0.68)
        return HStack(spacing: 10) {
            Text(info.short).font(.caption.bold()).foregroundStyle(unitColor)
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(width: doctors ? 84 : 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.doc).font(.subheadline.weight(a.isMe || isToday ? .bold : .semibold)).foregroundStyle(nameColor)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text("\(a.start)–\(a.end)").font(.caption2)
                    .foregroundStyle(a.isMe ? .white.opacity(0.75) : Theme.ink.opacity(0.55))
            }
            Spacer(minLength: 4)
            if a.isMe {
                Text("you").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(.white.opacity(0.22)).clipShape(Capsule())
            }
            if let doc {
                Rectangle().fill(a.isMe ? .white.opacity(0.35) : info.color.opacity(0.3)).frame(width: 1, height: 28)
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 3) {
                        if doc.night { Image(systemName: "moon.fill").font(.system(size: 9)).foregroundStyle(a.isMe ? .white : .indigo) }
                        Text(doc.name).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(nameColor)
                    HStack(spacing: 3) {
                        if doc.sub != "in CCU" { Image(systemName: "phone.fill").font(.system(size: 8)) }
                        Text(doc.sub).font(.caption2.monospacedDigit())
                    }
                    .foregroundStyle(a.isMe ? .white.opacity(0.75) : Theme.ink.opacity(0.55))
                }
                .frame(width: 78, alignment: .trailing)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 11).fill(info.color.opacity(fillOp)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(info.color.opacity(a.isMe ? 0 : (isToday ? 0.4 : 0.14)), lineWidth: 1))
    }

    private func order(_ u: UnitKey) -> Int { unitStore.order.firstIndex(of: u) ?? 99 }
}

// MARK: - Landscape: week grid (units left, days across the top)

struct WhoWeekGrid: View {
    let days: [String]
    let byDay: [String: [Assignment]]
    let todayISO: String
    let scrollTo: String
    let scrollTick: Int
    let availHeight: CGFloat
    @Binding var visibleMonth: String
    @ObservedObject private var unitStore = UnitOrderStore.shared

    private let unitColW: CGFloat = 92
    private let colW: CGFloat = 134
    private let headerH: CGFloat = 34              // compact day header, higher up
    var bottomInset: CGFloat = 84                  // space reserved for the floating tab bar (per-view: Crew keeps 84)
    var onMine: (String, UnitKey, Bool) -> Void = { _, _, _ in }   // long-press my own upcoming cell → swap/give-away
    var doctors = false                                            // stethoscope toggle → doctor line per ICU + a Night row
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var roster = DoctorRoster.shared

    private var rowCount: Int { unitStore.order.count + (doctors ? 1 : 0) }
    // Fit all units on screen: divide the leftover height across the rows (no vertical scroll).
    private var rowH: CGFloat {
        max(28, (availHeight - headerH - bottomInset) / CGFloat(rowCount))
    }
    private var gridH: CGFloat { headerH + rowH * CGFloat(rowCount) }

    var body: some View {
        HStack(spacing: 0) {
            // Fixed unit column on the left.
            VStack(spacing: 0) {
                Color.clear.frame(width: unitColW, height: headerH)
                ForEach(unitStore.order, id: \.self) { u in
                    let info = Units.info[u] ?? UnitInfo(short: u.rawValue, full: "", color: .gray)
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(info.color).frame(width: 5, height: 26)
                        Text(info.short).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.ink)
                            .lineLimit(2).minimumScaleFactor(0.65)
                        Spacer(minLength: 0)
                    }
                    .frame(width: unitColW, height: rowH).padding(.leading, 7)
                }
                if doctors {
                    HStack(spacing: 5) {
                        Image(systemName: "moon.stars.fill").font(.system(size: 12)).foregroundStyle(.indigo).frame(width: 5)
                        Text("On call\ntonight").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.ink)
                            .lineLimit(2).minimumScaleFactor(0.65)
                        Spacer(minLength: 0)
                    }
                    .frame(width: unitColW, height: rowH).padding(.leading, 7)
                }
            }
            .frame(height: gridH)
            .background(Theme.panel)
            .overlay(Rectangle().fill(Theme.line).frame(width: 1), alignment: .trailing)

            // Day columns — scroll horizontally, active day centered.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(spacing: 0) {
                        ForEach(days, id: \.self) { day in dayColumn(day).id(day) }
                    }
                }
                .coordinateSpace(name: "whoHScroll")
                .onPreferenceChange(DayFrameKey.self) { frames in
                    // the visible column nearest the left edge (x≈0) drives the anchored month
                    if let leading = frames.min(by: { abs($0.value) < abs($1.value) }) {
                        let m = monthLabel(leading.key)
                        if m != visibleMonth { visibleMonth = m }
                    }
                }
                .onAppear { recenter(proxy) }
                .onChange(of: scrollTo) { _, _ in recenter(proxy) }
                .onChange(of: scrollTick) { _, _ in recenter(proxy) }
            }
        }
        .frame(height: gridH, alignment: .top)
        .padding(.top, 4)
        .onDisappear { visibleMonth = "" }        // back to portrait → restore the normal title
    }

    private func monthLabel(_ iso: String) -> String { fmt(iso, "MMMM yyyy") }

    // Defer so the lazy day columns exist before we jump to today.
    private func recenter(_ proxy: ScrollViewProxy) {
        // Two passes: a quick hop materializes the lazy rows around the target day, then an animated hop
        // centers it precisely. A single deferred scroll only landed centered ~2-in-3 tries (the lazy row
        // wasn't laid out yet when the first scroll fired).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { proxy.scrollTo(scrollTo, anchor: .center) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(scrollTo, anchor: .center) }
        }
    }

    @ViewBuilder private func dayColumn(_ day: String) -> some View {
        let isToday = day == todayISO
        let byUnit = Dictionary(grouping: byDay[day] ?? []) { $0.unit }
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Text(weekday(day)).font(.system(size: 10.5, weight: .semibold))
                Text(dayNum(day)).font(.system(size: 17, weight: .heavy))
            }
            .foregroundStyle(isToday ? .white : Theme.ink.opacity(0.7))
            .frame(width: colW, height: headerH - 4)
            .background(isToday ? Theme.accent : Theme.panel.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.bottom, 4)

            ForEach(unitStore.order, id: \.self) { u in
                VStack(spacing: 0) {
                    cell(byUnit[u] ?? [], unit: u, day: day, isToday: isToday)
                    if doctors, let d = docLine(day, u) {
                        HStack(spacing: 3) {
                            Image(systemName: d.night ? "moon.fill" : "stethoscope").font(.system(size: 8))
                                .foregroundStyle(d.night ? .indigo : Theme.muted)
                            Text(d.name).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(isToday ? Theme.ink : Theme.ink.opacity(0.65))
                        .frame(height: 13).padding(.bottom, 2)
                    }
                }
                .frame(width: colW, height: rowH)
                .clipped()
                .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
            }
            if doctors {
                nightCell(day, isToday: isToday).frame(width: colW, height: rowH).clipped()
            }
        }
        .frame(width: colW, height: gridH, alignment: .top)
        .background(isToday ? Theme.accent.opacity(0.14) : .clear)      // active day column stands out (brighter)
        .background(GeometryReader { g in                               // report position → anchored month
            Color.clear.preference(key: DayFrameKey.self, value: [day: g.frame(in: .named("whoHScroll")).minX])
        })
        .overlay(Rectangle().fill(Theme.line).frame(width: 1), alignment: .trailing)
        .task(id: doctors ? day : "") { if doctors { await roster.ensure(day, demo: model.demo) } }
    }

    private func docLine(_ day: String, _ unit: UnitKey) -> DocTag? {
        if unit == .CCU { return roster.inCCU(day).map { DocTag(name: $0, sub: "in CCU", night: false) } }
        guard DocTag.phones[unit] != nil, let n = roster.name(day, unit.rawValue, "day") else { return nil }
        return DocTag(name: n, sub: "", night: roster.night(day)?.name == n)
    }

    /// Bottom row with the toggle on: tonight's intensivist (all ICUs) over tonight's cardiologist on call.
    private func nightCell(_ day: String, isToday: Bool) -> some View {
        let ccu = Units.info[.CCU]?.color ?? .red
        return VStack(spacing: 2) {
            if let n = roster.night(day) {
                HStack(spacing: 3) {
                    Image(systemName: "moon.fill").font(.system(size: 9)).foregroundStyle(.indigo)
                    Text(n.name).font(.system(size: 12, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            if let c = roster.name(day, "CCU", "oncall") {
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill").font(.system(size: 8)).foregroundStyle(ccu)
                    Text(c).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .foregroundStyle(isToday ? Theme.ink : Theme.ink.opacity(0.7))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.indigo.opacity(isToday ? 0.14 : 0.05))
    }

    private func cell(_ people: [Assignment], unit: UnitKey, day: String, isToday: Bool) -> some View {
        let info = Units.info[unit] ?? UnitInfo(short: unit.rawValue, full: "", color: .gray)
        // Collapse a doctor's day/night segments to one name (kills "Du Toit / Du Toit" and the shrinking).
        var seen = Set<String>(); var names: [(name: String, isMe: Bool)] = []
        for a in people.sorted(by: { $0.start < $1.start }) {
            let nm = surname(a.doc)
            if seen.insert(nm).inserted { names.append((nm, a.isMe)) }
        }
        let mineActionable = day >= todayISO
        return Group {
            if names.isEmpty {
                Color.clear
            } else {
                // Names SHARE the row height equally (maxHeight: .infinity) and scale to fit, so a cell with
                // two or three doctors never spills into the row below — the whole grid stays on its lines.
                VStack(spacing: 2) {
                    ForEach(names.indices, id: \.self) { i in
                        let p = names[i]
                        // Tiers: you (white on full colour) > today (white, bright) > other days (colour on faint fill).
                        let chip = Text(p.name)
                            .font(.system(size: isToday ? 14.5 : 13, weight: p.isMe ? .heavy : (isToday ? .bold : .semibold)))
                            .foregroundStyle(p.isMe ? .white : (isToday ? .white : info.color))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(p.isMe ? info.color : info.color.opacity(isToday ? 0.46 : 0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        if p.isMe && mineActionable {                     // long-press my own upcoming cell → act
                            chip.contextMenu {
                                Button { onMine(day, unit, false) } label: { Label("Find a swap", systemImage: "arrow.triangle.2.circlepath") }
                                Button { onMine(day, unit, true)  } label: { Label("Give it away", systemImage: "arrow.up.forward") }
                            }
                        } else {
                            chip
                        }
                    }
                }
                .padding(.horizontal, 4).padding(.vertical, 3)
            }
        }
    }

    private func surname(_ name: String) -> String {
        let parts = name.split(separator: " ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " ") : name   // drop first name
    }
}

// MARK: - Shared date helpers (dates are plain calendar strings; used by Who's On + Compare)

let isoFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f
}()
// Anchor at noon in the DEVICE's calendar so the date picker shows the same calendar day (parsing as UTC
// midnight and displaying locally shifted it a day earlier).
func isoToDate(_ s: String) -> Date {
    let p = s.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3 else { return Date() }
    var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = 12
    return Calendar.current.date(from: c) ?? Date()
}
/// "yyyy-MM-dd" → the next calendar day by plain arithmetic (no formatter, no device calendar) — cheap and safe
/// off the main actor; used to walk the Who's On day list.
func nextISODay(_ iso: String) -> String {
    let p = iso.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3, (1...12).contains(p[1]) else { return iso }
    var y = p[0], m = p[1], d = p[2] + 1
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    let dim = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if d > dim[m - 1] { d = 1; m += 1; if m > 12 { m = 1; y += 1 } }
    return String(format: "%04d-%02d-%02d", y, m, d)
}
/// Day of week for "yyyy-MM-dd" (0 = Sunday … 6 = Saturday) by arithmetic (Sakamoto) — no formatter, so it's
/// cheap inside per-day loops (stats, calendars). nil for a malformed date.
func isoWeekday0(_ iso: String) -> Int? {
    let p = iso.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3, (1...12).contains(p[1]) else { return nil }
    let t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
    let y = p[1] < 3 ? p[0] - 1 : p[0]
    return (y + y / 4 - y / 100 + y / 400 + t[p[1] - 1] + p[2]) % 7
}
func dateToISO(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
}

private var fmtCache: [String: DateFormatter] = [:]      // reuse formatters by pattern (main-thread UI use)
func fmt(_ iso: String, _ pattern: String) -> String {
    guard let d = isoFmt.date(from: iso) else { return "" }
    let f: DateFormatter
    if let cached = fmtCache[pattern] { f = cached }
    else {
        let x = DateFormatter(); x.timeZone = TimeZone(identifier: "UTC"); x.locale = Locale(identifier: "en_US_POSIX"); x.dateFormat = pattern
        fmtCache[pattern] = x; f = x
    }
    return f.string(from: d)
}
func weekday(_ iso: String) -> String { fmt(iso, "EEE") }
func dayNum(_ iso: String) -> String { fmt(iso, "d") }
func longDate(_ iso: String) -> String { fmt(iso, "MMM d") }
func monthLabelFull(_ iso: String) -> String { fmt(iso, "MMMM yyyy") }

/// Each day column's left-edge x within the scroll — used to anchor the current month (leading column) in the title.
struct DayFrameKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Floating day panel (My Shifts → double-tap a date)

/// A small draggable card over My Shifts showing who's working one day — sized to its content so the calendar
/// stays visible underneath. Drag the header to move it; tapping another date (while open) retargets it.
struct WhoDayPanel: View {
    @EnvironmentObject var model: AppModel
    let iso: String
    let bounds: CGSize                          // the calendar's area — the panel is clamped inside it
    @Binding var offset: CGSize                 // committed position (offset from bottom-centre)
    var onClose: () -> Void
    @GestureState private var drag: CGSize = .zero
    @State private var size: CGSize = .zero
    @State private var listH: CGFloat = 0
    @State private var tonightH: CGFloat = 0                       // the Tonight line under the rows, measured
    @ObservedObject private var unitStore = UnitOrderStore.shared
    @ObservedObject private var roster = DoctorRoster.shared
    @AppStorage("hb_panel_doctors") private var doctors = false   // stethoscope on the panel (remembered, separate from Who's On)

    private var landscape: Bool { bounds.width > bounds.height }
    // Doctors on → full width (capped sideways), and the whole card stays within about a third of the screen
    // so the calendar still scrolls under it; past that the rows scroll inside the card.
    private var width: CGFloat {
        doctors ? min(bounds.width - 16, 560) : min(landscape ? 340 : 300, bounds.width - 24)
    }
    private var maxRowsH: CGFloat {
        doctors ? max(90, bounds.height * (landscape ? 0.6 : 0.48) - 52 - (hasTonight ? tonightH : 0))
                : max(120, bounds.height * 0.55 - 64)   // ~55% of the screen incl. header
    }
    private var isToday: Bool { iso == AppModel.todayRegina() }
    private var rows: [Assignment] {
        (model.whoByDay[iso] ?? []).sorted {
            order($0.unit) == order($1.unit) ? $0.start < $1.start : order($0.unit) < order($1.unit)
        }
    }
    private func order(_ u: UnitKey) -> Int { unitStore.order.firstIndex(of: u) ?? 99 }

    // Keep the card inside the calendar area: x within the side margins, y between the bottom and the top.
    private func clamp(_ o: CGSize) -> CGSize {
        let maxX = max(0, (bounds.width - size.width) / 2 - 8)
        let maxUp = max(0, bounds.height - size.height - 24)
        return CGSize(width: min(max(o.width, -maxX), maxX), height: min(max(o.height, -maxUp), 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 6)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
        .offset(clamp(CGSize(width: offset.width + drag.width, height: offset.height + drag.height)))
        .padding(.bottom, 12)
        .transition(.scale(scale: 0.92).combined(with: .opacity))
        .task(id: model.whoByDay.isEmpty) { if model.whoByDay.isEmpty { await model.loadGroupHistory() } }
        .task(id: doctors ? iso : "") { if doctors { await roster.ensure(iso, demo: model.demo) } }
    }

    // Grab bar + date + close. The whole header is the drag handle.
    private var header: some View {
        VStack(spacing: 6) {
            Capsule().fill(Theme.muted.opacity(0.35)).frame(width: 34, height: 4)
            HStack(spacing: 8) {
                Text(weekday(iso)).font(.subheadline.weight(.heavy)).foregroundStyle(isToday ? Theme.accent : Theme.ink)
                Text(fmt(iso, "d MMM")).font(.subheadline).foregroundStyle(Theme.muted)
                if isToday {
                    Text("TODAY").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent).clipShape(Capsule())
                }
                Spacer()
                Button { withAnimation(.snappy(duration: 0.2)) { doctors.toggle() } } label: {
                    Image(systemName: doctors ? "stethoscope.circle.fill" : "stethoscope").font(.title3)
                        .foregroundStyle(doctors ? Theme.accent : Theme.muted)
                }
                .buttonStyle(.plain).accessibilityLabel(doctors ? "Hide doctors" : "Show doctors")
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain).accessibilityLabel("Close")
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(coordinateSpace: .global)
            .updating($drag) { v, s, _ in s = v.translation }
            .onEnded { v in
                offset = clamp(CGSize(width: offset.width + v.translation.width, height: offset.height + v.translation.height))
            })
    }

    @ViewBuilder private var content: some View {
        if model.whoByDay.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading who's on…") }
                .font(.caption).foregroundStyle(Theme.muted)
        } else if rows.isEmpty {
            Text("No one scheduled").font(.caption).foregroundStyle(Theme.muted)
        } else {
            // The card hugs its rows; past the cap the same rows scroll inside it.
            ScrollView {
                list.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { listH = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(listH > 0 ? listH : CGFloat(rows.count) * 34, maxRowsH))
            if doctors && hasTonight {
                tonightLine.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { tonightH = $0 + 8 }
            }
        }
    }

    private var list: some View {
        // Doctor beside each unit's first row; when the roster has nobody for this day, the plain rows (no empty column).
        let docs = Dictionary(grouping: rows, by: \.unit).reduce(into: [Assignment.ID: DocTag]()) { m, g in
            if let first = g.value.first, let d = docTag(g.key) { m[first.id] = d }
        }
        return VStack(spacing: doctors ? 4 : 5) {
            ForEach(rows) { a in
                if doctors && !docs.isEmpty { docRow(a, doc: docs[a.id]) } else { row(a) }
            }
        }
    }

    // MARK: Doctors (stethoscope on)

    /// The unit's doctor today: the ICU intensivist (+ their on-call number; 🌙 if also on call tonight), or who's in CCU.
    private func docTag(_ unit: UnitKey) -> DocTag? {
        if unit == .CCU { return roster.inCCU(iso).map { DocTag(name: $0, sub: "in CCU", night: false) } }
        guard let phone = DocTag.phones[unit], let n = roster.name(iso, unit.rawValue, "day") else { return nil }
        return DocTag(name: n, sub: phone, night: roster.night(iso)?.name == n)
    }

    /// "08:00" → "08"; anything not on the hour stays as is.
    private func hr(_ t: String) -> String { t.hasSuffix(":00") ? String(t.prefix(2)) : t }

    /// One line per CCA, the unit's doctor in a right-hand column on its first row — same height as without.
    private func docRow(_ a: Assignment, doc: DocTag?) -> some View {
        let info = Units.info[a.unit] ?? UnitInfo(short: a.unit.rawValue, full: "", color: .gray)
        let sub: Color = a.isMe ? .white.opacity(0.8) : Theme.muted
        return HStack(spacing: 7) {
            Text(info.short).font(.caption2.bold()).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(a.isMe ? .white.opacity(0.92) : info.color)
                .frame(width: 70, alignment: .leading)
            Text(a.doc).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.65)
                .foregroundStyle(a.isMe ? .white : Theme.ink)
            Spacer(minLength: 2)
            Text("\(hr(a.start))–\(hr(a.end))").font(.caption2.monospacedDigit()).fixedSize().foregroundStyle(sub)
            Rectangle().fill(doc == nil ? .clear : (a.isMe ? .white.opacity(0.35) : info.color.opacity(0.35))).frame(width: 1, height: 16)
            HStack(spacing: 3) {
                if let doc {
                    if doc.sub == "in CCU" { Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(a.isMe ? .white : info.color) }
                    if doc.night { Image(systemName: "moon.fill").font(.system(size: 9)).foregroundStyle(a.isMe ? .white : .indigo) }
                    Text(doc.name).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(a.isMe ? .white : Theme.ink)
                    if doc.sub != "in CCU" { Text(doc.sub).font(.caption2.monospacedDigit()).foregroundStyle(sub) }
                }
            }
            .frame(width: 116, alignment: .leading)
        }
        .padding(.vertical, 6).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(info.color.opacity(a.isMe ? 1 : 0.12)))
    }

    /// Tonight, from 17:00: the one ICU intensivist on call for all the units · cardiology On call · STEMI.
    private var tonight: [(label: String?, name: String)] {
        var parts: [(label: String?, name: String)] = []
        if let n = roster.night(iso)?.name { parts.append((nil, n)) }
        if let n = roster.name(iso, "CCU", "oncall") { parts.append(("On call", n)) }
        if let n = roster.name(iso, "CCU", "stemi_oncall") { parts.append(("STEMI", n)) }
        return parts
    }
    private var hasTonight: Bool { !tonight.isEmpty }

    private var tonightLine: some View {
        let ccu = Units.info[.CCU]?.color ?? .red
        return HStack(spacing: 5) {
            Image(systemName: "moon.stars.fill").font(.system(size: 11)).foregroundStyle(.indigo)
            ForEach(Array(tonight.enumerated()), id: \.offset) { i, p in
                if i > 0 { Text("·").font(.caption.bold()).foregroundStyle(Theme.muted) }
                if p.label == "On call" { Image(systemName: "heart.fill").font(.system(size: 9)).foregroundStyle(ccu) }   // cardiology
                if let l = p.label { Text(l).font(.caption2.bold()).foregroundStyle(ccu) }
                Text(p.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .lineLimit(1).minimumScaleFactor(0.75)
        .padding(.vertical, 6).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.indigo.opacity(0.07)))
    }

    // Compact version of the Who's On row: unit, name, hours; my own shift on the solid unit colour.
    private func row(_ a: Assignment) -> some View {
        let info = Units.info[a.unit] ?? UnitInfo(short: a.unit.rawValue, full: "", color: .gray)
        return HStack(spacing: 8) {
            Text(info.short).font(.caption2.bold()).lineLimit(1).minimumScaleFactor(0.7)
                .foregroundStyle(a.isMe ? .white.opacity(0.92) : info.color)
                .frame(width: 78, alignment: .leading)
            Text(a.doc).font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.65)
                .foregroundStyle(a.isMe ? .white : Theme.ink)
            Spacer(minLength: 4)
            Text("\(a.start)–\(a.end)").font(.caption2.monospacedDigit()).fixedSize()
                .foregroundStyle(a.isMe ? .white.opacity(0.8) : Theme.muted)
        }
        .padding(.vertical, 6).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(info.color.opacity(a.isMe ? 1 : 0.12)))
    }
}
