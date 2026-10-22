import Foundation

struct APIConfig: Equatable {
    let baseURL: URL
    let token: String
}

/// Server URL and list choice live in UserDefaults; the token lives in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    /// None: each install points at its own server (https://<machine>.<tailnet>.ts.net), typed in Settings.
    static let defaultServerURL = ""

    private enum Keys {
        static let serverURL = "serverURL"
        static let reminderListID = "reminderListID"
        static let token = "apiToken"
        static let voiceLanguage = "voiceLanguage"
        static let speakReplies = "speakReplies"
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

    /// Language Aide listens for when you talk: a BCP 47 code like en-US or it-IT.
    @Published var voiceLanguage: String {
        didSet { UserDefaults.standard.set(voiceLanguage, forKey: Keys.voiceLanguage) }
    }
    @Published var speakReplies: Bool {
        didSet { UserDefaults.standard.set(speakReplies, forKey: Keys.speakReplies) }
    }

    #if DEBUG
    /// Simulator screenshots: the token comes from the launch environment (`SIMCTL_CHILD_AIDE_TOKEN`) and is never
    /// saved, and the phone's side (reminders sync, Health, push) stays off so a simulator can't touch real data.
    let isPreview = ProcessInfo.processInfo.environment["AIDE_TOKEN"] != nil
    #else
    let isPreview = false
    #endif

    init() {
        let defaults = UserDefaults.standard
        serverURL = defaults.string(forKey: Keys.serverURL) ?? Self.defaultServerURL
        token = Keychain.get(Keys.token) ?? ""
        #if DEBUG
        if let previewToken = ProcessInfo.processInfo.environment["AIDE_TOKEN"] { token = previewToken }
        #endif
        reminderListID = defaults.string(forKey: Keys.reminderListID) ?? ""
        voiceLanguage = defaults.string(forKey: Keys.voiceLanguage) ?? "en-US"
        speakReplies = defaults.object(forKey: Keys.speakReplies) as? Bool ?? true
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
