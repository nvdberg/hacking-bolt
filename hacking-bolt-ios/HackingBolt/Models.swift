import SwiftUI

// Unit taxonomy — mirrors the UNITS map in stage2/run.mjs.
enum UnitKey: String, CaseIterable, Codable {
    case MICU, SICU, CCU, PHICU, RR, PRR, MSU
}

struct UnitInfo { let short: String; let full: String; let color: Color }

enum Units {
    static let info: [UnitKey: UnitInfo] = [
        .MICU:  .init(short: "MICU",         full: "Medical ICU",                     color: Color(hex: 0x41A00E)),
        .SICU:  .init(short: "SICU",         full: "Surgical ICU",                    color: Color(hex: 0x3A70EE)),
        .CCU:   .init(short: "CCU",          full: "Coronary Care",                   color: Color(hex: 0xBF3654)),
        .PHICU: .init(short: "PICU",         full: "Pasqua ICU",                      color: Color(hex: 0x0A7B71)),
        .RR:    .init(short: "RGH-Rapid",    full: "Rapid Response",                  color: Color(hex: 0xED8207)),
        .PRR:   .init(short: "Pasqua-Rapid", full: "Pasqua Rapid Response",           color: Color(hex: 0x14C28B)),
        .MSU:   .init(short: "Pasqua-MSU",   full: "Pasqua Medical Surveillance Unit",color: Color(hex: 0x14C28B)),
    ]

    /// Map a raw assignment/shift name (from the feed or LbsAppData) to a unit — mirrors unitKey() in run.mjs.
    static func key(fromRaw raw: String) -> UnitKey? {
        let r = raw.uppercased()
        if r.contains("BUDDY")          { return nil }   // a new CCA's learning shift — never a clinical slot of its own
        if r.contains("PASQUA RAPID")   { return .PRR }
        if r.contains("RAPID RESPONSE") { return .RR }
        if r.hasPrefix("MSU")           { return .MSU }
        if r.hasPrefix("PHICU") || r.hasPrefix("PICU") { return .PHICU }
        if r.hasPrefix("MICU")          { return .MICU }
        if r.hasPrefix("SICU")          { return .SICU }
        if r.hasPrefix("CCU")           { return .CCU }
        return nil   // unknown / non-clinical — skip
    }

    /// "CCA Buddy Shift": a new CCA learning the units alongside whoever works one that day (Who's On only).
    static func isBuddy(_ raw: String) -> Bool { raw.uppercased().contains("BUDDY") }

    /// A unit named anywhere in a label ("CCA Buddy Shift - SICU"), for pairing a buddy with that unit.
    static func mentioned(in raw: String) -> UnitKey? {
        let r = raw.uppercased()
        if r.contains("PASQUA RAPID") { return .PRR }
        if r.contains("RAPID")        { return .RR }
        if r.contains("MSU")          { return .MSU }
        if r.contains("PHICU") || r.contains("PICU") || r.contains("PASQUA ICU") { return .PHICU }
        if r.contains("MICU")         { return .MICU }
        if r.contains("SICU")         { return .SICU }
        if r.contains("CCU")          { return .CCU }
        return nil
    }
}

/// One of my own roster shifts.
struct MyShift: Identifiable, Codable, Hashable {
    var id = UUID()
    let date: String        // "YYYY-MM-DD"
    let unit: UnitKey
    let start: String       // "HH:MM"
    let end: String         // "HH:MM"
    let overnight: Bool
    var slotID: Int? = nil     // Lightning Bolt slot_id — present for live-harvested shifts; enables give-away
    var slotID2: Int? = nil    // second slot for a Pasqua Rapid+MSU combo (both halves move together on a trade)
    var templateID: Int? = nil // the LB schedule/template this shift belongs to (for the give-away payload)
}

/// An offered (open) shift shown in the pool — a whole shift or one split segment.
struct OpenShift: Identifiable, Codable, Equatable {
    let id: String          // slot_id, or a composite key when no exact slot matched
    let iso: String         // "YYYY-MM-DD"
    let unit: UnitKey
    let offerer: String
    let hoursLabel: String  // e.g. "12:30–15:30 · 3h"
    let flag: String        // "Available" or a conflict label
    let conflict: Bool
    let acceptURL: URL?
    let hasDirect: Bool     // true when we have the exact slot_id -> one-tap accept
    let isSplit: Bool
    var offererEmp: Int? = nil   // emp_id of whoever posted it — lets "My Posts" find the shifts I put up
    var pendingEmp: Int? = nil   // the one person it's offered to (nil = open to the pool)
    var pendingName: String? = nil
    /// Posted on LB but offered to a list that leaves me out (shared poller set) — shown under All, never takeable.
    var notOffered: Bool? = nil
    /// Aimed at one other person (a swap / direct offer) rather than open to everyone. LB sets pending_emp_id
    /// to the holder themselves on an ordinary pool offer.
    var directedTo: Int? { pendingEmp != offererEmp ? pendingEmp : nil }
}

/// A shift that recently left the pool because someone took it (Pool → "Recently taken"), with who took it.
struct RecentTake: Identifiable, Hashable {
    let id: Int
    let iso: String
    let unit: UnitKey
    let when: Date
    var swap = false     // a swap between two people — never open to anyone else
    var mine = false     // I gave it or took it
    var taker: String? = nil   // who took it ("you" when it was me) — names shown to all crew (owner, 2026-10-18)
}

/// One entry in the "My Posts" tracker — a shift I put up (gave away or offered to swap), and where it stands.
/// Pending entries come from the open pool (my still-unclaimed offers); completed entries come from the group
/// history (a shift of mine that changed hands) or, later, the backend poller.
struct MyPost: Identifiable, Hashable {
    let id: String
    let iso: String              // the shift's date "YYYY-MM-DD"
    let unit: UnitKey
    let hoursLabel: String       // "08:00–08:00 · 24h" (may be empty for a completed entry we only saw in history)
    let kind: Kind
    let status: Status
    let counterparty: String?    // who picked it up / who I swapped with (nil while pending)
    let when: String?            // completion time "YYYY-MM-DDTHH:MM:SS" — nil while pending; drives month grouping
    var slotID: Int? = nil       // LB slot_id — present on pending entries so they can be cancelled from here
    var note: String? = nil      // the swap/give-away note (shown on a pending swap)
    enum Kind: String, Hashable { case giveaway = "Give-away", swap = "Swap" }
    enum Status: String, Hashable { case pending, completed }
}

/// A shift that changed hands (admin-only "Shift pickups" card). Reconstructed from the group schedule:
/// a slot whose `original_emp_id` differs from its current `emp_id`. `isPickup` marks the pool give-away
/// flow ("X's request to swap … was approved by …") vs. a direct "Swapped A with B" trade or a time edit.
struct SwapEvent: Identifiable, Codable, Hashable {
    var id: Int { slotID }
    let slotID: Int
    let date: String        // "YYYY-MM-DD" — the shift's date
    let unit: UnitKey
    let from: String        // giver (original holder)
    let to: String          // taker (works it now)
    let toIsMe: Bool
    var fromIsMe: Bool = false   // I was the giver — powers "My Posts" (a shift I posted that got picked up)
    let when: String        // "YYYY-MM-DDTHH:MM:SS" — when the swap was approved
    let hist: String        // plain-English history line from Lightning Bolt
    let isPickup: Bool      // classified as an open-pool give-away pickup ("request to swap … approved by")
    var isSwap: Bool = false  // classified as a direct swap ("Swapped A with B by C") — kept separate from give-aways
    var lines: [String]? = nil  // LB's full history for the slot (owner taps a row to see it) — optional: older caches lack it
    var orig: String? = nil     // who the scheduler first rostered it to (history walked back hop by hop) — Unit mix "As rostered"
}

/// One doctor's assignment on a unit for a day — powers the Who's Working view.
struct Assignment: Identifiable, Codable, Hashable {
    var id = UUID()
    let date: String        // "YYYY-MM-DD"
    let unit: UnitKey
    let doc: String         // doctor's display name
    let start: String       // "HH:MM"
    let end: String         // "HH:MM"
    let overnight: Bool
    let isMe: Bool
    var slotID: Int? = nil      // LB slot_id (group fetch) — lets the Swap Finder send a one-step exchange
    var slotID2: Int? = nil     // second half of a merged Pasqua Rapid+MSU
    var buddy: Bool? = nil      // a buddy (learning) shift, shown beside the unit it's paired with — Who's On only
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8)  & 0xff) / 255,
                  blue:  Double( hex        & 0xff) / 255)
    }
}
