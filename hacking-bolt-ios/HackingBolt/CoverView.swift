import SwiftUI

// MARK: - Who could cover? (OWNER ONLY — logistics; never in the Guide or Android)
//
// Long-press anyone's upcoming shift in Who's On → everyone who could legally work it, ranked by how likely
// they are to say yes. Same rest rules as the give-away picker (not working that day, not post/pre-call,
// free the next day for an overnight, SICU only if they've done SICU), then scored on:
//   • pickups in the last year (the strongest "says yes" signal — from the owner's swap log)
//   • a light week around the date (fewer shifts ±3 days)
//   • a lighter month than their usual
//   • worked this unit in the last year
//   • not working the day right before/after

struct CoverCandidate: Identifiable {
    let emp: Int
    let name: String
    let score: Double
    let chips: [(text: String, good: Bool)]
    var id: Int { emp }
    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

struct CoverResult {
    var ranked: [CoverCandidate] = []          // free + rest rules OK, best first
    var timeOff: [(name: String, label: String)] = []   // a time-off entry that day (could still be asked)
    var blocked: [(name: String, why: String)] = []      // can't legally take it
}

extension AppModel {
    func coverCandidates(for a: Assignment) -> CoverResult {
        let d = a.date, today = Self.todayRegina()
        let yearAgo = Self.addDays(today, -365)
        let busy     = Dictionary((whoByDay[d] ?? []).map { ($0.doc, $0.unit) }, uniquingKeysWith: { f, _ in f })
        let postCall = Set((whoByDay[Self.addDays(d, -1)] ?? []).filter { $0.overnight }.map { $0.doc })
        let preCall  = Set((whoByDay[Self.addDays(d,  1)] ?? []).filter { $0.overnight }.map { $0.doc })
        let nextDay  = Set((whoByDay[Self.addDays(d,  1)] ?? []).map { $0.doc })
        let prevDay  = Set((whoByDay[Self.addDays(d, -1)] ?? []).map { $0.doc })
        let sicuDocs = sicuDoctors(before: today)
        let off = offByDay[d] ?? [:]

        // One pass over the last year (+ the future roster): per-doc dates, unit counts, monthly counts.
        var dates = [String: Set<String>](), unitN = [String: Int](), months = [String: [String: Int]]()
        for x in whoData where x.date >= yearAgo {
            dates[x.doc, default: []].insert(x.date)
            if x.unit == a.unit && x.date < today { unitN[x.doc, default: 0] += 1 }
            months[x.doc, default: [:]][String(x.date.prefix(7)), default: 0] += 1
        }
        var pickups = [String: Int]()
        for e in swapLog where e.isPickup && e.date >= yearAgo { pickups[e.to, default: 0] += 1 }
        let week = Set((-3...3).filter { $0 != 0 }.map { Self.addDays(d, $0) })
        let month = String(d.prefix(7)), thisMonth = String(today.prefix(7))
        let unitName = Units.info[a.unit]?.short ?? a.unit.rawValue

        var out = CoverResult()
        for c in colleagues where c.name != a.doc {
            if let u = busy[c.name] { out.blocked.append((c.name, "Working \(Units.info[u]?.short ?? u.rawValue) that day")); continue }
            if postCall.contains(c.name) { out.blocked.append((c.name, "Post-call")); continue }
            if preCall.contains(c.name) { out.blocked.append((c.name, "On call the next day")); continue }
            if a.overnight && nextDay.contains(c.name) { out.blocked.append((c.name, "Works the next morning")); continue }
            if a.unit == .SICU && !sicuDocs.contains(c.name) { out.blocked.append((c.name, "Hasn't done SICU")); continue }
            if let label = off[c.name] { out.timeOff.append((c.name, label)); continue }

            var score = 0.0, chips = [(text: String, good: Bool)]()
            let p = pickups[c.name] ?? 0
            if p > 0 { score += min(Double(p), 5) * 2.5; chips.append(("\(p) pickup\(p == 1 ? "" : "s") this year", true)) }
            let wk = (dates[c.name] ?? []).intersection(week).count
            score -= Double(wk) * 1.5
            chips.append(wk == 0 ? ("Free that week", true) : ("\(wk) shift\(wk == 1 ? "" : "s") that week", wk <= 1))
            // Their usual month = average over past months they worked (needs 3+ to mean anything).
            let past = (months[c.name] ?? [:]).filter { $0.key < thisMonth && $0.key != month }
            if past.count >= 3 {
                let avg = Double(past.values.reduce(0, +)) / Double(past.count)
                let now = Double(months[c.name]?[month] ?? 0)
                let gap = avg - now
                score += max(-4, min(4, gap))
                if gap >= 1.5 { chips.append(("Light month (\(Int(now)) vs ~\(Int(avg.rounded())))", true)) }
                else if gap <= -1.5 { chips.append(("Busy month (\(Int(now)) vs ~\(Int(avg.rounded())))", false)) }
            }
            let un = unitN[c.name] ?? 0
            if un == 0 { score -= 3; chips.append(("No \(unitName) this year", false)) } else { score += min(Double(un), 10) * 0.3 }
            if prevDay.contains(c.name) || nextDay.contains(c.name) { score -= 1; chips.append(("Works the day before/after", false)) }
            out.ranked.append(CoverCandidate(emp: c.emp, name: c.name, score: score, chips: chips))
        }
        out.ranked.sort { $0.score == $1.score ? $0.name < $1.name : $0.score > $1.score }
        out.timeOff.sort { $0.name < $1.name }
        out.blocked.sort { $0.name < $1.name }
        return out
    }
}

struct CoverView: View {
    let shift: Assignment
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var result = CoverResult()
    @State private var showBlocked = false
    @State private var loading = true

    private var unit: UnitInfo { Units.info[shift.unit] ?? UnitInfo(short: shift.unit.rawValue, full: "", color: .gray) }
    private var when: String { "\(unit.short) \(shift.start)–\(shift.end) on \(swapPretty(shift.date))" }
    private func cell(_ emp: Int) -> String? { let c = model.directory[emp]?.cell; return (c?.isEmpty ?? true) ? nil : c }
    private func ask(_ first: String?) -> String {
        "Hi\(first.map { " \($0)" } ?? ""), would you be able to work \(when)? Let me know, thanks!"
    }
    // Top third = likely, middle = possible, rest = long shot (relative, so it adapts to the day).
    // A low score caps the tier, so a lone candidate with a full week doesn't read "Likely".
    private func tier(_ i: Int) -> (String, Color) {
        let n = max(result.ranked.count, 1), score = result.ranked[i].score
        if i < (n + 2) / 3 && score >= -2 { return ("Likely", .green) }
        if i < (2 * n + 2) / 3 && score >= -6 { return ("Possible", .orange) }
        return ("Long shot", Theme.muted)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 5).fill(unit.color).frame(width: 5, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(unit.short) · \(fmt(shift.date, "EEE, MMM d"))").font(.headline)
                            Text("\(shift.start)–\(shift.end)\(shift.overnight ? " (+1)" : "") · now \(shift.doc)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    if loading && result.ranked.isEmpty {
                        HStack(spacing: 8) { ProgressView(); Text("Loading the group roster…").foregroundStyle(.secondary) }
                    } else if result.ranked.isEmpty {
                        Text("No one is free to work this under the rest rules.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(result.ranked.enumerated()), id: \.element.id) { i, c in row(i, c) }
                } header: {
                    Text("Free to work it — most likely first (\(result.ranked.count))")
                } footer: {
                    let top = result.ranked.prefix(5).compactMap { cell($0.emp) }
                    if top.count > 1 {
                        Button { openGroupText(ask(nil), cells: top) } label: {
                            Label("Text the top \(top.count)", systemImage: "bubble.left.and.bubble.right.fill").font(.footnote.weight(.semibold))
                        }.padding(.top, 6)
                    }
                }
                if !result.timeOff.isEmpty {
                    Section("Time off that day") {
                        ForEach(result.timeOff, id: \.name) { t in
                            HStack { Text(t.name); Spacer(); Text(t.label).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                    }
                }
                if !result.blocked.isEmpty {
                    Section {
                        DisclosureGroup("Can't take it (\(result.blocked.count))", isExpanded: $showBlocked) {
                            ForEach(result.blocked, id: \.name) { b in
                                HStack { Text(b.name).foregroundStyle(.secondary); Spacer(); Text(b.why).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Who could cover?").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                result = model.coverCandidates(for: shift)
                // The colleague roster isn't kept on the phone — it only fills from the group fetch. Opened before
                // that ran, the list was empty and read "No one is free". Load it first (as Give away does).
                if model.colleagues.isEmpty { await model.loadGroupHistory() }
                result = model.coverCandidates(for: shift)
                loading = false
                await model.loadDirectory()                 // for the text buttons (cached a day)
            }
            // Group data / roster landing later (a refresh already in flight) → re-rank.
            .onChange(of: model.groupVersion) { _, _ in result = model.coverCandidates(for: shift) }
            .onChange(of: model.rosterVersion) { _, _ in result = model.coverCandidates(for: shift) }
        }
    }

    private func row(_ i: Int, _ c: CoverCandidate) -> some View {
        let t = tier(i)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("\(i + 1)").font(.caption.bold().monospacedDigit()).foregroundStyle(Theme.muted).frame(width: 18, alignment: .trailing)
                Text(c.name).font(.subheadline.weight(.semibold))
                Text(t.0).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(t.1.opacity(0.16)).foregroundStyle(t.1).clipShape(Capsule())
                Spacer()
                if let cell = cell(c.emp) {
                    Button { openSwapText(ask(c.firstName), cell: cell) } label: { Image(systemName: "message.fill").foregroundStyle(Theme.accent) }
                        .buttonStyle(.borderless)
                }
            }
            FlowChips(chips: c.chips).padding(.leading, 26)
        }
        .padding(.vertical, 2)
    }
}

/// Wrapping row of small good/bad reason chips.
private struct FlowChips: View {
    let chips: [(text: String, good: Bool)]
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { items }
            VStack(alignment: .leading, spacing: 4) { items }
        }
    }
    @ViewBuilder private var items: some View {
        ForEach(chips.indices, id: \.self) { i in
            let c = chips[i]
            Text(c.text).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                .background((c.good ? Color.green : Color.orange).opacity(0.13))
                .foregroundStyle(c.good ? Color.green : Color.orange).clipShape(Capsule())
        }
    }
}
