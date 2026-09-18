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
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,   // don't prompt, just check presence
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
        return s == errSecSuccess ? nil : "Couldn't save (error \(s))."
    }

    /// Read the credentials. If they were saved in biometric mode this TRIGGERS the Face ID / Touch ID prompt
    /// (`reason` is shown in it); if saved as "Keep me signed in" it returns silently while the device is
    /// unlocked. Returns nil if the user cancels, fails biometrics, or nothing is stored.
    static func load(reason: String) async -> (username: String, password: String)? {
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
                guard s == errSecSuccess, let data = out as? Data,
                      let str = String(data: data, encoding: .utf8) else { cont.resume(returning: nil); return }
                let parts = str.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else { cont.resume(returning: nil); return }
                cont.resume(returning: (parts[0], parts[1]))
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
    }
}
