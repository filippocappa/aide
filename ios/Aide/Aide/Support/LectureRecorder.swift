import AppIntents
import AVFoundation
import UIKit
import UserNotifications

/// Recording a lecture on the phone (docs/API.md, "Study": `POST /v1/lectures` with the audio as the body). It goes on
/// with the screen locked (the `audio` background mode), comes back after a call, and is written in 10-minute pieces
/// so that if iOS (or a swipe) ends the app mid-lecture only the last piece is lost: the next launch sends the rest.
/// Stopping joins the pieces into one .m4a and hands it to `LectureUploads`, which keeps it until the server has it.
/// The server files it by the timetable event on when it started unless a course is given, then transcribes it,
/// writes the notes and posts them in the course's chat.
@MainActor
final class LectureRecorder: NSObject, ObservableObject {
    static let shared = LectureRecorder()

    /// What's being recorded, kept on disk beside its pieces so a recording cut short can still be sent.
    struct Session: Codable, Equatable {
        var id: String
        var course: Int?
        /// The course's name, for the screen.
        var name: String?
        var started: Date
        /// When the lecture ends (the timetable's), for the "still recording?" reminder.
        var ends: Date?
        var pieces: [String]
        /// Seconds in the pieces before the current one.
        var before: TimeInterval
    }

    enum State: Equatable { case idle, recording, paused, finishing }

    @Published private(set) var state = State.idle
    @Published private(set) var session: Session?
    /// 0–1, the microphone's level now.
    @Published private(set) var level: Float = 0
    /// The last few seconds of `level`, for the waveform.
    @Published private(set) var levels: [Float] = []
    @Published private(set) var elapsed: TimeInterval = 0
    /// A call or Siri took the microphone; it picks up again when they're done.
    @Published private(set) var interrupted = false
    @Published var error: String?
    /// The recorder's screen, over the tabs.
    @Published var showSheet = false

    static let piece: TimeInterval = 600
    static let cap: TimeInterval = 4 * 3600
    private static let reminderID = "lecture-recording"

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    /// Paused by the user, not by an interruption: don't pick up again by itself.
    private var userPaused = false
    /// Waiting for the microphone permission: a second tap doesn't start a second recording.
    private var starting = false

    override private init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(interruption(_:)), name: AVAudioSession.interruptionNotification,
                           object: nil)
        center.addObserver(self, selector: #selector(servicesReset), name: AVAudioSession.mediaServicesWereResetNotification,
                           object: nil)
    }

    var isActive: Bool { state != .idle }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Lectures", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func dir(_ id: String) -> URL { folder.appendingPathComponent(id, isDirectory: true) }

    // MARK: Start, pause, stop

    /// Starts recording, for a course or (nil) for whatever the timetable has on now. Shows the recorder.
    func start(course: Int? = nil, name: String? = nil, ends: Date? = nil) async {
        showSheet = true
        guard state == .idle, !starting else { return }
        error = nil
        starting = true
        defer { starting = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            error = "Aide can't use the microphone. Allow it in Settings → Aide."
            return
        }
        let id = "rec-" + UUID().uuidString.prefix(8).lowercased()
        try? FileManager.default.createDirectory(at: Self.dir(id), withIntermediateDirectories: true)
        session = Session(id: id, course: course, name: name, started: .now, ends: ends, pieces: [], before: 0)
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .default)
            try audio.setActive(true)
            try nextPiece()
        } catch {
            self.error = "Couldn't start recording: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: Self.dir(id))
            session = nil
            return
        }
        state = .recording
        userPaused = false
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        remind(ends)
        if course == nil { Task { await fillCourse(id) } }
    }

    /// Started with no course: the timetable's lecture on now, looked up once recording (a lecture hall's signal is
    /// slow). Not found: the server files it by when it started.
    private func fillCourse(_ id: String) async {
        guard let now = try? await AppEnvironment.shared.api.study().now,
              session?.id == id, session?.course == nil else { return }
        session?.course = now.course
        session?.name = now.name
        session?.ends = now.ends.flatMap(Wire.parse)
        save()
        remind(session?.ends)
    }

    func pause() {
        guard state == .recording else { return }
        recorder?.pause()
        userPaused = true
        state = .paused
        save()
    }

    func resume() {
        guard state == .paused else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if recorder?.record() == true {
            userPaused = false
            interrupted = false
            state = .recording
        } else {
            error = "Couldn't pick the recording up again."
        }
    }

    /// Stops and sends it: the pieces joined into one file, in the upload queue.
    func stop() async {
        guard let session, state == .recording || state == .paused else { return }
        state = .finishing
        let total = elapsed
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
        await Self.finish(session, duration: total)
        self.session = nil
        elapsed = 0
        level = 0
        levels = []
        interrupted = false
        state = .idle
        showSheet = false
        await LectureUploads.shared.flush()
    }

    /// Throws the recording away.
    func discard() {
        guard let session else { return }
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.reminderID])
        try? FileManager.default.removeItem(at: Self.dir(session.id))
        self.session = nil
        elapsed = 0
        level = 0
        levels = []
        interrupted = false
        state = .idle
        showSheet = false
    }

    // MARK: Pieces

    private func nextPiece() throws {
        guard var session else { return }
        let name = String(format: "piece-%03d.m4a", session.pieces.count + 1)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 22_050,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000, // speech: ~14 MB an hour
        ]
        let r = try AVAudioRecorder(url: Self.dir(session.id).appendingPathComponent(name), settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw RecorderError.wontStart }
        recorder = r
        session.pieces.append(name)
        self.session = session
        save()
    }

    private func tick() {
        guard let recorder, var session else { return }
        elapsed = session.before + recorder.currentTime
        if recorder.isRecording {
            recorder.updateMeters()
            let db = recorder.averagePower(forChannel: 0) // -160…0
            level = max(0, min(1, (db + 55) / 50))
        } else {
            level = 0
        }
        levels.append(level)
        if levels.count > 60 { levels.removeFirst(levels.count - 60) }
        if elapsed >= Self.cap {
            Task { await stop() }
        } else if state == .recording, recorder.currentTime >= Self.piece {
            session.before += recorder.currentTime
            self.session = session
            recorder.stop()
            do { try nextPiece() } catch { self.error = "The recording stopped: \(error.localizedDescription)" }
        }
    }

    private func save() {
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        try? data.write(to: Self.dir(session.id).appendingPathComponent("session.json"), options: .atomic)
    }

    // MARK: Calls, Siri, other apps

    @objc nonisolated private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        Task { @MainActor in
            guard self.state == .recording || self.state == .paused else { return }
            switch type {
            case .began:
                if self.state == .recording { self.interrupted = true; self.state = .paused; self.save() }
            case .ended:
                // A lecture goes on through a call: pick up again whatever iOS suggests, unless you paused it.
                guard self.interrupted, !self.userPaused else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                if self.recorder?.record() == true {
                    self.interrupted = false
                    self.state = .recording
                } else {
                    // The old file won't take more: carry on in a new piece.
                    self.session?.before += self.recorder?.currentTime ?? 0
                    self.recorder?.stop()
                    do { try self.nextPiece(); self.interrupted = false; self.state = .recording } catch {
                        self.error = "The recording stopped after the call. Tap Resume."
                    }
                }
            @unknown default: break
            }
        }
    }

    @objc nonisolated private func servicesReset() {
        Task { @MainActor in
            guard self.state == .recording else { return }
            self.session?.before += self.recorder?.currentTime ?? 0
            self.recorder = nil
            try? AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            do { try self.nextPiece() } catch { self.error = "The recording stopped. Tap Resume."; self.state = .paused }
        }
    }

    /// Ten minutes after the lecture's end, in case it's still going.
    private func remind(_ ends: Date?) {
        guard let ends else { return }
        let at = ends.addingTimeInterval(600)
        guard at > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = "Still recording"
        content.body = "\(session?.name.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "The lecture") ended "
            + "\(ends.formatted(date: .omitted, time: .shortened)). Stop it so Professor can write the notes."
        content.userInfo = ["aide": ["kind": "recording"]]
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: at.timeIntervalSinceNow, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.reminderID, content: content,
                                                                     trigger: trigger))
    }

    // MARK: Joining the pieces

    /// Joins a recording's pieces into `lecture.m4a` and queues it; the pieces go once it's made.
    private static func finish(_ session: Session, duration: TimeInterval?) async {
        let dir = dir(session.id)
        let out = dir.appendingPathComponent("lecture.m4a")
        let pieces = session.pieces.map { dir.appendingPathComponent($0) }
        do {
            let seconds = try await join(pieces, into: out)
            for p in pieces { try? FileManager.default.removeItem(at: p) }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("session.json"))
            LectureUploads.shared.add(.init(id: session.id, course: session.course, name: session.name,
                                            recordedAt: session.started, duration: duration ?? seconds))
        } catch {
            // Nothing could be read (stopped within a second, or every piece cut off): nothing to send.
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// The pieces that can be read, one after another, in one .m4a: its length in seconds.
    nonisolated private static func join(_ files: [URL], into out: URL) async throws -> TimeInterval {
        var parts: [(URL, AVAssetTrack, CMTime)] = []
        for file in files {
            let asset = AVURLAsset(url: file)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let length = try? await asset.load(.duration), length.seconds > 0.5 else { continue }
            parts.append((file, track, length))
        }
        guard !parts.isEmpty else { throw RecorderError.nothing }
        try? FileManager.default.removeItem(at: out)
        if parts.count == 1 { // one piece: it is the lecture
            try FileManager.default.copyItem(at: parts[0].0, to: out)
            return parts[0].2.seconds
        }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecorderError.nothing
        }
        var at = CMTime.zero
        for (_, source, length) in parts {
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: at)
            at = at + length
        }
        // The AAC as it is when the pieces allow it (fast, the same size), else encoded again.
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            try? FileManager.default.removeItem(at: out)
            guard let export = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            do {
                if #available(iOS 18, *) {
                    try await export.export(to: out, as: .m4a)
                } else {
                    export.outputURL = out
                    export.outputFileType = .m4a
                    await export.export()
                    guard export.status == .completed else { throw export.error ?? RecorderError.nothing }
                }
                return at.seconds
            } catch {
                continue
            }
        }
        throw RecorderError.nothing
    }

    /// At launch: a recording the app was ended in the middle of is joined from the pieces it finished and sent.
    func recover() async {
        guard state == .idle else { return }
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where dir.hasDirectoryPath {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                  let old = try? JSONDecoder().decode(Session.self, from: data) else { continue }
            await Self.finish(old, duration: nil)
        }
    }

    enum RecorderError: LocalizedError {
        case wontStart, nothing
        var errorDescription: String? {
            switch self {
            case .wontStart: "the microphone didn't start"
            case .nothing: "nothing was recorded"
            }
        }
    }
}

/// Recordings waiting to reach the server, kept on disk until it has them (a lecture hall often has no signal):
/// tried when one is made, on launch and each time the app comes back.
@MainActor
final class LectureUploads: ObservableObject {
    static let shared = LectureUploads()

    struct Item: Codable, Identifiable, Equatable {
        let id: String
        let course: Int?
        let name: String?
        let recordedAt: Date
        let duration: TimeInterval
        var error: String?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var sending: String?
    /// The last one the server took, for "Sent" on the Study page.
    @Published private(set) var sent: Item?

    private var queueFile: URL { LectureRecorder.folder.appendingPathComponent("queue.json") }

    private init() {
        if let data = try? Data(contentsOf: queueFile), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    func file(_ item: Item) -> URL {
        LectureRecorder.folder.appendingPathComponent(item.id, isDirectory: true).appendingPathComponent("lecture.m4a")
    }

    func add(_ item: Item) {
        items.append(item)
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        try? FileManager.default.removeItem(at: LectureRecorder.folder.appendingPathComponent(item.id, isDirectory: true))
        save()
    }

    /// Sends what's waiting, one at a time.
    func flush() async {
        guard sending == nil, !items.isEmpty, AppEnvironment.shared.settings.isConfigured else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "Lecture upload")
        defer { UIApplication.shared.endBackgroundTask(task) }
        for item in items {
            guard FileManager.default.fileExists(atPath: file(item).path) else { remove(item); continue }
            sending = item.id
            do {
                _ = try await AppEnvironment.shared.api.uploadRecording(file(item), type: "audio/m4a", course: item.course,
                                                                       recordedAt: item.recordedAt)
                remove(item)
                sent = item
            } catch {
                if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].error = error.localizedDescription }
                save()
                sending = nil
                return // offline or the server's down: the rest wait too
            }
        }
        sending = nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: queueFile, options: .atomic) }
    }
}

/// "Record a lecture" for Shortcuts and the Action Button: opens Aide recording (the course from the timetable).
struct RecordLectureIntent: AppIntent {
    static var title: LocalizedStringResource = "Record a lecture"
    static var description = IntentDescription("Opens Aide and starts recording the lecture on now. Professor writes the notes.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppEnvironment.shared.push.route = .record
        return .result()
    }
}
