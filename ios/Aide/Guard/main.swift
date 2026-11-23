import AppKit

// Aide Guard (`Mac/MacGuard.swift`): an accessory app, no Dock icon, no menu bar, started by launchd.
MainActor.assumeIsolated {
    let delegate = GuardDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
