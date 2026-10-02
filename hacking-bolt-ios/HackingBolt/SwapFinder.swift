import SwiftUI
import UIKit

// MARK: - Models

struct Contact: Hashable { let cell: String; let email: String }

enum SwapStatus: Hashable {
    case free
    case off(String)
    var isFree: Bool { if case .free = self { return true }; return false }
}

/// One viable swap: a colleague + a specific future shift of theirs I could take (they can take mine too).
struct SwapOption: Identifiable {
    let emp: Int
    let name: String
    var cell: String? = nil
    let statusOnMyDate: SwapStatus
    let returnShift: Assignment
    var id: String { "\(emp)|\(returnShift.date)|\(returnShift.unit.rawValue)|\(returnShift.start)" }
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

// MARK: - helpers

private let prettyFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE MMM d"; f.timeZone = TimeZone(identifier: "UTC"); return f }()
private let swapIsoFmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f }()
func swapPretty(_ iso: String) -> String {
    guard let d = swapIsoFmt.date(from: iso) else { return iso }
    return prettyFmt.string(from: d)
}
func unitShort(_ u: UnitKey) -> String { Units.info[u]?.short ?? u.rawValue }
func unitColor(_ u: UnitKey) -> Color { Units.info[u]?.color ?? .gray }

func swapMessage(mineUnit: UnitKey, mineDate: String, opt: SwapOption) -> String {
    "Hi \(opt.firstName), any chance we could swap — I take your \(unitShort(opt.returnShift.unit)) on \(swapPretty(opt.returnShift.date)), you take my \(unitShort(mineUnit)) on \(swapPretty(mineDate))? Thanks!"
}
func openSwapText(_ msg: String, cell: String) {
    let digits = cell.filter { $0.isNumber || $0 == "+" }
    let enc = msg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    guard !digits.isEmpty, let url = URL(string: "sms:\(digits)&body=\(enc)") else { return }
    UIApplication.shared.open(url)
}
/// Open a group SMS to several colleagues at once (iOS makes it a group thread). Numbers without digits are skipped.
func openGroupText(_ msg: String, cells: [String]) {
    let nums = cells.map { $0.filter { $0.isNumber || $0 == "+" } }.filter { !$0.isEmpty }
    guard !nums.isEmpty else { return }
    let enc = msg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
    guard let url = URL(string: "sms:\(nums.joined(separator: ","))&body=\(enc)") else { return }
    UIApplication.shared.open(url)
}

struct SwapStatusChip: View {
    let status: SwapStatus
    var body: some View {
        switch status {
        case .free:           chip("free", .green)
        case .off(let label): chip("⚠️ \(label)", .orange)
        }
    }
    private func chip(_ t: String, _ c: Color) -> some View {
        Text(t).font(.caption2.bold()).padding(.horizontal, 7).padding(.vertical, 2)
            .background(c.opacity(0.18)).foregroundStyle(c).clipShape(Capsule())
    }
}

/// Bright worked-day + faded post-call for one month, matching the My Shifts calendar (see MiniMonth).
struct MonthShiftMap {
    var fill: [Int: Color] = [:]      // day → shift colour (bright)
    var post: [Int: Color] = [:]      // day → post-call colour (faded)
    var fuseStart: Set<Int> = []      // on-call day bleeds right into…
    var fuseEnd: Set<Int> = []        // …the post-call day
    init(_ shifts: [MyShift], year: Int, month: Int) {
        let key = String(format: "%04d-%02d", year, month)
        let cal = Calendar(identifier: .gregorian)
        func day(_ iso: String) -> Int? { Int(iso.suffix(2)) }
        for s in shifts where s.date.hasPrefix(key) {
            if let d = day(s.date), let c = Units.info[s.unit]?.color { fill[d] = c }
        }
        for s in shifts where s.overnight {
            let nd = ConflictEngine.addDay(s.date)
            if nd.hasPrefix(key), let d = day(nd), let c = Units.info[s.unit]?.color { post[d] = c }
            if s.date.hasPrefix(key), let cd = day(s.date), let nday = day(nd), nd.hasPrefix(key) {
                var comp = DateComponents(); comp.year = year; comp.month = month; comp.day = cd
                let wd = cal.date(from: comp).map { cal.component(.weekday, from: $0) - 1 } ?? 0
                if wd < 6 { fuseStart.insert(cd); fuseEnd.insert(nday) }  // don't fuse across a Sat/Sun week break
            }
        }
    }
}

// MARK: - Paged, tappable month calendar (native swipe + arrows, future-only)

struct SwapCalendar: View {
    @Binding var offset: Int                 // months from the current month (0 = this month)
    let months: Int
    let myShifts: [MyShift]                   // drawn as coloured unit blocks (with name)
    let availByDay: [String: [UnitKey]]       // iso → distinct units you could pick up that day (empty for the my-shifts calendar)
    let selectedISO: String?
    let tappable: (String) -> Bool
    let onTap: (String) -> Void

    private var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Regina")!; return c }
    private var base: Date { cal.date(from: cal.dateComponents([.year, .month], from: Date()))! }
    private func monthDate(_ o: Int) -> Date { cal.date(byAdding: .month, value: o, to: base) ?? base }
    private var todayISO: String { AppModel.todayRegina() }
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Button { if offset > 0 { withAnimation(.easeInOut(duration: 0.2)) { offset -= 1 } } }
                    label: { Image(systemName: "chevron.left").font(.subheadline.bold()).frame(width: 30, height: 26) }
                    .buttonStyle(.bordered).disabled(offset <= 0)
                Spacer(); Text(monthTitle(offset)).font(.headline); Spacer()
                Button { if offset < months - 1 { withAnimation(.easeInOut(duration: 0.2)) { offset += 1 } } }
                    label: { Image(systemName: "chevron.right").font(.subheadline.bold()).frame(width: 30, height: 26) }
                    .buttonStyle(.bordered).disabled(offset >= months - 1)
            }
            HStack(spacing: 3) { ForEach(0..<7, id: \.self) { i in
                Text(["S","M","T","W","T","F","S"][i]).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity) } }
            TabView(selection: $offset) {
                ForEach(0..<months, id: \.self) { o in grid(o).tag(o) }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 336)
        }
    }

    private static let monthTitleFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; f.timeZone = TimeZone(identifier: "America/Regina"); return f }()
    private func monthTitle(_ o: Int) -> String { Self.monthTitleFmt.string(from: monthDate(o)) }

    // my shifts for a month → day → [(unit, isCall)]  (isCall=false is the post-call morning)
    private func myBlocks(_ y: Int, _ m: Int) -> [Int: [(UnitKey, Bool)]] {
        let key = String(format: "%04d-%02d", y, m); var out = [Int: [(UnitKey, Bool)]]()
        func day(_ iso: String) -> Int? { Int(iso.suffix(2)) }
        for s in myShifts where s.date.hasPrefix(key) { if let d = day(s.date) { out[d, default: []].append((s.unit, true)) } }
        for s in myShifts where s.overnight { let nd = ConflictEngine.addDay(s.date); if nd.hasPrefix(key), let d = day(nd) { out[d, default: []].append((s.unit, false)) } }
        return out
    }

    private func grid(_ o: Int) -> some View {
        let d = monthDate(o)
        let y = cal.component(.year, from: d), m = cal.component(.month, from: d)
        let blk = myBlocks(y, m)
        let first = cal.date(from: DateComponents(year: y, month: m, day: 1))!
        let blanks = cal.component(.weekday, from: first) - 1
        let days = cal.range(of: .day, in: .month, for: first)!.count
        return LazyVGrid(columns: cols, spacing: 3) {
            ForEach(2000..<(2000 + blanks), id: \.self) { _ in Color.clear.frame(height: 52) }   // own id-space — 0…n clashed with day ids 1…n and hid those days
            ForEach(1...days, id: \.self) { dd in
                let iso = String(format: "%04d-%02d-%02d", y, m, dd)
                cell(dd, iso: iso, blocks: blk[dd] ?? [], past: iso < todayISO)
            }
        }
    }

    @ViewBuilder private func cell(_ d: Int, iso: String, blocks: [(UnitKey, Bool)], past: Bool) -> some View {
        let units = availByDay[iso] ?? []
        // squares show on pickup days AND under my own traded shift's block (same-day unit swaps)
        let avail = !units.isEmpty && !past
        let selected = selectedISO == iso, today = iso == todayISO
        VStack(alignment: .leading, spacing: 2) {
            Text("\(d)").font(.system(size: 11, weight: today ? .heavy : .semibold))
                .foregroundStyle(today ? Theme.accent : (past ? Theme.muted.opacity(0.55) : Theme.muted))
            // my shifts: coloured block + unit name — bright on the day I work, lighter (post-call) the morning after
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in unitBlock(b.0, filled: b.1) }
            // available pickups: minimalist small coloured squares (one per distinct unit); tap the day → the shifts
            if avail {
                HStack(spacing: 3) {
                    ForEach(Array(units.prefix(5).enumerated()), id: \.offset) { _, u in
                        RoundedRectangle(cornerRadius: 2).fill(unitColor(u)).frame(width: 9, height: 9)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading).padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.accent : (today ? Theme.accent.opacity(0.55) : Theme.line), lineWidth: selected ? 2 : 1))
        .opacity(past && blocks.isEmpty ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !past && tappable(iso) { onTap(iso) } }
    }

    private func unitBlock(_ u: UnitKey, filled: Bool) -> some View {
        let c = unitColor(u)
        return Text(unitShort(u)).font(.system(size: 9, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
            .foregroundStyle(filled ? .white : c)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 16).padding(.horizontal, 4)
            .background(filled ? c : c.opacity(0.22)).clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Swap screen (opened from More)

struct SwapView: View {
    @EnvironmentObject var model: AppModel
    @State private var selShift: MyShift?
    @State private var myOffset = 0
    @State private var swapOffset = 0
    @State private var selDay: String?
    @State private var tradePart: TradePart = .both      // for a Pasqua day: give both (24h) or one half
    enum TradePart: String, CaseIterable { case both = "24h", rapid = "Rapid", msu = "MSU" }
    @State private var options: [SwapOption] = []
    @State private var loading = false
    @State private var recomputeTask: Task<Void, Never>?
    @State private var requestOpt: SwapOption?
    @State private var pickupOpt: SwapOption?           // "ask to pick up" = one-way hand-off of my shift (diff-day only)
    @State private var filterEmps: Set<Int> = []       // empty = everyone who can work it
    @State private var filterUnits: Set<UnitKey> = []  // empty = all shift types
    @State private var showFilter = false
    @State private var giveAwaySheet = false           // "give away instead" → the give-away wizard for the picked shift
    @State private var didAutoGiveAway = false
    var initialShift: MyShift? = nil                   // when opened from My Shifts, preselect this shift
    var initialGiveAway = false                        // opened via "Give it away" → jump straight into the give-away wizard

    private var todayISO: String { AppModel.todayRegina() }
    private var myAll: [MyShift] { model.shiftLog.isEmpty ? model.myShifts : model.shiftLog }     // for the visual layer
    private var myTradeable: [String: MyShift] {
        var byDay = [String: [MyShift]]()
        for s in model.myShifts where s.slotID != nil && AppModel.notStarted(s.date, s.start) { byDay[s.date, default: []].append(s) }
        return byDay.mapValues { mergeMinePasqua($0) }
    }
    // My Pasqua Rapid+MSU on one day = one 24h "Pasqua" trade; both slots move together (slotID + slotID2).
    private func mergeMinePasqua(_ arr: [MyShift]) -> MyShift {
        if let p = arr.first(where: { $0.unit == .PRR }), let m = arr.first(where: { $0.unit == .MSU }) {
            return MyShift(date: p.date, unit: .PRR, start: p.start, end: m.end, overnight: true,
                           slotID: m.slotID, slotID2: p.slotID, templateID: m.templateID ?? p.templateID)
        }
        return arr.first(where: { $0.overnight }) ?? arr[0]
    }
    // Options after the results filter (default: everyone / all units). Drives the calendar squares AND the list.
    private var filteredOptions: [SwapOption] {
        options.filter { (filterEmps.isEmpty || filterEmps.contains($0.emp))
                       && (filterUnits.isEmpty || filterUnits.contains($0.returnShift.unit)) }
    }
    private var filterActive: Bool { !filterEmps.isEmpty || !filterUnits.isEmpty }
    // Distinct colleagues / units present in the raw results — what the filter sheet offers.
    private var optionEmps: [(emp: Int, name: String)] {
        var seen = Set<Int>(); var out = [(Int, String)]()
        for o in options.sorted(by: { $0.name < $1.name }) where !seen.contains(o.emp) { seen.insert(o.emp); out.append((o.emp, o.name)) }
        return out
    }
    private var optionUnits: [UnitKey] { Array(Set(options.map { $0.returnShift.unit })).sorted { $0.rawValue < $1.rawValue } }

    private var unitsByDay: [String: [UnitKey]] {   // distinct units you could pick up, per day
        var m = [String: [UnitKey]]()
        for o in filteredOptions where !(m[o.returnShift.date]?.contains(o.returnShift.unit) ?? false) {
            m[o.returnShift.date, default: []].append(o.returnShift.unit)
        }
        return m.mapValues { $0.sorted { $0.rawValue < $1.rawValue } }
    }
    private var dayOptions: [SwapOption] { selDay.map { d in filteredOptions.filter { $0.returnShift.date == d } } ?? [] }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height + 40
            if wide {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView { myPane.padding(.vertical, 2) }
                    ScrollView { swapPane.padding(.vertical, 2) }
                }.padding(12)
            } else {
                ScrollView { VStack(spacing: 10) { myPane; swapPane }.padding(12) }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Swap or Give Away").navigationBarTitleDisplayMode(.inline)
        .task {
            await ensureLoaded()
            // Opened via "Give it away" → drop straight into the give-away wizard (within this shared screen).
            if initialGiveAway, !didAutoGiveAway, selShift != nil { didAutoGiveAway = true; giveAwaySheet = true }
        }
        .sheet(item: $requestOpt) { o in if let s = selShift { SwapRequestSheet(shift: s, option: o).environmentObject(model) } }
        .sheet(item: $pickupOpt) { o in if let s = selShift { SwapRequestSheet(shift: s, option: o, pickup: true).environmentObject(model) } }
        .sheet(isPresented: $showFilter) { filterSheet }
        .sheet(isPresented: $giveAwaySheet) {
            if let s = selShift {
                let p = pasquaHalves(s.date)
                GiveAwayWizard(shift: p?.rapid ?? s, pasqua: p).environmentObject(model)
            }
        }
    }

    // One tidy row: give the picked shift away instead (→ wizard, same shift + Pasqua split), with the results
    // Filter beside it. A slim second line shows the count + Clear only while a filter is active.
    private var actionRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { giveAwaySheet = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill").font(.caption)
                        Text("Give away instead").font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.10)))
                }
                Button { showFilter = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: filterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        Text(filterActive ? "Filtered" : "Filter").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(filterActive ? .white : Theme.accent)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(filterActive ? Theme.accent : Theme.accent.opacity(0.12)))
                }
                .fixedSize()
            }
            if filterActive {
                HStack(spacing: 8) {
                    Spacer()
                    Text("\(filteredOptions.count) of \(options.count)").font(.caption).foregroundStyle(Theme.muted)
                    Button { filterEmps = []; filterUnits = [] } label: { Text("Clear").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent) }
                }
            }
        }
    }

    // Two-section sheet: pick specific colleagues and/or specific units (empty = all). Only what's actually in
    // the results is offered, so you can't filter to something that has no swaps.
    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section("Shift types") {
                    ForEach(optionUnits, id: \.self) { u in
                        Button { toggle(&filterUnits, u) } label: {
                            HStack {
                                Text(unitShort(u)).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(unitColor(u).opacity(0.16)).foregroundStyle(unitColor(u)).clipShape(Capsule())
                                Spacer()
                                if filterUnits.contains(u) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }.foregroundStyle(.primary)
                    }
                }
                Section("Colleagues") {
                    ForEach(optionEmps, id: \.emp) { c in
                        Button { toggle(&filterEmps, c.emp) } label: {
                            HStack {
                                Text(c.name)
                                Spacer()
                                if filterEmps.contains(c.emp) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }.foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Filter swaps").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Clear") { filterEmps = []; filterUnits = [] } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showFilter = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }
    private func toggle<T: Hashable>(_ set: inout Set<T>, _ v: T) { if set.contains(v) { set.remove(v) } else { set.insert(v) } }

    private var myPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1 · Your shifts — tap one to trade").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
            SwapCalendar(offset: $myOffset, months: 13, myShifts: myAll, availByDay: [:],
                         selectedISO: selShift?.date, tappable: { myTradeable[$0] != nil }) { iso in
                if let s = myTradeable[iso] { selShift = s; tradePart = .both; selDay = nil; swapOffset = 0; filterEmps = []; filterUnits = []; recompute() }
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }

    private var swapPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("2 · Available swaps").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
            if let s = selShift {
                tradebar(s)
                actionRow
                SwapCalendar(offset: $swapOffset, months: 13, myShifts: myAll, availByDay: unitsByDay,
                             selectedISO: selDay, tappable: { !(unitsByDay[$0] ?? []).isEmpty }) { iso in selDay = iso }
                Text("Coloured blocks = your shifts · small squares = units you could swap into (tap a day to see who)").font(.caption2).foregroundStyle(Theme.muted)
                detail
            } else {
                Text("Pick one of your shifts above, then swipe the months for who you could swap with.")
                    .font(.callout).foregroundStyle(Theme.muted).padding(.vertical, 8)
            }
            // 🥚 for the man with the idea
            Text("Robin's idea 🤝")
                .font(.system(size: 10)).foregroundStyle(Theme.muted.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .center).padding(.top, 8)
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }

    // The Pasqua Rapid+MSU halves I work on a day (both have slotIDs), if any — enables giving one half away.
    private func pasquaHalves(_ date: String) -> (rapid: MyShift, msu: MyShift)? {
        let day = model.myShifts.filter { $0.date == date && $0.slotID != nil }
        guard let r = day.first(where: { $0.unit == .PRR }), let m = day.first(where: { $0.unit == .MSU }) else { return nil }
        return (r, m)
    }

    private func tradebar(_ s: MyShift) -> some View {
        let halves = pasquaHalves(s.date)   // clickable only on a Pasqua day
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(unitColor(s.unit)).frame(width: 4, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Trading away").font(.caption2).foregroundStyle(Theme.muted)
                    Text("\(tradeLabel(s)) · \(swapPretty(s.date))").font(.subheadline.bold())
                }
                Spacer(); if loading { ProgressView() }
            }
            if let h = halves {
                Picker("", selection: $tradePart) {
                    ForEach(TradePart.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: tradePart) { _, part in
                    switch part {
                    case .both:  selShift = mergeMinePasqua([h.rapid, h.msu])
                    case .rapid: selShift = h.rapid
                    case .msu:   selShift = h.msu
                    }
                    selDay = nil; swapOffset = 0; filterEmps = []; filterUnits = []; recompute()
                }
            }
        }
        .padding(9).background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.10)))
    }
    // "Pasqua 24h" for the combined shift; the unit's short name otherwise.
    private func tradeLabel(_ s: MyShift) -> String { (s.unit == .PRR && s.overnight) ? "Pasqua 24h" : unitShort(s.unit) }
    // Generic group feeler (candidates each have a different return shift, so no specific reciprocal here).
    private func feelerMessage(_ s: MyShift) -> String {
        "Hi — I'm looking to move my \(tradeLabel(s)) on \(swapPretty(s.date)). Any of you keen to swap or take it? Let me know, thanks!"
    }

    @ViewBuilder private var detail: some View {
        if let day = selDay, !dayOptions.isEmpty {
            let sameDay = day == selShift?.date
            let cells = dayOptions.compactMap { o in o.cell.flatMap { $0.isEmpty ? nil : $0 } }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(sameDay ? "Same day · swap units — \(dayOptions.count)"
                                 : "\(swapPretty(day)) — \(dayOptions.count) you could take")
                        .font(.subheadline.bold())
                    Spacer()
                    if cells.count > 1, let s = selShift {
                        Button { openGroupText(feelerMessage(s), cells: cells) } label: {
                            Label("Text all", systemImage: "bubble.left.and.bubble.right.fill").font(.caption2)
                        }.buttonStyle(.bordered).controlSize(.mini)
                    }
                }.padding(.top, 2)
                ForEach(dayOptions) { optionRow($0) }
            }
        } else if !options.isEmpty {
            Text("Tap a day with a teal number to see who's working it.").font(.footnote).foregroundStyle(Theme.muted).padding(.top, 4)
        } else if loading {
            HStack(spacing: 8) { ProgressView(); Text("Loading roster…").font(.footnote).foregroundStyle(Theme.muted) }.padding(.top, 4)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No one can swap this shift right now. If the whole app looks empty, your Lightning Bolt session may have expired — sign out and back in (More → About area) and retry.")
                    .font(.footnote).foregroundStyle(Theme.muted)
                Button { recompute() } label: { Label("Reload", systemImage: "arrow.clockwise") }.buttonStyle(.bordered).controlSize(.small)
            }.padding(.top, 4)
        }
    }

    private func optionRow(_ o: SwapOption) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(unitShort(o.returnShift.unit)).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(unitColor(o.returnShift.unit).opacity(0.16)).foregroundStyle(unitColor(o.returnShift.unit)).clipShape(Capsule())
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) { Text(o.name).font(.subheadline.bold()); SwapStatusChip(status: o.statusOnMyDate) }
                    Text("\(o.returnShift.start)–\(o.returnShift.end)\(o.returnShift.overnight ? " (+1)" : "")").font(.caption2).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                if let cell = o.cell, !cell.isEmpty, let s = selShift {
                    Button { openSwapText(swapMessage(mineUnit: s.unit, mineDate: s.date, opt: o), cell: cell) } label: {
                        Label("Text", systemImage: "message.fill") }.buttonStyle(.bordered).controlSize(.small)
                }
                Button { requestOpt = o } label: { Label("Ask to swap", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                // One-way hand-off: only for a DIFFERENT day (a same-day colleague is already working, so they
                // can't also pick up my same-day shift — only swap units).
                if o.returnShift.date != selShift?.date {
                    Button { pickupOpt = o } label: { Label("Ask to pickup", systemImage: "hand.raised.fill") }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(10).background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }

    private func ensureLoaded() async {
        loading = true
        if selShift == nil, let want = initialShift { selShift = myTradeable[want.date] ?? want }  // opened from My Shifts
        await model.loadDirectory()
        if model.whoData.isEmpty { await model.loadGroupHistory(force: true) }
        // Stale-session guard: the ~1h token can expire leaving the group data OLD (not empty) — e.g. it doesn't
        // cover my selected shift's date, so no candidates match. Detect that (nobody, not even me, recorded on my
        // own shift's day = the data is stale) and force a re-capture + reload, so swaps appear without a manual
        // sign-out/in. (loadGroupHistory itself now refresh()+retries on an empty fetch.)
        let stale = selShift.map { (model.whoByDay[$0.date]?.isEmpty ?? true) } ?? false
        if !model.demo, model.loggedIn, (model.whoData.isEmpty || model.roster.isEmpty || stale) {
            await model.refresh()
            await model.loadDirectory()
            await model.loadGroupHistory(force: true)
        }
        if Task.isCancelled { return }                   // a newer recompute superseded this one
        if let s = selShift { options = model.swapOptions(for: s) }
        loading = false
    }
    private func recompute() {
        recomputeTask?.cancel()                          // don't let an older, slower pass overwrite a newer result
        loading = true
        recomputeTask = Task { await ensureLoaded() }
    }
}

// MARK: - In-app swap request

struct SwapRequestSheet: View {
    let shift: MyShift
    let option: SwapOption
    let pickup: Bool          // true = one-way "please take my shift" (no reciprocal); false = mutual swap
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    @State private var sending = false
    @State private var result: String?
    @State private var ok = false
    @State private var confirming = false     // swap: confirm exactly what moves before sending

    init(shift: MyShift, option: SwapOption, pickup: Bool = false) {
        self.shift = shift; self.option = option; self.pickup = pickup
        let n = pickup
            ? "Could you pick up my \(unitShort(shift.unit)) on \(swapPretty(shift.date))? Thanks!"
            : "Swap? I'll take your \(unitShort(option.returnShift.unit)) on \(swapPretty(option.returnShift.date)) if you take my \(unitShort(shift.unit)) on \(swapPretty(shift.date))."
        _note = State(initialValue: n)
    }

    private var pickupText: String { "Hi \(option.firstName), could you pick up my \(unitShort(shift.unit)) on \(swapPretty(shift.date))? Thanks!" }

    var body: some View {
        NavigationStack {
            Form {
                Section(pickup ? "Ask \(option.name) to pick up" : "Ask \(option.name) to swap") {
                    Text(pickup
                         ? "They'd take your \(unitShort(shift.unit)) on \(swapPretty(shift.date)). You don't take one of theirs."
                         : "You'd take their \(unitShort(option.returnShift.unit)) on \(swapPretty(option.returnShift.date)); they'd take your \(unitShort(shift.unit)) on \(swapPretty(shift.date)).")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Note", text: $note, axis: .vertical).lineLimit(2...5)
                }
                if let cell = option.cell, !cell.isEmpty {
                    Section { Button { openSwapText(pickup ? pickupText : swapMessage(mineUnit: shift.unit, mineDate: shift.date, opt: option), cell: cell) }
                        label: { Label("Text \(option.firstName) instead", systemImage: "message") } }
                }
                if let result { Section { Text(result).font(.callout).foregroundStyle(ok ? .green : .red) } }
                Section {
                    Button { if pickup { send() } else { confirming = true } } label: {
                        HStack { if sending { ProgressView() }; Text(ok ? "Sent" : (pickup ? "Send pickup request" : "Send swap request")).frame(maxWidth: .infinity) }
                    }.buttonStyle(.borderedProminent).disabled(sending || ok || note.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    if !pickup { Text("They get your shift offered with this note. If they accept in Working-Bolt, their shift comes straight back to you — one tap in the Pool takes it.") }
                }
            }
            .confirmationDialog("Send this swap?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Send swap request") { sendSwap() }
                Button("Not yet", role: .cancel) {}
            } message: {
                Text("Your \(unitShort(shift.unit)) on \(swapPretty(shift.date)) for \(option.name)'s \(unitShort(option.returnShift.unit)) on \(swapPretty(option.returnShift.date)). When \(option.firstName) accepts and sends theirs back, their \(unitShort(option.returnShift.unit)) on \(swapPretty(option.returnShift.date)) comes back to you to take in one tap.")
            }
            .navigationTitle(pickup ? "Pickup request" : "Swap request").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ok ? "Done" : "Cancel") { dismiss() } } }
        }
    }
    private func sendSwap() {
        sending = true; result = nil
        Task {
            let out = await model.requestSwap(mine: shift, theirs: option.returnShift, toEmp: option.emp, note: note)
            sending = false; ok = out.ok
            result = out.ok ? "✅ Swap sent to \(option.name). When they accept, theirs comes back to you — take it from the Pool."
                            : (out.message ?? "Couldn't send the swap — pull to refresh and try again.")
        }
    }
    private func send() {
        sending = true; result = nil
        Task {
            let out = await model.giveAway(shift: shift, toEmp: option.emp, note: note, reason: nil)
            sending = false; ok = out.ok
            result = out.ok ? "✅ Sent to \(option.name). They'll see your shift offered with the note."
                            : (out.message ?? "Couldn't send — pull to refresh and try again.")
        }
    }
}
