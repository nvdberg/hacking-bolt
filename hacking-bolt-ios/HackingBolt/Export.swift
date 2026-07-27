import SwiftUI
import UIKit

// MARK: - Export hub (More → Export)

struct ExportView: View {
    @EnvironmentObject var model: AppModel
    @State private var scope = 0                 // 0 = this year, 1 = all time, 2 = custom range
    @State private var rangeStart = Calendar(identifier: .gregorian).date(byAdding: .month, value: -3, to: Date()) ?? Date()
    @State private var rangeEnd = Date()
    @State private var share: ShareItem?

    private var today: String { AppModel.todayRegina() }
    private var year: String { String(today.prefix(4)) }

    // ISO yyyy-MM-dd in Regina time, so custom-range pickers line up with the stored shift dates.
    private static let isoFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/Regina")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static func iso(_ d: Date) -> String { isoFmt.string(from: d) }
    private var rangeLo: String { min(Self.iso(rangeStart), Self.iso(rangeEnd)) }
    private var rangeHi: String { max(Self.iso(rangeStart), Self.iso(rangeEnd)) }

    private var scopedLog: [MyShift] {
        switch scope {
        case 0:  return model.shiftLog.filter { $0.date.hasPrefix(year) }
        case 2:  return model.shiftLog.filter { $0.date >= rangeLo && $0.date <= rangeHi }
        default: return model.shiftLog
        }
    }

    // Human label for the chosen period, reused in captions and the PDF headers.
    private var periodLabel: String {
        switch scope {
        case 0:  return year
        case 2:  return "\(longDate(rangeLo)) – \(longDate(rangeHi))"
        default: return "since 2022"
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Period", selection: $scope) {
                    Text("This year").tag(0)
                    Text("All time").tag(1)
                    Text("Custom").tag(2)
                }.pickerStyle(.segmented)
                if scope == 2 {
                    DatePicker("From", selection: $rangeStart, displayedComponents: .date)
                    DatePicker("To", selection: $rangeEnd, in: rangeStart..., displayedComponents: .date)
                }
                Text("\(scopedLog.count) shift\(scopedLog.count == 1 ? "" : "s") \(scope == 2 ? "in range" : (scope == 0 ? "in \(year)" : "since 2022"))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("My shifts") {
                exportButton("Add to Calendar (.ics)", "calendar.badge.plus") { ShiftExport.ics(scopedLog) }
                exportButton("Spreadsheet (CSV — Excel / Numbers)", "tablecells") { ShiftExport.csv(scopedLog) }
                exportButton("Printable list (PDF)", "doc.richtext") { ShiftExport.pdf(shiftsPDF, name: "my-shifts.pdf") }
            }

            Section("My stats") {
                exportButton("Summary (PDF)", "chart.bar.doc.horizontal") { ShiftExport.pdf(statsPDF, name: "my-stats.pdf") }
                exportButton("Summary (CSV)", "tablecells") { statsCSV() }
            }

            Section {
                Text("The .ics drops your shifts straight into Apple/Google Calendar. For a spreadsheet, tap “Copy to Numbers” or “Save to Files” in the share sheet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadHistory() }
        .sheet(item: $share) { ActivityView(items: [$0.url]) }
    }

    // A row that generates its file ONLY when tapped, then opens the share sheet.
    @ViewBuilder private func exportButton(_ title: String, _ icon: String, _ make: @escaping () -> URL?) -> some View {
        Button { if let u = make() { share = ShareItem(url: u) } } label: {
            Label(title, systemImage: icon)
        }
        .disabled(scopedLog.isEmpty)
    }

    private func statsCSV() -> URL? {
        let from = scopedLog.map(\.date).min() ?? today
        let to = scopedLog.map(\.date).max() ?? today
        let st = ShiftStats.compute(scopedLog, from: from, to: to)
        var s = "Metric,Value\nShifts,\(st.count)\nHours,\(Int(st.totalHours.rounded()))\nShifts/month,\(String(format: "%.1f", st.avgShiftsPerMonth))\nHours/month,\(Int(st.avgHoursPerMonth.rounded()))\n\nUnit,Count,Hours\n"
        for u in st.byUnit { s += "\(u.name),\(u.count),\(Int(u.hours.rounded()))\n" }
        s += "\nLength,Count\n"
        for b in st.byLength { s += "\(b.label),\(b.count)\n" }
        return ShiftExport.write(s.data(using: .utf8), name: "my-stats.csv")
    }

    // MARK: printable layouts (rendered off-screen)

    private var shiftsPDF: some View {
        let byMonth = Dictionary(grouping: scopedLog.sorted { $0.date < $1.date }) { String($0.date.prefix(7)) }
        let months = byMonth.keys.sorted()
        return VStack(alignment: .leading, spacing: 12) {
            Text("My shifts\(model.userName.isEmpty ? "" : " — \(model.userName)")").font(.title3.bold())
            Text("\(scopedLog.count) shifts · \(periodLabel) · generated \(longDate(today))")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(months, id: \.self) { m in
                VStack(alignment: .leading, spacing: 3) {
                    Text(monthLabelFull(m + "-01")).font(.headline)
                    ForEach(byMonth[m] ?? []) { s in
                        HStack(spacing: 8) {
                            Text(fmt(s.date, "EEE d")).frame(width: 64, alignment: .leading)
                            Circle().fill(Units.info[s.unit]?.color ?? .gray).frame(width: 8, height: 8)
                            Text(Units.info[s.unit]?.short ?? s.unit.rawValue).frame(width: 96, alignment: .leading)
                            Text("\(s.start)–\(s.end)")
                            Spacer()
                            Text("\(Int(ShiftStats.hours(of: s).rounded()))h").foregroundStyle(.secondary)
                        }.font(.caption).monospacedDigit()
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(20).frame(width: 560, alignment: .leading).background(Color(.systemBackground))
    }

    private var statsPDF: some View {
        let from = scopedLog.map(\.date).min() ?? today
        let to = scopedLog.map(\.date).max() ?? today
        return VStack(alignment: .leading, spacing: 14) {
            Text("Shift stats\(model.userName.isEmpty ? "" : " — \(model.userName)")").font(.title3.bold())
            Text("\(periodLabel) · generated \(longDate(today))").font(.caption).foregroundStyle(.secondary)
            StatsCard(title: scope == 0 ? year : (scope == 2 ? "Custom range" : "All time"),
                      subtitle: "\(longDate(from)) – \(longDate(to))",
                      stats: ShiftStats.compute(scopedLog, from: from, to: to))
        }
        .padding(20).frame(width: 560, alignment: .leading).background(Color(.systemBackground))
    }
}

/// Presents the system share sheet (so users can save to Files, Copy to Numbers, add to Calendar, etc.).
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable { let id = UUID(); let url: URL }

// MARK: - About (More → About)

struct AboutView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "bolt.fill").font(.system(size: 44)).foregroundStyle(.orange)
                    Text("Working-Bolt").font(.title2.bold())
                    Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            Section {
                Text("A companion for your shift schedule — see the open-shift pool, your roster, who's on, and your stats at a glance. It reads your own authorized account; you always accept shifts on the scheduler's own screen.")
                    .font(.subheadline)
            }
            Section {
                Text("Disclaimer: this is a prototype — but a damn good one. 🙂")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Feedback (More → Feedback)

struct FeedbackView: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "paperplane.fill").font(.system(size: 40)).foregroundStyle(.orange)
                    Text("Feedback").font(.title2.bold())
                }
                .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            Section {
                Text("Spotted a bug? Dreamt up a genius feature in the on-call room? Fire it over.\n\n🗑️  Negative comments are fed straight into the e-shredder.\n⛄  The rest might just make it to my basecamp at the North Pole.")
                    .font(.subheadline)
            }
            Section("How to send it") {
                Label("Take a screenshot while you're in the app", systemImage: "camera.viewfinder")
                Label("Tap “Share Beta Feedback” when TestFlight pops up", systemImage: "square.and.arrow.up")
                Label("Scribble a note — a picture of the mess says a thousand words", systemImage: "pencil.and.outline")
            }
            .font(.subheadline)
            Section {
                Text("Goes to TestFlight, not anyone's inbox — no spam, no “how satisfied are you, 1 to 10?” surveys. 🙂")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Feedback")
        .navigationBarTitleDisplayMode(.inline)
    }
}
