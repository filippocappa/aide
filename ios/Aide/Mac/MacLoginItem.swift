import ServiceManagement

/// Aide opens at login, so the Screen page and the daily limits count from the start of the day (they count only while
/// Aide runs). On by default: turned on the first time the app starts, then left to Settings → This Mac.
enum MacLoginItem {
    private static let setKey = "loginItemSet"

    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns it on the first time Aide starts.
    static func setUpOnce() {
        guard !UserDefaults.standard.bool(forKey: setKey) else { return }
        UserDefaults.standard.set(true, forKey: setKey)
        set(true)
    }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Aide login item: \(error.localizedDescription)")
        }
    }
}
