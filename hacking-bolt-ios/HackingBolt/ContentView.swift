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
        // Tapping a shift-alert push → jump to the Pool on that date.
        .onReceive(PushCenter.shared.$pendingJumpISO.compactMap { $0 }) { iso in
            PushCenter.shared.pendingJumpISO = nil
            model.selectedTab = 0
            Task {                                     // the alerted shift may be newer than the cached pool → fetch first
                await model.refreshPoolForJump()
                model.poolJumpDate = iso
            }
        }
        // Tapping a "your shift was picked up" push → open the Pool on the My Posts segment.
        .onReceive(PushCenter.shared.$pendingShowMyPosts.filter { $0 }) { _ in
            model.selectedTab = 0
            model.poolShowMine = true
            PushCenter.shared.pendingShowMyPosts = false
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var model: AppModel
    @State private var myShiftsTick = 0        // bumped when My Shifts tab is tapped → re-center on current month
    @State private var whoTick = 0             // bumped when Who's On tab is tapped → re-center on today
    @AppStorage("hb_default_tab") private var defaultTab = 0   // which tab the app opens on (Advanced setting)
    @State private var didInitTab = false
    @ObservedObject private var updater = UpdateChecker.shared
    // More tab. DEBUG screenshot hook: DEMO_SCREEN=stats|admin|cafe|swap opens that screen directly (inert in Release).
    @ViewBuilder private var moreTab: some View {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["DEMO_SCREEN"] {
        case "stats": NavigationStack { StatsView() }
        case "admin": NavigationStack { AdminView() }
        case "cafe": NavigationStack { CafeteriaView() }
        case "swap": NavigationStack { SwapView() }
        default: SettingsView()
        }
        #else
        SettingsView()
        #endif
    }

    var body: some View {
        TabView(selection: Binding(
            get: { model.selectedTab },
            set: { nv in
                if nv == 0 { Task { if !(await model.refreshOpenShifts()) { await model.refresh() } } }   // Pool → latest; recover token if the fetch failed
                if nv == 1 { myShiftsTick += 1 }
                if nv == 2 { whoTick += 1 }
                model.selectedTab = nv
            })) {
            PoolView().tabItem { Label("Pool", systemImage: "bolt.fill") }.tag(0)
            CalendarView(tabTick: myShiftsTick).tabItem { Label("My Shifts", systemImage: "calendar") }.tag(1)
            WhoView(tabTick: whoTick).tabItem { Label("Who's On", systemImage: "person.2.fill") }.tag(2)
            CompareView().tabItem { Label("Crew", systemImage: "person.3.fill") }.tag(3)
            moreTab.tabItem { Label("More", systemImage: "gearshape") }.tag(4)
        }
        .onAppear {
            if !didInitTab {
                didInitTab = true
                #if DEBUG
                if CommandLine.arguments.contains("-demoShot") { return }   // screenshot hook owns the tab
                #endif
                if (0...3).contains(defaultTab) { model.selectedTab = defaultTab }
            }
        }
        .task { await updater.check() }
        #if DEBUG
        .modifier(OnCallAccessoryPreview())       // DEMO_ACCESSORY=1 → iOS 26 bottom-accessory mock-up (not shipped)
        #endif
        .safeAreaInset(edge: .top) {
            if updater.updateAvailable && !updater.bannerDismissed { updateBanner }
        }
    }

    private var updateBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available").font(.footnote.weight(.bold))
                Text("Open TestFlight to get the latest").font(.caption2).opacity(0.95)
            }
            Spacer()
            Link("Update", destination: UpdateChecker.testFlightURL)
                .font(.footnote.weight(.bold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.white.opacity(0.22), in: Capsule())
            Button { withAnimation { updater.bannerDismissed = true } } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.orange.gradient)
    }
}

#if DEBUG
/// Mock-up only: tonight's on-call doctors in the iOS 26 glass strip above the tab bar (DEMO_ACCESSORY=1).
private struct OnCallAccessoryPreview: ViewModifier {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var roster = DoctorRoster.shared
    private let on = ProcessInfo.processInfo.environment["DEMO_ACCESSORY"] == "1"

    func body(content: Content) -> some View {
        if on, #available(iOS 26, *) {
            content.tabViewBottomAccessory { strip }
        } else {
            content
        }
    }

    private var strip: some View {
        let iso = AppModel.todayRegina()
        let ccu = Units.info[.CCU]?.color ?? .red
        return HStack(spacing: 10) {
            Image(systemName: "moon.stars.fill").foregroundStyle(.indigo)
            Text("Tonight").font(.footnote).foregroundStyle(.secondary)
            Text(roster.night(iso)?.name ?? "—").font(.footnote.weight(.semibold))
            Text("ICU").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Divider().frame(height: 14)
            Image(systemName: "heart.fill").font(.caption).foregroundStyle(ccu)
            Text(roster.name(iso, "CCU", "oncall") ?? "—").font(.footnote.weight(.semibold))
            Text("CCU").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .task { await roster.ensure(iso, demo: model.demo) }
    }
}
#endif
