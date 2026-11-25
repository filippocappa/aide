import AppKit

/// Aide Guard's one job (`MacGuard`): this Mac's locks and limits (`ScreenTimeService`, `MacShield`, Pebble's nudge)
/// and its time (`MacUsage`), with the server the app handed over, whether the app runs or not.
@MainActor
final class GuardDelegate: NSObject, NSApplicationDelegate {
    private var server = MacGuard.config
    private var screenTime: ScreenTimeService?
    private var shield: MacShield?
    private var nudges: MacNudges?
    private var observers: [NSObjectProtocol] = []
    private var binary: Stamp?
    private var watch: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the locks are asked for: the app may have handed the server over while the Guard was starting.
        takeHandOff()
        observers.append(MacGuard.listen { [weak self] in self?.takeHandOff() })
        let api = APIClient(config: { [weak self] in self?.server })
        let screenTime = ScreenTimeService(api: api)
        self.screenTime = screenTime
        MacUsage.shared.start()
        shield = MacShield(screenTime: screenTime)
        nudges = MacNudges(api: api)
        nudges?.onLock = { [weak screenTime] in
            await screenTime?.sync() // the lock the server just made, held now
            MacGuard.tell()
        }
        Task { await screenTime.sync() }
        NSLog("Aide Guard: started (\(server == nil ? "no server yet" : "server known"))")

        // A new Aide installed over this one: launchd starts the new Guard once this one goes.
        binary = Stamp(Bundle.main.executableURL)
        let watch = Timer(timeInterval: 30, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.checkBinary() }
        }
        RunLoop.main.add(watch, forMode: .common)
        self.watch = watch
    }

    func applicationWillTerminate(_ notification: Notification) {
        MacUsage.shared.follow() // the minute's time on disk
    }

    private func takeHandOff() {
        guard MacGuard.takeHandOff() else { return }
        let first = server == nil
        server = MacGuard.config
        NSLog("Aide Guard: server handed over")
        if first, let screenTime { Task { await screenTime.sync() } }
        nudges?.refreshNow()
    }

    private func checkBinary() {
        guard let binary, Stamp(Bundle.main.executableURL) != binary else { return }
        NSLog("Aide Guard: a new build is installed, restarting")
        MacUsage.shared.follow()
        exit(0)
    }

    /// Which file the executable is: a new install replaces it (another inode, size or date).
    private struct Stamp: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date

        init?(_ url: URL?) {
            guard let path = url?.path, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
            self.inode = inode
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = attributes[.modificationDate] as? Date ?? .distantPast
        }
    }
}
