import SwiftUI

/// Checks whether a newer TestFlight build is available, by fetching a tiny public JSON
/// (`{"latestBuild": N}`) and comparing to this build's number. The JSON is bumped by the ship
/// pipeline. Read-only, best-effort — if the check fails we simply show no status (never a false
/// "up to date"). Powers the About-screen indicator and the launch "update available" banner.
@MainActor final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    // Public gist raw URL holding {"latestBuild": N}. Serves the latest revision; bumped by the ship pipeline.
    private static let feedURL = URL(string: "https://gist.githubusercontent.com/nvdberg/4424d5a739b37fb2969ec1bbbf2097b0/raw/wb-version.json")

    /// The latest build number the server reports (nil until a successful check).
    @Published var latestBuild: Int?
    /// User dismissed the launch banner this session.
    @Published var bannerDismissed = false

    private var checking = false

    /// This build's number, from CFBundleVersion (e.g. "21" → 21).
    var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0 }

    /// True only when we successfully learned of a strictly-newer build.
    var updateAvailable: Bool { if let l = latestBuild { return l > currentBuild }; return false }

    /// Opens TestFlight (the public join link routes into the TestFlight app to update).
    static let testFlightURL = URL(string: "https://testflight.apple.com/join/9ThGvNv3")!

    func check() async {
        guard let url = Self.feedURL, !checking else { return }
        checking = true; defer { checking = false }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = obj["latestBuild"] as? Int else { return }
        latestBuild = n
    }
}
