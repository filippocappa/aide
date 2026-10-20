import AVFoundation
import NaturalLanguage
import Speech
import SwiftUI

/// Talk to Aide: what you say is sent after a pause, and replies are read aloud.
/// In a voice conversation it listens again after each spoken reply, until you tap stop, and it keeps
/// listening while it talks: start speaking and it stops to hear you.
///
/// The server transcribes (docs/API.md, "Voice"): the phone records until you pause, then sends the recording,
/// and an audio model writes down what you said in whatever language you said it. Meanwhile Apple's recogniser
/// shows your words as you say them, only as a preview. Without server transcription Apple's recogniser does
/// it all, in the language set in Settings.
///
/// Replies are read out a sentence at a time as they're written (`replyStarted`, `replyGrew`, `replyDone`).
///
/// Replies play through the same audio engine as the microphone, with voice processing on, so echo
/// cancellation removes Aide's own voice from what it hears.
@MainActor
final class VoiceController: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var transcript = ""
    /// The recording is with the server, being written down.
    @Published private(set) var isTranscribing = false
    /// 0…1 microphone loudness while listening.
    @Published private(set) var level: CGFloat = 0
    @Published var error: String?

    /// Called with the final text once the user stops talking.
    var onUtterance: ((String) async -> Void)?
    /// Set by AppEnvironment: language code for recognition and whether replies are read aloud.
    var languageCode: () -> String = { "en-US" }
    var speaksReplies: () -> Bool = { true }
    /// Set by AppEnvironment: a WAV recording to text, on the server. Nil: Apple's recogniser.
    var transcribe: ((Data) async throws -> String)?

    /// How long a pause has to be before what you said is sent.
    private static let pauseBeforeSending: TimeInterval = 2.4
    /// How long it waits for you to start talking before ending the voice chat.
    private static let giveUpAfter: TimeInterval = 10
    /// Recording for the server: how long a silence ends what you're saying, and the longest it records.
    private static let silenceBeforeSending: TimeInterval = 1.4
    private static let longestRecording: TimeInterval = 60
    /// Microphone level (0…1) that counts as talking; higher while Aide talks, so its echo doesn't.
    private static let talking: CGFloat = 0.12
    private static let talkingOver: CGFloat = 0.3

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
    /// The whole reply has been turned into audio: once that's played, it's your turn.
    private var speechWritten = false
    /// The reply being read out: its number, whether more of it may come, its draft so far and how much of that
    /// is already queued, the sentences waiting to be voiced, and the voice picked for it.
    private var replyID = 0
    private var replyOpen = false
    private var draft = ""
    private var draftSpoken = 0
    private var sentences: [String] = []
    private var writing = false
    private var replyVoice: AVSpeechSynthesisVoice?
    /// This listen records for the server rather than feeding Apple's recogniser.
    private var recording = false
    /// The server answered that it can't transcribe: Apple's recogniser from then on.
    private var serverOff = false
    /// While recording: you've started talking, when you were last heard, and how many loud buffers in a row.
    private var heardSpeech = false
    private var lastLoud = Date()
    private var loudRun = 0

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
        let toServer = transcribe != nil && !serverOff
        guard await authorize(speech: !toServer) else {
            error = toServer ? "Allow the microphone for Aide in iOS Settings."
                : "Allow the microphone and speech recognition for Aide in iOS Settings."
            stopAll()
            return
        }
        var recognizer: SFSpeechRecognizer?
        if !toServer {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageCode()))
            guard recognizer?.isAvailable == true else {
                error = "Speech recognition isn't available for this language right now."
                stopAll()
                return
            }
        }
        if toServer, SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            // Only for the live preview of your words: listening works without it.
            _ = await withCheckedContinuation { cont in SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) } }
        }
        guard conversation else { return } // stopped while asking for permission
        do {
            try startEngine()
        } catch {
            self.error = error.localizedDescription
            stopAll()
            return
        }
        guard let recognizer else { return startRecording() }
        self.recognizer = recognizer
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

    /// Records for the server until you pause (`heard` decides when you're talking).
    private func startRecording() {
        feed.recorder = PCMRecorder(input: engine.inputNode.outputFormat(forBus: 0))
        recording = true
        heardSpeech = false
        loudRun = 0
        transcript = ""
        error = nil
        isListening = true
        startedAt = Date()
        if !isSpeaking { startPreview() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// While recording: Apple's recogniser, on the phone, shows what it hears as you talk. Only to show: what's
    /// sent is the server's transcript. Not while Aide talks (it would show Aide), and not without permission.
    private func startPreview() {
        guard recording, feed.request == nil, SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageCode())), recognizer.isAvailable
        else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        self.recognizer = recognizer
        feed.request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in
                guard let self, self.recording, self.feed.request === req else { return }
                self.transcript = text
            }
        }
    }

    private func stopPreview() {
        feed.request?.endAudio()
        task?.cancel(); task = nil
        feed.request = nil
    }

    /// Each microphone buffer's level, while recording: is that you talking? Over Aide's voice it takes a louder
    /// quarter second to count, and then Aide stops and the recording keeps what you'd started to say.
    private func heard(_ level: CGFloat) {
        self.level = level
        guard isListening, recording else { return }
        let loud = level > (isSpeaking ? Self.talkingOver : Self.talking)
        loudRun = loud ? loudRun + 1 : 0
        if isSpeaking {
            if loudRun >= 12 {
                stopSpeaking()
                feed.recorder?.keepLast(0.8)
                heardSpeech = true
                lastLoud = Date()
                startPreview()
            } else {
                feed.recorder?.keepLast(1) // only the moment before you might cut in
            }
            return
        }
        if loudRun >= 3 { heardSpeech = true }
        if loud, heardSpeech { lastLoud = Date() }
    }

    /// Sends after a pause; gives up if nothing was said. While Aide talks only an interruption counts.
    private func tick() {
        guard isListening, !isSpeaking else { return }
        if recording {
            let now = Date()
            if heardSpeech, now.timeIntervalSince(lastLoud) > Self.silenceBeforeSending
                || (feed.recorder?.duration ?? 0) > Self.longestRecording {
                finishListening(send: true)
            } else if !heardSpeech, now.timeIntervalSince(startedAt) > Self.giveUpAfter {
                stopAll()
            }
            return
        }
        let idle = Date().timeIntervalSince(lastChange)
        if !transcript.isEmpty, idle > Self.pauseBeforeSending { finishListening(send: true) }
        else if transcript.isEmpty, Date().timeIntervalSince(startedAt) > Self.giveUpAfter { stopAll() }
    }

    private func finishListening(send: Bool) {
        guard isListening else { return }
        timer?.invalidate(); timer = nil
        if recording {
            stopPreview()
            let recorder = feed.recorder
            feed.recorder = nil
            recording = false
            isListening = false
            level = 0
            if send, heardSpeech, let wav = recorder?.wav() {
                Task { await transcribeAndSend(wav) }
            } else if !send {
                conversation = false
                stopSpeaking()
                teardown()
            }
            return
        }
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

    /// The recording to the server, and what it heard on to the chat. Nothing heard: listen again.
    private func transcribeAndSend(_ wav: Data) async {
        guard let transcribe else { return }
        isTranscribing = true
        do {
            let text = try await transcribe(wav).trimmingCharacters(in: .whitespacesAndNewlines)
            isTranscribing = false
            guard conversation else { return } // ended meanwhile
            if text.isEmpty { listenAgain() } else { await onUtterance?(text) }
        } catch {
            isTranscribing = false
            guard conversation else { return }
            if case APIError.server(status: 503, _) = error {
                serverOff = true
                self.error = "The server can't transcribe, so the phone's own speech recognition is listening."
            } else {
                self.error = error.localizedDescription
            }
            listenAgain()
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

    /// The microphone, and Apple's speech recognition only when it does the listening.
    private func authorize(speech: Bool) async -> Bool {
        if speech {
            let allowed = await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
            guard allowed else { return false }
        }
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
            let req = feed.request, recorder = feed.recorder
            guard req != nil || recorder != nil else { return }
            req?.append(buffer)
            recorder?.append(buffer)
            guard let samples = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in stride(from: 0, to: n, by: 4) { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(max(1, n / 4)))
            Task { @MainActor in self?.heard(CGFloat(min(1, rms * 9))) }
        }
        engine.prepare()
        try engine.start()
    }

    private func teardown() {
        player.stop()
        stopPreview()
        feed.recorder = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Speaking

    /// A reply is on its way. Its number goes with `replyGrew` and `replyDone`, so a reply you've talked over
    /// stays quiet if more of it arrives.
    func replyStarted() -> Int {
        replyID += 1
        replyOpen = conversation // replies are only spoken in a voice conversation
        draft = ""
        draftSpoken = 0
        replyVoice = nil
        return replyID
    }

    /// The reply so far: each finished sentence is read out while the rest is still being written.
    /// `restarted`: the earlier draft was dropped; what was already said stays said.
    func replyGrew(_ id: Int, draft: String, restarted: Bool) {
        guard id == replyID, replyOpen else { return }
        if restarted { draftSpoken = 0 }
        self.draft = draft
        let rest = draft.dropFirst(draftSpoken)
        guard let end = Self.lastSentenceEnd(in: rest) else { return }
        let sentence = rest[..<end]
        draftSpoken += sentence.count
        enqueue(String(sentence))
    }

    /// The reply is in: whatever wasn't read out yet goes now (all of it, from a server that doesn't stream),
    /// then it's your turn.
    func replyDone(_ id: Int, _ text: String) {
        guard id == replyID, replyOpen else { return }
        replyOpen = false
        let full = draft.isEmpty ? text : draft
        enqueue(String(full.dropFirst(draftSpoken)))
        if isSpeaking {
            if !writing { writeNext() }
        } else {
            listenAgain()
        }
    }

    /// Reads a whole reply aloud.
    func speak(_ text: String) {
        replyDone(replyStarted(), text)
    }

    /// Where the last whole sentence ends: at a line break, or after ". ", "! ", "? ", "… " once the space after
    /// it has arrived (so "10.30" and a sentence still being written don't count).
    static func lastSentenceEnd(in text: Substring) -> Substring.Index? {
        var end: Substring.Index?
        var i = text.startIndex
        while i < text.endIndex {
            let next = text.index(after: i)
            if text[i] == "\n" || ".!?…;".contains(text[i]) && next < text.endIndex && text[next].isWhitespace { end = next }
            i = next
        }
        return end
    }

    /// Queues a piece of the reply to be voiced, listening the whole time in case you interrupt.
    private func enqueue(_ text: String) {
        let plain = Self.spokenText(text)
        guard conversation, speaksReplies(), !plain.isEmpty else { return }
        sentences.append(plain)
        if !isSpeaking {
            speechID += 1
            buffersPlaying = 0
            speechWritten = false
            isSpeaking = true
            listenAgain()
        }
        if !writing { writeNext() }
    }

    /// Voices the next waiting sentence, in the language the reply is written in. With none waiting and the reply
    /// done, it's all written: the end of the audio ends Aide's turn.
    private func writeNext() {
        guard !sentences.isEmpty else {
            writing = false
            if !replyOpen { speechWritten = true; finishSpeakingIfDone() }
            return
        }
        writing = true
        let text = sentences.removeFirst()
        if replyVoice == nil {
            let detected = NLLanguageRecognizer.dominantLanguage(for: draft.isEmpty ? text : draft)?.rawValue ?? languageCode()
            // "en" alone has no accent: use the speaker's region when it's the same language.
            let lang = languageCode().hasPrefix(detected) ? languageCode() : detected
            replyVoice = Self.bestVoice(for: lang) ?? Self.bestVoice(for: languageCode())
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = replyVoice
        utterance.rate = 0.5
        utterance.pitchMultiplier = 1.0
        let id = speechID
        synthesizer.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            // The main queue keeps the buffers in order (separate Tasks might not).
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.play(pcm, id: id) } }
        }
    }

    private func play(_ pcm: AVAudioPCMBuffer, id: Int) {
        guard id == speechID, isSpeaking else { return }
        if pcm.frameLength == 0 { writeNext(); return } // the end of this sentence
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
        feed.recorder?.keepLast(0)
        startPreview()
        listenAgain()
    }

    /// Cuts a reply off (you interrupted, or the voice chat ended). Listening carries on.
    private func stopSpeaking() {
        speechID += 1
        replyOpen = false
        sentences = []
        writing = false
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
        if s.hasPrefix("- ") { s.removeFirst(2) } // a list item on its own, as the reply is read out in pieces
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the microphone tap feeds, shared with the audio thread: Apple's recogniser or the recording.
private final class RequestFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SFSpeechAudioBufferRecognitionRequest?
    private var currentRecorder: PCMRecorder?

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var recorder: PCMRecorder? {
        get { lock.withLock { currentRecorder } }
        set { lock.withLock { currentRecorder = newValue } }
    }
}

/// The microphone as 16 kHz mono 16-bit PCM, plenty for speech and small to send: 32 KB a second.
final class PCMRecorder: @unchecked Sendable {
    static let sampleRate = 16_000.0
    private let lock = NSLock()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private let converter: AVAudioConverter?
    private var samples = Data()

    init(input: AVAudioFormat) {
        converter = AVAudioConverter(from: input, to: format)
    }

    /// On the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var given = false
        var failure: NSError?
        converter.convert(to: out, error: &failure) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard failure == nil, let pcm = out.int16ChannelData?[0], out.frameLength > 0 else { return }
        let data = Data(buffer: UnsafeBufferPointer(start: pcm, count: Int(out.frameLength)))
        lock.withLock { samples.append(data) }
    }

    var duration: TimeInterval { lock.withLock { Double(samples.count) / 2 / Self.sampleRate } }

    /// Drops all but the last `seconds`, once there's a second more than that (so it isn't copying every buffer).
    func keepLast(_ seconds: TimeInterval) {
        let keep = Int(seconds * Self.sampleRate) * 2
        lock.withLock {
            guard samples.count > keep + Int(Self.sampleRate) * 2 || (keep == 0 && !samples.isEmpty) else { return }
            samples = Data(samples.suffix(keep))
        }
    }

    func wav() -> Data { Self.wav(lock.withLock { samples }) }

    /// A WAV file around 16 kHz mono 16-bit samples.
    static func wav(_ pcm: Data) -> Data {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let rate = UInt32(sampleRate)
        var d = Data("RIFF".utf8) + le32(36 + UInt32(pcm.count)) + Data("WAVE".utf8)
        d += Data("fmt ".utf8) + le32(16) + le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        d += Data("data".utf8) + le32(UInt32(pcm.count)) + pcm
        return d
    }
}
