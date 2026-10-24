import Foundation

struct APIConfig: Equatable {
    let baseURL: URL
    let token: String
}

/// Every setting lives in the Keychain, which keeps it through updates and even deleting the app
/// (UserDefaults doesn't). Values from before that move over from UserDefaults once.
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
        didSet { Keychain.set(serverURL, for: Keys.serverURL) }
    }
    @Published var token: String {
        didSet { Keychain.set(token, for: Keys.token) }
    }
    /// EKCalendar identifier of the synced list; empty means the system default list.
    @Published var reminderListID: String {
        didSet { Keychain.set(reminderListID, for: Keys.reminderListID) }
    }

    /// Language Aide listens for when you talk: a BCP 47 code like en-US or it-IT.
    @Published var voiceLanguage: String {
        didSet { Keychain.set(voiceLanguage, for: Keys.voiceLanguage) }
    }
    @Published var speakReplies: Bool {
        didSet { Keychain.set(speakReplies ? "1" : "0", for: Keys.speakReplies) }
    }

    #if DEBUG
    /// Simulator screenshots: the token (and the server, if given) come from the launch environment
    /// (`SIMCTL_CHILD_AIDE_TOKEN`, `SIMCTL_CHILD_AIDE_SERVER`) and are never saved, and the phone's side (reminders sync, Health, push) stays off so a simulator can't touch real data.
    let isPreview = ProcessInfo.processInfo.environment["AIDE_TOKEN"] != nil
    #else
    let isPreview = false
    #endif

    init() {
        Self.moveToKeychain([Keys.serverURL, Keys.reminderListID, Keys.voiceLanguage, Keys.speakReplies])
        if Bundle.main.bundleURL.pathExtension == "app" { Keychain.share([Keys.serverURL, Keys.token]) } // for the widgets
        serverURL = Keychain.get(Keys.serverURL) ?? Self.defaultServerURL
        token = Keychain.get(Keys.token) ?? ""
        #if DEBUG
        if let previewToken = ProcessInfo.processInfo.environment["AIDE_TOKEN"] { token = previewToken }
        if let previewServer = ProcessInfo.processInfo.environment["AIDE_SERVER"] { serverURL = previewServer }
        #endif
        reminderListID = Keychain.get(Keys.reminderListID) ?? ""
        voiceLanguage = Keychain.get(Keys.voiceLanguage) ?? "en-US"
        speakReplies = Keychain.get(Keys.speakReplies).map { $0 == "1" } ?? true
    }

    /// Settings saved in UserDefaults by older builds, into the Keychain (once; the Keychain wins).
    private static func moveToKeychain(_ keys: [String]) {
        let defaults = UserDefaults.standard
        for key in keys {
            guard let old = defaults.object(forKey: key) else { continue }
            if Keychain.get(key) == nil {
                let value = (old as? Bool).map { $0 ? "1" : "0" } ?? (old as? String) ?? ""
                Keychain.set(value, for: key)
            }
            defaults.removeObject(forKey: key)
        }
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
