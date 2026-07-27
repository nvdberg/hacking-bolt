import SwiftUI

/// Who's Working — the whole group's coverage.
/// Portrait: a vertical day-timeline (scroll up = earlier, down = later) with a date picker + Today.
/// Landscape: a week grid — units anchored down the left, days across the top, doctors in the cells.
struct WhoView: View {
    @EnvironmentObject var model: AppModel
    var tabTick: Int = 0                        // MainTabs bumps this when Who's On is tapped → re-center on today
    @State private var selectedISO: String = WhoView.todayISO()
    @State private var scrollTick = 0          // bump to force a re-center even if the date didn't change
    @State private var visibleMonth = ""       // landscape: the month currently scrolled into view (anchored in the title)

    static let unitOrder: [UnitKey] = [.SICU, .MICU, .CCU, .RR, .PHICU, .PRR, .MSU]

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
                                    visibleMonth: $visibleMonth, bottomInset: 68)
                    } else {
                        WhoDayTimeline(days: days, byDay: byDay, todayISO: Self.todayISO(),
                                       scrollTo: $selectedISO, scrollTick: scrollTick)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.bg.ignoresSafeArea())
            }
            .navigationTitle(visibleMonth.isEmpty ? "Who's Working" : visibleMonth)
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
                        Button("Today") { selectedISO = Self.todayISO(); scrollTick += 1 }
                            .font(.footnote.weight(.medium)).tint(Theme.muted)
                            .disabled(!days.contains(Self.todayISO()))
                    }
                }
            }
            .overlay {
                if model.loading && model.assignments.isEmpty {
                    ProgressView("Reading your roster…").tint(Theme.accent)
                }
            }
        }
        .onAppear { selectedISO = Self.todayISO(); scrollTick += 1 }   // entering the tab → snap to today, centered
        .onChange(of: tabTick) { _, _ in selectedISO = Self.todayISO(); scrollTick += 1 }   // tapping the tab → re-center on today
        .task { await model.loadGroupHistory() }                       // load the whole group's history (2022 →), cached
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

struct WhoDayTimeline: View {
    let days: [String]
    let byDay: [String: [Assignment]]
    let todayISO: String
    @Binding var scrollTo: String
    let scrollTick: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(days, id: \.self) { day in
                        daySection(day).id(day)
                    }
                }
                .padding(14)
            }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { proxy.scrollTo(scrollTo, anchor: .center) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(scrollTo, anchor: .center) }
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
                ForEach(rows) { a in personRow(a, isToday: isToday) }
            }
        }
        .padding(.bottom, 2)
    }

    // Same tier principle as the landscape grid: you = white on the SOLID unit colour (stands out most),
    // today = bright white on a stronger fill, surrounding days = unit colour on a faint/translucent fill.
    private func personRow(_ a: Assignment, isToday: Bool) -> some View {
        let info = Units.info[a.unit] ?? UnitInfo(short: a.unit.rawValue, full: "", color: .gray)
        let fillOp: Double = a.isMe ? 1.0 : (isToday ? 0.26 : 0.07)         // surrounding days more faded
        let nameColor: Color = a.isMe ? .white : (isToday ? Theme.ink : Theme.ink.opacity(0.72))
        let unitColor: Color = a.isMe ? .white.opacity(0.92) : info.color.opacity(isToday ? 1 : 0.68)
        return HStack(spacing: 10) {
            Text(info.short).font(.caption.bold()).foregroundStyle(unitColor)
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.doc).font(.subheadline.weight(a.isMe || isToday ? .bold : .semibold)).foregroundStyle(nameColor)
                Text("\(a.start)–\(a.end)").font(.caption2)
                    .foregroundStyle(a.isMe ? .white.opacity(0.75) : Theme.ink.opacity(0.55))
            }
            Spacer()
            if a.isMe {
                Text("you").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(.white.opacity(0.22)).clipShape(Capsule())
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 11).fill(info.color.opacity(fillOp)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(info.color.opacity(a.isMe ? 0 : (isToday ? 0.4 : 0.14)), lineWidth: 1))
    }

    private func order(_ u: UnitKey) -> Int { WhoView.unitOrder.firstIndex(of: u) ?? 99 }
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

    private let unitColW: CGFloat = 92
    private let colW: CGFloat = 134
    private let headerH: CGFloat = 34              // compact day header, higher up
    var bottomInset: CGFloat = 84                  // space reserved for the floating tab bar (per-view: Crew keeps 84)

    // Fit all units on screen: divide the leftover height across the rows (no vertical scroll).
    private var rowH: CGFloat {
        max(28, (availHeight - headerH - bottomInset) / CGFloat(WhoView.unitOrder.count))
    }
    private var gridH: CGFloat { headerH + rowH * CGFloat(WhoView.unitOrder.count) }

    var body: some View {
        HStack(spacing: 0) {
            // Fixed unit column on the left.
            VStack(spacing: 0) {
                Color.clear.frame(width: unitColW, height: headerH)
                ForEach(WhoView.unitOrder, id: \.self) { u in
                    let info = Units.info[u] ?? UnitInfo(short: u.rawValue, full: "", color: .gray)
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(info.color).frame(width: 5, height: 26)
                        Text(info.short).font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.ink)
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

            ForEach(WhoView.unitOrder, id: \.self) { u in
                cell(byUnit[u] ?? [], unit: u, isToday: isToday)
                    .frame(width: colW, height: rowH)
                    .clipped()
                    .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
            }
        }
        .frame(width: colW, height: gridH, alignment: .top)
        .background(isToday ? Theme.accent.opacity(0.14) : .clear)      // active day column stands out (brighter)
        .background(GeometryReader { g in                               // report position → anchored month
            Color.clear.preference(key: DayFrameKey.self, value: [day: g.frame(in: .named("whoHScroll")).minX])
        })
        .overlay(Rectangle().fill(Theme.line).frame(width: 1), alignment: .trailing)
    }

    private func cell(_ people: [Assignment], unit: UnitKey, isToday: Bool) -> some View {
        let info = Units.info[unit] ?? UnitInfo(short: unit.rawValue, full: "", color: .gray)
        // Collapse a doctor's day/night segments to one name (kills "Du Toit / Du Toit" and the shrinking).
        var seen = Set<String>(); var names: [(name: String, isMe: Bool)] = []
        for a in people.sorted(by: { $0.start < $1.start }) {
            let nm = surname(a.doc)
            if seen.insert(nm).inserted { names.append((nm, a.isMe)) }
        }
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
                        Text(p.name)
                            .font(.system(size: isToday ? 14.5 : 13, weight: p.isMe ? .heavy : (isToday ? .bold : .semibold)))
                            .foregroundStyle(p.isMe ? .white : (isToday ? .white : info.color))
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(p.isMe ? info.color : info.color.opacity(isToday ? 0.46 : 0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
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
