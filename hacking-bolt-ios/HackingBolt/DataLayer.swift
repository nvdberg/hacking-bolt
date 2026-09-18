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
    let template_id: Int?      // the LB schedule/template the slot belongs to — needed to give it away
}

/// A raw "changed hands" slot from the group schedule (see groupShiftsJS) — original holder != current.
struct RawSwap: Decodable {
    let slot_id: Int?
    let date: String?
    let start: String?
    let stop: String?
    let unit: String?
    let toName: String?     // current holder (taker) display name
    let toEmp: String?      // current emp_id
    let fromEmp: String?    // original_emp_id
    let fromName: String?   // resolved from the group's emp_id → name map
    let when: String?       // modified_date (approval time)
    let hist: String?       // slot_history[0].text
}

/// A person from LB's /personnel directory (emp_id → contact), for the Swap Finder's "text them" action.
struct RawPerson: Decodable {
    let emp: String
    let name: String
    let cell: String
    let email: String
}

/// Turns raw "changed hands" slots into SwapEvents for the admin "Shift pickups" card.
enum SwapBuilder {
    /// The open-pool give-away signature: a request→approve flow, e.g.
    /// "Nicolaas's request to swap Bea with Nicolaas was approved by Bea". Direct trades read
    /// "Swapped A with B by C"; time edits read "Changed time …" — neither matches.
    static func isPickup(_ hist: String) -> Bool {
        let h = hist.lowercased()
        return h.contains("request to swap") && h.contains("approved by")
    }
    /// A direct trade — "Swapped A with B by C" (incl. an admin arranging it directly). Kept distinct from
    /// pool give-aways; the poller records these as kind="swap" too. Time edits ("Changed time …") match neither.
    static func isSwap(_ hist: String) -> Bool {
        hist.lowercased().contains("swapped")
    }

    static func build(from raw: [RawSwap], myEmp: String?) -> [SwapEvent] {
        var seen = Set<Int>()
        var out: [SwapEvent] = []
        for s in raw {
            guard let id = s.slot_id, seen.insert(id).inserted,
                  let rawUnit = s.unit, let unit = Units.key(fromRaw: rawUnit),   // clinical units only
                  let date = s.date, !date.isEmpty else { continue }
            let to = (s.toName ?? "").trimmingCharacters(in: .whitespaces)
            let from = (s.fromName ?? "").trimmingCharacters(in: .whitespaces)
            // both people must be named, and skip Lightning Bolt's "EMPTY" vacancy fill (no real giver)
            guard !to.isEmpty, !from.isEmpty,
                  from.uppercased() != "EMPTY", to.uppercased() != "EMPTY", from != "—", to != "—" else { continue }
            let hist = s.hist ?? ""
            let haveMe = myEmp != nil && !myEmp!.isEmpty
            let toIsMe = haveMe && s.toEmp == myEmp
            let fromIsMe = haveMe && s.fromEmp == myEmp
            out.append(SwapEvent(slotID: id, date: date, unit: unit, from: from, to: to,
                                 toIsMe: toIsMe, fromIsMe: fromIsMe,
                                 when: s.when ?? "", hist: hist, isPickup: isPickup(hist), isSwap: isSwap(hist)))
        }
        // newest action first. Sort by approval time, but fall back to the shift date when LB didn't stamp a
        // modified_date (empty `when`) — otherwise those pickups sort to the very bottom and the card looks
        // "stuck" on an older one even though newer pickups exist.
        func sortKey(_ s: SwapEvent) -> String { s.when.isEmpty ? s.date + "T00:00:00" : s.when }
        return out.sorted { sortKey($0) > sortKey($1) }
    }
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
                isSplit: (counts[groupKey(s, k)] ?? 0) > 1,
                offererEmp: s.emp.flatMap { Int($0) }))   // who posted it — for the "My Posts" filter
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
                out.append(MyShift(date: h.iso, unit: k, start: sh, end: eh, overnight: overnight, slotID: s.slot_id, templateID: s.template_id))
            }
        }
        return out.sorted { $0.date < $1.date }
    }
}
