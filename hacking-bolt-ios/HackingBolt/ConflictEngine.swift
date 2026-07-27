import Foundation

/// Absolute-minute interval (minutes since the Unix epoch, UTC) — matches interval() in run.mjs.
struct MinInterval { let s: Int; let e: Int }

enum ConflictEngine {
    static func toMin(_ hhmm: String) -> Int {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? p[0] * 60 + p[1] : 0
    }

    private static let utc = TimeZone(identifier: "UTC")!
    // Reused instances — building a Calendar/DateFormatter per call was a hot-path cost during every harvest.
    private static let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = utc; return c }()
    private static let ymd: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = utc; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// Whole days since epoch for "YYYY-MM-DD" (tz-independent, like ordinal() in run.mjs).
    static func ordinal(_ iso: String) -> Int {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return 0 }
        var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]
        guard let d = cal.date(from: c) else { return 0 }
        return Int(d.timeIntervalSince1970 / 86400)
    }

    static func addDay(_ iso: String) -> String {
        let p = iso.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]
        guard let base = cal.date(from: c), let d = cal.date(byAdding: .day, value: 1, to: base) else { return iso }
        return ymd.string(from: d)
    }

    static func interval(_ iso: String, _ start: String, _ end: String, overnight ov: Bool) -> MinInterval {
        let base = ordinal(iso) * 1440, s = toMin(start), e = toMin(end)
        var E = base + e
        if ov || e <= s { E += 1440 }
        return MinInterval(s: base + s, e: E)
    }

    /// Assumed window for an open shift when we don't have its exact hours — mirrors openInterval() in run.mjs.
    static func openInterval(_ iso: String, _ k: UnitKey) -> MinInterval {
        switch k {
        case .RR, .PRR: return interval(iso, "08:00", "17:00", overnight: false)
        case .MSU:      return interval(iso, "17:00", "08:00", overnight: true)   // Pasqua MSU 17:00→08:00
        default:        return interval(iso, "08:00", "08:00", overnight: true)   // 24h units
        }
    }
}

/// My schedule as intervals + the post-call (full rest-day) map. Mirrors the myIvs / myPost logic in run.mjs.
struct MyScheduleModel {
    private let intervals: [(iv: MinInterval, short: String)]
    private let post: [String: String]   // date -> unit short (post-call = whole rest day, nothing pickable)

    init(_ mine: [MyShift]) {
        var ivs: [(MinInterval, String)] = []
        var p: [String: String] = [:]
        for s in mine {
            let iv = ConflictEngine.interval(s.date, s.start, s.end, overnight: s.overnight)
            let short = Units.info[s.unit]?.short ?? s.unit.rawValue
            ivs.append((iv, short))
            if s.overnight { p[ConflictEngine.addDay(s.date)] = short }
        }
        intervals = ivs.map { (iv: $0.0, short: $0.1) }
        post = p
    }

    /// nil = Available; otherwise a conflict label. Pass `exact` for a split/partial offer's real window.
    func flag(iso: String, unit: UnitKey, exact: MinInterval? = nil) -> String? {
        if let pc = post[iso] { return "Post-call · off \(pc)" }
        let o = exact ?? ConflictEngine.openInterval(iso, unit)
        var best: (rank: Int, short: String)?   // 3 = overlap, 2 = post-call, 1 = pre-call
        for m in intervals where m.iv.s <= o.e && m.iv.e >= o.s {
            let rank = (m.iv.s < o.e && m.iv.e > o.s) ? 3 : (m.iv.e == o.s ? 2 : 1)
            if best == nil || rank > best!.rank { best = (rank, m.short) }
        }
        guard let b = best else { return nil }
        switch b.rank {
        case 3:  return "You're on \(b.short)"
        case 2:  return "Post-call · off \(b.short)"
        default: return "Pre-call · before \(b.short)"
        }
    }
}
