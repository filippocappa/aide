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
///
/// You're talking when the live preview hears words or `SpeechDetector` hears your voice over the room's noise.
/// Each turn goes through `phase`, which is all the voice panel shows. `VoiceLog` keeps a diary for tuning.
@MainActor
final class VoiceController: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    /// Your words as you say them (the live preview).
    @Published private(set) var transcript = ""
    /// Where this turn is: waiting for you, hearing you, writing it down, thinking, or Aide speaking.
    enum Phase { case off, waiting, hearing, transcribing, thinking, speaking }
    @Published private(set) var phase = Phase.off
    /// What you said in the latest turn, once it's sent: the preview's words, then the server's.
    @Published private(set) var said = ""
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
    /// Apple's recogniser only: how long it waits for you to start talking before ending the voice chat.
    /// Recording for the server waits until you tap End.
    private static let giveUpAfter: TimeInterval = 30
    /// Recording for the server: how long a silence ends what you're saying, and the longest it records.
    private static let silenceBeforeSending: TimeInterval = 1.8
    private static let longestRecording: TimeInterval = 60

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
    /// While recording: you've started talking, and when you were last heard (loud, or new words).
    private var heardSpeech = false
    private var lastLoud = Date()
    private var detector = SpeechDetector()
    /// The live preview: words from recognitions that already ended this turn, the current one's, and when it began.
    private var previewEarlier = ""
    private var previewNow = ""
    private var previewStartedAt = Date()
    /// For the once-a-second line in the log: the loudest buffer, how many buffers came, the biggest raw sample.
    private var loudest = -100.0
    private var buffers = 0
    private var biggest: Float = 0
    private var loggedAt = Date()
    private var configObserver: NSObjectProtocol?

    var isActive: Bool { isListening || isSpeaking || conversation }

    // MARK: Listening

    func toggle() async {
        if isActive { stopAll() } else { conversation = true; said = ""; await startListening() }
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
        if !isSpeaking { phase = .waiting }
        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self, self.isListening, self.feed.request === req else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.transcript { self.transcript = text; self.lastChange = Date() }
                    if !self.isSpeaking, !text.isEmpty { self.phase = .hearing }
                    // You started talking over it: stop and listen. A lone sound isn't enough.
                    if self.isSpeaking, text.trimmingCharacters(in: .whitespaces).count >= 3 {
                        self.stopSpeaking()
                        self.phase = .hearing
                    }
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
        VoiceLog.note(isSpeaking ? "listening while Aide speaks" : "your turn")
        feed.recorder = PCMRecorder(input: engine.inputNode.outputFormat(forBus: 0))
        recording = true
        heardSpeech = false
        detector.newTurn()
        transcript = ""
        previewEarlier = ""
        previewNow = ""
        error = nil
        isListening = true
        startedAt = Date()
        if !isSpeaking { phase = .waiting; startPreview() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// While recording: Apple's recogniser, on the phone, shows what it hears as you talk, and its words tell that
    /// you're talking. What's sent is the server's transcript. Not while Aide talks (it would hear Aide), and not
    /// without permission.
    private func startPreview() {
        guard recording, feed.request == nil else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: languageCode())), recognizer.isAvailable
        else { VoiceLog.note("no live preview: speech recognition is off or unavailable"); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        self.recognizer = recognizer
        feed.request = req
        previewStartedAt = Date()
        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            let text = result?.bestTranscription.formattedString
            let ended = err != nil || result?.isFinal == true
            let why = err?.localizedDescription ?? "finished"
            Task { @MainActor in
                guard let self, self.recording, self.feed.request === req else { return }
                if let text { self.previewHeard(text) }
                if ended { self.previewEnded(why) }
            }
        }
    }

    /// New words are the surest sign you're talking, however quietly.
    private func previewHeard(_ text: String) {
        previewNow = text
        let all = [previewEarlier, text].filter { !$0.isEmpty }.joined(separator: " ")
        guard all != transcript else { return }
        transcript = all
        guard !isSpeaking, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if !heardSpeech { youStarted("words") }
        lastLoud = Date()
    }

    /// Apple ends a recognition after a few seconds of silence, and after about a minute anyway: start another,
    /// keeping the words so far. One that ends straight away (offline, say) waits a second before the next.
    private func previewEnded(_ why: String) {
        VoiceLog.note("preview ended (\(why)), starting another")
        previewEarlier = [previewEarlier, previewNow].filter { !$0.isEmpty }.joined(separator: " ")
        previewNow = ""
        stopPreview()
        let quick = Date().timeIntervalSince(previewStartedAt) < 1
        Task {
            if quick { try? await Task.sleep(for: .seconds(1)) }
            guard recording, !isSpeaking else { return }
            startPreview()
        }
    }

    private func youStarted(_ how: String) {
        heardSpeech = true
        phase = .hearing
        VoiceLog.note("heard you: \(how)")
    }

    private func stopPreview() {
        feed.request?.endAudio()
        task?.cancel(); task = nil
        feed.request = nil
    }

    /// Each microphone buffer, while recording: is that you talking? Over Aide's voice it takes louder and longer
    /// to count, and then Aide stops and the recording keeps what you'd started to say.
    private func heard(level: CGFloat, db: Double, duration: TimeInterval, peak: Float) {
        self.level = level
        buffers += 1
        biggest = max(biggest, peak)
        guard isListening, recording else { return }
        let talking = detector.feed(db, duration: duration, strict: isSpeaking)
        loudest = max(loudest, db)
        if isSpeaking {
            if talking {
                VoiceLog.note("you talked over Aide (\(Int(db)) dB)")
                stopSpeaking()
                feed.recorder?.keepLast(0.8)
                youStarted("over Aide")
                lastLoud = Date()
                startPreview()
            } else {
                feed.recorder?.keepLast(1) // only the moment before you might cut in
            }
            return
        }
        if talking {
            if !heardSpeech { youStarted("voice, \(Int(db)) dB over a bar of \(Int(detector.bar))") }
            lastLoud = Date()
        }
        // Before you're heard, the last 20 s: no long silence, but all of it if you tap Send having been missed.
        if !heardSpeech { feed.recorder?.keepLast(20) }
    }

    /// You're done: send what you've said now, without waiting for the pause.
    func sendNow() {
        guard isListening, !isSpeaking else { return }
        VoiceLog.note("send now")
        finishListening(send: true, force: true)
    }

    /// Sends after a pause. Apple's recogniser gives up if nothing was said. While Aide talks only an interruption
    /// counts.
    private func tick() {
        if recording, Date().timeIntervalSince(loggedAt) >= 1 {
            VoiceLog.note("loudest \(Int(loudest)) dB, noise \(Int(detector.noise ?? -100)), bar \(Int(detector.bar)), "
                          + "talking bar \(Int(detector.talkingBar)), "
                          + "\(heardSpeech ? "heard" : "waiting"), preview \(feed.request == nil ? "off" : "on"), "
                          + "\(buffers) buffers, biggest sample \(String(format: "%.6f", biggest)), "
                          + "engine \(engine.isRunning ? "running" : "stopped")")
            loudest = -100
            buffers = 0
            biggest = 0
            loggedAt = Date()
        }
        guard isListening, !isSpeaking else { return }
        if recording {
            let now = Date()
            if heardSpeech, now.timeIntervalSince(lastLoud) > Self.silenceBeforeSending
                || (feed.recorder?.duration ?? 0) > Self.longestRecording {
                finishListening(send: true)
            }
            return
        }
        let idle = Date().timeIntervalSince(lastChange)
        if !transcript.isEmpty, idle > Self.pauseBeforeSending { finishListening(send: true) }
        else if transcript.isEmpty, Date().timeIntervalSince(startedAt) > Self.giveUpAfter { stopAll() }
    }

    /// `force`: send the recording even though nothing in it counted as talking (you tapped Send).
    private func finishListening(send: Bool, force: Bool = false) {
        guard isListening else { return }
        timer?.invalidate(); timer = nil
        if recording {
            stopPreview()
            let recorder = feed.recorder
            feed.recorder = nil
            recording = false
            isListening = false
            level = 0
            VoiceLog.note("stopped recording: send \(send), heard \(heardSpeech), "
                          + "\(String(format: "%.1f", recorder?.duration ?? 0)) s, preview \(transcript.split(separator: " ").count) words")
            if send, heardSpeech || force, let wav = recorder?.wav() {
                said = transcript
                transcript = ""
                phase = .transcribing
                Task { await transcribeAndSend(wav) }
            } else if send {
                listenAgain() // nothing to send: keep listening
            } else {
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
            said = text
            phase = .thinking
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
        do {
            let text = try await transcribe(wav).trimmingCharacters(in: .whitespacesAndNewlines)
            VoiceLog.note("transcribed \(wav.count / 1000) KB: \(text.split(separator: " ").count) words")
            guard conversation else { return } // ended meanwhile
            if text.isEmpty {
                said = ""
                listenAgain()
            } else {
                said = text
                phase = .thinking
                await onUtterance?(text)
            }
        } catch {
            VoiceLog.note("transcribing failed: \(error.localizedDescription)")
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
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engineChanged() }
            }
        }
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
            let db = SpeechDetector.decibels(samples, count: n)
            let duration = Double(n) / buffer.format.sampleRate
            let level = CGFloat(min(1, 9 * pow(10, db / 20))) // the Pebble's pulse
            var peak: Float = 0
            for i in stride(from: 0, to: n, by: 4) { peak = max(peak, abs(samples[i])) }
            Task { @MainActor in self?.heard(level: level, db: db, duration: duration, peak: peak) }
        }
        engine.prepare()
        try engine.start()
        detector.reset()
        let route = session.currentRoute.inputs.map { "\($0.portType.rawValue) \($0.portName)" }.joined(separator: ", ")
        VoiceLog.note("microphone on: \(input.outputFormat(forBus: 0)), input \(route.isEmpty ? "none" : route), "
                      + "\(session.category.rawValue) \(session.mode.rawValue), \(Int(session.sampleRate)) Hz, "
                      + "voice processing \(input.isVoiceProcessingEnabled), muted \(input.isVoiceProcessingInputMuted), "
                      + "permission \(AVAudioApplication.shared.recordPermission.rawValue)")
    }

    /// iOS changed the audio setup (voice processing coming up, a route change, a call) and stopped the engine:
    /// without this the microphone just goes quiet. Start it again, recording on where it was.
    private func engineChanged() {
        VoiceLog.note("audio setup changed, engine \(engine.isRunning ? "running" : "stopped")")
        guard conversation, !engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        do { try startEngine() } catch { VoiceLog.note("couldn't restart the microphone: \(error.localizedDescription)") }
    }

    private func teardown() {
        phase = .off
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
            phase = .speaking
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
        transcript = ""
        previewEarlier = ""
        previewNow = ""
        if isListening { phase = .waiting; VoiceLog.note("your turn") }
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
    private var converter: AVAudioConverter? // only touched on the audio thread after init
    private var samples = Data()

    init(input: AVAudioFormat) {
        converter = AVAudioConverter(from: input, to: format)
    }

    /// On the audio thread. A microphone restarted in another format gets a new converter.
    func append(_ buffer: AVAudioPCMBuffer) {
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
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
