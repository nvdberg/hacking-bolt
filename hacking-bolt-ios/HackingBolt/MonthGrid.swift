import SwiftUI

// Port of the web My-Shifts calendar (stage2/site/calendar.html): a month grid with coloured shift
// blocks, and 24h/overnight calls fusing into a lighter "post-call" block the next morning.

private let DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

private struct Blk: Identifiable { let id: Int; let kind: Int; let unit: UnitKey? } // kind 0 spacer, 1 call, 2 pc
private struct DayD: Identifiable { let id: Int; let iso: String; let today: Bool; let past: Bool
    let fuseCall: Set<Int>; let fuseEndPC: Bool; let blocks: [Blk] }
private struct MonthD: Identifiable { let id: String; let title: String; let stat: String; let breakdown: String
    let leading: Int; let cells: [DayD] }

struct RosterCalendar: View {
    let shifts: [MyShift]
    let userName: String
    var landscape: Bool = false          // bigger type + roomier cells when the phone's on its side
    var scrollTick: Int = 0              // bump to re-center on the current month ("This Month" / tapping the tab)
    var jumpToYM: String = ""            // set by the year-month picker → scroll to that month
    var openDates: Set<String> = []      // dates with an open shift in the pool → subtle amber corner marker
    var onOpenTap: (String) -> Void = { _ in }   // tapping a marked day → jump to that shift in the Pool
    var onRefresh: () async -> Void = {}
    @State private var didInitialScroll = false
    @State private var months: [MonthD] = []     // cached build() output — rebuilt only when the shift log changes
    @State private var subtitle = ""
    @State private var builtSig = ""

    // Cheap signature of the inputs that affect the built month model (NOT landscape — that's metrics only).
    // Content-sensitive signature: catches in-place changes too (e.g. a swap that keeps the same date but
    // changes the unit), which a count/first/last-only signature would miss and leave the calendar stale.
    private var sig: String {
        var h = Hasher(); h.combine(shifts.count); h.combine(userName)
        for s in shifts { h.combine(s.date); h.combine(s.unit); h.combine(s.start); h.combine(s.end) }
        return "\(h.finalize())"
    }

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)

    // Landscape gets larger metrics (glasses-friendly); portrait keeps the compact grid.
    private var blockH: CGFloat  { landscape ? 27 : 20 }
    private var cellMinH: CGFloat { landscape ? 86 : 62 }
    private var daySize: CGFloat  { landscape ? 13 : 10 }
    private var blkSize: CGFloat  { landscape ? 12.5 : 9 }
    private var dowSize: CGFloat  { landscape ? 12 : 9 }

    var body: some View {
        let curYM = String(AppModel.todayRegina().prefix(7))
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(subtitle).font(.caption).foregroundStyle(Theme.muted).padding(.horizontal, 2)
                    ForEach(months) { m in monthSection(m).id(m.id) }
                    Text("24h calls run 08:00 → 08:00; the faint block next morning is post-call.  ⚡ Working-Bolt")
                        .font(.caption2).foregroundStyle(Theme.muted).padding(.top, 4).padding(.horizontal, 2)
                }
                .padding(14)
            }
            .background(Theme.bg.ignoresSafeArea())
            .refreshable { await onRefresh() }
            .onAppear {
                rebuildIfNeeded()
                if !didInitialScroll { didInitialScroll = true; jump(proxy, curYM) }
            }
            .onChange(of: sig) { _, _ in rebuildIfNeeded() }
            .onChange(of: scrollTick) { _, _ in jump(proxy, curYM) }
            .onChange(of: jumpToYM) { _, ym in jumpTo(proxy, ym) }
        }
    }

    // Rebuild the month model only when the shift log actually changed — keeps switching to My Shifts snappy
    // (build() no longer runs on every render / tab switch, only when the data behind it moves).
    private func rebuildIfNeeded() {
        guard builtSig != sig else { return }
        let d = build()
        months = d.months; subtitle = d.subtitle; builtSig = sig
    }

    // Center the current month in view (first open + "This Month" + tapping the My Shifts tab).
    private func jump(_ proxy: ScrollViewProxy, _ ym: String) {
        let target = months.contains(where: { $0.id == ym }) ? ym : months.last?.id
        guard let t = target else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(t, anchor: .center) }
        }
    }

    // Jump to a specific month chosen from the year-month picker (anchored near the top).
    private func jumpTo(_ proxy: ScrollViewProxy, _ ym: String) {
        guard !ym.isEmpty, months.contains(where: { $0.id == ym }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(ym, anchor: .top) }
        }
    }

    // MARK: sections

    @ViewBuilder private func legend(_ present: [UnitKey]) -> some View {
        if !present.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 6) {
                ForEach(present, id: \.self) { k in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Units.info[k]?.color ?? .gray).frame(width: 11, height: 11)
                        Text("\(Units.info[k]?.short ?? k.rawValue)").font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(12).background(Theme.panel).clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        }
    }

    @ViewBuilder private func monthSection(_ m: MonthD) -> some View {
        // Arrange into fixed week-rows (leading pads + days, padded to whole weeks). A non-lazy VStack of
        // HStacks measures its height exactly — unlike LazyVGrid, whose lazy height estimate drifts and makes
        // successive months creep together and eventually overlap.
        let slots: [DayD?] = Array(repeating: nil, count: m.leading) + m.cells.map { Optional($0) }
        let padded = slots + Array(repeating: nil, count: (7 - slots.count % 7) % 7)
        let weeks = stride(from: 0, to: padded.count, by: 7).map { Array(padded[$0..<$0 + 7]) }
        return VStack(alignment: .leading, spacing: 3) {
            Text(m.title).font(.headline).foregroundStyle(Theme.ink)
            HStack(alignment: .firstTextBaseline) {
                Text(m.stat).font(.caption).foregroundStyle(Theme.muted)
                Spacer()
                if !m.breakdown.isEmpty {
                    Text(m.breakdown).font(.caption2.weight(.medium)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.bottom, 4)
            HStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { i in
                    Text(DOW[i].prefix(1)).font(.system(size: dowSize, weight: .semibold))
                        .foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
                }
            }
            ForEach(weeks.indices, id: \.self) { wi in
                HStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { di in
                        if let d = weeks[wi][di] { cell(d) }
                        else { Color.clear.frame(maxWidth: .infinity, minHeight: cellMinH) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ d: DayD) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(d.id)").font(.system(size: daySize, weight: d.today ? .heavy : .semibold))
                .foregroundStyle(d.today ? Theme.accent : (d.past ? Theme.muted.opacity(0.6) : Theme.muted))
            ForEach(d.blocks) { b in block(b, day: d) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: cellMinH, alignment: .topLeading)
        .padding(4)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(d.today ? Theme.accent : Theme.line, lineWidth: d.today ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // Subtle amber marker (same look as the mini-calendar) on days that have an open shift in the pool.
        // Sits bottom-right, in the empty space below the shift blocks, so it never crowds them.
        .overlay(alignment: .bottomTrailing) {
            if openDates.contains(d.iso) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Theme.available, lineWidth: 1.6)
                    .frame(width: landscape ? 13 : 10, height: landscape ? 13 : 10)
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if openDates.contains(d.iso) { onOpenTap(d.iso) } }   // → jump to that shift in the Pool
        // (past days: the shift blocks themselves are lightened in block(); the grid stays crisp)
    }

    @ViewBuilder private func block(_ b: Blk, day d: DayD) -> some View {
        if b.kind == 0 {
            Color.clear.frame(height: blockH)
        } else if let u = b.unit, let info = Units.info[u] {
            let isCall = b.kind == 1
            let fuse = isCall ? d.fuseCall.contains(b.id) : d.fuseEndPC
            Text(info.short)
                .font(.system(size: blkSize, weight: .bold)).lineLimit(2).minimumScaleFactor(0.6)
                .foregroundStyle(isCall ? .white : info.color)
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: blockH)
                .padding(.horizontal, 5)
                .background(isCall ? info.color : info.color.opacity(0.24))
                .clipShape(corners(isCall: isCall, fuse: fuse))
                .opacity(d.past ? 0.5 : 1)                                // completed shifts sit a touch lighter
                .padding(isCall ? .trailing : .leading, fuse ? -9 : 0)   // bleed to bridge the day gap
                .zIndex(isCall ? 1 : 0)
        }
    }

    private func corners(isCall: Bool, fuse: Bool) -> UnevenRoundedRectangle {
        guard fuse else { return UnevenRoundedRectangle(cornerRadii: .init(topLeading: 6, bottomLeading: 6, bottomTrailing: 6, topTrailing: 6)) }
        return isCall
            ? UnevenRoundedRectangle(cornerRadii: .init(topLeading: 6, bottomLeading: 6, bottomTrailing: 0, topTrailing: 0))   // cont-start
            : UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 6, topTrailing: 6))   // cont-end
    }

    // MARK: build

    private func build() -> (months: [MonthD], present: [UnitKey], subtitle: String) {
        let clinical = shifts.filter { Units.info[$0.unit] != nil }
        guard !clinical.isEmpty else { return ([], [], userName.isEmpty ? "My roster" : userName) }

        var byDate: [String: [MyShift]] = Dictionary(grouping: clinical) { $0.date }
        for k in byDate.keys { byDate[k]?.sort { ConflictEngine.toMin($0.start) < ConflictEngine.toMin($1.start) } }
        let dates = byDate.keys.sorted()

        // post-call map (day after an overnight), with srcIndex so it aligns with its source row
        var postcall: [String: (unit: UnitKey, srcIndex: Int)] = [:]
        for d in dates {
            let top = postcall[d].map { $0.srcIndex + 1 } ?? 0
            for (i, s) in (byDate[d] ?? []).enumerated() where s.overnight {
                postcall[ConflictEngine.addDay(d)] = (s.unit, top + i)
            }
        }

        let present = ["MICU", "SICU", "CCU", "PHICU", "RR", "PRR", "MSU"]
            .compactMap { UnitKey(rawValue: $0) }
            .filter { k in clinical.contains { $0.unit == k } }

        let today = AppModel.todayRegina()
        let first = dates.first!, last = dates.last!
        // Guard the string→Int parsing so a single malformed cached date can't crash the My Shifts tab.
        guard let fy = Int(first.prefix(4)), let fm = Int(first.dropFirst(5).prefix(2)),
              let ly = Int(last.prefix(4)), let lmRaw = Int(last.dropFirst(5).prefix(2)) else {
            return ([], present, userName.isEmpty ? "My roster" : userName)
        }
        var months: [MonthD] = []
        var y = fy, m0 = fm - 1
        let lm0 = lmRaw - 1

        while y < ly || (y == ly && m0 <= lm0) {
            let cal = Calendar(identifier: .gregorian)
            var c = DateComponents(); c.year = y; c.month = m0 + 1; c.day = 1
            guard let firstDate = cal.date(from: c), let range = cal.range(of: .day, in: .month, for: firstDate) else {
                m0 += 1; if m0 > 11 { m0 = 0; y += 1 }; continue
            }
            let leading = cal.component(.weekday, from: firstDate) - 1
            let days = range.count
            let ym = String(format: "%04d-%02d", y, m0 + 1)

            var cells: [DayD] = []
            for dd in 1...days {
                let iso = String(format: "%@-%02d", ym, dd)
                var wc = DateComponents(); wc.year = y; wc.month = m0 + 1; wc.day = dd
                let dow = cal.component(.weekday, from: cal.date(from: wc)!) - 1
                var blocks: [Blk] = []; var bid = 0
                var fuseCall: Set<Int> = []; var fuseEndPC = false
                if let pc = postcall[iso] {
                    for _ in 0..<pc.srcIndex { blocks.append(Blk(id: bid, kind: 0, unit: nil)); bid += 1 }
                    fuseEndPC = dow > 0
                    blocks.append(Blk(id: bid, kind: 2, unit: pc.unit)); bid += 1
                }
                for s in (byDate[iso] ?? []) {
                    if s.overnight && dow < 6 { fuseCall.insert(bid) }
                    blocks.append(Blk(id: bid, kind: 1, unit: s.unit)); bid += 1
                }
                cells.append(DayD(id: dd, iso: iso, today: iso == today, past: iso < today,
                                  fuseCall: fuseCall, fuseEndPC: fuseEndPC, blocks: blocks))
            }

            let mShifts = clinical.filter { $0.date.hasPrefix(ym) }
            let st = monthStats(mShifts)
            let title = monthTitle(y: y, m0: m0)
            months.append(MonthD(id: ym, title: title,
                                 stat: "\(st.shifts) shift\(st.shifts == 1 ? "" : "s") · \(Int(st.hours.rounded())) h",
                                 breakdown: breakdown(st), leading: leading, cells: cells))
            m0 += 1; if m0 > 11 { m0 = 0; y += 1 }
        }

        let name = userName.isEmpty ? "My roster" : userName
        let sub = "\(name) · through \(monthTitle(y: ly, m0: lm0))"
        return (months, present, sub)
    }

    // stats (same spec as the list view)
    private struct RS { var shifts = 0; var hours = 0.0; var full24 = 0; var rr9 = 0; var msu = 0; var half = 0 }
    private func hrs(_ s: MyShift) -> Double {
        let iv = ConflictEngine.interval(s.date, s.start, s.end, overnight: s.overnight); return Double(iv.e - iv.s) / 60.0
    }
    private func std(_ k: UnitKey) -> Double { switch k { case .RR, .PRR: return 9; case .MSU: return 15; default: return 24 } }
    private func monthStats(_ shifts: [MyShift]) -> RS {
        var st = RS()
        let byDate = Dictionary(grouping: shifts) { $0.date }
        var consumed = Set<UUID>(); var combos = 0
        for (_, day) in byDate {
            if let p = day.first(where: { $0.unit == .PRR }), let m = day.first(where: { $0.unit == .MSU }) {
                combos += 1; consumed.insert(p.id); consumed.insert(m.id)
            }
        }
        st.full24 += combos
        for s in shifts {
            st.hours += hrs(s)
            if consumed.contains(s.id) { continue }
            if hrs(s) < std(s.unit) - 1.0 { st.half += 1; continue }
            switch s.unit {
            case .MICU, .SICU, .CCU, .PHICU: st.full24 += 1
            case .RR, .PRR: st.rr9 += 1
            case .MSU: st.msu += 1
            }
        }
        st.shifts = shifts.count - combos
        return st
    }
    private func breakdown(_ st: RS) -> String {
        var p: [String] = []
        if st.full24 > 0 { p.append("24h ×\(st.full24)") }
        if st.rr9 > 0    { p.append("9h ×\(st.rr9)") }
        if st.msu > 0    { p.append("15h ×\(st.msu)") }
        if st.half > 0   { p.append("half ×\(st.half)") }
        return p.joined(separator: "    ")
    }
    private func monthTitle(y: Int, m0: Int) -> String {
        let names = ["January","February","March","April","May","June","July","August","September","October","November","December"]
        return "\(names[max(0, min(11, m0))]) \(y)"
    }
}
