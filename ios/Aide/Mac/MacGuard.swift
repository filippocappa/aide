import AppKit
import ServiceManagement

/// Aide Guard (#85): a small helper inside Aide.app (`Contents/Library/LoginItems/AideGuard.app`, `Guard/`) that holds
/// this Mac's Screen Time locks and limits and counts its time whether Aide's window app runs or not. launchd starts it
/// at login and again whenever it stops (a LaunchAgent, KeepAlive, registered by the app with `SMAppService.agent`);
/// it has no Dock icon or menu, only Pebble over the Dock when it closes an app. The app hands it the server's address
/// and token (it can't read the app's keychain items) and tells it after each change; each reads the other's picks
/// from the app's defaults. While the Guard runs, the app's own shield and counting stand down; turned off in System
/// Settings → General → Login Items ("Allow in the Background"), the app enforces again while it's open.
enum MacGuard {
    /// The app's bundle ID, in the app and in the Guard (whose Info.plist names it).
    static let appID: String = (Bundle.main.object(forInfoDictionaryKey: "AideMainBundle") as? String)
        .flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 } ?? Bundle.main.bundleIdentifier ?? "com.filippocappa.aide.mac"
    static let guardID = appID + ".guard"
    static let isGuard = Bundle.main.bundleIdentifier == guardID

    /// The app's defaults, where the Mac's picks live (`MacLockApps`): its own in the app, read by name in the Guard
    /// (neither is sandboxed).
    static let defaults: UserDefaults = isGuard ? UserDefaults(suiteName: appID) ?? .standard : .standard

    // MARK: Telling each other

    private static let fromApp = Notification.Name(appID + ".guard.app-changed")
    private static let fromGuard = Notification.Name(appID + ".guard.guard-changed")

    /// Tells the other side something changed: a lock saved, apps picked, a limit reached, an unlock. Nothing in it:
    /// the other reads the defaults and the server again.
    static func tell() {
        // At once: the Guard is never the active app, and a waiting notification would wait for good.
        DistributedNotificationCenter.default().postNotificationName(isGuard ? fromGuard : fromApp, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
    }

    /// Runs `changed` when the other side tells.
    @MainActor static func listen(_ changed: @escaping @MainActor () async -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: isGuard ? fromApp : fromGuard, object: nil,
                                                            queue: .main) { _ in
            Task { @MainActor in await changed() }
        }
    }

    // MARK: The app's side

    /// The Guard's LaunchAgent, `Contents/Library/LaunchAgents/<guard id>.plist` in Aide.app (written at build time).
    static var service: SMAppService { .agent(plistName: guardID + ".plist") }

    /// Allowed to run (not turned off in Login Items).
    static var isOn: Bool { service.status == .enabled }

    /// Running now.
    static var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: guardID).isEmpty }

    /// Registers the Guard, from the Aide in /Applications only (a build run from Xcode leaves it to the installed
    /// one). Not again once it's been turned off in Login Items.
    static func register() {
        guard !isGuard, Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        let service = self.service
        switch service.status {
        case .enabled, .requiresApproval:
            return
        default:
            do {
                try service.register()
            } catch {
                NSLog("Aide Guard: \(error.localizedDescription)")
            }
        }
    }

    /// The server's address and token for the Guard: a file only this user can read, which the Guard takes into its
    /// own keychain items and deletes at once (and the app deletes 10 s later if it's still there).
    @MainActor static func handOff(_ config: APIConfig?) {
        guard !isGuard, running, let config,
              let data = try? JSONEncoder().encode(["url": config.baseURL.absoluteString, "token": config.token])
        else { return }
        let file = handOffFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        guard FileManager.default.createFile(atPath: file.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else { return }
        tell()
        Task {
            try? await Task.sleep(for: .seconds(10))
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static var handOffFile: URL {
        URL.applicationSupportDirectory.appending(path: "Aide/guard-handoff.json")
    }

    // MARK: The Guard's side

    private enum Keys {
        static let serverURL = "serverURL"
        static let token = "apiToken"
    }

    /// Takes what the app handed over into the Guard's own keychain items. True when there was something.
    @discardableResult
    static func takeHandOff() -> Bool {
        guard isGuard, let data = try? Data(contentsOf: handOffFile) else { return false }
        try? FileManager.default.removeItem(at: handOffFile)
        guard let given = try? JSONDecoder().decode([String: String].self, from: data),
              let url = given["url"], let token = given["token"] else { return false }
        Keychain.set(url, for: Keys.serverURL)
        Keychain.set(token, for: Keys.token)
        return true
    }

    /// The server as the app last handed it over.
    static var config: APIConfig? {
        guard let base = Keychain.get(Keys.serverURL), let token = Keychain.get(Keys.token), !token.isEmpty,
              let url = URL(string: base), url.scheme?.hasPrefix("http") == true, url.host != nil else { return nil }
        return APIConfig(baseURL: url, token: token)
    }
}

/// Whether the Guard runs, for the app: its shield and counting stand down while it does.
@MainActor
final class MacGuardWatch {
    private(set) var runs = MacGuard.running
    private let changed: (Bool) -> Void
    private var observers: [NSObjectProtocol] = []
    private var poll: Timer?

    init(_ changed: @escaping (Bool) -> Void) {
        self.changed = changed
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == MacGuard.guardID else { return }
                Task { @MainActor [weak self] in self?.check() }
            })
        }
        // A background app's launch isn't always announced: a look every 15 s too.
        let poll = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        RunLoop.main.add(poll, forMode: .common)
        self.poll = poll
        changed(runs)
    }

    func check() {
        let now = MacGuard.running
        guard now != runs else { return }
        runs = now
        changed(now)
    }
}
