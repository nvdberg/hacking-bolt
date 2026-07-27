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
        if r.contains("PASQUA RAPID")   { return .PRR }
        if r.contains("RAPID RESPONSE") { return .RR }
        if r.hasPrefix("MSU")           { return .MSU }
        if r.hasPrefix("PHICU") || r.hasPrefix("PICU") { return .PHICU }
        if r.hasPrefix("MICU")          { return .MICU }
        if r.hasPrefix("SICU")          { return .SICU }
        if r.hasPrefix("CCU")           { return .CCU }
        return nil   // unknown / non-clinical — skip
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
}

/// An offered (open) shift shown in the pool — a whole shift or one split segment.
struct OpenShift: Identifiable, Codable {
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
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8)  & 0xff) / 255,
                  blue:  Double( hex        & 0xff) / 255)
    }
}
