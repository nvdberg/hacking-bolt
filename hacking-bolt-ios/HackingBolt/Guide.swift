import SwiftUI

/// More → "How to use Working-Bolt": every crew-facing feature, organised by tab, searchable.
///
/// KEEP THIS CURRENT: any build that adds or changes something a user can see or do updates this file in the
/// same build (see CLAUDE.md → "In-app guide"). Bump `Guide.updatedForBuild` when you do.
/// Crew-facing only — owner/admin features never appear here.
enum Guide {
    static let updatedForBuild = 97

    struct Item: Identifiable { let id = UUID(); let icon: String; let title: String; let how: String }
    struct Topic: Identifiable { let id = UUID(); let icon: String; let title: String; let items: [Item] }

    static let topics: [Topic] = [
        Topic(icon: "hand.tap", title: "Quick gestures", items: [
            Item(icon: "hand.tap", title: "Tap one of your shifts (My Shifts)",
                 how: "Choose Find a swap or Give it away."),
            Item(icon: "hand.tap", title: "Double-tap any day (My Shifts)",
                 how: "Opens a small Who's On card for that day. Drag its header to move it; tap other days to switch; × closes it. Its stethoscope adds the doctors: each ICU's intensivist + on-call number (🌙 = also on call tonight), ♥ who's in CCU, and a Tonight line — 🌙 ICU on call · ♥ cardiology On call · STEMI. It stays on till you tap it again."),
            Item(icon: "hand.point.up.left", title: "Press and hold a day (My Shifts)",
                 how: "Mark busy… — add a note like STARS. The Pool then warns you before you take a shift that day."),
            Item(icon: "square.dashed", title: "Tap an orange square (calendars)",
                 how: "Jumps to that open shift in the Pool."),
            Item(icon: "hand.point.up.left", title: "Press and hold your own shift (Who's On)",
                 how: "Find a swap or Give it away, straight from the roster."),
            Item(icon: "arrow.down", title: "Pull down (Pool, My Shifts, Time Off)",
                 how: "Refreshes from Lightning Bolt."),
            Item(icon: "rotate.right", title: "Turn your phone sideways",
                 how: "My Shifts and Who's On switch to a wider week/month view."),
        ]),
        Topic(icon: "bolt.fill", title: "Pool — open shifts", items: [
            Item(icon: "list.bullet", title: "All · For me · My posts",
                 how: "All = every shift anyone can pick up. For me = only ones that don't clash with your roster or a busy day. My posts = shifts you've offered (shows when you have some — change in More → Advanced)."),
            Item(icon: "checkmark.circle", title: "Picking one up",
                 how: "Tap Available → Lightning Bolt's own accept page opens inside the app. Nothing is taken until you accept there. It shows in My Shifts as soon as LB has it."),
            Item(icon: "exclamationmark.triangle", title: "Clash labels",
                 how: "\"You're on …\", \"Post-call\" or \"Pre-call\" means it overlaps or sits next to one of your shifts. \"You're busy\" = a day you marked busy — tapping asks Take it anyway?"),
            Item(icon: "calendar", title: "Mini-calendars on top",
                 how: "Your shifts in colour, open shifts as orange squares. Tap a square to jump to it."),
            Item(icon: "clock", title: "Updated · Recently taken",
                 how: "Updated shows when the Pool was last checked. Recently taken (bottom) lists shifts picked up in the last 2 days — no names — so a shift that vanished was taken, not lost. Under For me it only shows ones you could have taken. Hide it with the eye."),
            Item(icon: "arrow.left.arrow.right", title: "Swaps card",
                 how: "Swaps sent to you (Accept swap), the return half of a swap you sent (Take it), and swaps that didn't go through show at the top."),
            Item(icon: "lock", title: "Private offers",
                 how: "A swap or shift offered to one person only shows in their Pool — not everyone's."),
        ]),
        Topic(icon: "calendar", title: "My Shifts", items: [
            Item(icon: "calendar", title: "Your calendar",
                 how: "Colour = unit. 24-hour calls run into a faded post-call day. A purple outline = a shift you've posted. Orange square = an open shift you could take."),
            Item(icon: "calendar.badge.clock", title: "Jump around",
                 how: "This Month returns to today. The calendar icon (top left) jumps to any month back to 2022."),
            Item(icon: "calendar.badge.minus", title: "Busy days",
                 how: "Press and hold a day → Mark busy… → note → Save. Grey dashed tag on the day. Hold again to edit or clear. Stored on this phone only (never sent anywhere); comes back with an iPhone backup. Your LB time-off requests count as busy too."),
            Item(icon: "square.and.arrow.up", title: "Share icon (top right)",
                 how: "Sends your shifts as a calendar file (.ics)."),
        ]),
        Topic(icon: "arrow.triangle.2.circlepath", title: "Swaps & give-aways", items: [
            Item(icon: "arrow.triangle.2.circlepath", title: "Find a swap",
                 how: "Pick your shift → the app lists colleagues who are free that day and have a shift you could take back. Filter by person or unit. Send it with a note; when they accept and send theirs back, it appears in your Pool as Take it."),
            Item(icon: "arrow.up.forward", title: "Give it away",
                 how: "Offer to everyone eligible (goes to the Pool) or to one person. You can give away part of a shift — note: only a scheduler can merge pieces back."),
            Item(icon: "tray.full", title: "Cancel an offer",
                 how: "Pool → My posts → Cancel on the post → Withdraw offer."),
            Item(icon: "message", title: "Text colleagues",
                 how: "In Find a swap, Text all opens one group message to everyone listed; each swap option can also text that person."),
        ]),
        Topic(icon: "person.2.fill", title: "Who's On", items: [
            Item(icon: "person.2", title: "Who's working",
                 how: "Upright: a day-by-day list of who's on each unit — scroll, or pick a date / Today. Sideways: a week grid, units down the side. You're highlighted."),
            Item(icon: "stethoscope", title: "Doctors on call",
                 how: "Tap the stethoscope (top right). Each ICU row adds that day's intensivist and their on-call number (a slim bar along the top holds each unit's desk number, with the CCA call room 🛏 under it — Pasqua wards too); CCU shows who's in CCU this week (Fri → Thu). Under each day, two lines: 🌙 ICU = the one intensivist on call tonight for all the ICUs (plus 2nd call for mass events); ♥ = who's in CCU this week (Friday to Thursday, handover Friday) · 8–5 consults, with RGH cardiology On call · STEMI on the line under it. A circled name = on call from 17:00. Sideways, it adds a Tonight row. Tap again to hide."),
            Item(icon: "arrow.up.arrow.down", title: "Unit order",
                 how: "Reorder the unit rows in More → Advanced → Who's On order."),
        ]),
        Topic(icon: "person.3.fill", title: "Crew", items: [
            Item(icon: "person.3", title: "Compare people",
                 how: "Pick a few colleagues to see only their shifts in the Who's On layout — handy for finding days you're all off."),
        ]),
        Topic(icon: "calendar.badge.minus", title: "More → Time Off Requests", items: [
            Item(icon: "plus", title: "New request",
                 how: "Choose Time Off or Night Off, pick the days (any mix of dates), add a reason → confirm → sent to Lightning Bolt. Days you're already rostered on are pointed out first."),
            Item(icon: "list.bullet", title: "Status",
                 how: "Upcoming and Past requests with their status (pending, approved, declined). Days sent together show as one row. Pull down to refresh."),
            Item(icon: "xmark.circle", title: "Cancel",
                 how: "Swipe a pending request left (or press and hold it) → Cancel. Only pending ones can be cancelled."),
        ]),
        Topic(icon: "chart.bar.fill", title: "More → My Stats", items: [
            Item(icon: "square.grid.2x2", title: "Cards",
                 how: "Month by month · Monthly average · Coming up (your next shift + what's booked by month) · Year to date · By year · Custom range (pick From/To)."),
            Item(icon: "arrow.up.arrow.down", title: "Reorder",
                 how: "Tap Reorder (top right), drag the cards, tap Done. Saved on this phone."),
            Item(icon: "clock.arrow.circlepath", title: "Your shift log",
                 how: "Kept on this phone back to 2022 — even shifts no longer in the roster. Future shifts update as you pick up or give away. A Pasqua Rapid + MSU day counts as one shift."),
        ]),
        Topic(icon: "square.and.arrow.up", title: "More → Export", items: [
            Item(icon: "calendar", title: "Pick a period", how: "This year, All time or Custom (From / To)."),
            Item(icon: "doc", title: "Your shifts as…",
                 how: "Add to Calendar (.ics) · Spreadsheet (CSV for Excel / Numbers) · Printable list (PDF)."),
            Item(icon: "chart.bar.doc.horizontal", title: "Your summary as…", how: "Summary PDF or Summary CSV."),
            Item(icon: "square.and.arrow.up", title: "Sharing", how: "Opens the share sheet — Save to Files, Copy to Numbers, AirDrop, Mail…"),
        ]),
        Topic(icon: "calendar.badge.clock", title: "More → Sync to Calendar", items: [
            Item(icon: "link", title: "Live calendar link",
                 how: "Turn it on to get a private subscribe link. Unlike Export (a one-off copy), it keeps updating itself with new shifts, swaps and pickups."),
            Item(icon: "iphone", title: "Apple Calendar",
                 how: "Settings → Calendar → Accounts → Add Account → Other → Add Subscribed Calendar → paste the link. Refreshes fast (can be hourly)."),
            Item(icon: "g.circle", title: "Google Calendar",
                 how: "Use Add it to Google Calendar. Google refreshes on its own schedule — a new shift can take up to a day."),
        ]),
        Topic(icon: "slider.horizontal.3", title: "More → Advanced", items: [
            Item(icon: "rectangle.on.rectangle", title: "Open the app on", how: "Shift Pool, My Shifts, Who's On or Crew."),
            Item(icon: "person.crop.circle.badge.checkmark", title: "Shift Pool opens on “For me”", how: "Start the Pool on shifts you can actually take."),
            Item(icon: "checkmark.circle", title: "Show “Recently taken” in the Pool", how: "On/off for the list at the bottom of the Pool."),
            Item(icon: "tray.full", title: "My Posts tab", how: "Auto (when you have posts) · Always show · Only when awaiting pickup."),
            Item(icon: "calendar", title: "Week starts on", how: "Sunday or Monday, for the month calendars (My Shifts, Pool and the swap calendars)."),
            Item(icon: "arrow.up.arrow.down", title: "Who's On order", how: "Drag the unit rows into the order you like."),
            Item(icon: "app.badge", title: "App icon", how: "Pick a different home-screen icon."),
            Item(icon: "text.quote", title: "Witty lines", how: "The one-liners the app shows — add your own, delete, or Reset to defaults."),
            Item(icon: "key.fill", title: "Auto sign-in",
                 how: "Optional. Face ID: your LB sign-in is unlocked with Face ID when LB logs you out. Keep me signed in: same, without Face ID while the phone is unlocked. Stored only in this phone's keychain — never sent anywhere, not in iCloud."),
            Item(icon: "sun.max", title: "Hennie holiday", how: "Your next run of 4+ days off in a row."),
        ]),
        Topic(icon: "ellipsis.circle", title: "More → the rest", items: [
            Item(icon: "arrow.triangle.2.circlepath", title: "Swap or Give Away", how: "The same swap / give-away screen as tapping a shift — see Swaps & give-aways."),
            Item(icon: "fork.knife", title: "Cafeteria menu", how: "On More (🍴, just above App), with today's lunch feature underneath. The day's specials at RGH or Pasqua with prices — ☀ lunch feature and its sides first, then pizza, soup and 🌙 supper. Arrows step through the days."),
            Item(icon: "timer", title: "Start screen", how: "In the App section: tap it to pick how long the opening screen holds, 2 to 8 seconds (default 8). Tap the opening screen to skip it anytime."),
            Item(icon: "bubble.left.and.bubble.right", title: "Feedback",
                 how: "Take a screenshot in the app → Share Beta Feedback → add a note. Goes to the developer through TestFlight."),
            Item(icon: "info.circle", title: "About", how: "Your version, and an Update available button when a newer build is out."),
            Item(icon: "rectangle.portrait.and.arrow.right", title: "Sign out", how: "Clears the session and roster data cached on this phone."),
        ]),
        Topic(icon: "bell.badge", title: "Notifications", items: [
            Item(icon: "bolt", title: "Open: …", how: "A new shift landed in the Pool, open to everyone."),
            Item(icon: "arrow.left.arrow.right", title: "Swap offer · Offered to you · Swap back",
                 how: "Something aimed at you only — nobody else gets these."),
            Item(icon: "checkmark", title: "Picked up: …", how: "Someone took a shift you gave away."),
            Item(icon: "arrow.down.app", title: "Update banner",
                 how: "When a newer build is out, a banner points you to TestFlight."),
        ]),
        Topic(icon: "hand.raised", title: "Good to know", items: [
            Item(icon: "lock.shield", title: "Lightning Bolt stays in charge",
                 how: "Working-Bolt reads your roster and opens LB's own pages for anything that changes it. Every send asks you first."),
            Item(icon: "iphone", title: "What's kept on your phone",
                 how: "Your shift log, busy days, settings and (if you turn it on) your sign-in. Signing out clears the roster data cached on this phone."),
        ]),
    ]
}

struct GuideView: View {
    @State private var query = ProcessInfo.processInfo.environment["DEMO_GUIDE_Q"] ?? ""   // screenshot: prefilled search

    private var shown: [Guide.Topic] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Guide.topics }
        return Guide.topics.compactMap { t in
            let hits = t.items.filter { "\(t.title) \($0.title) \($0.how)".lowercased().contains(q) }
            return hits.isEmpty ? nil : Guide.Topic(icon: t.icon, title: t.title, items: hits)
        }
    }

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    Text("Everything Working-Bolt can do, by tab. Start with Quick gestures — most features live behind a tap, double-tap or press-and-hold.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }
            }
            ForEach(shown) { t in
                Section {
                    ForEach(t.items) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: i.icon).font(.subheadline).foregroundStyle(Theme.accent).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(i.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                Text(i.how).font(.footnote).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: { Label(t.title, systemImage: t.icon) }
            }
            if shown.isEmpty {
                Text("Nothing matches “\(query)”.").foregroundStyle(Theme.muted)
            }
            Section {
                Text("Guide updated for build \(Guide.updatedForBuild). Missing something? More → Feedback.")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
        }
        .searchable(text: $query, prompt: "Search the guide")
        .navigationTitle("How to use Working-Bolt")
        .navigationBarTitleDisplayMode(.inline)
    }
}
