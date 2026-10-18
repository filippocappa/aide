import Foundation

struct APIConfig: Equatable {
    let baseURL: URL
    let token: String
}

/// Server URL and list choice live in UserDefaults; the token lives in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    /// The tailnet address from docs/API.md. It isn't a secret; the token is.
    static let defaultServerURL = "https://your-machine.your-tailnet.ts.net"

    private enum Keys {
        static let serverURL = "serverURL"
        static let reminderListID = "reminderListID"
        static let token = "apiToken"
    }

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Keys.serverURL) }
    }
    @Published var token: String {
        didSet { Keychain.set(token, for: Keys.token) }
    }
    /// EKCalendar identifier of the synced list; empty means the system default list.
    @Published var reminderListID: String {
        didSet { UserDefaults.standard.set(reminderListID, forKey: Keys.reminderListID) }
    }

    init() {
        let defaults = UserDefaults.standard
        serverURL = defaults.string(forKey: Keys.serverURL) ?? Self.defaultServerURL
        token = Keychain.get(Keys.token) ?? ""
        reminderListID = defaults.string(forKey: Keys.reminderListID) ?? ""
    }

    var apiConfig: APIConfig? {
        let base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tok.isEmpty, let url = URL(string: base), url.scheme?.hasPrefix("http") == true, url.host != nil
        else { return nil }
        return APIConfig(baseURL: url, token: tok)
    }

    var isConfigured: Bool { apiConfig != nil }
}
