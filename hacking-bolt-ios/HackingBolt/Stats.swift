import SwiftUI
import UIKit
import CoreGraphics

// MARK: - Stats computation

/// A tally of the logged-in person's shifts over a date range: totals, per-month averages, and the
/// breakdown by shift length (24h / 12h / 9h / …) and by unit (CCU / SICU / …). Computed from the
/// durable shift log (AppModel.shiftLog), which keeps past shifts on file permanently.
struct ShiftStats {
    let count: Int
    let totalHours: Double
    let months: Double
    let byLength: [LenBucket]     // sorted longest → shortest
    let byUnit: [UnitBucket]      // sorted most → least
    let nights: Int               // overnight shifts
    let weekends: Int             // shifts starting on Sat/Sun

    var avgShiftsPerMonth: Double { months > 0 ? Double(count) / months : 0 }
    var avgHoursPerMonth: Double  { months > 0 ? totalHours / months : 0 }

    struct LenBucket: Identifiable { let hours: Int; let count: Int; let totalHours: Double; var id: Int { hours }; var label: String { "\(hours)h" } }
    struct UnitBucket: Identifiable { let name: String; let color: Color; let count: Int; let hours: Double; var id: String { name } }

    static func hours(of s: MyShift) -> Double {
        let iv = ConflictEngine.interval(s.date, s.start, s.end, overnight: s.overnight)
        return Double(iv.e - iv.s) / 60
    }

    static func compute(_ shifts: [MyShift], from: String, to: String) -> ShiftStats {
        let inRange = shifts.filter { $0.date >= from && $0.date <= to }
        var total = 0.0, nights = 0, weekends = 0, count = 0
        var lenMap: [Int: (count: Int, h: Double)] = [:]
        var unitMap: [String: (name: String, color: Color, count: Int, h: Double)] = [:]
        func addLen(_ hr: Int, _ h: Double) { var v = lenMap[hr] ?? (0, 0.0); v.count += 1; v.h += h; lenMap[hr] = v }
        func addUnit(_ key: String, _ name: String, _ color: Color, _ h: Double) {
            var v = unitMap[key] ?? (name, color, 0, 0.0); v.count += 1; v.h += h; unitMap[key] = v
        }
        func addRealUnit(_ u: UnitKey, _ h: Double) {
            let info = Units.info[u]
            addUnit(u.rawValue, info?.short ?? u.rawValue, info?.color ?? .gray, h)
        }

        // Process per day so a Pasqua Rapid Response (day) + Pasqua-MSU (night) on the SAME day counts
        // as ONE combined 24h shift ("Pasqua Rapid+MSU"), not two short ones.
        let byDate = Dictionary(grouping: inRange) { $0.date }
        for (d, dayShifts) in byDate {
            var remaining = dayShifts
            if let pi = remaining.firstIndex(where: { $0.unit == .PRR }),
               remaining.contains(where: { $0.unit == .MSU }) {
                let prr = remaining.remove(at: pi)
                if let mi = remaining.firstIndex(where: { $0.unit == .MSU }) {
                    let msu = remaining.remove(at: mi)
                    let h = hours(of: prr) + hours(of: msu)
                    count += 1; total += h; nights += 1
                    if isWeekend(d) { weekends += 1 }
                    addLen(24, h)                                                        // one combined 24h shift
                    addUnit("PRR+MSU", "Pasqua Rapid+MSU", Units.info[.PRR]?.color ?? .gray, h)
                } else { remaining.append(prr) }
            }
            for s in remaining {
                let h = hours(of: s)
                count += 1; total += h
                if s.overnight { nights += 1 }
                if isWeekend(d) { weekends += 1 }
                addLen(Int(h.rounded()), h)
                addRealUnit(s.unit, h)
            }
        }

        let startOrd = ConflictEngine.ordinal(from), endOrd = ConflictEngine.ordinal(to)
        let months = max(1.0, Double(endOrd - startOrd + 1) / 30.4375)
        var byLength: [LenBucket] = []
        for (hr, v) in lenMap { byLength.append(LenBucket(hours: hr, count: v.count, totalHours: v.h)) }
        byLength.sort { $0.hours > $1.hours }
        var byUnit: [UnitBucket] = []
        for (_, v) in unitMap { byUnit.append(UnitBucket(name: v.name, color: v.color, count: v.count, hours: v.h)) }
        byUnit.sort { $0.count == $1.count ? $0.hours > $1.hours : $0.count > $1.count }
        return ShiftStats(count: count, totalHours: total, months: months,
                          byLength: byLength, byUnit: byUnit, nights: nights, weekends: weekends)
    }

    static func isWeekend(_ iso: String) -> Bool { let w = weekday(iso); return w == "Sat" || w == "Sun" }
}

/// "Brian Arnold" -> "B. Arnold" — disambiguates doctors who share a surname (e.g. two Arnolds).
func initialSurname(_ name: String) -> String {
    let parts = name.split(separator: " ")
    guard parts.count > 1, let initial = parts.first?.first else { return name }
    return "\(initial). \(parts.dropFirst().joined(separator: " "))"
}

// MARK: - My Stats screen

/// The tally sections, shown in a user-reorderable order (drag in "Reorder" mode; saved per device).
enum StatSection: String, CaseIterable {
    case perMonth, monthlyAvg, comingUp, ytd, groupCompare, unitMix, year2025, custom
    static let defaultOrder: [StatSection] = [.perMonth, .monthlyAvg, .comingUp, .ytd, .groupCompare, .unitMix, .year2025, .custom]
}

struct StatsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hb_stats_order") private var orderRaw = ""
    @AppStorage("hb_show_admin") private var showAdmin = true    // owner: hide the group-comparison card during demos
    @State private var rStart = ""       // custom range (ISO)
    @State private var rEnd = ""
    @State private var loadingHistory = false
    @State private var editMode: EditMode = .inactive
    @State private var expanded: Set<String> = []          // which month-by-month cards are opened
    @State private var groupYear = 0                       // admin card: selected year (0 → set to current on appear)
    @State private var groupExpanded = true                // admin card minimize toggle
    @State private var mixYear = 0                          // unit-mix card: selected year (0 → current on appear)
    @State private var mixExpanded = true                  // unit-mix card minimize toggle
    @State private var mixSort: UnitKey? = nil             // unit-mix card: tap a unit header to sort rows by it (nil = by total)
    @State private var mixDocCols: String? = nil           // unit-mix card: tap a doctor to order columns by their most-worked units
    @State private var yearSel = 0                         // by-year card: selected full year (0 → most recent full year)
    @State private var statsShare: ShareItem?              // export files are built on tap (not every render)

    private var today: String { AppModel.todayRegina() }
    private var year: String { String(today.prefix(4)) }
    private var log: [MyShift] { model.shiftLog }
    private var haveData: Bool { !log.isEmpty }
    private var allTimeStart: String { log.map(\.date).min() ?? "2022-01-01" }   // your actual first shift

    var body: some View {
        Group {
            if !haveData {
                ScrollView { emptyState.padding(16) }
            } else {
                List {
                    ForEach(order, id: \.self) { section in
                        sectionView(section)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onMove(perform: moveSections)

                    footer
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 24, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.editMode, $editMode)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("My Stats")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $statsShare) { ActivityView(items: [$0.url]) }
        .toolbar {
            if haveData {
                ToolbarItem(placement: .topBarLeading) {
                    Button(editMode.isEditing ? "Done" : "Reorder") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .font(.subheadline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { if let u = ShiftExport.csv(log) { statsShare = ShareItem(url: u) } } label: {
                            Label("Shift log (CSV, for Excel)", systemImage: "tablecells")
                        }
                        Button { if let u = ShiftExport.pdf(pdfContent) { statsShare = ShareItem(url: u) } } label: {
                            Label("Summary (PDF)", systemImage: "doc.richtext")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task {
            if rStart.isEmpty { rStart = Self.shift(today, days: -90); rEnd = today }
            if groupYear == 0 { groupYear = Int(year) ?? 2026 }
            if mixYear == 0 { mixYear = Int(year) ?? 2026 }
            loadingHistory = true
            await model.loadHistory()      // backfill the whole personal history (2022 →), then cached
            loadingHistory = false
            await model.loadGroupHistory()  // whole group's history (also powers Who's On / Crew)
        }
    }

    // MARK: reorderable sections (saved per device)

    private var order: [StatSection] {
        let saved = orderRaw.split(separator: ",").compactMap { StatSection(rawValue: String($0)) }
        var result = saved
        for s in StatSection.defaultOrder where !result.contains(s) {   // forward-compat: slot new sections in sensibly
            if s == .groupCompare, let i = result.firstIndex(of: .ytd) { result.insert(s, at: i + 1) }
            else if s == .unitMix, let i = result.firstIndex(of: .groupCompare) { result.insert(s, at: i + 1) }
            else { result.append(s) }
        }
        if !model.isOwner || !showAdmin { result.removeAll { $0 == .groupCompare || $0 == .unitMix } }   // admin-only, and hideable together
        return result
    }
    private func moveSections(from: IndexSet, to: Int) {
        var o = order
        o.move(fromOffsets: from, toOffset: to)
        orderRaw = o.map(\.rawValue).joined(separator: ",")
    }

    @ViewBuilder private func sectionView(_ s: StatSection) -> some View {
        switch s {
        case .perMonth:   perMonthCards
        case .monthlyAvg: StatsCard(title: "Monthly average", subtitle: "since \(allTimeStart.prefix(4))",
                                    stats: ShiftStats.compute(log, from: allTimeStart, to: today))
        case .comingUp:   upcomingCard
        case .ytd:        StatsCard(title: "Year to date", subtitle: "Jan 1 \(year) – today",
                                    stats: ShiftStats.compute(log, from: "\(year)-01-01", to: today))
        case .groupCompare: groupCompareCard
        case .unitMix:      unitMixCard
        case .year2025:   yearCard
        case .custom:     customCard
        }
    }

    // Full calendar years present in the log (excludes the current year — that's "Year to date"), newest first.
    private var fullYears: [Int] {
        let cur = Int(year) ?? 2026
        let ys = Set(log.compactMap { Int($0.date.prefix(4)) })
        return ys.filter { $0 < cur && $0 >= AppModel.firstYear }.sorted(by: >)
    }

    // A per-year card with tappable year chips (2025 / 2024 / 2023 / 2022 …).
    @ViewBuilder private var yearCard: some View {
        let years = fullYears
        if !years.isEmpty {
            let sel = years.contains(yearSel) ? yearSel : (years.first ?? 0)
            VStack(alignment: .leading, spacing: 12) {
                Text("By year").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(years, id: \.self) { y in
                            let on = sel == y
                            Button { withAnimation { yearSel = y } } label: {
                                Text("\(y)")
                                    .font(.subheadline.weight(on ? .bold : .regular))
                                    .padding(.horizontal, 13).padding(.vertical, 6)
                                    .background(Capsule().fill(on ? Theme.accent.opacity(0.16) : Theme.bg))
                                    .foregroundStyle(on ? Theme.accent : Theme.ink)
                                    .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.4) : Theme.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                StatsCard(title: "", subtitle: "\(sel) · full year",
                          stats: ShiftStats.compute(log, from: "\(sel)-01-01", to: "\(sel)-12-31"), embedded: true)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line, lineWidth: 1))
        }
    }

    // One card per month since Jan 2026 (only months you actually worked), newest first.
    private var perMonthCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Month by month").font(.headline)
            ForEach(monthsForCards, id: \.self) { ym in
                CollapsibleMonthCard(
                    title: monthLabelFull(ym + "-01"),
                    stats: ShiftStats.compute(log, from: ym + "-01", to: monthEnd(ym)),
                    expanded: Binding(get: { expanded.contains(ym) },
                                      set: { if $0 { expanded.insert(ym) } else { expanded.remove(ym) } }))
            }
        }
    }
    private var monthsForCards: [String] {
        let cur = String(today.prefix(7))
        var out: [String] = []; var y = 2026, m = 1
        while true {
            let ym = String(format: "%04d-%02d", y, m)
            if ym > cur { break }
            if log.contains(where: { $0.date.hasPrefix(ym) }) { out.append(ym) }
            m += 1; if m > 12 { m = 1; y += 1 }
            if out.count > 120 { break }
        }
        return out.reversed()   // newest month first
    }
    private func monthEnd(_ ym: String) -> String {
        let p = ym.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2 else { return ym + "-28" }
        var c = DateComponents(); c.year = p[0]; c.month = p[1]
        let cal = Calendar(identifier: .gregorian)
        guard let d = cal.date(from: c), let r = cal.range(of: .day, in: .month, for: d) else { return ym + "-28" }
        return String(format: "%@-%02d", ym, r.count)
    }

    // Coming up — the dynamic future half of the log, over two horizons + a month-by-month breakdown.
    private var upcomingCard: some View {
        let future = log.filter { $0.date >= today }.sorted { $0.date < $1.date }
        let eoy = "\(year)-12-31"
        let toYear = future.filter { $0.date <= eoy }
        let rosterEnd = log.map(\.date).max() ?? today
        let toYearHours = toYear.reduce(0.0) { $0 + ShiftStats.hours(of: $1) }
        let toRosterHours = future.reduce(0.0) { $0 + ShiftStats.hours(of: $1) }
        let byMonth = Dictionary(grouping: future) { String($0.date.prefix(7)) }
        let months = byMonth.keys.sorted()
        return VStack(alignment: .leading, spacing: 12) {
            Text("Coming up").font(.headline)
            HStack(spacing: 10) {
                comingBlock("To end of \(year)", shifts: toYear.count, hours: toYearHours, sub: "by Dec 31")
                comingBlock("To roster end", shifts: future.count, hours: toRosterHours, sub: "ends \(fmt(rosterEnd, "MMM d, yyyy"))")
            }
            if let n = future.first {
                let info = Units.info[n.unit]
                HStack(spacing: 6) {
                    Circle().fill(info?.color ?? .gray).frame(width: 8, height: 8)
                    Text("Next: \(info?.short ?? n.unit.rawValue) · \(longDate(n.date)) · \(n.start)–\(n.end)")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
            if !months.isEmpty {
                Divider().overlay(Theme.line)
                Text("BY MONTH").font(.caption2.weight(.bold)).foregroundStyle(Theme.muted).tracking(0.6)
                ForEach(months, id: \.self) { ym in upcomingMonthRow(ym, byMonth[ym] ?? []) }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
    }

    // One upcoming month: total shifts + per-unit chips.
    private func upcomingMonthRow(_ ym: String, _ items: [MyShift]) -> some View {
        var counts: [UnitKey: Int] = [:]
        for s in items { counts[s.unit, default: 0] += 1 }
        let units = WhoView.unitOrder.filter { counts[$0] != nil }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(monthLabelFull(ym + "-01")).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(items.count) shift\(items.count == 1 ? "" : "s")").font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(units, id: \.self) { u in
                    HStack(spacing: 5) {
                        Circle().fill(Units.info[u]?.color ?? .gray).frame(width: 8, height: 8)
                        Text(Units.info[u]?.short ?? u.rawValue).font(.caption2).foregroundStyle(Theme.muted)
                        Text("×\(counts[u] ?? 0)").font(.caption2.weight(.bold)).monospacedDigit().foregroundStyle(Theme.ink)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func comingBlock(_ title: String, shifts: Int, hours: Double, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(shifts)").font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(Theme.ink)
                Text("shifts").font(.caption2).foregroundStyle(Theme.muted)
            }
            Text("\(Self.hoursStr(hours)) h").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.accent)
            Text(sub).font(.caption2).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg))
    }

    // Admin-only: the logged-in person's shifts/hours vs the group, ranked, over a chosen calendar period.
    // Source is the cumulative group log (deep-scanned once, then kept current); falls back to the live
    // Who's On window until the one-time scan has run.
    // The years with group data (+ the current year), newest first — drives the admin card's year chips.
    private var availableYears: [Int] {
        let cur = Int(year) ?? 2026
        var ys = Set(model.groupLog.compactMap { Int($0.date.prefix(4)) })
        ys.insert(cur)
        return ys.filter { $0 >= AppModel.firstYear && $0 <= cur }.sorted(by: >)
    }

    private var groupCompareCard: some View {
        let curYear = Int(year) ?? 2026
        let yr = groupYear == 0 ? curYear : groupYear
        let isCurrentYear = yr == curYear
        // the current year is counted through the END of the last completed month (no partial current month).
        let prevEnd = dateToISO(Calendar.current.date(byAdding: .day, value: -1,
                        to: isoToDate(String(today.prefix(7)) + "-01")) ?? isoToDate(today))
        let from = "\(yr)-01-01"
        let to = isCurrentYear ? prevEnd : "\(yr)-12-31"
        let label = isCurrentYear ? "Jan 1 – \(fmt(prevEnd, "MMM d, yyyy"))" : "\(yr) (full year)"
        let src = model.groupLog.isEmpty ? model.assignments : model.groupLog
        let inPeriod = src.filter { $0.date >= from && $0.date <= to }
        func hoursOf(_ a: Assignment) -> Double {
            let iv = ConflictEngine.interval(a.date, a.start, a.end, overnight: a.overnight); return Double(iv.e - iv.s) / 60
        }
        var byDoc: [String: (shifts: Int, hours: Double)] = [:]
        var mineShifts = 0; var mineHours = 0.0
        for a in inPeriod where !a.doc.isEmpty && a.doc != "—" && a.doc.uppercased() != "EMPTY" {
            let h = hoursOf(a)                                   // exclude Lightning Bolt's "EMPTY" vacant-slot placeholder
            var v = byDoc[a.doc] ?? (0, 0.0); v.shifts += 1; v.hours += h; byDoc[a.doc] = v
            if a.isMe { mineShifts += 1; mineHours += h }
        }
        let n = byDoc.count
        let avgShifts = n > 0 ? Double(byDoc.values.reduce(0) { $0 + $1.shifts }) / Double(n) : 0
        let avgHours  = n > 0 ? byDoc.values.reduce(0.0) { $0 + $1.hours } / Double(n) : 0
        let shiftRank = byDoc.values.filter { $0.shifts > mineShifts }.count + 1
        let hoursRank = byDoc.values.filter { $0.hours > mineHours }.count + 1
        let myDoc = inPeriod.first(where: { $0.isMe })?.doc ?? ""
        let ranked = byDoc.sorted { $0.value.hours > $1.value.hours }
        // Self-check: the group covers every unit every day → 5 units × 24h + RGH-Rapid 9h = 129 h/day.
        // Actual total clinical hours should ≈ 129 × days. Big shortfall = incomplete data.
        let totalGroupHours = byDoc.values.reduce(0.0) { $0 + $1.hours }
        let days = max(1, ConflictEngine.ordinal(to) - ConflictEngine.ordinal(from) + 1)
        let expectedHours = 129.0 * Double(days)
        let coverage = expectedHours > 0 ? totalGroupHours / expectedHours * 100 : 0
        let coverageOK = abs(coverage - 100) <= 5

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { withAnimation { groupExpanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text("You vs group").font(.headline).foregroundStyle(Theme.ink)
                        Image(systemName: groupExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold)).foregroundStyle(Theme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text("admin only").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
                Button { withAnimation { showAdmin = false } } label: {
                    Image(systemName: "eye.slash").font(.footnote)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)
            }

            if !groupExpanded {
                if n >= 2 {
                    Text("You're #\(hoursRank) of \(n) by hours · \(label)")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availableYears, id: \.self) { y in
                            let sel = yr == y
                            Button { withAnimation { groupYear = y } } label: {
                                Text(y == curYear ? "\(y) YTD" : "\(y)")
                                    .font(.subheadline.weight(sel ? .bold : .regular))
                                    .padding(.horizontal, 13).padding(.vertical, 6)
                                    .background(Capsule().fill(sel ? Theme.accent.opacity(0.16) : Theme.bg))
                                    .foregroundStyle(sel ? Theme.accent : Theme.ink)
                                    .overlay(Capsule().strokeBorder(sel ? Theme.accent.opacity(0.4) : Theme.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if model.groupScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Theme.accent)
                        Text("Loading the whole group's history (2022 →)…")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                }

                if n < 2 {
                    Text(model.groupScanning
                         ? "Fetching every doctor's shifts back to 2022 — just a moment."
                         : "No group data yet — it loads automatically here. Pull down to refresh if this persists.")
                        .font(.caption).foregroundStyle(Theme.muted)
                } else {
                    Text("\(label) · \(n) doctors · total hours").font(.caption).foregroundStyle(Theme.muted)
                    compareRow("Shifts", mine: Double(mineShifts), avg: avgShifts, hours: false, rank: shiftRank, total: n)
                    compareRow("Hours",  mine: mineHours,          avg: avgHours,  hours: true,  rank: hoursRank, total: n)

                    Divider().overlay(Theme.line)
                    Text("GROUP RANKED · TOTAL HOURS").font(.caption2.weight(.bold)).foregroundStyle(Theme.muted).tracking(0.6)
                    VStack(spacing: 6) {
                        ForEach(Array(ranked.enumerated()), id: \.offset) { i, e in
                            HStack(spacing: 8) {
                                Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(Theme.muted).frame(width: 20, alignment: .trailing)
                                Text(initialSurname(e.key)).font(.subheadline.weight(e.key == myDoc ? .bold : .regular))
                                    .foregroundStyle(e.key == myDoc ? Theme.accent : Theme.ink).lineLimit(1).minimumScaleFactor(0.8)
                                Spacer(minLength: 6)
                                Text("\(Self.hoursStr(e.value.hours)) h").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.ink)
                                Text("· \(e.value.shifts)").font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                                    .frame(width: 34, alignment: .trailing)
                            }
                            .padding(.vertical, 1)
                            .background(e.key == myDoc ? Theme.accent.opacity(0.08) : .clear)
                        }
                    }
                    Divider().overlay(Theme.line)
                    HStack(spacing: 6) {
                        Image(systemName: coverageOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(coverageOK ? Color(hex: 0x178A51) : Color(hex: 0xED8207))
                        Text("Data check: \(StatsView.hoursStr(totalGroupHours)) of \(StatsView.hoursStr(expectedHours)) h expected · \(Int(coverage.rounded()))%")
                            .font(.caption.weight(.medium)).foregroundStyle(Theme.ink)
                    }
                    Text("Expected = 129 h/day (SICU·MICU·CCU·PICU·Pasqua 24h each + RGH-Rapid 9h) × \(days) days. ≈100% = every unit covered / data complete.")
                        .font(.caption2).foregroundStyle(Theme.muted)
                    Text(isCurrentYear
                         ? "Total hours through the last completed month (\(fmt(prevEnd, "MMM yyyy"))), to keep it fair. Admin-only; hidden from everyone else."
                         : "Total hours across all of \(yr). Admin-only; hidden from everyone else.")
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line, lineWidth: 1))
    }

    @ViewBuilder private func compareRow(_ label: String, mine: Double, avg: Double, hours: Bool, rank: Int, total: Int) -> some View {
        let delta = avg > 0 ? (mine - avg) / avg * 100 : 0
        let up = delta >= 0
        let mineStr = hours ? "\(Self.hoursStr(mine)) h" : "\(Int(mine.rounded()))"
        let avgStr  = hours ? "\(Self.hoursStr(avg)) h"  : String(format: "%.1f", avg)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                Text(rank >= 1 && rank <= total ? "#\(rank) of \(total)" : "—")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent).monospacedDigit()
            }
            .frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(mineStr).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(Theme.ink)
                Text("you").font(.caption2).foregroundStyle(Theme.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(avgStr).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.ink.opacity(0.7))
                Text("group avg").font(.caption2).foregroundStyle(Theme.muted)
            }
            Text("\(up ? "+" : "")\(Int(delta.rounded()))%")
                .font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(up ? Color(hex: 0x178A51) : Color(hex: 0xC23A54)))
        }
    }

    // Admin-only: how many shifts of each unit every doctor worked over the chosen year — a matrix you can
    // scan down a column to compare one unit across the group, or across a row to see one doctor's mix.
    // Same year windowing as "You vs group" (current year through the last completed month; else full year).
    private let mixUnits: [UnitKey] = [.SICU, .MICU, .CCU, .PHICU, .RR, .PRR, .MSU]
    private let mixNameW: CGFloat = 140    // frozen doctor-name column
    private let mixColW: CGFloat = 56      // each unit / total column
    private let mixRowH: CGFloat = 36
    private let mixHeadH: CGFloat = 46
    private func mixCode(_ u: UnitKey) -> String {
        switch u {
        case .SICU: return "SICU"; case .MICU: return "MICU"; case .CCU: return "CCU"
        case .PHICU: return "PICU"; case .RR: return "RR"; case .PRR: return "PRR"; case .MSU: return "MSU"
        }
    }

    private var unitMixCard: some View {
        let curYear = Int(year) ?? 2026
        let yr = mixYear == 0 ? curYear : mixYear
        let isCurrentYear = yr == curYear
        let prevEnd = dateToISO(Calendar.current.date(byAdding: .day, value: -1,
                        to: isoToDate(String(today.prefix(7)) + "-01")) ?? isoToDate(today))
        let from = "\(yr)-01-01"
        let to = isCurrentYear ? prevEnd : "\(yr)-12-31"
        let label = isCurrentYear ? "Jan 1 – \(fmt(prevEnd, "MMM d, yyyy"))" : "\(yr) (full year)"
        let src = model.groupLog.isEmpty ? model.assignments : model.groupLog
        let inPeriod = src.filter {
            $0.date >= from && $0.date <= to && !$0.doc.isEmpty && $0.doc != "—" && $0.doc.uppercased() != "EMPTY"
        }
        var counts: [String: [UnitKey: Int]] = [:]
        var totals: [String: Int] = [:]
        var isMeByDoc: [String: Bool] = [:]
        var colTotal: [UnitKey: Int] = [:]
        for a in inPeriod {
            counts[a.doc, default: [:]][a.unit, default: 0] += 1
            totals[a.doc, default: 0] += 1
            colTotal[a.unit, default: 0] += 1
            if a.isMe { isMeByDoc[a.doc] = true }
        }
        let grandTotal = totals.values.reduce(0, +)
        var docs: [(doc: String, dict: [UnitKey: Int], total: Int, isMe: Bool)] = []
        for (d, t) in totals { docs.append((d, counts[d] ?? [:], t, isMeByDoc[d] ?? false)) }
        docs.sort { a, b in
            if let u = mixSort {
                let ca = a.dict[u] ?? 0, cb = b.dict[u] ?? 0
                if ca != cb { return ca > cb }         // most → least in the tapped unit
            }
            if a.total != b.total { return a.total > b.total }
            return a.doc < b.doc
        }
        let n = docs.count

        // Column order: default fixed order, or — when a doctor is tapped — that doctor's units most → least.
        var cols = mixUnits
        if let d = mixDocCols, let dict = counts[d] {
            cols = mixUnits.enumerated().sorted { a, b in
                let ca = dict[a.element] ?? 0, cb = dict[b.element] ?? 0
                if ca != cb { return ca > cb }
                return a.offset < b.offset            // stable tiebreak → keeps default order among ties
            }.map { $0.element }
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { withAnimation { mixExpanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Text("Unit mix by doctor").font(.headline).foregroundStyle(Theme.ink)
                        Image(systemName: mixExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.bold)).foregroundStyle(Theme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text("admin only").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
                Button { withAnimation { showAdmin = false } } label: {
                    Image(systemName: "eye.slash").font(.footnote)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)
            }

            if !mixExpanded {
                if n >= 1 {
                    Text("\(n) doctors · \(grandTotal) shifts · \(label)")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availableYears, id: \.self) { y in
                            let sel = yr == y
                            Button { withAnimation { mixYear = y } } label: {
                                Text(y == curYear ? "\(y) YTD" : "\(y)")
                                    .font(.subheadline.weight(sel ? .bold : .regular))
                                    .padding(.horizontal, 13).padding(.vertical, 6)
                                    .background(Capsule().fill(sel ? Theme.accent.opacity(0.16) : Theme.bg))
                                    .foregroundStyle(sel ? Theme.accent : Theme.ink)
                                    .overlay(Capsule().strokeBorder(sel ? Theme.accent.opacity(0.4) : Theme.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if n < 1 {
                    Text(model.groupScanning
                         ? "Fetching every doctor's shifts back to 2022 — just a moment."
                         : "No group data yet — it loads automatically here. Pull down to refresh if this persists.")
                        .font(.caption).foregroundStyle(Theme.muted)
                } else {
                    HStack(spacing: 6) {
                        let rowsBy = mixSort == nil ? "rows by total" : "rows by \(mixCode(mixSort!))"
                        let colsBy = mixDocCols == nil ? "" : " · cols by \(initialSurname(mixDocCols!))"
                        Text("\(label) · \(rowsBy)\(colsBy)")
                            .font(.caption).foregroundStyle(Theme.muted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 4)
                        if mixSort != nil || mixDocCols != nil {
                            Button { withAnimation { mixSort = nil; mixDocCols = nil } } label: {
                                Label("Reset", systemImage: "arrow.uturn.backward")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.plain).foregroundStyle(Theme.accent)
                        }
                    }

                    // Frozen doctor-name column on the left; unit columns scroll horizontally beside it.
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            mixNameCell(nil, "Doctor", isMe: false, header: true)
                            Divider().overlay(Theme.line)
                            ForEach(Array(docs.enumerated()), id: \.offset) { i, e in
                                Button { withAnimation { mixDocCols = (mixDocCols == e.doc ? nil : e.doc) } } label: {
                                    mixNameCell(i + 1, e.doc, isMe: e.isMe, selected: mixDocCols == e.doc)
                                }
                                .buttonStyle(.plain)
                            }
                            Divider().overlay(Theme.line)
                            mixNameCell(nil, "Group", isMe: false, group: true)
                        }
                        .frame(width: mixNameW)
                        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }

                        ScrollView(.horizontal, showsIndicators: true) {
                            VStack(spacing: 0) {
                                mixUnitHeader(cols)
                                Divider().overlay(Theme.line)
                                ForEach(Array(docs.enumerated()), id: \.offset) { i, e in
                                    mixMetricRow(e.dict, e.total, isMe: e.isMe, units: cols, selected: mixDocCols == e.doc)
                                }
                                Divider().overlay(Theme.line)
                                mixMetricRow(colTotal, grandTotal, isMe: false, units: cols, group: true)
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))

                    Text("Tap a unit heading to rank doctors by it; tap a doctor to reorder the columns by their most-worked units. Tap again (or Reset) to revert. Counts each roster assignment once (a Pasqua Rapid + MSU pair shows in both columns). “·” = none. Admin-only; hidden from everyone else.")
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line, lineWidth: 1))
    }

    // Frozen left column cell (also renders the header "Doctor" and the "Group" total row).
    // `selected` = this doctor's row is the one currently ordering the columns.
    @ViewBuilder private func mixNameCell(_ rank: Int?, _ name: String, isMe: Bool, group: Bool = false, header: Bool = false, selected: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(rank.map { "\($0)" } ?? "")
                .font(.footnote.weight(.bold)).foregroundStyle(Theme.muted)
                .frame(width: 22, alignment: .trailing)
            Text(header ? "Doctor" : (group ? "Group" : initialSurname(name)))
                .font((header || group) ? .subheadline.weight(.bold) : .subheadline.weight(isMe || selected ? .bold : .regular))
                .foregroundStyle(isMe ? Theme.accent : ((header || group) ? Theme.muted : Theme.ink))
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            if selected { Image(systemName: "arrow.left.arrow.right").font(.caption2).foregroundStyle(Theme.accent) }
        }
        .padding(.horizontal, 6)
        .frame(width: mixNameW, height: header ? mixHeadH : mixRowH, alignment: .leading)
        .background(selected ? Theme.accent.opacity(0.16) : (isMe ? Theme.accent.opacity(0.08) : .clear))
    }

    // Tappable unit headings — tap to sort rows by that unit, tap again to clear.
    private func mixUnitHeader(_ units: [UnitKey]) -> some View {
        HStack(spacing: 0) {
            ForEach(units, id: \.self) { u in
                Button { withAnimation { mixSort = (mixSort == u ? nil : u) } } label: {
                    VStack(spacing: 3) {
                        Circle().fill(Units.info[u]?.color ?? .gray).frame(width: 10, height: 10)
                        Text(mixCode(u)).font(.caption.weight(.semibold))
                            .foregroundStyle(mixSort == u ? Theme.accent : Theme.muted)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(width: mixColW, height: mixHeadH)
                    .background(mixSort == u ? Theme.accent.opacity(0.14) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Σ").font(.subheadline.weight(.bold)).foregroundStyle(Theme.muted)
                .frame(width: mixColW, height: mixHeadH)
        }
    }

    // One doctor's per-unit counts (also renders the "Group" totals row).
    // `units` = current column order; `selected` = this doctor's row is ordering the columns.
    @ViewBuilder private func mixMetricRow(_ dict: [UnitKey: Int], _ total: Int, isMe: Bool, units: [UnitKey], group: Bool = false, selected: Bool = false) -> some View {
        HStack(spacing: 0) {
            ForEach(units, id: \.self) { u in
                let c = dict[u] ?? 0
                Text(c == 0 ? "·" : "\(c)")
                    .font(.subheadline.weight(isMe || group || selected ? .semibold : .regular)).monospacedDigit()
                    .foregroundStyle(c == 0 ? Theme.muted.opacity(0.4) : (group ? Theme.muted : Theme.ink))
                    .frame(width: mixColW, height: mixRowH)
                    .background(mixSort == u ? Theme.accent.opacity(0.08) : .clear)
            }
            Text("\(total)").font(.subheadline.weight(.bold)).monospacedDigit()
                .foregroundStyle(isMe ? Theme.accent : Theme.muted)
                .frame(width: mixColW, height: mixRowH)
        }
        .background(selected ? Theme.accent.opacity(0.16) : (isMe ? Theme.accent.opacity(0.08) : .clear))
    }

    // Selectable date range.
    private var customCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom range").font(.headline)
            VStack(spacing: 8) {
                DatePicker("From", selection: dateBinding({ rStart }, { rStart = $0 }), in: bounds, displayedComponents: .date)
                DatePicker("To",   selection: dateBinding({ rEnd },   { rEnd = $0 }),   in: bounds, displayedComponents: .date)
            }
            .font(.subheadline).tint(Theme.accent)
            Divider().overlay(Theme.line)
            StatsCard(title: "Selected range", subtitle: "\(longDate(rStart)) – \(longDate(rEnd))",
                      stats: ShiftStats.compute(log, from: min(rStart, rEnd), to: max(rStart, rEnd)), embedded: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line, lineWidth: 1))
    }

    private var footer: some View {
        Text("Your shift log is saved on this device and remembers every shift you've worked since 2022 — even ones no longer shown in the roster. Future shifts update automatically as you pick up or give away.")
            .font(.caption2).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if loadingHistory {
                ProgressView().tint(Theme.accent)
                Text("Building your shift log…").font(.subheadline).foregroundStyle(Theme.ink)
                Text("Reading your roster back to 2022 — just this once.").font(.caption).foregroundStyle(Theme.muted)
            } else {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 34)).foregroundStyle(Theme.muted)
                Text("No shifts logged yet").foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    // A compact one-page layout for the PDF export (rendered off-screen, so it's self-contained).
    private var pdfContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shift stats — \(model.userName.isEmpty ? "My shifts" : model.userName)").font(.title3.bold())
            Text("Generated \(longDate(today)) · log since \(allTimeStart.prefix(4))").font(.caption).foregroundStyle(.secondary)
            StatsCard(title: "Monthly average", subtitle: "since \(allTimeStart.prefix(4))",
                      stats: ShiftStats.compute(log, from: allTimeStart, to: today))
            StatsCard(title: "Year to date", subtitle: "Jan 1 \(year) – today",
                      stats: ShiftStats.compute(log, from: "\(year)-01-01", to: today))
            if year != "2025" {
                StatsCard(title: "2025", subtitle: "last full year",
                          stats: ShiftStats.compute(log, from: "2025-01-01", to: "2025-12-31"))
            }
        }
        .padding(20)
        .frame(width: 560, alignment: .leading)
        .background(Color(.systemBackground))
    }

    // MARK: helpers
    private var bounds: ClosedRange<Date> { isoToDate(allTimeStart)...isoToDate(log.map(\.date).max() ?? today) }
    private func dateBinding(_ get: @escaping () -> String, _ set: @escaping (String) -> Void) -> Binding<Date> {
        Binding(get: { isoToDate(get()) }, set: { set(dateToISO($0)) })
    }

    @ViewBuilder private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.bold)).monospacedDigit().foregroundStyle(Theme.ink)
            Text(label).font(.caption2).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg))
    }

    static func hoursStr(_ h: Double) -> String { Int(h.rounded()).formatted() }
    static func shift(_ iso: String, days: Int) -> String {
        dateToISO(Calendar.current.date(byAdding: .day, value: days, to: isoToDate(iso)) ?? isoToDate(iso))
    }
}

// MARK: - Reusable stats card

struct StatsCard: View {
    let title: String
    let subtitle: String
    let stats: ShiftStats
    var embedded: Bool = false
    var showAverages: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !embedded {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer()
                    Text(subtitle).font(.caption).foregroundStyle(Theme.muted)
                }
            } else {
                Text(subtitle).font(.caption).foregroundStyle(Theme.muted)
            }

            // totals + per-month averages
            HStack(spacing: 10) {
                metric("\(stats.count)", "shifts")
                metric(StatsView.hoursStr(stats.totalHours), "hours")
                if showAverages {
                    metric(String(format: "%.1f", stats.avgShiftsPerMonth), "shifts/mo")
                    metric(StatsView.hoursStr(stats.avgHoursPerMonth), "h/mo")
                }
            }

            if stats.count == 0 {
                Text("No shifts in this range.").font(.caption).foregroundStyle(Theme.muted)
            } else {
                if !stats.byLength.isEmpty {
                    label("By length")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(stats.byLength) { b in
                            HStack(spacing: 5) {
                                Text(b.label).font(.caption.weight(.bold))
                                Text("×\(b.count)").font(.caption).foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Theme.bg))
                            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                        }
                    }
                }
                if !stats.byUnit.isEmpty {
                    label("By unit")
                    VStack(spacing: 6) {
                        ForEach(stats.byUnit) { u in
                            HStack(spacing: 7) {
                                Circle().fill(u.color).frame(width: 9, height: 9)
                                Text(u.name).font(.subheadline).foregroundStyle(Theme.ink)
                                Spacer(minLength: 4)
                                Text("×\(u.count)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink).monospacedDigit()
                                if showAverages {
                                    Text("· \(String(format: "%.1f", Double(u.count) / stats.months))/mo")
                                        .font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                                }
                                Text("· \(StatsView.hoursStr(u.hours))h").font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                            }
                            .lineLimit(1).minimumScaleFactor(0.75)
                        }
                    }
                }
                if stats.nights > 0 || stats.weekends > 0 {
                    Text("\(stats.nights) overnight · \(stats.weekends) weekend day\(stats.weekends == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(embedded ? 0 : 16)
        .background(embedded ? nil : RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(embedded ? nil : RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line, lineWidth: 1))
    }

    @ViewBuilder private func metric(_ value: String, _ lbl: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(lbl).font(.caption2).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg))
    }

    @ViewBuilder private func label(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(Theme.muted).tracking(0.6).padding(.top, 2)
    }
}

// MARK: - Collapsible month card (Month-by-month: tap to open the full breakdown)

struct CollapsibleMonthCard: View {
    let title: String
    let stats: ShiftStats
    @Binding var expanded: Bool

    private var summary: String {
        let c24 = stats.byLength.first(where: { $0.hours == 24 })?.count ?? 0
        let c9  = stats.byLength.first(where: { $0.hours == 9 })?.count ?? 0
        var parts = ["\(stats.count) · \(StatsView.hoursStr(stats.totalHours))h"]
        if c24 > 0 { parts.append("24h ×\(c24)") }
        if c9  > 0 { parts.append("9h ×\(c9)") }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: expanded ? 12 : 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(title).font(.headline).foregroundStyle(Theme.ink)
                    Spacer(minLength: 6)
                    if !expanded {
                        Text(summary).font(.caption).foregroundStyle(Theme.muted)
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold)).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                StatsCard(title: "", subtitle: "", stats: stats, embedded: true, showAverages: false)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line, lineWidth: 1))
    }
}

// MARK: - Export (tapped from the share menu — never automatic)

enum ShiftExport {
    /// The full shift log as CSV — opens directly in Excel / Numbers.
    static func csv(_ log: [MyShift]) -> URL? {
        var s = "Date,Weekday,Unit,Start,End,Hours,Overnight\n"
        for x in log.sorted(by: { $0.date < $1.date }) {
            let h = ShiftStats.hours(of: x)
            let unit = Units.info[x.unit]?.short ?? x.unit.rawValue
            s += "\(x.date),\(weekday(x.date)),\(unit),\(x.start),\(x.end),\(String(format: "%.1f", h)),\(x.overnight ? "yes" : "no")\n"
        }
        return write(s.data(using: .utf8), name: "shift-log.csv")
    }

    /// The shifts as an iCalendar (.ics) — imports straight into Apple / Google Calendar with correct times.
    static func ics(_ log: [MyShift]) -> URL? {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd'T'HHmmss"; f.timeZone = TimeZone(identifier: "America/Regina")
        let stamp = f.string(from: Date())
        var s = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Working-Bolt//Shifts//EN\r\nCALSCALE:GREGORIAN\r\n"
        for x in log.sorted(by: { $0.date < $1.date }) {
            let info = Units.info[x.unit]
            let startDT = x.date.replacingOccurrences(of: "-", with: "") + "T" + x.start.replacingOccurrences(of: ":", with: "") + "00"
            let endDate = (x.overnight || x.end <= x.start) ? ConflictEngine.addDay(x.date) : x.date
            let endDT = endDate.replacingOccurrences(of: "-", with: "") + "T" + x.end.replacingOccurrences(of: ":", with: "") + "00"
            s += "BEGIN:VEVENT\r\n"
            s += "UID:\(x.date)-\(x.unit.rawValue)-\(x.start)@hackingbolt\r\n"
            s += "DTSTAMP:\(stamp)\r\n"
            s += "DTSTART:\(startDT)\r\n"
            s += "DTEND:\(endDT)\r\n"
            s += "SUMMARY:\(info?.short ?? x.unit.rawValue) · \(Int(ShiftStats.hours(of: x).rounded()))h\r\n"
            s += "END:VEVENT\r\n"
        }
        s += "END:VCALENDAR\r\n"
        return write(s.data(using: .utf8), name: "my-shifts.ics")
    }

    /// A PDF rendered from the given SwiftUI view.
    @MainActor static func pdf(_ content: some View, name: String = "export.pdf") -> URL? {
        let renderer = ImageRenderer(content: content)
        renderer.scale = UIScreen.main.scale
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        var ok = false
        renderer.render { size, ctx in
            var box = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            guard let cg = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            cg.beginPDFPage(nil)
            ctx(cg)
            cg.endPDFPage()
            cg.closePDF()
            ok = true
        }
        return ok ? url : nil
    }

    static func write(_ data: Data?, name: String) -> URL? {
        guard let data else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: url); return url } catch { return nil }
    }
}
