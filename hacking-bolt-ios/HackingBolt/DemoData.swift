import Foundation

/// Sample data for the no-login "Explore" mode. Lets a reviewer (or a curious colleague) walk the whole
/// app — Pool, My Shifts, Who's On, Crew, My Stats — without ever signing in. Fully in-memory and
/// deterministic, so it looks the same on every launch and never touches the network.
enum DemoData {
    static let me = "Demo User"
    static let others = ["Aivars Berzins", "Sarah Chen", "James Okafor", "Maria Santos", "David Kim",
                         "Emily Novak", "Raj Patel", "Lena Fischer", "Tom Wright", "Anna Kowalski"]
    static let units: [UnitKey] = [.SICU, .MICU, .CCU, .PHICU, .RR, .PRR, .MSU]

    /// Realistic hours per unit: 24h ICU calls (08:00→08:00), 9h day rapid-response, MSU overnight.
    private static func times(_ u: UnitKey) -> (start: String, end: String, overnight: Bool) {
        switch u {
        case .RR, .PRR: return ("08:00", "17:00", false)
        case .MSU:      return ("17:00", "08:00", true)
        default:        return ("08:00", "08:00", true)   // 24h ICU units
        }
    }

    /// Builds a couple of years of history (2024 → ~2 months ahead): every unit covered every day by some
    /// doctor, with the "Demo User" holding roughly one shift every five days.
    static func build(today: String) -> (mine: [MyShift], group: [Assignment], open: [OpenShift]) {
        var mine: [MyShift] = []
        var group: [Assignment] = []
        let cal = Calendar(identifier: .gregorian)
        let start = isoToDate("2024-01-01")
        let end = cal.date(byAdding: .day, value: 60, to: isoToDate(today)) ?? isoToDate(today)

        var d = start
        var dayIdx = 0
        while d <= end {
            let iso = dateToISO(d)
            for (ui, u) in units.enumerated() {
                let (s, e, ov) = times(u)
                let mineSlot = (dayIdx % 5 == 0) && (ui == (dayIdx / 5) % units.count)   // ~1 shift / 5 days
                if mineSlot {
                    group.append(Assignment(date: iso, unit: u, doc: me, start: s, end: e, overnight: ov, isMe: true))
                    mine.append(MyShift(date: iso, unit: u, start: s, end: e, overnight: ov))
                } else {
                    let doc = others[(dayIdx + ui) % others.count]
                    group.append(Assignment(date: iso, unit: u, doc: doc, start: s, end: e, overnight: ov, isMe: false))
                }
            }
            d = cal.date(byAdding: .day, value: 1, to: d) ?? end
            dayIdx += 1
        }
        return (mine.sorted { $0.date < $1.date }, group.sorted { $0.date < $1.date }, buildOpen(today: today))
    }

    /// A handful of upcoming open offers for the Pool tab (no accept URL — read-only in demo).
    private static func buildOpen(today: String) -> [OpenShift] {
        let cal = Calendar(identifier: .gregorian)
        let base = isoToDate(today)
        let offers: [(days: Int, unit: UnitKey, who: String)] = [
            (2, .RR, "Sarah Chen"), (4, .SICU, "James Okafor"), (5, .PRR, "Maria Santos"),
            (8, .MICU, "David Kim"), (11, .CCU, "Emily Novak"), (14, .MSU, "Raj Patel"),
        ]
        var out: [OpenShift] = []
        for (i, off) in offers.enumerated() {
            let iso = dateToISO(cal.date(byAdding: .day, value: off.days, to: base) ?? base)
            let (s, e, ov) = times(off.unit)
            let hours = (ov || e <= s) ? 24 : 9
            out.append(OpenShift(id: "demo-\(i)", iso: iso, unit: off.unit, offerer: off.who,
                                 hoursLabel: "\(s)–\(e) · \(hours)h", flag: "Available", conflict: false,
                                 acceptURL: nil, hasDirect: false, isSplit: false))
        }
        return out
    }
}
