import Foundation
import OSLog

/// The voice chat's diary, for tuning it on the phone: levels and events, never your words (word counts only). `Library/Caches/voice.log` (the last 200 KB or so), and the
/// system log. Pulled over the cable without root:
///
///     xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
///         --domain-identifier com.filippocappa.aide --source Library/Caches/voice.log --destination voice.log
enum VoiceLog {
    private static let diary = Diary(name: "voice")

    static func note(_ text: String) { diary.note(text) }
}

/// A small log for trying something on the phone: `Library/Caches/<name>.log` (the last 200 KB or so) and the system
/// log, pulled with `devicectl` as above. Never anything the user said or typed.
struct Diary: Sendable {
    private let logger: Logger
    private let queue: DispatchQueue
    private let url: URL
    private static let limit = 200_000

    init(name: String) {
        logger = Logger(subsystem: "com.filippocappa.aide", category: name)
        queue = DispatchQueue(label: "com.filippocappa.aide.\(name)-log")
        url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("\(name).log")
    }

    func note(_ text: String) {
        logger.info("\(text, privacy: .public)")
        let line = Data("\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(text)\n".utf8)
        let url = url
        queue.async {
            guard let handle = try? FileHandle(forWritingTo: url) else { try? line.write(to: url); return }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size > Self.limit, let all = try? Data(contentsOf: url) {
                try? (all.suffix(Self.limit / 2) + line).write(to: url) // the handle's write would land past the end
                return
            }
            handle.write(line)
        }
    }
}
