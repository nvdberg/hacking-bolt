import SwiftUI

/// The witty lines shown on the opening screen. Editable in-app (Settings → Witty lines) and saved on
/// the device, so the pool can be tweaked without a rebuild. Seeded with ~50 defaults.
@MainActor
final class QuipStore: ObservableObject {
    static let shared = QuipStore()
    private let key = "hb_quips"

    @Published var quips: [String] { didSet { save() } }

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let a = try? JSONDecoder().decode([String].self, from: d), !a.isEmpty {
            quips = a
        } else {
            quips = Self.defaults
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(quips) { UserDefaults.standard.set(d, forKey: key) }
    }

    func add(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        quips.append(t)
    }
    func update(_ i: Int, _ s: String) {
        guard quips.indices.contains(i) else { return }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { quips.remove(at: i) } else { quips[i] = t }
    }
    func delete(at offsets: IndexSet) { quips.remove(atOffsets: offsets) }
    func move(from: IndexSet, to: Int)  { quips.move(fromOffsets: from, toOffset: to) }
    func resetToDefaults() { quips = Self.defaults }

    /// ~50 dry one-liners. The "sleepless nights" line gets a special enlarge effect on the splash.
    static let defaults: [String] = [
        "Grab the wrong shift and — surprise — you're working it. 🙂",
        "Not responsible for your sleepless nights.",
        "No take-backs: if you tapped it, it's yours.",
        "No “how much does your life suck today?” surveys. 🙂",
        "Tap “Available” and you are, in fact, now available.",
        "Reads your roster so you don't have to squint at it.",
        "Shows what's open. Doesn't judge how you got here.",
        "The pool is deep. The coffee is not.",
        "Every shift, colour-coded. Your regrets, not included.",
        "Post-call is a state of mind — and a legal rest requirement.",
        "We show the shifts. The consequences are between you and your calendar.",
        "Warning: contains other people's night shifts.",
        "If it says 08:00–08:00, believe it.",
        "Available ≠ advisable. You decide.",
        "Pick wisely. Or don't — we're not the scheduling committee.",
        "Swapping shifts since refreshing the roster 40 times a day stopped being fun.",
        "One tap closer to regret-free scheduling. Mostly.",
        "The roster doesn't lie. It just disappoints.",
        "Built by a colleague, not a committee.",
        "Your schedule, minus the doom-scrolling.",
        "Free shifts, hot and fresh. Handle with care.",
        "Coffee not included. It never is.",
        "We flag the conflicts. You still have to live your life.",
        "No pop-ups. No smileys. No “just checking in.”",
        "Rapid Response: the shift, not your reaction to this app.",
        "Somewhere, a shift is open. This app knows which one.",
        "The only pool at the hospital worth checking.",
        "Trades shifts, not stocks. Please don't confuse them.",
        "Yes, the December shifts are real. No, we can't hide them.",
        "If you're reading this, you probably have a shift to cover.",
        "Making questionable scheduling decisions faster than ever.",
        "Unofficial, unaffiliated, and quietly proud of it.",
        "Your future self will have opinions about this pickup.",
        "Colour-coded so you can panic more efficiently.",
        "We don't ask how you're feeling. We already know.",
        "All the open shifts. None of the guilt trip.",
        "Tap gently. It's a legally binding vibe.",
        "The night shift called. This app answered.",
        "More reliable than the on-call room WiFi.",
        "Suspiciously fewer clicks than the actual scheduler.",
        "Pick up a shift, or just admire them from afar.",
        "Sleep is for the unscheduled.",
        "This is what “work–life balance” looks like at 3 a.m.",
        "Every swap is a small act of optimism.",
        "We sort by date. Your priorities are your own business.",
        "Proudly enabling questionable overtime decisions.",
        "The shift board that doesn't ask you to log in every 12 minutes.",
        "You've got this. Or you've got a shift. Same thing.",
        "MSU nights don't advertise themselves. We do.",
        "Consider this your one and only warning label.",
        // — general dry / satirical —
        "Work expands to fill the shifts available.",
        "Everything's fine. That's what the coffee is for.",
        "Optimism is just a temporary shortage of information.",
        "A schedule is a to-do list that fights back.",
        "The plan survives right up until the first phone call.",
        "Multitasking: ruining several things at once, efficiently.",
        "Sleep — the feature everyone praises and no one uses.",
        "Experience is what you get right after you needed it.",
        "There are two kinds of plans: lucky and late.",
        "The early bird gets the shift nobody else wanted.",
        "Hard work pays off eventually. Procrastination pays off now.",
        "If it works, don't touch it. If it doesn't, you touched it.",
        "Deadlines move faster than the speed of light.",
        "Adulthood is mostly googling how to do things.",
        "Do it right, or do it twice.",
        "Behind every calm doctor is a very loud pager.",
        "Some days you're the defibrillator; some days you're the flatline.",
        "Reality called — it wants its overtime back.",
        // — self-aware — (the "prototype" disclaimer is a fixed line on the splash, not part of this rotation)
        "Version 0.1, and quietly proud of it.",
        "Held together by good intentions and caffeine.",
        "Built in a few evenings. Don't overthink it.",
        "Not a medical device. Just a very organised one.",
    ]
}

// MARK: - Settings tab

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSignOut = false

    var body: some View {
        NavigationStack {
            List {
                NavigationLink { StatsView() } label: { Label("My Stats", systemImage: "chart.bar.fill") }
                NavigationLink { ExportView() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                if model.isOwner {   // owner-only tools — hidden from the crew
                    NavigationLink { StartScreenSettings() } label: { Label("Start Screen", systemImage: "sparkles") }
                    NavigationLink { AdminView() } label: { Label("Admin", systemImage: "lock.shield") }
                }
                NavigationLink { FeedbackView() } label: { Label("Feedback", systemImage: "bubble.left.and.bubble.right") }
                NavigationLink { AboutView() } label: { Label("About", systemImage: "info.circle") }

                Section {
                    if !model.userName.isEmpty {
                        Text("Signed in as \(model.userName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) { showSignOut = true } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("More")
            .confirmationDialog("Sign out?", isPresented: $showSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { model.signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Clears the session and cached data on this device. Your history re-loads when you (or someone else) signs back in.")
            }
        }
    }
}

// MARK: - Admin (owner-only) — quick links into App Store Connect for managing testers + reading feedback.

struct AdminView: View {
    // Direct deep-links into App Store Connect (App ID 6792563972, "Colleagues" external group).
    private let testersURL = URL(string: "https://appstoreconnect.apple.com/apps/6792563972/testflight/groups/c37c1e17-2142-4b87-9bae-400dd799bc45")
    private let feedbackURL = URL(string: "https://appstoreconnect.apple.com/apps/6792563972/testflight")

    var body: some View {
        Form {
            Section("Testers") {
                if let u = testersURL {
                    Link(destination: u) { Label("Manage / add testers", systemImage: "person.2.badge.plus") }
                }
                Text("Opens App Store Connect. Add a colleague by email to invite them and track who's installed and using it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Feedback") {
                if let u = feedbackURL {
                    Link(destination: u) { Label("Tester feedback & crashes", systemImage: "exclamationmark.bubble") }
                }
                Text("Screenshots, comments, and crash reports from testers. Named testers show who sent what.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Admin only — visible just to you. These open App Store Connect in the browser (sign-in required).")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The opening-screen settings — duration for everyone; the witty-line editor is the owner's only.
struct StartScreenSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = QuipStore.shared
    @AppStorage("hb_show_admin") private var showAdmin = true

    var body: some View {
        Form {
            if model.isOwner {
                Section("Witty lines") {
                    NavigationLink {
                        QuotesView()
                    } label: {
                        HStack { Text("Edit lines"); Spacer()
                            Text("\(store.quips.count)").foregroundStyle(.secondary) }
                    }
                    Text("Shown one at a time on the opening screen — cycling, in random order.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Admin") {
                    Toggle("Show group comparison", isOn: $showAdmin)
                    Text("The “You vs group” card in My Stats (rankings vs the group). Turn off to hide it while showing the app to colleagues.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Start Screen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Witty-line editor

struct QuotesView: View {
    @ObservedObject private var store = QuipStore.shared
    @State private var editing: EditItem?
    @State private var adding = false

    struct EditItem: Identifiable { let id: Int; let text: String }

    var body: some View {
        List {
            ForEach(Array(store.quips.enumerated()), id: \.offset) { i, q in
                Text(q)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = EditItem(id: i, text: q) }
            }
            .onDelete { store.delete(at: $0) }
            .onMove   { store.move(from: $0, to: $1) }
        }
        .navigationTitle("Witty lines")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading)  { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Reset to defaults", role: .destructive) { store.resetToDefaults() }
            }
        }
        .sheet(item: $editing) { item in
            QuipEditor(text: item.text) { store.update(item.id, $0) }
        }
        .sheet(isPresented: $adding) {
            QuipEditor(text: "") { store.add($0) }
        }
    }
}

private struct QuipEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    var onSave: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Witty line", text: $text, axis: .vertical).lineLimit(1...5)
            }
            .navigationTitle(text.isEmpty ? "New line" : "Edit line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(text); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
