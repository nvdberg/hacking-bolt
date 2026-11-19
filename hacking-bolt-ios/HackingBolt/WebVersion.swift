import SwiftUI
import UIKit

/// More → On a computer: the link to Working-Bolt in a computer's browser (web/ in the repo, published by GitHub
/// Pages from the `working-bolt` org). The old nvdberg.github.io/hacking-bolt/ address still works too.
struct WebVersionView: View {
    static let url = URL(string: "https://working-bolt.github.io/")!
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Text("Working-Bolt also runs in a computer's browser — the Pool, My Shifts, Who's On, Crew, stats and the cafeteria on a big screen. Sign in with your Lightning Bolt username and password; there's nothing to install.")
                    .font(.subheadline)
                Text("working-bolt.github.io")
                    .font(.body.monospaced().weight(.semibold)).foregroundStyle(Theme.accent)
                    .textSelection(.enabled)
            }
            Section {
                ShareLink(item: Self.url) { Label("Share link", systemImage: "square.and.arrow.up") }
                Button {
                    UIPasteboard.general.url = Self.url
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                } label: { Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc") }
                Link(destination: Self.url) { Label("Open it", systemImage: "safari") }
            } footer: {
                Text("Share it to yourself (AirDrop, Messages, email) to open on your computer, or send it to a colleague.")
            }
            Section {
                Label("On the computer, open the link (Chrome, Edge, Firefox or Safari).", systemImage: "1.circle")
                Label("Sign in with your Lightning Bolt username and password.", systemImage: "2.circle")
                Label("On your own computer, tick Keep me signed in so it opens straight away next time (about a week).", systemImage: "3.circle")
            } header: {
                Text("How to start it")
            } footer: {
                Text("Your password goes to Lightning Bolt through Working-Bolt's relay, which keeps nothing. Prefer not to type it there? The page also has a bookmark that opens Working-Bolt over a Lightning Bolt tab. Explore with sample data to look around first.")
            }
        }
        .navigationTitle("On a computer")
        .navigationBarTitleDisplayMode(.inline)
    }
}
