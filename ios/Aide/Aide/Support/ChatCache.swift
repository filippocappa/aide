import Foundation

/// What the chats looked like the last time the server answered (#79), so they open with no connection: the server's
/// own JSON for the chat list, the Team chat, the agents and each chat's history, kept as it came (no copy of the
/// models to keep in step). Photos are kept apart, up to a size, the oldest seen going first. And the messages waiting
/// to be sent (#80), so they survive the app being closed.
///
/// In Application Support/Aide/Chats on both the phone and the Mac (the Mac's own folder, not the phone's).
@MainActor
final class ChatCache: ResponseStore {
    static let shared = ChatCache()

    /// Chats whose history is kept per agent, newest first; archived ones aren't (#81).
    static let chatsPerAgent = 30
    /// Photos on disk, at most.
    static let photoBytes = 200_000_000

    let folder: URL
    private var photos: URL { folder.appending(path: "photos", directoryHint: .isDirectory) }
    var outboxFolder: URL { folder.appending(path: "outbox", directoryHint: .isDirectory) }

    init(folder: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.folder = folder ?? base.appending(path: "Aide/Chats", directoryHint: .isDirectory)
        for dir in [self.folder, photos, outboxFolder] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: Responses

    private func file(_ key: String) -> URL {
        // Keys are "conversations", "team", "agents", "history-c_91f…", "photo-p_3f9a…": safe as names once slashes go.
        let name = key.replacingOccurrences(of: "/", with: "_")
        return key.hasPrefix("photo-") ? photos.appending(path: name) : folder.appending(path: name + ".json")
    }

    func save(_ data: Data, as key: String) {
        try? data.write(to: file(key), options: .atomic)
    }

    /// The bytes and when they were saved. A photo read counts as a use (the oldest seen go first).
    func load(_ key: String) -> (Data, Date)? {
        let url = file(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let saved = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
        if key.hasPrefix("photo-") { try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path) }
        return (data, saved)
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: file(key))
    }

    /// Drops the histories of chats not in `keep` (deleted, archived, or past the newest per agent).
    func keepHistories(_ keep: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("history-") && name.hasSuffix(".json") {
            let id = String(name.dropFirst("history-".count).dropLast(".json".count))
            if !keep.contains(id) { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
        }
    }

    /// Photos past the size cap go, least recently seen first. Run now and then (at launch).
    func trimPhotos() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: photos, includingPropertiesForKeys: Array(keys))) ?? [])
            .compactMap { url -> (URL, Date, Int)? in
                guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
                return (url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
            }
            .sorted { $0.1 > $1.1 }
        var total = 0
        for (url, _, size) in files {
            total += size
            if total > Self.photoBytes { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Outbox

    /// The messages waiting to be sent, in order.
    func loadOutbox() -> [Outgoing] {
        guard let data = try? Data(contentsOf: folder.appending(path: "outbox.json")) else { return [] }
        return (try? JSONDecoder().decode([Outgoing].self, from: data)) ?? []
    }

    func saveOutbox(_ items: [Outgoing]) {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: folder.appending(path: "outbox.json"), options: .atomic)
        }
        // A photo or PDF no message points at any more (sent, or taken back) goes.
        let used = Set(items.flatMap { $0.photos + $0.files.map { String($0.split(separator: "/")[0]) } })
        for name in (try? FileManager.default.contentsOfDirectory(atPath: outboxFolder.path)) ?? [] where !used.contains(name) {
            try? FileManager.default.removeItem(at: outboxFolder.appending(path: name))
        }
    }

    /// Keeps a photo for a waiting message; returns its file's name.
    func keepPhoto(_ jpeg: Data) -> String? {
        let name = UUID().uuidString + ".jpg"
        return (try? jpeg.write(to: outboxFolder.appending(path: name))) != nil ? name : nil
    }

    /// Keeps a copy of a PDF for a waiting message (the one picked may be a temporary file), in a folder of its own
    /// so it keeps its name; returns its path in the outbox folder ("<uuid>/Notes.pdf").
    func keepFile(_ url: URL) -> String? {
        let folder = UUID().uuidString
        let path = folder + "/" + url.lastPathComponent
        do {
            try FileManager.default.createDirectory(at: outboxFolder.appending(path: folder), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: outboxFolder.appending(path: path))
            return path
        } catch {
            return nil
        }
    }

    func outboxURL(_ path: String) -> URL { outboxFolder.appending(path: path) }
}

/// A message waiting on the device (#69, #80): written while a reply was on its way, or while the server couldn't be
/// reached. Its `id` is the `client_id` the server answers once, however often it's sent (docs/API.md, "Chat").
struct Outgoing: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The chat's id on the server; nil for a new chat not made yet, then `blank` says which one.
    var chat: String?
    var blank: UUID?
    /// Who the new chat is with (the chat's agent).
    var agent: String
    var text: String
    /// Photo files in the outbox folder, JPEG, and PDFs' paths in it (`ChatCache.keepFile`).
    var photos: [String] = []
    var files: [String] = []
    var writtenAt = Date()
    /// The server said no to it (not a lost connection): it waits for Try again, Edit or Don't send.
    var failed: String?
}
