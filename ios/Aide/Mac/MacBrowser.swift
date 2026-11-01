import AppKit
import CoreServices

/// Which website a browser shows, for the Screen page and for locks and limits on websites. Aide asks the browser
/// for its front window's tab (an Apple Event; macOS asks once per browser, "Aide wants to control Safari") and keeps
/// only the site (youtube.com), never the page. Safari and the Chromium ones (Chrome, Arc, Brave, Edge, Vivaldi,
/// Opera) can be asked; Firefox can't, so it stays the app. A browser not allowed is the app too.
@MainActor
enum MacBrowser {
    /// A browser's front tab: its app, the site and the address (to open it again after Open anyway).
    struct Tab: Equatable {
        let app: String
        let site: String
        let url: URL
    }

    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func isBrowser(_ id: String) -> Bool { safari.contains(id) || chromium.contains(id) }

    /// The front tab of a running browser, nil when it isn't one, isn't allowed, or shows no website.
    static func tab(of app: NSRunningApplication) -> Tab? {
        guard let id = app.bundleIdentifier, isBrowser(id), !app.isTerminated, permitted(id),
              let text = run(id, read: true), let url = URL(string: text), let site = site(of: url) else { return nil }
        return Tab(app: id, site: site, url: url)
    }

    /// Closes the browser's front tab, if it still shows that site.
    static func closeTab(_ tab: Tab) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: tab.app).first,
              self.tab(of: app)?.site == tab.site else { return }
        _ = run(tab.app, read: false)
    }

    /// The site of an address: its host without "www." or "m.", for web pages only.
    nonisolated static func site(of url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var host = url.host()?.lowercased() else { return nil }
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        return host.contains(".") ? host : nil
    }

    /// A site as typed ("YouTube.com", "https://www.youtube.com/watch…"), or nil.
    nonisolated static func site(typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        return URL(string: text.contains("://") ? text : "https://\(text)").flatMap(site(of:))
    }

    // MARK: Asking the browser

    /// Allowed, by browser; with when it was last checked (a "no" is asked again quietly every 10 minutes, in case
    /// it was turned on in System Settings → Privacy & Security → Automation).
    private static var allowed: [String: (ok: Bool, at: Date)] = [:]
    private static var asking: Set<String> = []

    private static func permitted(_ id: String) -> Bool {
        let known = allowed[id]
        if known?.ok == true { return true }
        guard !asking.contains(id), known.map({ Date().timeIntervalSince($0.at) > 600 }) ?? true else { return false }
        asking.insert(id)
        let ask = known == nil
        // Off the main thread: the first time, macOS shows its question and this waits for the answer.
        Task.detached(priority: .utility) {
            let status = determine(id, ask: ask)
            await MainActor.run {
                asking.remove(id)
                // Not running (-600) or not answered yet: ask again next time.
                if status == noErr { allowed[id] = (true, Date()) }
                else if status == OSStatus(errAEEventNotPermitted) { allowed[id] = (false, Date()) }
            }
        }
        return false
    }

    nonisolated private static func determine(_ id: String, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: id)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
    }

    private static var scripts: [String: NSAppleScript] = [:]

    /// Reads the front tab's address, or closes the front tab. At most a second: a busy browser is skipped.
    private static func run(_ id: String, read: Bool) -> String? {
        let key = "\(id) \(read)"
        let script: NSAppleScript
        if let compiled = scripts[key] {
            script = compiled
        } else {
            let tab = safari.contains(id) ? "current tab" : "active tab"
            let body = read
                ? "return URL of \(tab) of front window"
                : "close \(tab) of front window"
            let source = """
            if application id "\(id)" is running then
                with timeout of 1 second
                    tell application id "\(id)"
                        if (count of windows) is 0 then return ""
                        \(body)
                    end tell
                end timeout
            end if
            return ""
            """
            guard let made = NSAppleScript(source: source) else { return nil }
            var error: NSDictionary?
            guard made.compileAndReturnError(&error) else { return nil }
            scripts[key] = made
            script = made
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }
}

/// Sites in a lock's or a limit's list, kept beside the apps' bundle IDs as "site:youtube.com".
enum MacSites {
    static let prefix = "site:"

    static func entry(_ site: String) -> String { prefix + site }

    static func site(of entry: String) -> String? {
        entry.hasPrefix(prefix) ? String(entry.dropFirst(prefix.count)) : nil
    }

    /// The list covers this app, or this site ("site:music.youtube.com" under "site:youtube.com").
    static func covers(_ entries: Set<String>, _ id: String) -> Bool {
        if entries.contains(id) { return true }
        guard let host = site(of: id) else { return false }
        return entries.contains { entry in
            site(of: entry).map { host == $0 || host.hasSuffix(".\($0)") } == true
        }
    }
}
