import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSplash = true
    var body: some View {
        ZStack {
            // The web view is always mounted. During the first full scan it stays VISIBLE (a translucent
            // scrim, not an opaque cover) so WebKit never throttles it and every month loads reliably.
            LoginWebView(source: model.source)
                .ignoresSafeArea()
                .allowsHitTesting(model.showLogin)

            if model.showLogin {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill").foregroundStyle(.orange)
                        Text("Sign in to your schedule").font(.headline)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12).background(.thinMaterial)
                    Spacer()
                    // No-login preview — for reviewers and anyone curious before signing in.
                    VStack(spacing: 6) {
                        Button { model.enterDemo() } label: {
                            Label("Explore with sample data", systemImage: "wand.and.stars")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Capsule().fill(.orange))
                                .foregroundStyle(.white)
                        }
                        Text("No login needed — a preview with example shifts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 28)
                    .background(.thinMaterial)
                }
            } else if model.syncing && !model.hasData {
                Color.black.opacity(0.42).ignoresSafeArea()          // translucent → web view stays un-occluded
                VStack(spacing: 14) {
                    Image(systemName: "bolt.fill").font(.system(size: 42)).foregroundStyle(.orange)
                    ProgressView().tint(.white)
                    Text("Setting up — reading your roster…").font(.headline).foregroundStyle(.white)
                    Text("Just this once; a few seconds.").font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                .padding(30)
            } else {
                Color(.systemBackground).ignoresSafeArea()           // opaque cover once we have data
                MainTabs()
            }

            // Branded opening moment, over everything, while login + first sync spin up underneath.
            if showSplash {
                LaunchScreen { withAnimation(.easeOut(duration: 0.45)) { showSplash = false } }
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.onForeground() } else if phase == .background { model.onBackground() }
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var model: AppModel
    @State private var myShiftsTick = 0        // bumped when My Shifts tab is tapped → re-center on current month
    @State private var whoTick = 0             // bumped when Who's On tab is tapped → re-center on today
    var body: some View {
        TabView(selection: Binding(
            get: { model.selectedTab },
            set: { nv in
                if nv == 0 { Task { await model.refreshOpenShifts() } }   // tapping Pool → grab the latest open shifts
                if nv == 1 { myShiftsTick += 1 }
                if nv == 2 { whoTick += 1 }
                model.selectedTab = nv
            })) {
            PoolView().tabItem { Label("Pool", systemImage: "bolt.fill") }.tag(0)
            CalendarView(tabTick: myShiftsTick).tabItem { Label("My Shifts", systemImage: "calendar") }.tag(1)
            WhoView(tabTick: whoTick).tabItem { Label("Who's On", systemImage: "person.2.fill") }.tag(2)
            CompareView().tabItem { Label("Crew", systemImage: "person.3.fill") }.tag(3)
            SettingsView().tabItem { Label("More", systemImage: "gearshape") }.tag(4)
            // More → Start Screen (duration for all; witty-line editor is owner-only) + My Stats (everyone, their own).
        }
    }
}
