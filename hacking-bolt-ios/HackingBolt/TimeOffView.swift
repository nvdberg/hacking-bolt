import SwiftUI

/// One day of one of my time-off / night-off requests, as LB lists it (cached — every field but `id`/`date`
/// is tolerant so older caches keep decoding).
struct TimeOffRequest: Codable, Identifiable, Hashable {
    let id: Int                 // LB request_id (one per day)
    let date: String            // "YYYY-MM-DD"
    var status: String          // "pending" / "approved" / "denied" …
    var kind: String            // "Time Off" / "Night Off"
    var note: String
    var submitted: String?      // "YYYY-MM-DDTHH:MM:SS" (Regina)
    var decision: String?       // LB's decision / denial reason, if any

    var isPending: Bool { status.lowercased() == "pending" }
}

/// Consecutive days submitted together (same kind, note, status, submit time) — shown as one row.
struct TimeOffBlock: Identifiable {
    let days: [TimeOffRequest]
    var id: Int { days[0].id }
    var first: TimeOffRequest { days[0] }
    var ids: [Int] { days.map(\.id) }

    static func group(_ reqs: [TimeOffRequest]) -> [TimeOffBlock] {
        var out: [[TimeOffRequest]] = []
        for r in reqs.sorted(by: { $0.date < $1.date }) {
            if var last = out.last, let p = last.last,
               p.kind == r.kind, p.note == r.note, p.status == r.status, p.submitted == r.submitted,
               dateToISO(Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: isoToDate(p.date)) ?? isoToDate(p.date)) == r.date {
                last.append(r); out[out.count - 1] = last
            } else { out.append([r]) }
        }
        return out.map(TimeOffBlock.init)
    }
}

/// Matt's ask: request time off / a night off from Working-Bolt, see the status, cancel while pending.
/// Only ever touches the signed-in user's OWN requests; every send sits behind a confirm that says exactly what goes.
struct TimeOffView: View {     // pushed from More (under Swap or Give Away)
    @EnvironmentObject var model: AppModel

    @State private var composing = false
    @State private var cancelBlock: TimeOffBlock?
    @State private var busy = false
    @State private var result: (ok: Bool, text: String)?

    private var today: String { AppModel.todayRegina() }
    private var upcoming: [TimeOffBlock] { TimeOffBlock.group(model.myRequests.filter { $0.date >= today }) }
    private var past: [TimeOffBlock] { TimeOffBlock.group(model.myRequests.filter { $0.date < today }).reversed() }

    var body: some View {
        List {
            Section {
                Button { composing = true } label: {
                    Label("New request", systemImage: "plus.circle.fill").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .disabled(busy)
            }
            if let r = result {
                Section {
                    Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(r.ok ? Theme.accent : Theme.available)
                }
            }
            Section {
                if upcoming.isEmpty {
                    Text(model.requestsLoading ? "Loading your requests…" : "No upcoming requests.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                ForEach(upcoming) { b in
                    TimeOffRow(block: b)
                        .swipeActions(edge: .trailing) {
                            if b.first.isPending {
                                Button("Cancel") { cancelBlock = b }.tint(.red)
                            }
                        }
                        .contextMenu {
                            if b.first.isPending { Button("Cancel request", systemImage: "xmark.circle", role: .destructive) { cancelBlock = b } }
                        }
                }
            } header: { Text("Upcoming") } footer: {
                if upcoming.contains(where: { $0.first.isPending }) { Text("Swipe a pending request to cancel it.") }
            }
            if !past.isEmpty {
                Section("Past") {
                    ForEach(past) { b in TimeOffRow(block: b).opacity(0.6) }
                }
            }
            Section {                                            // quiet easter egg — the feature was Matt's idea
                Text("Matt's idea 🤝").font(.caption2).italic()
                    .foregroundStyle(Theme.muted).frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("Time Off")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if busy || model.requestsLoading { ToolbarItem(placement: .primaryAction) { ProgressView() } }
        }
        .refreshable { await model.loadRequests() }
        .task { await model.loadRequests() }
        .sheet(isPresented: $composing) {
            TimeOffCompose { kind, dates, note in
                composing = false
                Task { await send(kind: kind, dates: dates, note: note) }
            }
            .environmentObject(model)
        }
        .confirmationDialog(cancelTitle, isPresented: Binding(get: { cancelBlock != nil }, set: { if !$0 { cancelBlock = nil } }),
                            titleVisibility: .visible, presenting: cancelBlock) { b in
            Button(b.days.count == 1 ? "Cancel this request" : "Cancel all \(b.days.count) days", role: .destructive) {
                Task { await cancel(b) }
            }
            Button("Keep it", role: .cancel) {}
        } message: { b in
            Text("Asks Lightning Bolt to delete your \(b.first.kind) request for \(TimeOffRow.range(b)). Nothing else changes.")
        }
    }

    private var cancelTitle: String { "Cancel \(cancelBlock?.first.kind ?? "") request?" }

    private func send(kind: LBWebSource.RequestKind, dates: [String], note: String) async {
        busy = true; defer { busy = false }
        let out = await model.submitTimeOff(kind: kind, dates: dates, note: note)
        result = out.ok ? (true, "Sent — \(kind.rawValue) for \(dates.count) day\(dates.count == 1 ? "" : "s") is pending approval.")
                        : (false, out.message ?? "Lightning Bolt didn't accept it.")
    }
    private func cancel(_ b: TimeOffBlock) async {
        busy = true; defer { busy = false }
        let out = await model.cancelRequests(ids: b.ids)
        result = out.ok ? (true, "Cancelled.") : (false, out.message ?? "Lightning Bolt didn't accept the cancel.")
    }
}

/// One request block: kind, dates, note, status.
struct TimeOffRow: View {
    let block: TimeOffBlock

    static func range(_ b: TimeOffBlock) -> String {
        let a = b.days.first!.date, z = b.days.last!.date
        return a == z ? fmt(a, "EEE, MMM d") : "\(fmt(a, "EEE, MMM d")) – \(fmt(z, "EEE, MMM d"))"
    }
    private var statusColor: Color {
        switch block.first.status.lowercased() {
        case "pending":  return Theme.available
        case "approved", "granted": return Theme.accent
        default:         return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: block.first.kind == "Night Off" ? "moon.zzz.fill" : "sun.max.fill")
                .font(.title3).foregroundStyle(Theme.muted).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(block.first.kind).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    if block.days.count > 1 { Text("· \(block.days.count) days").font(.caption).foregroundStyle(Theme.muted) }
                }
                Text(Self.range(block)).font(.footnote).foregroundStyle(Theme.ink)
                if !block.first.note.isEmpty {
                    Text("“\(block.first.note)”").font(.caption).foregroundStyle(Theme.muted).lineLimit(2)
                }
                if let d = block.first.decision, !d.isEmpty {
                    Text(d).font(.caption).foregroundStyle(statusColor).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Text(block.first.status.capitalized)
                .font(.caption2.weight(.bold)).foregroundStyle(statusColor)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(statusColor.opacity(0.14), in: Capsule())
        }
        .padding(.vertical, 2)
    }
}

/// Compose a new request: kind, the days (LB's own UI picks individual dates too), a reason → confirm → send.
struct TimeOffCompose: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onSend: (LBWebSource.RequestKind, [String], String) -> Void

    @State private var kind: LBWebSource.RequestKind = .timeOff
    @State private var picked: Set<DateComponents> = []
    @State private var note = ""
    @State private var confirming = false

    private static let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = .current; return c }()
    private var dates: [String] {
        picked.compactMap { c in
            guard let y = c.year, let m = c.month, let d = c.day else { return nil }
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
        .filter { $0 >= AppModel.todayRegina() }
        .sorted()
    }
    /// Days I'm already rostered on — worth knowing before asking for them off.
    private var clashes: [(String, String)] {
        let set = Set(dates)
        let log = model.shiftLog.isEmpty ? model.myShifts : model.shiftLog
        var byDay: [String: [String]] = [:]                          // one line per day (a Pasqua pair = two units)
        for sh in log where set.contains(sh.date) { byDay[sh.date, default: []].append(Units.info[sh.unit]?.short ?? sh.unit.rawValue) }
        return byDay.keys.sorted().map { ($0, byDay[$0]!.joined(separator: " + ")) }
    }
    private var datesSummary: String {
        guard let a = dates.first, let z = dates.last else { return "" }
        if dates.count == 1 { return fmt(a, "EEE, MMM d") }
        return "\(dates.count) days · \(fmt(a, "MMM d")) – \(fmt(z, "MMM d"))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(LBWebSource.RequestKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                Section {
                    MultiDatePicker("Days", selection: $picked, in: Self.cal.startOfDay(for: isoToDate(AppModel.todayRegina()))...)
                        .tint(Theme.accent)
                        .environment(\.calendar, Self.cal)
                } header: { Text("Days") } footer: {
                    Text(dates.isEmpty ? "Tap each day you want off." : datesSummary)
                }
                if !clashes.isEmpty {
                    Section {
                        ForEach(clashes, id: \.0) { c in
                            Label("You're rostered \(c.1) on \(fmt(c.0, "EEE, MMM d"))", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote).foregroundStyle(Theme.available)
                        }
                    } footer: { Text("A request doesn't move a shift you already have — swap or give it away separately.") }
                }
                Section("Reason") {
                    TextField("e.g. family event", text: $note, axis: .vertical).lineLimit(1...4)
                }
                Section {
                    Button { confirming = true } label: {
                        Text("Review & send").frame(maxWidth: .infinity).font(.body.weight(.semibold))
                    }
                    .disabled(dates.isEmpty)
                } footer: {
                    Text(model.demo ? "Sample data — nothing is sent in the preview." : "Goes to Lightning Bolt as a pending request for your scheduler to approve. You can cancel it while it's pending.")
                }
            }
            .navigationTitle("New request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Send this request?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Send \(kind.rawValue) request") {
                    onSend(kind, dates, note.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                Button("Not yet", role: .cancel) {}
            } message: {
                Text("\(kind.rawValue) · \(datesSummary)\n\(note.isEmpty ? "No reason given" : "Reason: “\(note)”")\n\nSent to Lightning Bolt for your own roster only.")
            }
        }
    }
}
