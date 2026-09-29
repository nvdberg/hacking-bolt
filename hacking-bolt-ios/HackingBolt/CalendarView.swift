import SwiftUI

/// My Shifts — the web-style month grid (coloured blocks, 24h calls fusing into post-call), via RosterCalendar.
struct CalendarView: View {
    @EnvironmentObject var model: AppModel
    var tabTick: Int = 0                       // MainTabs bumps this when My Shifts is tapped → re-center on current month
    @State private var jumpTick = 0            // "This Month" button
    @State private var targetYM = ""           // year-month picker → jump to that month

    private var log: [MyShift] { model.shiftLog.isEmpty ? model.myShifts : model.shiftLog }
    private let monthNames = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    @State private var pickGiveAway = false            // show the shift picker
    @State private var pickerShifts: [MyShift] = []    // which shifts the picker offers (a day's, or all upcoming)
    @State private var giveAwayShift: MyShift?         // chosen shift → presents the give-away wizard
    @State private var givePasqua: (rapid: MyShift, msu: MyShift)?   // set when the tapped day is a Pasqua Rapid+MSU pair
    @State private var pastAlert = false               // tapped a shift that can't be given away (past / no slot_id)
    @State private var choosing = false                // tap → choose: find a swap, or give away
    @State private var pendingShift: MyShift?          // the tapped shift awaiting that choice
    @State private var pendingPasqua: (rapid: MyShift, msu: MyShift)?
    @State private var swapSheet = false               // present the (shared) Swap/give-away screen preselected
    @State private var swapInitial: MyShift?
    @State private var swapGiveAway = false             // land straight in give-away within that shared screen
    @State private var shareItem: ShareItem?            // .ics export → share sheet
    @State private var timeOff = false                  // my time-off / night-off requests sheet
    @State private var whoISO: String?                  // double-tapped day → floating Who's On panel
    @State private var panelOffset = CalendarView.lastPanelOffset
    private static var lastPanelOffset: CGSize = .zero  // where the panel was dragged — kept while the app runs
    private var todayISO: String { AppModel.todayRegina() }
    // Upcoming shifts I could give away — from the LIVE harvest (myShifts), which carries the real slot_id
    // (the durable shiftLog's cached entries may predate slot_id tracking).
    private var giveable: [MyShift] {
        model.myShifts.filter { $0.slotID != nil && $0.date >= todayISO }.sorted { $0.date < $1.date }
    }
    // A Pasqua Rapid+MSU pair I work on this day (both givable) → treat as one 24h shift with a half-split option.
    private func pasquaPair(on iso: String) -> (rapid: MyShift, msu: MyShift)? {
        let day = giveable.filter { $0.date == iso }
        guard let r = day.first(where: { $0.unit == .PRR }), let m = day.first(where: { $0.unit == .MSU }) else { return nil }
        return (r, m)
    }
    /// Tapping one of my shift days: offer a choice — find a swap, or give it away. (Several unrelated that day → picker.)
    private func tapMyShift(_ iso: String) {
        guard !model.demo else { return }
        let day = giveable.filter { $0.date == iso }
        if let pair = pasquaPair(on: iso) { pendingPasqua = pair; pendingShift = pair.rapid; choosing = true }
        else if day.count == 1 { pendingPasqua = nil; pendingShift = day.first; choosing = true }
        else if day.count > 1 { pickerShifts = day; pickGiveAway = true }
        else { pastAlert = true }   // that day's shift is past or has no slot_id
    }

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
                ZStack(alignment: .bottom) {
                RosterCalendar(shifts: log,
                               userName: model.userName,
                               landscape: geo.size.width > geo.size.height,
                               scrollTick: jumpTick + tabTick,
                               jumpToYM: targetYM,
                               openDates: Set(model.openShifts.map { $0.iso }),
                               postedDates: model.postedPendingDates,
                               onOpenTap: { iso in model.poolJumpDate = iso; model.selectedTab = 0 },
                               onShiftTap: { iso in tapMyShift(iso) },
                               markedISO: whoISO,
                               pickMode: whoISO != nil,
                               onDayPick: { iso in withAnimation(.snappy(duration: 0.22)) { whoISO = iso } },
                               onRefresh: { await model.refresh() })
                if let iso = whoISO {
                    WhoDayPanel(iso: iso, bounds: geo.size, offset: $panelOffset,
                                onClose: { withAnimation(.snappy(duration: 0.2)) { whoISO = nil } })
                }
                }
            }
            .onChange(of: panelOffset) { _, o in CalendarView.lastPanelOffset = o }
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
                ToolbarItem(placement: .topBarLeading) {
                    Button { timeOff = true } label: { Image(systemName: "calendar.badge.minus") }
                        .tint(Theme.muted)
                        .accessibilityLabel("Time off requests")
                }
                // (Give-away shortcut removed — tap a shift in the grid to swap or give it away.)
                ToolbarItem(placement: .topBarTrailing) {
                    Button { if let url = ICSExporter.writeFile(shifts: log) { shareItem = ShareItem(url: url) } }
                        label: { Image(systemName: "square.and.arrow.up") }
                        .tint(Theme.muted).disabled(log.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("This Month") { jumpTick += 1 }
                        .font(.footnote.weight(.medium)).tint(Theme.muted)
                }
            }
            .sheet(isPresented: $pickGiveAway) {
                GiveAwayPicker(shifts: pickerShifts.isEmpty ? giveable : pickerShifts) { s in
                    pickGiveAway = false; giveAwayShift = s
                }
            }
            .alert("Can't give this one away", isPresented: $pastAlert) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.myShifts.isEmpty ? "Your live roster is still loading — try again in a moment." : "You can only give away upcoming shifts.") }
            .sheet(item: $giveAwayShift, onDismiss: { givePasqua = nil }) { s in
                GiveAwayWizard(shift: s, pasqua: givePasqua).environmentObject(model)
            }
            .confirmationDialog("What do you want to do with this shift?", isPresented: $choosing, titleVisibility: .visible) {
                Button("Find a swap") { swapInitial = pendingShift; swapGiveAway = false; swapSheet = true }
                Button("Give it away") { swapInitial = pendingShift; swapGiveAway = true; swapSheet = true }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $swapSheet) {
                NavigationStack {
                    SwapView(initialShift: swapInitial, initialGiveAway: swapGiveAway).environmentObject(model)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { swapSheet = false } } }
                }
            }
            .sheet(item: $shareItem) { ActivityView(items: [$0.url]) }   // .ics export → Add to Calendar
            .sheet(isPresented: $timeOff) { TimeOffView().environmentObject(model) }
            .overlay {
                if model.loading && model.myShifts.isEmpty {
                    ProgressView("Reading your roster…").tint(Theme.accent)
                }
            }
        }
        .task { await model.loadHistory() }        // backfill the full log (2022 →) so the calendar shows history too
    }
}
