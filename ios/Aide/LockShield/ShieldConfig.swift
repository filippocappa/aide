import ManagedSettings
import ManagedSettingsUI
import UIKit

/// What a locked app shows instead of itself: "Locked until 07:00", the lock's name and who set it; or, for a daily
/// limit that's used up, "Time's up for today" and the limit; the Focus filter's list; a ration's "Open · 2 left
/// today" (LockAction spends it).
final class ShieldConfig: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        shield(app: application.token)
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        shield(app: application.token, category: category.token)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        shield(domain: webDomain.token)
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        shield(category: category.token, domain: webDomain.token)
    }

    /// What holds this app, the strongest first: a lock, a limit used up, the Focus filter, a ration.
    private func shield(app: ApplicationToken? = nil, category: ActivityCategoryToken? = nil,
                        domain: WebDomainToken? = nil) -> ShieldConfiguration {
        if LockBook.lockHolding(app: app, category: category, domain: domain) == nil {
            if let limit = LockBook.limitHolding(app: app, category: category, domain: domain) { return shield(limit) }
            if let list = LockBook.focusFilterHolding(app: app, category: category, domain: domain) {
                return configuration(title: "Locked while you focus",
                                     lines: ["\(list.name) is locked while this Focus is on."])
            }
            if let ration = LockBook.rationHolding(app: app, category: category, domain: domain) {
                let left = LockBook.opensLeft(ration)
                guard left > 0 else {
                    return configuration(title: "No opens left today",
                                         lines: ["\(ration.title): \(ration.summary). They come back at midnight."])
                }
                return configuration(
                    title: ration.title,
                    lines: ["\(left) of \(ration.opens) opens left today. An open lasts while you use it, and ends once it's been closed \(ration.gap) minutes."],
                    button: "Open · \(left) left", secondary: "Not now")
            }
        }
        return shield(nil)
    }

    /// A lock that holds names the shield; else the limit used up, if there is one.
    private func shield(_ limit: ScreenLimit?) -> ShieldConfiguration {
        let title: String
        var lines: [String] = []
        if LockBook.current() == nil, let limit {
            title = "Time's up for today"
            lines.append("\(limit.title): \(limit.summary). It opens at midnight.")
            lines.append(limit.strict ? "It's strict: only an emergency pass in Aide ends it early."
                         : "To end it for today, open Aide and give a reason.")
            return configuration(title: title, lines: lines)
        }
        if let (lock, until) = LockBook.current() {
            let sameDay = Calendar.current.isDate(until, inSameDayAs: Date())
            title = "Locked until \(until.formatted(date: sameDay ? .omitted : .abbreviated, time: .shortened))"
            lines.append(lock.agent.map { "\(lock.title) · set by \($0.prefix(1).uppercased() + $0.dropFirst())" } ?? lock.title)
        } else {
            title = "Locked for now"
        }
        let strict = LockBook.locks.contains { $0.isStrict && LockClock.until($0) != nil }
        lines.append(strict ? "It's strict: only an emergency pass in Aide ends it early."
                     : "To end it early, open Aide and give a reason.")
        return configuration(title: title, lines: lines)
    }

    private func configuration(title: String, lines: [String], button: String = "OK",
                               secondary: String? = nil) -> ShieldConfiguration {
        // Aide's slate, the app's accent in light mode (Theme.accent).
        let accent = UIColor(red: 0x34 / 255, green: 0x41 / 255, blue: 0x3F / 255, alpha: 1)
        return ShieldConfiguration(
            backgroundBlurStyle: .systemThickMaterial,
            icon: UIImage(named: "Pebble-sleeping")?.withTintColor(.label, renderingMode: .alwaysOriginal),
            title: ShieldConfiguration.Label(text: title, color: .label),
            subtitle: ShieldConfiguration.Label(text: lines.joined(separator: "\n"), color: .secondaryLabel),
            primaryButtonLabel: ShieldConfiguration.Label(text: button, color: .white),
            primaryButtonBackgroundColor: accent,
            secondaryButtonLabel: secondary.map { ShieldConfiguration.Label(text: $0, color: accent) })
    }
}
