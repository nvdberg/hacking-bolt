import SwiftUI
import UIKit

/// Live calendar subscription. Unlike the one-tap Export (a snapshot .ics you re-send whenever the roster
/// changes), this gives you a *subscribe URL*: the poller regenerates your .ics every few minutes, so once
/// Google or Apple Calendar is subscribed it keeps itself up to date — new shifts, swaps, and pickups all
/// flow in on their own. The URL carries a random, unguessable token; nothing is public without it.
struct CalendarSyncView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("hb_cal_token") private var token = ""

    @State private var enabled = false
    @State private var loading = true
    @State private var working = false
    @State private var copied = false
    @State private var error: String?

    private var feedURL: String { token.isEmpty ? "" : Supabase.calendarURL(token: token) }

    var body: some View {
        Form {
            if loading {
                Section { HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) } }
            } else if let error {
                Section { Text(error).foregroundStyle(.red).font(.callout) }
            } else {
                Section {
                    Toggle("Keep a calendar in sync", isOn: Binding(
                        get: { enabled },
                        set: { on in setEnabled(on) }))
                    .disabled(working)
                } footer: {
                    Text("Turns your roster into a live calendar feed. Subscribe once in Google or Apple Calendar and it updates itself — every new shift, swap and pickup appears automatically. Colour-tagged titles, 24-hour calls folded, Pasqua Rapid/MSU merged, just like Export.")
                }

                if enabled {
                    Section {
                        Text(feedURL).font(.footnote.monospaced()).foregroundStyle(Theme.accent)
                            .textSelection(.enabled).lineLimit(3).minimumScaleFactor(0.8)
                        Button {
                            UIPasteboard.general.string = feedURL
                            copied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: { Label(copied ? "Copied!" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        if let u = URL(string: feedURL) {
                            ShareLink(item: u) { Label("Share link", systemImage: "square.and.arrow.up") }
                        }
                    } header: {
                        Text("Your subscribe link")
                    } footer: {
                        Text("Private to you — the link contains a random token. Just turned on? Give it a few minutes to fill in the first time.")
                    }

                    Section {
                        step(1, "Open Google Calendar on a computer", "calendar.google.com — the phone app can’t add a calendar by link, but once it’s added on the web it shows up on your phone too.")
                        step(2, "Other calendars → + → From URL", "In the left sidebar, next to “Other calendars”, tap +, then choose “From URL”.")
                        step(3, "Paste the link → Add calendar", "Paste your subscribe link and confirm. It lands under “Other calendars”.")
                        step(4, "Show it on your phone", "In the Google Calendar app: ☰ → Settings → the new calendar → tick “Sync”.")
                    } header: {
                        Text("Add it to Google Calendar")
                    } footer: {
                        Text("Heads-up: Google refreshes subscribed calendars on its own schedule — usually every 8–24 hours — so a brand-new shift can take up to a day to appear there. That’s a Google limit, not the app.")
                    }

                    Section("Prefer Apple Calendar?") {
                        Text("iPhone Settings → Calendar → Accounts → Add Account → Other → Add Subscribed Calendar → paste the link. Apple refreshes much faster than Google (you can set it to hourly).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Sync to Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.footnote.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Circle().fill(Theme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        guard let emp = Int(model.userEmp) else {
            error = "Sign in to Lightning Bolt first, then come back to set up calendar sync."
            loading = false; return
        }
        // Prefer the server's record (survives reinstalls, keeps the URL stable); fall back to the local token.
        let sub = await Supabase.calSub(emp: emp)
        if let sub { token = sub.token; enabled = sub.enabled ?? true }
        else if token.isEmpty { token = UUID().uuidString.lowercased() }   // first ever — mint a stable token
        loading = false
    }

    private func setEnabled(_ on: Bool) {
        guard let emp = Int(model.userEmp), !token.isEmpty else { return }
        working = true; enabled = on
        Task {
            let ok = await Supabase.enrollCalendar(emp: emp, token: token, enabled: on)
            await MainActor.run {
                working = false
                if !ok { enabled = !on; error = "Couldn’t reach the server — check your connection and try again." }
            }
        }
    }
}
