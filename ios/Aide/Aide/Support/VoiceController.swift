import AVFoundation
import NaturalLanguage
import Speech
import SwiftUI

/// Talk to Aide: live speech-to-text that sends itself after a pause, and replies read aloud.
/// In a voice conversation it listens again after each spoken reply, until you tap stop, and it keeps
/// listening while it talks: start speaking and it stops to hear you.
///
/// Replies play through the same audio engine as the microphone, with voice processing on, so echo
/// cancellation removes Aide's own voice from what the recogniser hears.
@MainActor
final class VoiceController: ObservableObject {
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

    /// How long a pause has to be before what you said is sent.
    private static let pauseBeforeSending: TimeInterval = 2.4
    /// How long it waits for you to start talking before ending the voice chat.
    private static let giveUpAfter: TimeInterval = 10

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playerFormat: AVAudioFormat?
    private let synthesizer = AVSpeechSynthesizer()
    private let feed = RequestFeed()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var timer: Timer?
    private var lastChange = Date()
    private var startedAt = Date()
    /// True from the first tap on the mic until stop: keep listening after each reply.
    private var conversation = false
    /// Bumped whenever speech starts or is cut off, so buffers from an older reply are dropped.
    private var speechID = 0
    private var buffersPlaying = 0
    private var speechWritten = false

    var isActive: Bool { isListening || isSpeaking || conversation }

    // MARK: Listening

    func toggle() async {
        if isActive { stopAll() } else { conversation = true; await startListening() }
    }

    func stopAll() {
        conversation = false
        finishListening(send: false)
        stopSpeaking()
        teardown()
    }

    private func startListening() async {
        guard !isListening else { return }
        guard await authorize() else {
            error = "Allow the microphone and speech recognition for Aide in iOS Settings."
            stopAll()
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageCode())), recognizer.isAvailable else {
            error = "Speech recognition isn't available for this language right now."
            stopAll()
            return
        }
        guard conversation else { return } // stopped while asking for permission
        self.recognizer = recognizer
        do {
            try startEngine()
        } catch {
            self.error = error.localizedDescription
            stopAll()
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        feed.request = req

        transcript = ""
        error = nil
        isListening = true
        lastChange = Date()
        startedAt = Date()
        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self, self.isListening, self.feed.request === req else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.transcript { self.transcript = text; self.lastChange = Date() }
                    // You started talking over it: stop and listen. A lone sound isn't enough.
                    if self.isSpeaking, text.trimmingCharacters(in: .whitespaces).count >= 3 { self.stopSpeaking() }
                    if result.isFinal { self.isSpeaking ? self.relisten() : self.finishListening(send: true) }
                } else if err != nil {
                    // While it talks, a recogniser that gave up ("no speech") just starts over.
                    if self.isSpeaking { self.relisten() } else { self.finishListening(send: !self.transcript.isEmpty) }
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Sends after a pause; gives up if nothing was said. While Aide talks only an interruption counts.
    private func tick() {
        guard isListening, !isSpeaking else { return }
        let idle = Date().timeIntervalSince(lastChange)
        if !transcript.isEmpty, idle > Self.pauseBeforeSending { finishListening(send: true) }
        else if transcript.isEmpty, Date().timeIntervalSince(startedAt) > Self.giveUpAfter { stopAll() }
    }

    private func finishListening(send: Bool) {
        guard isListening else { return }
        timer?.invalidate(); timer = nil
        feed.request?.endAudio()
        feed.request = nil
        task?.cancel(); task = nil
        isListening = false
        level = 0
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        if send, !text.isEmpty {
            Task { await onUtterance?(text) }
        } else if !send {
            conversation = false
            stopSpeaking()
            teardown()
        }
    }

    /// A fresh recognition task, keeping the conversation and the engine going.
    private func relisten() {
        timer?.invalidate(); timer = nil
        feed.request?.endAudio()
        feed.request = nil
        task?.cancel(); task = nil
        isListening = false
        transcript = ""
        listenAgain()
    }

    private func authorize() async -> Bool {
        let speech = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Audio engine

    /// Microphone in and replies out through one engine, for the whole voice conversation.
    private func startEngine() throws {
        guard !engine.isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true) // echo cancellation: it can hear you over its own voice
        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)

        let feed = feed
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let req = feed.request else { return }
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
    }

    private func teardown() {
        player.stop()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Speaking

    /// Reads a reply aloud in the language it's written in, listening the whole time in case you
    /// interrupt, and keeps listening afterwards in a voice conversation.
    func speak(_ text: String) {
        guard conversation else { return } // replies are only spoken in a voice conversation
        let plain = Self.spokenText(text)
        guard speaksReplies(), !plain.isEmpty else { listenAgain(); return }
        let utterance = AVSpeechUtterance(string: plain)
        let detected = NLLanguageRecognizer.dominantLanguage(for: plain)?.rawValue ?? languageCode()
        // "en" alone has no accent: use the speaker's region when it's the same language.
        let lang = languageCode().hasPrefix(detected) ? languageCode() : detected
        utterance.voice = Self.bestVoice(for: lang) ?? Self.bestVoice(for: languageCode())
        utterance.rate = 0.5
        utterance.pitchMultiplier = 1.0

        speechID += 1
        let id = speechID
        buffersPlaying = 0
        speechWritten = false
        isSpeaking = true
        listenAgain()
        synthesizer.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            // The main queue keeps the buffers in order (separate Tasks might not).
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.play(pcm, id: id) } }
        }
    }

    private func play(_ pcm: AVAudioPCMBuffer, id: Int) {
        guard id == speechID, isSpeaking else { return }
        if pcm.frameLength == 0 { speechWritten = true; finishSpeakingIfDone(); return } // end of the reply
        do { try startEngine() } catch { self.error = error.localizedDescription; stopSpeaking(); return }
        if playerFormat != pcm.format {
            engine.connect(player, to: engine.mainMixerNode, format: pcm.format)
            playerFormat = pcm.format
        }
        buffersPlaying += 1
        player.scheduleBuffer(pcm) { [weak self] in
            Task { @MainActor in
                guard let self, id == self.speechID else { return }
                self.buffersPlaying -= 1
                self.finishSpeakingIfDone()
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func finishSpeakingIfDone() {
        guard isSpeaking, speechWritten, buffersPlaying == 0 else { return }
        isSpeaking = false
        // Your turn: the pause and give-up timers start now, not when the reply began.
        lastChange = Date()
        startedAt = Date()
        listenAgain()
    }

    /// Cuts a reply off (you interrupted, or the voice chat ended). Listening carries on.
    private func stopSpeaking() {
        speechID += 1
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        guard isSpeaking else { return }
        isSpeaking = false
        lastChange = Date()
        startedAt = Date()
    }

    private func listenAgain() {
        guard conversation, !isListening else { return }
        Task { await startListening() }
    }

    /// The best installed voice for a language: Premium, then Enhanced, then the default one.
    /// Novelty voices (Bells, Bad News, …) never count. At equal quality the exact region and then the
    /// system's own voice for it win, instead of whichever happens to come first.
    /// Better voices are a free download in iOS Settings > Accessibility > Spoken Content > Voices.
    static func bestVoice(for language: String) -> AVSpeechSynthesisVoice? {
        let prefix = language.prefix(2)
        let standard = AVSpeechSynthesisVoice(language: language)
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        func score(_ voice: AVSpeechSynthesisVoice) -> Int {
            voice.quality.rawValue * 10
                + (voice.language == language ? 2 : 0)
                + (voice.identifier == standard?.identifier ? 1 : 0)
        }
        return candidates.max { score($0) < score($1) } ?? standard
    }

    /// Drops markdown markers and symbols that sound wrong when read out.
    static func spokenText(_ text: String) -> String {
        var s = text
        for junk in ["**", "__", "`", "#"] { s = s.replacingOccurrences(of: junk, with: "") }
        s = s.replacingOccurrences(of: "\n- ", with: "\n").replacingOccurrences(of: "• ", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The recognition request the microphone tap feeds, shared with the audio thread.
private final class RequestFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SFSpeechAudioBufferRecognitionRequest?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}
