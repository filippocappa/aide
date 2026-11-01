#if DEBUG
import Foundation

/// Made-up use for Simulator screenshots, which have no Screen Time data: the same every run.
enum UsageSample {
    private static let apps: [(String, String, Double)] = [
        ("com.burbn.instagram", "Instagram", 1), ("com.google.ios.youtube", "YouTube", 0.6),
        ("net.whatsapp.WhatsApp", "WhatsApp", 0.55), ("com.apple.mobilesafari", "Safari", 0.45),
        ("ph.telegra.Telegraph", "Telegram", 0.3), ("aide", "Aide", 0.28), ("com.spotify.client", "Spotify", 0.2),
        ("com.apple.Maps", "Maps", 0.15), ("com.apple.mobilemail", "Mail", 0.12), ("com.reddit.Reddit", "Reddit", 0.1),
        ("com.apple.camera", "Camera", 0.05), ("com.apple.Health", "Health", 0.04),
    ]
    /// How much of the day's use falls in each hour.
    private static let shape: [Double] = [0.3, 0, 0, 0, 0, 0, 0, 1, 1.8, 0.9, 0.7, 0.5, 1.4, 2.5, 2, 1.1, 0.7, 0.9,
                                          1.6, 2.7, 3.4, 2.9, 2.5, 1.6]

    static func data(_ kind: UsageKind, containing date: Date, now: Date = Date()) -> UsageReportData {
        let asked = UsageMath.asked(kind, containing: date)
        let days = UsageMath.days(of: asked).filter { $0 <= now }.map { day(on: $0, now: now) }
        return UsageReportData(kind: kind, days: days, period: UsageMath.period(kind, containing: date))
    }

    private static func day(on date: Date, now: Date) -> UsageDay {
        var seed = UInt64(date.timeIntervalSince1970 / 86400) &* 2654435761
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        let minutes = 190 + random() * 120 // the whole day's use
        let elapsed = now.timeIntervalSince(date)
        let weights = shape.map { $0 * (0.6 + random() * 0.8) }
        let sum = weights.reduce(0, +)
        var day = UsageDay(date: date)
        day.firstPickup = date.addingTimeInterval(7 * 3600 + random() * 3000)
        let appSum = apps.reduce(0) { $0 + $1.2 }
        for (id, name, share) in apps {
            let jitter = 0.7 + random() * 0.6
            var app = UsageApp(id: id, name: name)
            app.hourly = weights.enumerated().map { h, w in
                let start = TimeInterval(h) * 3600
                let done = min(1, max(0, (elapsed - start) / 3600))
                return minutes * 60 * w / sum * share / appSum * jitter * done
            }
            app.seconds = app.hourly.reduce(0, +)
            app.pickups = Int(app.seconds / 60 / 4 * (0.8 + random() * 0.4))
            app.notifications = Int(Double(app.pickups) * random() * 2)
            day.apps.append(app)
        }
        return day
    }
}
#endif
