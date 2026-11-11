import AppKit
import CryptoKit
import Foundation

/// The user's course folders on this Mac and Aide's study files, kept in step both ways (#73, docs/API.md, "Course
/// folders"): each subfolder of the chosen folder is a course (guessed by name, or chosen in Settings → This Mac);
/// a PDF in it that Aide doesn't have goes up (`from=folder`: the server says when it has it already), and the
/// course's Moodle files that aren't in the folder come down into its `moodle/` subfolder, which never goes up.
/// What was sent and copied is remembered by SHA-256 in Application Support/Aide/course-folders.json, so a file
/// goes up once, and a Moodle copy the user deletes stays deleted.
@MainActor
final class MacCourseFolders: ObservableObject {
    static let shared = MacCourseFolders()

    nonisolated static let moodleFolder = "moodle"
    private static let rootKey = "courseFoldersRoot"
    private static let mapKey = "courseFolderMap"
    private static let every: TimeInterval = 10 * 60
    nonisolated private static let biggest = 150 * 1024 * 1024 // a PDF over this stays on the Mac

    /// The folder holding a folder per course; nil: off.
    @Published private(set) var root: URL?
    /// Subfolder name → course id, as the user chose it (0: none).
    @Published private(set) var chosen: [String: Int]
    @Published private(set) var courses: [StudyCourse] = []
    @Published private(set) var subfolders: [String] = []
    @Published private(set) var running = false
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastResult: String?

    private var state: State
    private var timer: Timer?

    private struct State: Codable {
        struct Seen: Codable, Sendable { var size: Int; var modified: Double; var sha: String }
        /// path → the hash it had at that size and time, so a file is read again only when it changes.
        var seen: [String: Seen] = [:]
        /// sha → the study file it is on the server (sent, or the one it already was).
        var sent: [String: String] = [:]
        /// study file id → where its Moodle copy went (kept after the user deletes it: not copied again).
        var copied: [String: String] = [:]
    }

    private init() {
        root = UserDefaults.standard.string(forKey: Self.rootKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        chosen = UserDefaults.standard.dictionary(forKey: Self.mapKey) as? [String: Int] ?? [:]
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: Self.stateFile))) ?? State()
    }

    /// At launch: a first run soon, then every 10 minutes and when Aide comes forward.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { _ in
            Task { @MainActor in await MacCourseFolders.shared.sync() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            Task { @MainActor in
                let me = MacCourseFolders.shared
                if (me.lastRun.map { Date().timeIntervalSince($0) > 60 }) ?? true { await me.sync() }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(20))
            await sync()
        }
    }

    func setRoot(_ url: URL?) {
        root = url
        UserDefaults.standard.set(url?.path, forKey: Self.rootKey)
        listSubfolders()
        Task { await sync() }
    }

    /// Asks for the folder (the one with a folder per course).
    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder with a folder for each course."
        if let root { panel.directoryURL = root }
        if panel.runModal() == .OK, let url = panel.url { setRoot(url) }
    }

    func choose(_ course: Int?, for folder: String) {
        if let course { chosen[folder] = course } else { chosen.removeValue(forKey: folder) }
        UserDefaults.standard.set(chosen, forKey: Self.mapKey)
        Task { await sync() }
    }

    /// The course a subfolder is: the user's choice, else the guess (nil: none, it's left alone).
    func course(for folder: String) -> Int? {
        if let id = chosen[folder] { return id == 0 ? nil : id }
        return guess(folder)
    }

    /// The course whose name has every word of the folder's, as a word or the start of one ("math II" is "maths for
    /// economics II"); of those, the one with the fewest other words ("business law" over "Business law study").
    func guess(_ folder: String) -> Int? {
        let mine = Self.words(folder)
        guard !mine.isEmpty else { return nil }
        let fits = courses.compactMap { c -> (Int, Int)? in
            let theirs = Self.words(c.name)
            let all = mine.allSatisfy { w in theirs.contains { $0 == w || ($0.hasPrefix(w) && w.count >= 3) } }
            return all ? (c.id, theirs.count) : nil
        }
        let best = fits.min { $0.1 < $1.1 }
        return fits.filter { $0.1 == best?.1 }.count == 1 ? best?.0 : nil
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func listSubfolders() {
        guard let root else { subfolders = []; return }
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        subfolders = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func sync() async {
        guard let root, !running else { return }
        guard AppEnvironment.shared.settings.isConfigured else { note("not set up"); return }
        running = true
        defer { running = false; lastRun = Date() }
        note("looking at \(root.path)")
        let api = AppEnvironment.shared.api
        do {
            courses = try await api.study().courses
        } catch {
            lastResult = "Couldn't reach Aide: \(error.localizedDescription)"
            note(lastResult!)
            return
        }
        listSubfolders()
        note("folders: \(subfolders.map { "\($0) → \(course(for: $0).map(String.init) ?? "none")" }.joined(separator: ", "))")
        var up = 0, down = 0, failed: [String] = []
        for folder in subfolders {
            guard let course = course(for: folder) else { continue }
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            // Up: the folder's own PDFs.
            var here = Set<String>() // the study files the folder has
            let seen = state.seen
            let found = await Task.detached { Self.scan(dir, seen: seen) }.value
            for (path, entry) in found { state.seen[path] = entry }
            for (path, entry) in found.sorted(by: { $0.key < $1.key }) {
                let pdf = URL(fileURLWithPath: path), sha = entry.sha
                if let id = state.sent[sha] { here.insert(id); continue }
                do {
                    let f = try await api.uploadFolderPDF(pdf, name: pdf.lastPathComponent, course: course)
                    state.sent[sha] = f.id
                    here.insert(f.id)
                    if f.duplicate != true { up += 1 }
                    save()
                } catch {
                    note("couldn't send \(pdf.lastPathComponent): \(error.localizedDescription)")
                    failed.append(pdf.lastPathComponent)
                }
            }
            // Down: the course's Moodle files the folder hasn't got.
            guard let files = try? await api.files(course: course) else { continue }
            let mine = Set(state.sent.keys)
            for f in files where f.source == "moodle" && !here.contains(f.id) && state.copied[f.id] == nil
                && !(f.sha256.map(mine.contains) ?? false) {
                do {
                    let target = try place(f, in: dir.appendingPathComponent(Self.moodleFolder, isDirectory: true))
                    let data = try await api.fileData(f.id)
                    try data.write(to: target, options: .atomic)
                    state.copied[f.id] = target.path
                    if let sha = f.sha256 { state.sent[sha] = f.id }
                    down += 1
                    save()
                } catch {
                    note("couldn't copy \(f.name): \(error.localizedDescription)")
                    failed.append(f.name)
                }
            }
        }
        var parts: [String] = []
        if up > 0 { parts.append("sent \(up) file\(up == 1 ? "" : "s") to Aide") }
        if down > 0 { parts.append("copied \(down) from Moodle") }
        if !failed.isEmpty { parts.append("couldn't do \(failed.count): \(failed.prefix(3).joined(separator: ", "))") }
        lastResult = parts.isEmpty ? "Up to date" : parts.joined(separator: "; ").capitalizedFirst
        note(lastResult!)
        save()
    }

    /// The folder's PDFs with their hashes, off the main thread (a first look reads every byte).
    nonisolated private static func scan(_ dir: URL, seen: [String: State.Seen]) -> [String: State.Seen] {
        var out: [String: State.Seen] = [:]
        for pdf in pdfs(in: dir) {
            if let entry = hash(pdf, seen: seen[pdf.path]) { out[pdf.path] = entry }
        }
        return out
    }

    /// The folder's PDFs, its subfolders' too, but not its `moodle/` (Aide's copies).
    nonisolated private static func pdfs(in dir: URL) -> [URL] {
        guard let walk = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walk {
            if url.lastPathComponent == Self.moodleFolder, url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
                walk.skipDescendants()
                continue
            }
            if url.pathExtension.lowercased() == "pdf" { out.append(url) }
        }
        return out
    }

    /// The file's SHA-256, the one seen before while its size and time haven't changed.
    nonisolated private static func hash(_ url: URL, seen: State.Seen?) -> State.Seen? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, size > 0, size <= biggest else { return nil }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        if let seen, seen.size == size, seen.modified == modified { return seen }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try? handle.read(upToCount: 1 << 20), !block.isEmpty { hasher.update(data: block) }
        let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .init(size: size, modified: modified, sha: sha)
    }

    /// Where a Moodle file goes: `moodle/<name>.pdf`, or `<name> 2.pdf` when that's taken.
    private func place(_ f: StudyFile, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = f.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(ext.isEmpty ? "\(name).pdf" : name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).\(ext.isEmpty ? "pdf" : ext)")
            n += 1
        }
        return url
    }

    private static var stateFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aide", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("course-folders.json")
    }

    /// A line in Application Support/Aide/course-folders.log (the last 200 kept), to see what it did.
    private func note(_ line: String) {
        let url = Self.stateFile.deletingLastPathComponent().appendingPathComponent("course-folders.log")
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").suffix(199).map(String.init)
        lines.append("\(Date().formatted(.iso8601)) \(line)")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func save() {
        state.seen = state.seen.filter { FileManager.default.fileExists(atPath: $0.key) }
        try? JSONEncoder().encode(state).write(to: Self.stateFile, options: .atomic)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
