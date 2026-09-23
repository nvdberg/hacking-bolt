import SwiftUI
import UserNotifications

/// Bridges APNs push into the app: the AppDelegate receives the device token + notification taps;
/// `PushCenter` carries them to the SwiftUI world. New-open-shift alerts are sent by the poller
/// (stage2/run.mjs) to the tokens registered here in Supabase `devices`.
final class PushCenter: ObservableObject {
    static let shared = PushCenter()
    private init() {}

    /// Set when a push is tapped → ContentView deep-links to that date in the Pool.
    @Published var pendingJumpISO: String?
    /// Set when a "your shift was picked up" push is tapped → open the Pool on the My Posts segment.
    @Published var pendingShowMyPosts = false
    /// The APNs device token (hex), set by the AppDelegate once Apple returns it.
    var deviceTokenHex: String?
    /// AppModel hooks this so a freshly-arrived token is upserted to Supabase.
    var onToken: (() -> Void)?
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        PushCenter.shared.deviceTokenHex = hex
        PushCenter.shared.onToken?()
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No push this run (e.g. simulator, or capability not yet provisioned). Silent — app still works.
    }

    // Show the alert even when the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    // Tapping a shift alert deep-links into the Pool on that date.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if (info["kind"] as? String) == "pickup" {
            DispatchQueue.main.async { PushCenter.shared.pendingShowMyPosts = true }   // → Pool → My Posts
        } else if let iso = info["iso"] as? String {
            DispatchQueue.main.async { PushCenter.shared.pendingJumpISO = iso }         // → Pool on that date
        }
        completionHandler()
    }
}
