import SwiftUI

/// Crew — pick a few doctors and see when they're working, in the exact Who's On format (units × days),
/// but only your chosen people appear in the cells; everyone else is left blank. Handy for spotting shared
/// off-days to plan time away together.
struct CompareView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hb_selectedDocs") private var selectedRaw = ""     // "\n"-joined doctor names, persisted
    @State private var selectedISO = WhoView.todayISO()
    @State private var scrollTick = 0
    @State private var visibleMonth = ""
    @State private var showPicker = false

    private var selected: [String] { selectedRaw.split(separator: "\n").map(String.init) }
    private var selectedSet: Set<String> { Set(selected) }

    private var allDocs: [String] {
        Array(Set(model.whoData.map(\.doc)))
            .sorted { surname($0).localizedCaseInsensitiveCompare(surname($1)) == .orderedAscending }
    }
    private var chosen: [String] {
        selected.sorted { surname($0).localizedCaseInsensitiveCompare(surname($1)) == .orderedAscending }
    }

    // Same shape as Who's On, but only the chosen doctors' assignments — so cells for everyone else are blank.
    private var byDay: [String: [Assignment]] {
        Dictionary(grouping: model.whoData.filter { selectedSet.contains($0.doc) }) { $0.date }
    }
    private var days: [String] { model.whoDays }
    private var selectedDate: Binding<Date> {
        Binding(get: { isoToDate(selectedISO) }, set: { selectedISO = dateToISO($0) })
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Text("you can thank Pieter")               // feature credit 🙂 (above the chips, no clash)
                            .font(.caption2).italic().foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 14).padding(.top, 4)
                    chipsBar
                    Divider().overlay(Theme.line)
                    if selected.isEmpty {
                        emptyPrompt
                    } else if landscape {
                        WhoWeekGrid(days: days, byDay: byDay, todayISO: WhoView.todayISO(),
                                    scrollTo: selectedISO, scrollTick: scrollTick,
                                    availHeight: geo.size.height - 52, visibleMonth: $visibleMonth)   // minus the chips bar
                    } else {
                        WhoDayTimeline(days: days, byDay: byDay, todayISO: WhoView.todayISO(),
                                       scrollTo: $selectedISO, scrollTick: scrollTick)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.bg.ignoresSafeArea())
            }
            .navigationTitle(visibleMonth.isEmpty ? "Crew" : visibleMonth)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !days.isEmpty && !selected.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        DatePicker("", selection: selectedDate, in: isoToDate(days.first!)...isoToDate(days.last!),
                                   displayedComponents: .date).labelsHidden().tint(Theme.muted)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Today") { selectedISO = WhoView.todayISO(); scrollTick += 1 }
                            .font(.footnote.weight(.medium)).tint(Theme.muted)
                            .disabled(!days.contains(WhoView.todayISO()))
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                DocPicker(allDocs: allDocs, myName: model.userName, selectedRaw: $selectedRaw)
            }
        }
        .task { await model.loadGroupHistory() }       // full group history (2022 →) powers Crew too
    }

    private var chipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { showPicker = true } label: {
                    Label(selected.isEmpty ? "Choose doctors" : "Add", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.accent.opacity(0.14)).foregroundStyle(Theme.accent).clipShape(Capsule())
                }
                ForEach(chosen, id: \.self) { doc in
                    HStack(spacing: 5) {
                        Text(doc == model.userName ? "You" : doc).font(.caption.weight(.semibold)).lineLimit(1)
                        Button { remove(doc) } label: { Image(systemName: "xmark.circle.fill").font(.caption2) }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Theme.panel).foregroundStyle(Theme.ink)
                    .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1)).clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
    }

    private var emptyPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.3").font(.system(size: 34)).foregroundStyle(Theme.muted)
            Text("Pick a few doctors to see when they're working").font(.subheadline).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text("Their shifts show in the grid; blank means off — handy for finding shared days away.")
                .font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Button("Choose doctors") { showPicker = true }
                .font(.subheadline.weight(.semibold)).tint(Theme.accent).padding(.top, 4)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func remove(_ doc: String) {
        selectedRaw = selected.filter { $0 != doc }.joined(separator: "\n")
    }
}

// MARK: - Doctor picker

struct DocPicker: View {
    let allDocs: [String]
    let myName: String
    @Binding var selectedRaw: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var selected: Set<String> { Set(selectedRaw.split(separator: "\n").map(String.init)) }
    private var filtered: [String] {
        search.isEmpty ? allDocs : allDocs.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.self) { doc in
                Button {
                    var s = selected
                    if s.contains(doc) { s.remove(doc) } else { s.insert(doc) }
                    selectedRaw = s.sorted().joined(separator: "\n")
                } label: {
                    HStack {
                        Text(doc == myName ? "\(doc) (you)" : doc).foregroundStyle(Theme.ink)
                        Spacer()
                        if selected.contains(doc) {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold)
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search doctors")
            .navigationTitle("Doctors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !selected.isEmpty { Button("Clear") { selectedRaw = "" }.tint(Theme.muted) }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Last-name helper (drop the first name), shared with Who's On.
func surname(_ name: String) -> String {
    let parts = name.split(separator: " ")
    return parts.count > 1 ? parts.dropFirst().joined(separator: " ") : name
}
