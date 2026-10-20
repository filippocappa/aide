import Foundation
import OSLog

/// The voice chat's diary, for tuning it on the phone: levels and events, never your words (word counts only). `Library/Caches/voice.log` (the last 200 KB or so), and the
/// system log. Pulled over the cable without root:
///
///     xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
///         --domain-identifier com.filippocappa.aide --source Library/Caches/voice.log --destination voice.log
enum VoiceLog {
    private static let logger = Logger(subsystem: "com.filippocappa.aide", category: "voice")
    private static let queue = DispatchQueue(label: "com.filippocappa.aide.voice-log")
    private static let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("voice.log")
    private static let limit = 200_000

    static func note(_ text: String) {
        logger.info("\(text, privacy: .public)")
        let line = Data("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(text)\n".utf8)
        queue.async {
            guard let handle = try? FileHandle(forWritingTo: url) else { try? line.write(to: url); return }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size > limit, let all = try? Data(contentsOf: url) {
                try? (all.suffix(limit / 2) + line).write(to: url) // the handle's write would land past the end
                return
            }
            handle.write(line)
        }
    }
}
