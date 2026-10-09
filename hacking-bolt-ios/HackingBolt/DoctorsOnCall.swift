import SwiftUI

// MARK: - Doctors on call (Who's On → stethoscope toggle)
//
// Intensivists come from PetalMD, cardiology from the monthly RGH PDF — both captured on the Unit Board from the
// hospital network into Supabase `oncall_roster` (date, unit, role, name). The app only reads it. Names are
// never hard-coded or logged here (public repo); demo mode uses made-up tree names.

/// Read-through cache of `oncall_roster`, kept on disk so the card still shows the last good read offline.
@MainActor final class DoctorRoster: ObservableObject {
    static let shared = DoctorRoster()
    typealias Row = Supabase.SupaRosterRow

    @Published private(set) var byDate: [String: [Row]] = [:]
    @Published private(set) var loading = false
    private var fetchedAt: [String: Date] = [:]          // month "YYYY-MM" → when this run last read it (re-read after 10 min)
    private var inflight: [String: Task<Void, Never>] = [:]   // month → the read in progress (rows join it)

    private static let io = DispatchQueue(label: "hb.oncall.cache", qos: .utility)
    private static var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("hb_oncall.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL), let rows = try? JSONDecoder().decode([Row].self, from: data) {
            byDate = Dictionary(grouping: rows, by: \.date)
        }
    }

    /// Make sure the month around `iso` is loaded (± a week, so the "in CCU" Friday is there too). One read per
    /// month per 10 min, however many rows ask. A failed read keeps whatever we had.
    func ensure(_ iso: String, demo: Bool) async {
        #if DEBUG
        let demo = demo && ProcessInfo.processInfo.environment["DEMO_REAL_DOCTORS"] != "1"   // layout check against the live roster
        #endif
        if demo {
            for k in -7...7 { let d = AppModel.addDays(iso, k); if byDate[d] == nil { byDate[d] = Self.demoRows(d) } }
            return
        }
        let month = String(iso.prefix(7))
        if let t = inflight[month] { await t.value; return }
        if let t = fetchedAt[month], Date().timeIntervalSince(t) < 600 { return }
        // The read runs in the store's own task, not the row's: a row that scrolls away or a quick stethoscope
        // off/on cancels its .task, and a cancelled read used to leave every other row waiting on nothing.
        let t = Task { await fetch(month) }
        inflight[month] = t; loading = true
        await t.value
    }

    private func fetch(_ month: String) async {
        defer { inflight[month] = nil; loading = !inflight.isEmpty }
        let first = month + "-01"
        let from = AppModel.addDays(first, -7), to = AppModel.addDays(first, 38)
        guard let rows = await Supabase.oncallRoster(from: from, to: to) else { return }
        fetchedAt[month] = Date()
        var all = byDate
        for (date, rs) in Dictionary(grouping: rows, by: \.date) { all[date] = rs }      // only dates the server returned
        if all != byDate { byDate = all }                                               // one publish, and none when nothing changed
        let snapshot = all.values.flatMap { $0 }, url = Self.fileURL
        Self.io.async {                                                                 // encode + write off the main thread, in order
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    static let icuUnits = ["SICU", "MICU", "PHICU"]

    /// Tonight's intensivist: ONE person covers all the ICUs overnight (the name on most on-call rows); any other
    /// on-call name is 2nd call (mass event only). `home` = the unit that person works by day, if any.
    func night(_ iso: String) -> (name: String, home: String?, second: [String])? {
        var order: [String] = [], count: [String: Int] = [:]
        for u in Self.icuUnits { if let n = name(iso, u, "oncall") { if count[n] == nil { order.append(n) }; count[n, default: 0] += 1 } }
        let ranked = order.enumerated().sorted { (count[$0.element]!, -$0.offset) > (count[$1.element]!, -$1.offset) }.map(\.element)
        guard let top = ranked.first else { return nil }
        return (top, Self.icuUnits.first { name(iso, $0, "day") == top }, Array(ranked.dropFirst()))
    }

    /// The cardiologist physically in CCU: an explicit `ccu` row if the board ever stores one, else the cardiologist
    /// on the Friday that starts this Fri → Thu week.
    func inCCU(_ iso: String) -> String? {
        if let n = name(iso, "CCU", "ccu") { return n }
        let dow = Int(fmt(iso, "e")) ?? 1                       // 1 = Sunday … 6 = Friday
        return name(AppModel.addDays(iso, -((dow + 1) % 7)), "CCU", "day")
    }

    func name(_ iso: String, _ unit: String, _ role: String) -> String? {
        guard let n = byDate[iso]?.first(where: { $0.unit == unit && $0.role == role })?.name,
              !n.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return n
    }

    func has(_ iso: String, units: [String]) -> Bool { byDate[iso]?.contains { units.contains($0.unit) } ?? false }

    // Sample data for the no-login preview — invented names only.
    private static func demoRows(_ iso: String) -> [Row] {
        let trees = ["Maple", "Birch", "Cedar", "Aspen", "Willow", "Rowan", "Alder", "Spruce", "Larch", "Poplar"]
        let n = Int(fmt(iso, "D")) ?? 1
        func t(_ k: Int) -> String { trees[(n + k) % trees.count] }
        return [
            Row(date: iso, unit: "SICU", role: "day", name: t(0)), Row(date: iso, unit: "SICU", role: "oncall", name: t(1)),
            Row(date: iso, unit: "MICU", role: "day", name: t(1)), Row(date: iso, unit: "MICU", role: "oncall", name: t(1)),
            Row(date: iso, unit: "PHICU", role: "day", name: t(2)), Row(date: iso, unit: "PHICU", role: "oncall", name: t(8)),
            Row(date: iso, unit: "CCU", role: "day", name: t(4)), Row(date: iso, unit: "CCU", role: "oncall", name: t(4)),
            Row(date: iso, unit: "CCU", role: "stemi_day", name: t(5)), Row(date: iso, unit: "CCU", role: "stemi_oncall", name: t(6)),
            Row(date: iso, unit: "CCU", role: "consults", name: t(7)),
        ]
    }
}

/// The doctor shown beside a unit's first CCA row (Who's On, stethoscope toggle on).
struct DocTag {
    let name: String
    let sub: String          // the on-call intensivist's number, or "in CCU"
    let night: Bool          // this intensivist is also on call tonight for all the ICUs
    // On-call intensivist numbers, per ICU.
    static let phones: [UnitKey: String] = [.SICU: "4268", .MICU: "4265", .PHICU: "4249"]
    // The units' own desk numbers, and the CCA call rooms (one bar under the toolbar while the toggle is on).
    static let unitPhones: [UnitKey: String] = [.SICU: "3990", .MICU: "4291", .CCU: "4266", .PHICU: "8555"]
    static let callRooms: [UnitKey: String] = [.SICU: "3971", .MICU: "4823", .CCU: "4241", .PHICU: "8556"]
    static let wardsRoom = "2417"           // Pasqua wards CCA call room
}

/// The units' desk numbers with the CCA call room under each, once, under the Who's On toolbar while the stethoscope
/// toggle is on — they don't change by day, so they stay out of the roster rows.
struct UnitPhonesBar: View {
    @ObservedObject private var unitStore = UnitOrderStore.shared

    var body: some View {
        let units = unitStore.order.filter { DocTag.unitPhones[$0] != nil }
        HStack(alignment: .top, spacing: 0) {
            ForEach(units, id: \.self) { u in
                let info = Units.info[u] ?? UnitInfo(short: u.rawValue, full: "", color: .gray)
                column(info.short, info.color, desk: DocTag.unitPhones[u], room: DocTag.callRooms[u])
            }
            column("Wards", Units.info[.PRR]?.color ?? .green, desk: nil, room: DocTag.wardsRoom)
        }
        .padding(.vertical, 6).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: 1))
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Unit phone numbers and CCA call rooms")
    }

    /// Unit + desk number on top; the call room (bed) underneath, smaller.
    private func column(_ label: String, _ tint: Color, desk: String?, room: String?) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Text(label).font(.caption2.bold()).foregroundStyle(tint)
                if let desk { Text(desk).font(.caption2.weight(.medium).monospacedDigit()).foregroundStyle(Theme.ink.opacity(0.7)) }
            }
            if let room {
                HStack(spacing: 2) {
                    Image(systemName: "bed.double.fill").font(.system(size: 7))
                    Text(room).font(.system(size: 10, weight: .medium).monospacedDigit())
                }
                .foregroundStyle(Theme.muted)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity)
    }
}

/// Closes each day in Who's On when the stethoscope toggle is on: who's on call overnight. One intensivist covers
/// every ICU after 17:00; cardiology lists the daytime name, then the evening one circled.
struct OnCallStrip: View {
    let day: String
    let isToday: Bool
    @ObservedObject private var roster = DoctorRoster.shared

    var body: some View {
        let night = roster.night(day)
        let hasCCU = roster.has(day, units: ["CCU"])
        let ccu = Units.info[.CCU]?.color ?? .red
        if night != nil || hasCCU {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                if let night {
                    GridRow(alignment: .firstTextBaseline) {
                        label("ICU tonight", icon: "moon.stars.fill", tint: .indigo)
                        HStack(spacing: 6) {
                            circled(night.name, .indigo)
                            if !night.second.isEmpty {
                                Text("2nd " + night.second.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                    }
                }
                if hasCCU {
                    GridRow(alignment: .firstTextBaseline) {
                        label("Cardiology", icon: "heart.fill", tint: ccu)
                        VStack(alignment: .leading, spacing: 6) {
                            let consult = roster.name(day, "CCU", "consults")
                            let inCCU = roster.inCCU(day)
                            HStack(spacing: 5) {                    // ♥ = who's in the CCU unit this week (Fri → Thu)
                                if let inCCU { name(inCCU) }        // the ♥ says "in CCU"
                                if inCCU != nil, consult != nil { dot }
                                if let consult { tagged("Consults 8–5", name(consult), ccu) }
                            }
                            cardiology(ccu)                         // RGH cardiology on call — second line
                        }
                    }
                }
            }
            .padding(.vertical, 9).padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.indigo.opacity(isToday ? 0.10 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.line, lineWidth: 1))
            .opacity(isToday ? 1 : 0.85)
        }
    }

    /// Icon only — the moon / heart carry the meaning and leave the width to the names.
    private func label(_ s: String, icon: String, tint: Color) -> some View {
        Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            .frame(width: 16).accessibilityLabel(s)
    }

    /// Cardiology on call on one line — On call · STEMI — falling back to two when the surnames are long.
    @ViewBuilder private func cardiology(_ ccu: Color) -> some View {
        let onCall = tagged("On call", pair(roster.name(day, "CCU", "day"), roster.name(day, "CCU", "oncall"), ccu), ccu)
        let stemi = tagged("STEMI", pair(roster.name(day, "CCU", "stemi_day"), roster.name(day, "CCU", "stemi_oncall"), ccu), ccu)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { onCall; dot; stemi }
            VStack(alignment: .leading, spacing: 6) { onCall; stemi }
        }
    }

    private var dot: some View { Text("·").font(.caption.bold()).foregroundStyle(Theme.muted) }

    private func tagged(_ tag: String, _ v: some View, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Text(tag).font(.caption2.bold()).foregroundStyle(tint).fixedSize()
            v
        }
    }

    /// Daytime name, then the evening (17:00 →) name circled; one circled name when it's the same person.
    @ViewBuilder private func pair(_ day: String?, _ night: String?, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            if let day, day != night { name(day) }
            if let night { circled(night, tint) }
            if day == nil && night == nil { Text("—").font(.footnote).foregroundStyle(Theme.muted) }
        }
    }

    private func name(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
    }

    private func circled(_ s: String, _ tint: Color) -> some View {
        name(s).padding(.horizontal, 5).padding(.vertical, 1).overlay(Capsule().strokeBorder(tint, lineWidth: 1.3))
    }
}
