import SwiftUI
import UIKit

/// Exports the roster as an .ics (iCalendar) file for Google or Apple Calendar. Each shift is one event
/// titled with a coloured-square emoji + unit ("🟥 CCU") — no time in the title, since the event's own
/// start/end carries it. A 24h call runs 08:00 → 08:00 so it folds into the post-call morning (no separate
/// block); a Pasqua Rapid + MSU day merges into one 24h "Pasqua". Times are the shift's own, emitted in UTC
/// (Saskatchewan is UTC-6 year-round, no DST). Stable UIDs → re-exporting updates events instead of duplicating.
enum ICSExporter {
    static let emoji: [UnitKey: String] = [
        .MICU: "🟩", .SICU: "🟦", .CCU: "🟥", .PHICU: "🟢", .RR: "🟧", .PRR: "🟪", .MSU: "🟪",
    ]
    private static let reginaTZ = TimeZone(identifier: "America/Regina") ?? TimeZone(identifier: "UTC")!
    private static let utcFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static var stampNow: String { utcFmt.string(from: Date()) }

    /// Regina-local date+time → UTC "yyyyMMddThhmmssZ".
    private static func utc(date: String, time: String) -> String {
        var c = DateComponents()
        c.year = Int(date.prefix(4)); c.month = Int(date.dropFirst(5).prefix(2)); c.day = Int(date.suffix(2))
        c.hour = Int(time.prefix(2)); c.minute = Int(time.suffix(2))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = reginaTZ
        return utcFmt.string(from: cal.date(from: c) ?? Date())
    }
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
         .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
    }
    private static func vevent(date: String, start: String, end: String, overnight: Bool, title: String, uid: String) -> [String] {
        let endDate = overnight ? ConflictEngine.addDay(date) : date
        return ["BEGIN:VEVENT", "UID:\(uid)@working-bolt", "DTSTAMP:\(stampNow)",
                "DTSTART:\(utc(date: date, time: start))", "DTEND:\(utc(date: endDate, time: end))",
                "SUMMARY:\(esc(title))", "END:VEVENT"]
    }

    static func ics(from shifts: [MyShift]) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Working-Bolt//Shifts//EN",
                     "CALSCALE:GREGORIAN", "METHOD:PUBLISH", "X-WR-CALNAME:Working-Bolt shifts"]
        let byDate = Dictionary(grouping: shifts, by: { $0.date })
        var pasquaDone = Set<String>()
        for s in shifts.sorted(by: { $0.date == $1.date ? $0.start < $1.start : $0.date < $1.date }) {
            // Pasqua Rapid + MSU on the same day → one 24h "Pasqua"
            if s.unit == .PRR || s.unit == .MSU {
                let day = byDate[s.date] ?? []
                if day.contains(where: { $0.unit == .PRR }) && day.contains(where: { $0.unit == .MSU }) {
                    if pasquaDone.contains(s.date) { continue }
                    pasquaDone.insert(s.date)
                    lines += vevent(date: s.date, start: "08:00", end: "08:00", overnight: true,
                                    title: "🟪 Pasqua-Rapid/MSU", uid: "wb-pasqua-\(s.date)")
                    continue
                }
            }
            let e = emoji[s.unit] ?? "⚪️"
            let name = Units.info[s.unit]?.short ?? s.unit.rawValue
            lines += vevent(date: s.date, start: s.start, end: s.end, overnight: s.overnight,
                            title: "\(e) \(name)", uid: "wb-\(s.slotID ?? 0)-\(s.date)-\(s.unit.rawValue)")
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    /// Write the .ics to a temp file for the share sheet.
    static func writeFile(shifts: [MyShift]) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Working-Bolt-shifts.ics")
        do { try ics(from: shifts).data(using: .utf8)?.write(to: url); return url } catch { return nil }
    }
}
// ShareItem + ActivityView already live in Export.swift — reused here.
