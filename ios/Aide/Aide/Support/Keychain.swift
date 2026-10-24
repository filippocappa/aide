import Foundation
import Security

/// Minimal generic-password wrapper. The API token lives here, never in source or UserDefaults.
/// Items are saved in the App Group, which is also a keychain access group, so the widget extension reads the
/// same server URL and token as the app.
enum Keychain {
    /// The app's bundle ID in both the app and the extension (Info.plist), so they look up the same items.
    private static let service = Bundle.main.object(forInfoDictionaryKey: "AideKeychainService") as? String
        ?? Bundle.main.bundleIdentifier ?? "com.filippocappa.aide"
    /// Nil in a build without the App Group (the unit tests): items then stay the app's own.
    static let group = (Bundle.main.object(forInfoDictionaryKey: "AideAppGroup") as? String).flatMap {
        $0.isEmpty || $0.contains("$(") ? nil : $0
    }

    private static func query(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /// Looks in every group this process has: the App Group, and the app's own where older builds saved.
    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(query(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let group { q[kSecAttrAccessGroup as String] = group }
        if SecItemAdd(q as CFDictionary, nil) == errSecMissingEntitlement {
            // Signed without the App Group: keep it the app's own rather than lose it.
            q.removeValue(forKey: kSecAttrAccessGroup as String)
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    /// Items saved before the App Group, moved into it (saving again puts them there).
    static func share(_ keys: [String]) {
        for key in keys { if let value = get(key) { set(value, for: key) } }
    }
}
