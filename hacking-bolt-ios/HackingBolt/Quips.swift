import SwiftUI
import UIKit

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
                NavigationLink { SwapView() } label: { Label("Swap or Give Away", systemImage: "arrow.triangle.2.circlepath") }
                NavigationLink { StatsView() } label: { Label("My Stats", systemImage: "chart.bar.fill") }
                NavigationLink { ExportView() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                NavigationLink { CalendarSyncView() } label: { Label("Sync to Calendar", systemImage: "calendar.badge.clock") }
                NavigationLink { AdvancedView() } label: { Label("Advanced", systemImage: "slider.horizontal.3") }
                NavigationLink { FaceIDLoginView() } label: { Label("Sign in with Face ID", systemImage: "faceid") }
                if model.isOwner {   // owner-only tools — hidden from the crew
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

// MARK: - Advanced — a home for user-specific personalization (Matt's suggestion). Future tweaks land here.

struct AdvancedView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hb_default_tab") private var defaultTab = 0
    @AppStorage("hb_pool_forme") private var poolForMe = false
    @AppStorage("hb_myposts_mode") private var myPostsMode = "auto"
    @AppStorage("hb_week_start") private var weekStart = 0

    private var hennie: (start: String, end: String, days: Int)? {
        nextHennieHoliday(model.shiftLog.isEmpty ? model.myShifts : model.shiftLog, today: AppModel.todayRegina())
    }

    var body: some View {
        Form {
            Section {
                Picker("Open the app on", selection: $defaultTab) {
                    Text("Shift Pool").tag(0)
                    Text("My Shifts").tag(1)
                    Text("Who's On").tag(2)
                    Text("Crew").tag(3)
                }
                Toggle("Shift Pool opens on \u{201C}For me\u{201D}", isOn: $poolForMe)
                Picker("My Posts tab", selection: $myPostsMode) {
                    Text("Auto — when I have posts").tag("auto")
                    Text("Always show").tag("always")
                    Text("Only when awaiting pickup").tag("pending")
                }
                Picker("Week starts on", selection: $weekStart) {
                    Text("Sunday").tag(0)
                    Text("Monday").tag(1)
                }
                NavigationLink { WhoOnOrderView() } label: { Label("Who's On order", systemImage: "arrow.up.arrow.down") }
                NavigationLink { AppIconPicker() } label: { Label("App icon", systemImage: "app.badge") }
                NavigationLink { QuotesView() } label: { Label("Witty lines", systemImage: "text.quote") }
            } header: {
                Text("Personalize")
            } footer: {
                Text("Make it yours. Witty lines start from the built-in set — add your own, or Reset to bring ours back. More options coming; send ideas via Feedback.")
            }

            Section {
                if let h = hennie {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("🌴 Next Hennie holiday").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        Text("\(fmt(h.start, "EEE, MMM d")) – \(fmt(h.end, "EEE, MMM d"))")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                        Text("\(h.days) days off in a row").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } else {
                    Text("No Hennie holiday on the horizon. Chin up — go pick one up. ☕️").font(.subheadline)
                }
            } header: {
                Text("Hennie holiday")
            } footer: {
                Text("Your next run of 4+ days off in a row. You know the one.")
            }

            if model.isOwner {
                Section("Owner") {
                    NavigationLink { StartScreenSettings() } label: { Label("Admin cards", systemImage: "eye") }
                }
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - App icon picker — swap the home-screen icon (alternate icons in the asset catalog).

struct AppIconPicker: View {
    // (label, alternate-icon-set name or nil = default "Classic", bolt tint, background)
    private let options: [(name: String, note: String, alt: String?, tint: Color, bg: Color)] = [
        ("Classic",  "Stealth black",        nil,            Color(hex: 0x6E7681), Color(hex: 0x15181D)),
        ("Neon",     "Electric cyan",        "AppIcon-Neon", Color(hex: 0x67E8F9), Color(hex: 0x0B1220)),
        ("Gold",     "Solid gold",           "AppIcon-Gold", Color(hex: 0xF5C542), Color(hex: 0x161206)),
        ("Code Red", "Night-shift red",      "AppIcon-Red",  Color(hex: 0xFF5B6B), Color(hex: 0x1A0A0C)),
    ]
    @State private var current = UIApplication.shared.alternateIconName

    var body: some View {
        List {
            Section {
                ForEach(options, id: \.name) { opt in
                    Button { setIcon(opt.alt) } label: {
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(opt.bg)
                                .frame(width: 54, height: 54)
                                .overlay(Image(systemName: "bolt.fill").font(.system(size: 24, weight: .black)).foregroundStyle(opt.tint))
                                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.08)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(opt.name).font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                                Text(opt.note).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if current == opt.alt {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).font(.title3)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Changes the icon on your home screen. iOS shows a quick confirmation the first time.")
            }
        }
        .navigationTitle("App icon")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setIcon(_ alt: String?) {
        guard UIApplication.shared.alternateIconName != alt else { return }
        UIApplication.shared.setAlternateIconName(alt) { err in
            DispatchQueue.main.async { if err == nil { current = alt } }
        }
    }
}

/// The next stretch of 4+ consecutive days off in the roster ("a Hennie holiday"), from today onward.
/// Only counts gaps that are bracketed by a worked day (so the open-ended void past the roster's end
/// isn't mistaken for a holiday).
func nextHennieHoliday(_ shifts: [MyShift], today: String) -> (start: String, end: String, days: Int)? {
    let iso = DateFormatter(); iso.dateFormat = "yyyy-MM-dd"
    iso.timeZone = TimeZone(identifier: "UTC"); iso.locale = Locale(identifier: "en_US_POSIX")
    let cal = Calendar(identifier: .gregorian)
    let worked = Set(shifts.map { $0.date })
    guard let startDate = iso.date(from: today),
          let lastShift = shifts.map({ $0.date }).max(), let lastDate = iso.date(from: lastShift),
          startDate <= lastDate else { return nil }
    var runStart: Date? = nil
    var d = startDate
    while d <= lastDate {
        if worked.contains(iso.string(from: d)) {
            if let rs = runStart {
                let days = cal.dateComponents([.day], from: rs, to: d).day ?? 0     // rs ..< d
                if days >= 4, let end = cal.date(byAdding: .day, value: -1, to: d) {
                    return (iso.string(from: rs), iso.string(from: end), days)
                }
            }
            runStart = nil
        } else if runStart == nil {
            runStart = d
        }
        guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
        d = next
    }
    return nil
}

// MARK: - Who's On order — drag to reorder the unit rows in the Who's Working grid (saved on-device).

struct WhoOnOrderView: View {
    @ObservedObject private var store = UnitOrderStore.shared

    var body: some View {
        List {
            Section {
                ForEach(store.order, id: \.self) { u in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(Units.info[u]?.color ?? .gray).frame(width: 13, height: 13)
                        Text(Units.info[u]?.short ?? u.rawValue).font(.body.weight(.medium))
                        Spacer()
                        Text(Units.info[u]?.full ?? "").font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
            } header: {
                Text("Drag to reorder the unit rows in Who's On (both the day timeline and the week grid).")
            }
        }
        .environment(\.editMode, .constant(.active))     // always draggable — no Edit button needed
        .navigationTitle("Who's On order")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reset") { withAnimation { store.reset() } }
            }
        }
    }
}

// MARK: - Admin (owner-only) — quick links into App Store Connect for managing testers + reading feedback.

struct AdminView: View {
    // Direct deep-links into App Store Connect (App ID 6792563972, "Colleagues" external group).
    private let testersURL = URL(string: "https://appstoreconnect.apple.com/apps/6792563972/testflight/groups/c37c1e17-2142-4b87-9bae-400dd799bc45")
    private let feedbackURL = URL(string: "https://appstoreconnect.apple.com/apps/6792563972/testflight")
    // Public TestFlight join link for the Colleagues group — share this to onboard a colleague (no email invite,
    // avoids the "invitation revoked/invalid" issue). They install TestFlight, open the link, done.
    private let inviteLink = "https://testflight.apple.com/join/9ThGvNv3"
    // Unlisted App Store page — anyone with the link installs straight from the App Store (no TestFlight).
    private let appStoreLink = "https://apps.apple.com/app/working-bolt/id6792563972"
    @State private var copied = false
    @State private var appCopied = false

    var body: some View {
        Form {
            Section("App Store link") {
                Text(appStoreLink).font(.footnote).foregroundStyle(Theme.accent).textSelection(.enabled)
                if let u = URL(string: appStoreLink) {
                    ShareLink(item: u) { Label("Share App Store link", systemImage: "square.and.arrow.up") }
                }
                Button {
                    UIPasteboard.general.string = appStoreLink
                    appCopied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { appCopied = false }
                } label: { Label(appCopied ? "Copied!" : "Copy App Store link", systemImage: appCopied ? "checkmark" : "doc.on.doc") }
                Text("The app is on the App Store (unlisted). Send a colleague this link and they install it straight from the App Store — no TestFlight needed. This is the simplest way to onboard someone now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Invite link") {
                Text(inviteLink).font(.footnote).foregroundStyle(Theme.accent).textSelection(.enabled)
                if let u = URL(string: inviteLink) {
                    ShareLink(item: u) { Label("Share invite link", systemImage: "square.and.arrow.up") }
                }
                Button {
                    UIPasteboard.general.string = inviteLink
                    copied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: { Label(copied ? "Copied!" : "Copy invite link", systemImage: copied ? "checkmark" : "doc.on.doc") }
                Text("Send this to a colleague to onboard them — they install TestFlight, tap the link, and they're in. No email invite needed (avoids the revoked/invalid link problem).")
                    .font(.caption).foregroundStyle(.secondary)
            }
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

/// Available to every user (More → Sign in with Face ID): opt in to store your OWN Lightning Bolt login in this
/// device's Face ID–protected Keychain, so the app re-signs-in automatically when your LB session expires.
struct FaceIDLoginView: View {
    @AppStorage("hb_faceid_login") private var faceIDOn = false
    @State private var showCredSheet = false

    var body: some View {
        Form {
            Section {
                Toggle("Sign in automatically with Face ID", isOn: Binding(
                    get: { faceIDOn },
                    set: { on in
                        if on { showCredSheet = true }                 // collect creds in the sheet, then store
                        else { LBCreds.clear(); faceIDOn = false }     // forget them
                    }))
                .disabled(!LBCreds.biometricsAvailable)
            } footer: {
                Text(LBCreds.biometricsAvailable
                     ? "Saves your Lightning Bolt username + password in this device's Face ID / Touch ID–protected Keychain, so the app signs you back in automatically when your Lightning Bolt session expires — no retyping. It stays on this device only, is never sent anywhere, and only unlocks with Face ID. Turn off to erase it."
                     : "Face ID / Touch ID isn't set up on this device, so automatic sign-in isn't available.")
            }
        }
        .navigationTitle("Face ID sign-in").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCredSheet) {
            FaceIDSetupSheet { faceIDOn = true }   // called only after a successful save
        }
    }
}

/// Owner enters their Lightning Bolt username + password once; it's saved to the Face ID–protected Keychain
/// (never transmitted). The password is typed by the user into a SecureField — the app only holds it long
/// enough to store it locally.
struct FaceIDSetupSheet: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var user = ""
    @State private var pass = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Lightning Bolt sign-in") {
                    TextField("Username", text: $user).textContentType(.username).autocorrectionDisabled().textInputAutocapitalization(.never)
                    SecureField("Password", text: $pass).textContentType(.password)
                }
                if let error { Section { Text(error).font(.callout).foregroundStyle(.red) } }
                Section {
                    Text("Stored only on this device, in the Face ID–protected Keychain. Used to sign you back in to Lightning Bolt automatically when your session expires. It's never sent anywhere. Turn the toggle off in Admin to erase it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Face ID sign-in").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let u = user.trimmingCharacters(in: .whitespaces)
                        if u.isEmpty || pass.isEmpty { error = "Enter both your username and password."; return }
                        if let e = LBCreds.save(username: u, password: pass) { error = e; return }
                        onSaved(); dismiss()
                    }.disabled(user.trimmingCharacters(in: .whitespaces).isEmpty || pass.isEmpty)
                }
            }
        }
    }
}

/// Owner-only: re-enable the admin cards after hiding them (the card eye-toggle sets the same flag).
struct StartScreenSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hb_show_admin") private var showAdmin = true
    @AppStorage("hb_splash_secs") private var splashSecs: Double = 8.0

    var body: some View {
        Form {
            Section("Start screen") {
                Stepper(value: $splashSecs, in: 2.5...8, step: 0.5) {
                    Text("Opening animation: \(splashSecs, specifier: "%.1f")s")
                }
                Text("How long the opening screen holds before the app appears. Tap the splash to skip it anytime.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.isOwner {
                Section("Admin cards") {
                    Toggle("Show admin cards in My Stats", isOn: $showAdmin)
                    Text("The “You vs group”, “Unit mix” and “Shift pickups” cards. Turn off to hide them all while showing the app to colleagues.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Admin cards")
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
