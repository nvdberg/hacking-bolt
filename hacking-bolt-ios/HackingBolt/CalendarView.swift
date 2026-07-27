import SwiftUI

/// My Shifts — the web-style month grid (coloured blocks, 24h calls fusing into post-call), via RosterCalendar.
struct CalendarView: View {
    @EnvironmentObject var model: AppModel
    var tabTick: Int = 0                       // MainTabs bumps this when My Shifts is tapped → re-center on current month
    @State private var jumpTick = 0            // "This Month" button
    @State private var targetYM = ""           // year-month picker → jump to that month

    private var log: [MyShift] { model.shiftLog.isEmpty ? model.myShifts : model.shiftLog }
    private let monthNames = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    // Months present in the log, grouped by year (both descending) — powers the "jump back" picker.
    private var yearMonths: [(year: Int, months: [Int])] {
        var map: [Int: Set<Int>] = [:]
        for d in log.map(\.date) {
            if let y = Int(d.prefix(4)), let m = Int(d.dropFirst(5).prefix(2)) { map[y, default: []].insert(m) }
        }
        return map.keys.sorted(by: >).map { y in (y, map[y]!.sorted(by: >)) }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                RosterCalendar(shifts: log,
                               userName: model.userName,
                               landscape: geo.size.width > geo.size.height,
                               scrollTick: jumpTick + tabTick,
                               jumpToYM: targetYM,
                               openDates: Set(model.openShifts.map { $0.iso }),
                               onOpenTap: { iso in model.poolJumpDate = iso; model.selectedTab = 0 },
                               onRefresh: { await model.refresh() })
            }
            .navigationTitle("My Shifts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(yearMonths, id: \.year) { ym in
                            Menu(String(ym.year)) {
                                ForEach(ym.months, id: \.self) { m in
                                    Button("\(monthNames[m]) \(String(ym.year))") {
                                        targetYM = String(format: "%04d-%02d", ym.year, m)
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "calendar.badge.clock")
                    }
                    .tint(Theme.muted)
                    .disabled(log.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("This Month") { jumpTick += 1 }
                        .font(.footnote.weight(.medium)).tint(Theme.muted)
                }
            }
            .overlay {
                if model.loading && model.myShifts.isEmpty {
                    ProgressView("Reading your roster…").tint(Theme.accent)
                }
            }
        }
        .task { await model.loadHistory() }        // backfill the full log (2022 →) so the calendar shows history too
    }
}
