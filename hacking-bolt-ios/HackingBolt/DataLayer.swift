import Foundation

/// Raw slot as read from window.LbsAppData.Slots (see LBWebSource JS).
struct RawSlot: Decodable {
    let slot_id: Int?
    let date: String?          // "YYYY-MM-DD"
    let start: String?         // "YYYY-MM-DDTHH:MM:SS"
    let stop: String?
    let unit: String?          // assign_display_name
    let offerer: String?       // display_name (the assigned doctor, or the offerer for a pending slot)
    let emp: String?           // emp_id (to flag "me" in the Who's-Working view)
}

/// One page-load's harvest: offered slots + my own roster slots + my name.
struct HarvestResult: Decodable {
    var pending: [RawSlot]          // overridden with the complete schedule/range?only_pending list
    let mine: [RawSlot]
    let me: String
    var emp: String? = nil          // my emp_id (gates the owner-only editor)
    var all: [RawSlot]? = nil       // every doctor's assignments across the roster (Who's Working)
    var dbg: String? = nil          // first-run diagnostics (User keys when emp_id not found)
}

/// Turns raw pending slots into OpenShifts with exact hours, conflict flags and accept links.
/// Mirrors the assembly in stage2/run.mjs (exact-hours + split handling).
enum OpenShiftBuilder {

    static func acceptURL(slotID: Int) -> URL? {
        // The in-app web view is ALREADY logged in, so go straight to the dashboard SPA's swop route.
        // The /login/?origin=…&origin_hash=… redirect form is only needed when NOT logged in (email links);
        // when already authed it just bounces to the plain dashboard and loses the shift.
        URL(string: "https://lblite.lightning-bolt.com/dashboard/#/swop/\(slotID)/accept")
    }

    /// -> (label "12:30–15:30 · 3h", interval, iso date) from ISO start/stop.
    static func hours(start: String, stop: String) -> (label: String, iv: MinInterval, iso: String)? {
        guard start.count >= 16, stop.count >= 16 else { return nil }
        let iso = String(start.prefix(10))
        let sh  = String(start.dropFirst(11).prefix(5))
        let eh  = String(stop.dropFirst(11).prefix(5))
        let overnight = String(stop.prefix(10)) > iso
        let iv = ConflictEngine.interval(iso, sh, eh, overnight: overnight)
        let h = Int((Double(iv.e - iv.s) / 60).rounded())
        return ("\(sh)–\(eh) · \(h)h", iv, iso)
    }

    static func build(pending: [RawSlot], schedule: MyScheduleModel, today: String) -> [OpenShift] {
        // count segments per (date|unit|offerer) so we can flag splits
        func groupKey(_ s: RawSlot, _ k: UnitKey) -> String {
            "\(s.date ?? "")|\(k.rawValue)|\((s.offerer ?? "").lowercased())"
        }
        var counts: [String: Int] = [:]
        for s in pending {
            if let raw = s.unit, let k = Units.key(fromRaw: raw) { counts[groupKey(s, k), default: 0] += 1 }
        }

        var out: [OpenShift] = []
        for s in pending {
            guard let id = s.slot_id, let raw = s.unit, let k = Units.key(fromRaw: raw),
                  let start = s.start, let stop = s.stop,
                  let h = hours(start: start, stop: stop), h.iso >= today else { continue }
            let flag = schedule.flag(iso: h.iso, unit: k, exact: h.iv)
            out.append(OpenShift(
                id: String(id), iso: h.iso, unit: k, offerer: s.offerer ?? "—",
                hoursLabel: h.label, flag: flag ?? "Available", conflict: flag != nil,
                acceptURL: acceptURL(slotID: id), hasDirect: true,
                isSplit: (counts[groupKey(s, k)] ?? 0) > 1))
        }
        return out.sorted { $0.iso == $1.iso ? $0.hoursLabel < $1.hoursLabel : $0.iso < $1.iso }
    }

    /// Everyone's assignments -> Assignment, clinical units only, de-duped. Powers the Who's Working view.
    static func assignments(from all: [RawSlot], myEmp: String?) -> [Assignment] {
        var seen = Set<String>()
        var out: [Assignment] = []
        for s in all {
            guard let raw = s.unit, let k = Units.key(fromRaw: raw),        // clinical only ("Time Off" etc. → nil)
                  let date = s.date, let start = s.start, let stop = s.stop,
                  start.count >= 16, stop.count >= 16 else { continue }
            let sh = String(start.dropFirst(11).prefix(5))
            let eh = String(stop.dropFirst(11).prefix(5))
            let overnight = String(stop.prefix(10)) > String(start.prefix(10))
            let doc = (s.offerer ?? "").isEmpty ? "—" : s.offerer!
            let key = "\(date)|\(k.rawValue)|\(doc)|\(sh)"
            guard seen.insert(key).inserted else { continue }
            let isMe = myEmp != nil && !myEmp!.isEmpty && s.emp == myEmp
            out.append(Assignment(date: date, unit: k, doc: doc, start: sh, end: eh, overnight: overnight, isMe: isMe))
        }
        return out.sorted { $0.date == $1.date ? $0.unit.rawValue < $1.unit.rawValue : $0.date < $1.date }
    }

    /// My roster: raw slots (emp_id == me) -> MyShift, de-duped.
    static func roster(from mine: [RawSlot]) -> [MyShift] {
        var seen = Set<String>()
        var out: [MyShift] = []
        for s in mine {
            guard let raw = s.unit, let k = Units.key(fromRaw: raw),
                  let start = s.start, let stop = s.stop, let h = hours(start: start, stop: stop) else { continue }
            let key = "\(h.iso)|\(k.rawValue)|\(start)"
            if seen.insert(key).inserted {
                let sh = String(start.dropFirst(11).prefix(5)), eh = String(stop.dropFirst(11).prefix(5))
                let overnight = String(stop.prefix(10)) > h.iso
                out.append(MyShift(date: h.iso, unit: k, start: sh, end: eh, overnight: overnight))
            }
        }
        return out.sorted { $0.date < $1.date }
    }
}
