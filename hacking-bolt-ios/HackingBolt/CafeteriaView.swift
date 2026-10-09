import SwiftUI

// MARK: - Cafeteria menu (More → Cafeteria menu)
//
// The RGH / Pasqua daily specials are a rotating cycle of weekly pages (cafeteriamenuRGH1.htm, …) on the hospital
// intranet. The Unit Board captures each page once into Supabase `cafeteria_menu`; here we pick the page for a date.

@MainActor final class CafeteriaStore: ObservableObject {
    static let shared = CafeteriaStore()
    typealias Page = Supabase.SupaMenuPage

    @Published private(set) var pages: [Page] = []
    @Published private(set) var loaded = false
    private var fetchedAt: Date?

    private static var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("hb_menus.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL), let p = try? JSONDecoder().decode([Page].self, from: data) {
            pages = p; loaded = !p.isEmpty
        }
    }

    /// Re-read at most every 30 min. A failed or empty read keeps the menus we already have.
    func load(demo: Bool) async {
        #if DEBUG
        let demo = demo && ProcessInfo.processInfo.environment["DEMO_REAL_MENU"] != "1"
        #endif
        if demo { if pages.isEmpty { pages = Self.demoPages() }; loaded = true; return }
        if let t = fetchedAt, Date().timeIntervalSince(t) < 1800 { return }
        guard let p = await Supabase.cafeteriaMenus() else { loaded = true; return }
        fetchedAt = Date(); loaded = true
        guard !p.isEmpty else { return }
        pages = p
        if let data = try? JSONEncoder().encode(p) { try? data.write(to: Self.fileURL) }
    }

    /// The menu for `iso` at `site`: a page that prints that date, else the rotation counted from the first page.
    func menu(_ iso: String, site: String) -> (day: Supabase.SupaMenuDay, week: Int, of: Int)? {
        let ps = pages.filter { $0.site == site }.sorted { $0.page < $1.page }
        guard !ps.isEmpty else { return nil }
        for (i, p) in ps.enumerated() {
            if let d = p.days?.first(where: { $0.date == iso }) { return (d, i + 1, ps.count) }
        }
        guard let ai = ps.firstIndex(where: { $0.first_date != nil }), let anchor = ps[ai].first_date else { return nil }
        let diff = Calendar.current.dateComponents([.day], from: isoToDate(anchor), to: isoToDate(iso)).day ?? 0
        let weeks = Int((Double(diff) / 7).rounded(.down))
        let idx = ((ai + weeks) % ps.count + ps.count) % ps.count
        let days = ps[idx].days ?? []
        let dow = fmt(iso, "EEEE").uppercased()
        let offset = ((diff % 7) + 7) % 7
        guard let d = days.first(where: { ($0.weekday ?? "").uppercased().hasPrefix(dow) })
                ?? (offset < days.count ? days[offset] : nil) else { return nil }
        return (d, idx + 1, ps.count)
    }

    private static func demoPages() -> [Page] {
        typealias S = Supabase.SupaMenuSection; typealias I = Supabase.SupaMenuItem
        let sunday = AppModel.addDays(AppModel.todayRegina(), -(Int(fmt(AppModel.todayRegina(), "e")) ?? 1) + 1)
        let names = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
        let soups = ["Cream of Mushroom", "Beef Barley", "Chicken Noodle", "Roasted Red Pepper", "Split Pea", "Clam Chowder", "Minestrone"]
        let mains = ["Butter Chicken", "Bacon Cheeseburger with choice of side", "Shepherd's Pie", "Fish & Chips",
                     "Perogy Platter", "Lasagna", "Pork Schnitzel"]
        func page(_ site: String) -> Page {
            Page(site: site, page: 1, first_date: sunday, days: names.enumerated().map { i, w in
                Supabase.SupaMenuDay(date: AppModel.addDays(sunday, i), weekday: w, sections: [
                    S(label: "Café Pizza", items: [I(name: "Pepperoni", price: "$3.75")]),
                    S(label: "Today's Soup", items: [I(name: soups[i], price: "Sm - $2.25 Lg - $2.75")]),
                    S(label: "Lunch Feature", items: [I(name: mains[i], price: "$8.95")]),
                    S(label: "Side", items: [I(name: "Mixed Greens with Carrots & Cucumber", price: "$2.50")]),
                    S(label: "Supper Feature", items: [I(name: mains[(i + 3) % 7], price: "$9.25")]),
                ])
            })
        }
        return [page("RGH"), page("PH")]
    }
}

struct CafeteriaView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = CafeteriaStore.shared
    @AppStorage("hb_cafe_site") private var site = "RGH"
    @State private var iso = AppModel.todayRegina()

    private var today: String { AppModel.todayRegina() }
    private var menu: (day: Supabase.SupaMenuDay, week: Int, of: Int)? { store.menu(iso, site: site) }

    var body: some View {
        List {
            Section {
                Picker("Site", selection: $site) {
                    Text("RGH").tag("RGH")
                    Text("Pasqua").tag("PH")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                HStack {
                    Button { iso = AppModel.addDays(iso, -1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 6) {   // one line — keeps the menu on one screen
                        Text(fmt(iso, "EEEE")).font(.headline).foregroundStyle(iso == today ? Theme.accent : Theme.ink)
                        Text(fmt(iso, "MMMM d")).font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button { iso = AppModel.addDays(iso, 1) } label: { Image(systemName: "chevron.right") }
                }
                .buttonStyle(.borderless).font(.title3.weight(.semibold)).tint(Theme.accent)
            }

            if let m = menu {
                // A card per special, tight rows + compact gaps so a day nearly fits on one screen.
                ForEach(Array(lunchFirst(m.day.sections ?? []).enumerated()), id: \.offset) { _, sec in
                    let items = (sec.items ?? []).filter { !($0.name ?? "").isEmpty }
                    if !items.isEmpty {
                        Section {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(it.name ?? "").font(.body).foregroundStyle(Theme.ink)
                                    Spacer(minLength: 6)
                                    if let p = it.price, !p.isEmpty {
                                        Text(p).font(.footnote.monospacedDigit()).foregroundStyle(Theme.muted)
                                            .multilineTextAlignment(.trailing)
                                    }
                                }
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                            }
                        } header: {
                            header(sec.label ?? "")
                        }
                    }
                }
                Section {} footer: {
                    Text("Menu week \(m.week) of \(m.of) · prices as printed. Rotating menu — if today looks off, blame the kitchen.")
                }
            } else if !store.loaded {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the specials…") }
                    .font(.subheadline).foregroundStyle(Theme.muted)
            } else {
                Section {} footer: {
                    Text(store.pages.contains { $0.site == site }
                         ? "Nothing listed for this day."
                         : "No menu yet — it's captured from the hospital intranet. Check back soon.")
                }
            }
        }
        .listSectionSpacing(4)
        .contentMargins(.top, 0, for: .scrollContent)     // site tabs right under the title
        .environment(\.defaultMinListRowHeight, 28)
        .navigationTitle("Cafeteria")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Today") { iso = today }.font(.footnote.weight(.medium)).disabled(iso == today)
            }
        }
        .task { await store.load(demo: model.demo) }
        .refreshable { await store.load(demo: model.demo) }
    }

    /// Lunch on top, with the side(s) printed right after it; everything else keeps the printed order.
    private func lunchFirst(_ secs: [Supabase.SupaMenuSection]) -> [Supabase.SupaMenuSection] {
        let has = { (s: Supabase.SupaMenuSection, w: String) in (s.label ?? "").localizedCaseInsensitiveContains(w) }
        guard let li = secs.firstIndex(where: { has($0, "lunch") }) else { return secs }
        var end = li + 1
        while end < secs.count, has(secs[end], "side") { end += 1 }
        return Array(secs[li..<end]) + Array(secs[..<li]) + Array(secs[end...])
    }

    /// Lunch and supper features stand out (☀ / 🌙, accent); the rest get a plain header.
    @ViewBuilder private func header(_ label: String) -> some View {
        let l = label.lowercased()
        let icon = l.contains("lunch") ? "sun.max.fill" : l.contains("supper") || l.contains("dinner") ? "moon.fill" : nil
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon) }
            Text(label)
        }
        .font(.subheadline.weight(icon != nil ? .bold : .semibold))
        .foregroundStyle(icon != nil ? Theme.accent : Theme.muted)
        .padding(.top, -6).padding(.bottom, -2)
    }
}
