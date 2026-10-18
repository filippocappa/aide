import AVFoundation
import NaturalLanguage
import Speech
import SwiftUI

/// Talk to Aide: live speech-to-text that sends itself after a pause, and replies read aloud.
/// In a voice conversation it listens again after each spoken reply, until you tap stop.
@MainActor
final class VoiceController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var transcript = ""
    /// 0…1 microphone loudness while listening.
    @Published private(set) var level: CGFloat = 0
    @Published var error: String?

    /// Called with the final text once the user stops talking.
    var onUtterance: ((String) async -> Void)?
    /// Set by AppEnvironment: language code for recognition and whether replies are read aloud.
    var languageCode: () -> String = { "en-US" }
    var speaksReplies: () -> Bool = { true }

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synthesizer = AVSpeechSynthesizer()
    private var timer: Timer?
    private var lastChange = Date()
    private var startedAt = Date()
    /// True from the first tap on the mic until stop: keep listening after each reply.
    private var conversation = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isActive: Bool { isListening || isSpeaking || conversation }

    // MARK: Listening

    func toggle() async {
        if isActive { stopAll() } else { conversation = true; await startListening() }
    }

    func stopAll() {
        conversation = false
        finishListening(send: false)
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func startListening() async {
        guard !isListening else { return }
        synthesizer.stopSpeaking(at: .immediate)
        guard await authorize() else {
            error = "Allow the microphone and speech recognition for Aide in iOS Settings."
            conversation = false
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageCode())), recognizer.isAvailable else {
            error = "Speech recognition isn't available for this language right now."
            conversation = false
            return
        }
        self.recognizer = recognizer
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                req.append(buffer)
                guard let samples = buffer.floatChannelData?[0] else { return }
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in stride(from: 0, to: n, by: 4) { sum += samples[i] * samples[i] }
                let rms = sqrt(sum / Float(max(1, n / 4)))
                Task { @MainActor in self?.level = CGFloat(min(1, rms * 9)) }
            }
            engine.prepare()
            try engine.start()

            transcript = ""
            error = nil
            isListening = true
            lastChange = Date()
            startedAt = Date()
            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                Task { @MainActor in
                    guard let self, self.isListening else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        if text != self.transcript { self.transcript = text; self.lastChange = Date() }
                        if result.isFinal { self.finishListening(send: true) }
                    } else if err != nil {
                        self.finishListening(send: !self.transcript.isEmpty)
                    }
                }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            self.error = error.localizedDescription
            finishListening(send: false)
            conversation = false
        }
    }

    /// Sends after 1.5 s of silence; gives up after 8 s if nothing was said.
    private func tick() {
        guard isListening else { return }
        let idle = Date().timeIntervalSince(lastChange)
        if !transcript.isEmpty, idle > 1.5 { finishListening(send: true) }
        else if transcript.isEmpty, Date().timeIntervalSince(startedAt) > 8 { stopAll() }
    }

    private func finishListening(send: Bool) {
        guard isListening else { return }
        timer?.invalidate(); timer = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        isListening = false
        level = 0
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        if send, !text.isEmpty {
            Task { await onUtterance?(text) }
        } else if !send {
            conversation = false
        }
    }

    private func authorize() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Speaking

    /// Reads a reply aloud in the language it's written in, then listens again in a voice conversation.
    func speak(_ text: String) {
        guard conversation else { return } // replies are only spoken in a voice conversation
        guard speaksReplies() else { listenAgain(); return }
        let plain = Self.spokenText(text)
        guard !plain.isEmpty else { listenAgain(); return }
        let utterance = AVSpeechUtterance(string: plain)
        let lang = NLLanguageRecognizer.dominantLanguage(for: plain)?.rawValue ?? languageCode()
        utterance.voice = Self.bestVoice(for: lang) ?? Self.bestVoice(for: languageCode())
        utterance.rate = 0.5
        utterance.pitchMultiplier = 1.0
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    private func listenAgain() {
        guard conversation else { return }
        Task { await startListening() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            listenAgain()
        }
    }

    /// The best installed voice for a language: Premium, then Enhanced, then the default one.
    /// Better voices are a free download in iOS Settings > Accessibility > Spoken Content > Voices.
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let prefix = language.prefix(2)
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        return candidates.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Drops markdown markers and symbols that sound wrong when read out.
    static func spokenText(_ text: String) -> String {
        var s = text
        for junk in ["**", "__", "`", "#"] { s = s.replacingOccurrences(of: junk, with: "") }
        s = s.replacingOccurrences(of: "\n- ", with: "\n").replacingOccurrences(of: "• ", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
