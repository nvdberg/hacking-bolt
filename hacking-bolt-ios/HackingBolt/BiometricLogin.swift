import Foundation
import Security
import LocalAuthentication

/// Convenience: store the Lightning Bolt username + password in the device Keychain so the app can re-sign-in
/// automatically when LB's login session expires — instead of the user having to type it again. Two opt-in
/// modes (mutually exclusive, they share one Keychain slot):
///   • biometric = true  → gated behind Face ID / Touch ID; released only after a biometric check.
///   • biometric = false → "Keep me signed in": released silently while the device is unlocked (no biometrics).
/// Either way the credentials NEVER leave the device (WhenUnlockedThisDeviceOnly — not synced to iCloud) and
/// are never transmitted anywhere. Off by default.
enum LBCreds {
    private static let service = "com.nvdberg.hackingbolt.lblogin"
    private static let account = "lb"

    /// Is auto-login set up? (Cheap existence check — does NOT trigger a Face ID prompt.)
    static var isEnabled: Bool {
        // A context that may not show UI: a Face ID–locked item then answers errSecInteractionNotAllowed ("there,
        // but locked") instead of prompting. (The old kSecUseAuthenticationUISkip SKIPS such items, so a saved
        // Face ID login read as missing and More → Keep me signed in switched itself off — build 121 fix.)
        let ctx = LAContext(); ctx.interactionNotAllowed = true
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: ctx,
            kSecReturnAttributes as String: true
        ]
        let s = SecItemCopyMatching(q as CFDictionary, nil)
        return s == errSecSuccess || s == errSecInteractionNotAllowed        // exists (the latter = present but locked)
    }

    /// True only if this device can actually do a biometric check (Face ID / Touch ID enrolled).
    static var biometricsAvailable: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    /// "Face ID", "Touch ID" or "Optic ID" — whichever this device has.
    static var biometryName: String {
        let c = LAContext(); var err: NSError?
        _ = c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        switch c.biometryType { case .touchID: return "Touch ID"; case .opticID: return "Optic ID"; default: return "Face ID" }
    }

    /// The saved username (not secret, kept beside the Keychain item) — lets a login typed by hand update the saved
    /// password only when it's the same person, never a colleague signing in on this phone.
    static let userKey = "hb_autologin_user"
    static var savedUsername: String? { UserDefaults.standard.string(forKey: userKey) }

    /// Save (or replace) the credentials. `biometric` true = future reads require Face ID / Touch ID;
    /// false = "Keep me signed in", read silently while the device is unlocked. Returns nil on success,
    /// else an error message.
    static func save(username: String, password: String, biometric: Bool = true) -> String? {
        clear()
        let payload = "\(username)\n\(password)".data(using: .utf8)!
        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: payload,
        ]
        if biometric {
            guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                            .biometryCurrentSet, nil) else {
                return "Couldn't set up secure storage on this device."
            }
            attrs[kSecAttrAccessControl as String] = acl
        } else {
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let s = SecItemAdd(attrs as CFDictionary, nil)
        if s == errSecSuccess { UserDefaults.standard.set(username, forKey: userKey) }
        return s == errSecSuccess ? nil : "Couldn't save (error \(s))."
    }

    enum Loaded { case creds(username: String, password: String), cancelled, missing }

    /// Read the credentials. If they were saved in biometric mode this TRIGGERS the Face ID / Touch ID prompt
    /// (`reason` is shown in it); if saved as "Keep me signed in" it returns silently while the device is
    /// unlocked. `.cancelled` = the user dismissed or failed the biometric check; `.missing` = nothing usable is
    /// stored (new phone / restored backup, or Face ID was changed, which makes iOS void a .biometryCurrentSet item).
    static func load(reason: String) async -> Loaded {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecUseOperationPrompt as String: reason
        ]
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var out: CFTypeRef?
                let s = SecItemCopyMatching(q as CFDictionary, &out)
                if s == errSecUserCanceled || s == errSecAuthFailed || s == errSecInteractionNotAllowed {
                    cont.resume(returning: .cancelled); return
                }
                guard s == errSecSuccess, let data = out as? Data,
                      let str = String(data: data, encoding: .utf8) else { cont.resume(returning: .missing); return }
                let parts = str.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else { cont.resume(returning: .missing); return }
                cont.resume(returning: .creds(username: parts[0], password: parts[1]))
            }
        }
    }

    /// Forget the stored credentials (turning auto-login off).
    static func clear() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
        UserDefaults.standard.removeObject(forKey: userKey)
    }
}
