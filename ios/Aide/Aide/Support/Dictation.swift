import AVFoundation
import SwiftUI

/// Dictation into the message box: tap the microphone, talk, tap again, and what you said lands in the box to edit
/// and send yourself. Nothing is sent to the agent. The server writes it down (`POST /v1/transcribe`, docs/API.md,
/// "Voice": an audio model on OpenRouter, Italian and English mixed included), so it works the same with live calls
/// off and on the Mac.
@MainActor
final class Dictation: ObservableObject {
    enum State: Equatable { case idle, recording, transcribing }
    @Published private(set) var state = State.idle
    /// 0…1 microphone loudness while recording.
    @Published private(set) var level: CGFloat = 0
    /// How long it's been recording.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var error: String?

    /// Set by AppEnvironment: a WAV recording to text, on the server.
    var transcribe: ((Data) async throws -> String)?

    /// 16 kHz mono 16-bit WAV is 32 KB a second: the server takes up to 10 MB, so stop before five minutes.
    static let longest: TimeInterval = 290

    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private var file: URL { FileManager.default.temporaryDirectory.appendingPathComponent("dictation.wav") }

    var isActive: Bool { state != .idle }

    /// Starts recording. False: the microphone isn't allowed (`error` says so) or wouldn't start.
    @discardableResult
    func start() async -> Bool {
        guard state == .idle else { return false }
        error = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            #if os(iOS)
            error = "Allow the microphone for Aide in iOS Settings."
            #else
            error = "Allow the microphone for Aide in System Settings → Privacy & Security."
            #endif
            return false
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let recorder = try AVAudioRecorder(url: file, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: Self.longest) else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
        } catch {
            self.error = "The microphone didn't start."
            deactivate()
            return false
        }
        state = .recording
        elapsed = 0
        meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        return true
    }

    /// What was said when it reached `longest` by itself, as if you'd tapped stop then.
    var onLimit: ((String) -> Void)?

    /// Stops and writes it down. The text, or nil when nothing was said or it failed (`error` says which).
    func stop() async -> String? {
        guard state == .recording, let recorder else { return nil }
        let seconds = recorder.currentTime
        finishRecording()
        guard seconds >= 0.4 else { // a tap, not a sentence
            state = .idle
            return nil
        }
        return await writeDown()
    }

    /// Stops without writing anything down.
    func cancel() {
        guard state == .recording else { return }
        finishRecording()
        state = .idle
        try? FileManager.default.removeItem(at: file)
    }

    private func writeDown() async -> String? {
        state = .transcribing
        defer {
            state = .idle
            try? FileManager.default.removeItem(at: file)
        }
        guard let transcribe, let wav = try? Data(contentsOf: file) else { return nil }
        do {
            let text = try await transcribe(wav).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { error = "Didn't catch anything." }
            return text.isEmpty ? nil : text
        } catch {
            self.error = "Couldn't write it down. Try again."
            return nil
        }
    }

    private func tick() {
        guard let recorder else { return }
        guard recorder.isRecording else { // it reached `longest` and stopped by itself
            finishRecording()
            Task { if let text = await writeDown() { onLimit?(text) } }
            return
        }
        recorder.updateMeters()
        level = CGFloat(min(1, max(0, (recorder.averagePower(forChannel: 0) + 50) / 50)))
        elapsed = recorder.currentTime
    }

    private func finishRecording() {
        meter?.invalidate()
        meter = nil
        recorder?.stop()
        recorder = nil
        level = 0
        deactivate()
    }

    private func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
