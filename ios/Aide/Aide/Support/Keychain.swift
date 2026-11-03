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

    /// Writes to the keychain so far (adds and updates), for the tests.
    private(set) static var writes = 0

    /// Saves in place: the item is updated where it is, and added only when there's none, so a failed write never
    /// leaves the key without its old value. The same value isn't written again. An empty value deletes the key.
    static func set(_ value: String, for key: String) {
        guard !value.isEmpty else {
            SecItemDelete(query(key) as CFDictionary)
            return
        }
        guard get(key) != value else { return }
        let data = Data(value.utf8)
        writes += 1
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return }
        add(data, for: key, group: group)
    }

    private static func add(_ data: Data, for key: String, group: String?) {
        var q = query(key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let group { q[kSecAttrAccessGroup as String] = group }
        if SecItemAdd(q as CFDictionary, nil) == errSecMissingEntitlement, group != nil {
            // Signed without the App Group: keep it the app's own rather than lose it.
            q.removeValue(forKey: kSecAttrAccessGroup as String)
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    /// Items saved before the App Group, copied into it so the widgets read them. Only when the App Group has no
    /// copy yet: nothing is deleted or written on a launch where they're already there. Later saves update both.
    static func share(_ keys: [String]) {
        guard let group else { return }
        for key in keys {
            var q = query(key)
            q[kSecAttrAccessGroup as String] = group
            guard SecItemCopyMatching(q as CFDictionary, nil) == errSecItemNotFound, let value = get(key) else { continue }
            writes += 1
            add(Data(value.utf8), for: key, group: group)
        }
    }

    /// How many items hold the key, in every group this process has (the tests).
    static func count(_ key: String) -> Int {
        var q = query(key)
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return 0 }
        return (out as? [Any])?.count ?? 0
    }
}
