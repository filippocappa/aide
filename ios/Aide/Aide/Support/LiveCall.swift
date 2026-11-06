import AVFoundation
import Foundation

/// A live call (docs/API.md, "Voice calls"): the microphone goes to the server as it's heard and the voice comes back
/// as it's spoken, over one WebSocket. The server's voice model listens and talks; the chat's agent does the work, and
/// each request and reply comes back as a `turn` for the chat. Nothing here decides when you've finished talking or
/// what you meant: the server does.
///
/// The voice plays through an engine of its own: voice processing on the microphone's engine made it flat and robotic
/// when it played there too (2026-11-06). Echo cancelling stays on the microphone while the phone's speaker plays
/// (voice processing, or the system's echo-cancelled input where the phone has it), so Aide doesn't hear itself;
/// with headphones there's no echo and no processing.
@MainActor
final class LiveCall {
    /// A request said in the call and its reply: `/v1/chat`'s response plus `text`, what was asked.
    struct Turn: Decodable {
        let text: String
        let reply: ChatReply

        init(from decoder: Decoder) throws {
            text = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .text)
            reply = try ChatReply(from: decoder)
        }
        private enum Key: String, CodingKey { case text }
    }

    enum Event {
        case started(rate: Double, agent: String)
        case state(working: Bool, step: String?)
        /// Words as they're written down, to append; `who` is "you" or the agent; `new` starts a new line of yours.
        case caption(who: String, text: String, new: Bool)
        /// You talked over the voice: what it hadn't said yet is dropped.
        case interrupted
        /// An ask or an answer between the agents while the turn works, shown as it happens.
        case team(TeamMessage)
        case turn(Turn)
        /// A spoken yes (or no) to queued actions, and the result to show as after a tap.
        case answered(ids: [Int], confirmed: Bool, result: String?)
        case ended(reason: String, seconds: Int)
        case error(String)
    }

    /// One message from the server, or nil for one this app doesn't know.
    static func parse(_ data: Data) -> Event? {
        struct Head: Decodable {
            let type: String
            var rate: Double?
            var agent: String?
            var state: String?
            var step: String?
            var who: String?
            var text: String?
            var new: Bool?
            var ids: [Int]?
            var confirmed: Bool?
            var result: String?
            var reason: String?
            var seconds: Double?
            var message: String?
        }
        struct Team: Decodable {
            let type: String
            let message: TeamMessage
        }
        if let team = try? JSONDecoder.api.decode(Team.self, from: data), team.type == "team" {
            return .team(team.message) // its `message` is an object, an error's a string
        }
        guard let head = try? JSONDecoder.api.decode(Head.self, from: data) else { return nil }
        switch head.type {
        case "started": return .started(rate: head.rate ?? 24_000, agent: head.agent ?? "aide")
        case "state": return .state(working: head.state == "working", step: head.step)
        case "caption": return .caption(who: head.who ?? "you", text: head.text ?? "", new: head.new ?? false)
        case "interrupted": return .interrupted
        case "turn": return (try? JSONDecoder.api.decode(Turn.self, from: data)).map(Event.turn)
        case "answered": return .answered(ids: head.ids ?? [], confirmed: head.confirmed ?? false, result: head.result)
        case "ended": return .ended(reason: head.reason ?? "ended", seconds: Int(head.seconds ?? 0))
        case "error": return .error(head.message ?? "The call didn't start.")
        default: return nil
        }
    }

    var onEvent: (Event) -> Void = { _ in }
    /// Your voice's loudness (0–1), for the Pebble's pulse.
    var onLevel: (CGFloat) -> Void = { _ in }
    /// The voice started or stopped playing.
    var onSpeaking: (Bool) -> Void = { _ in }

    /// The server said `started`: the voice is up and the microphone is going.
    private(set) var isStarted = false

    /// The microphone's engine, and the voice's.
    private let engine = AVAudioEngine()
    private let voice = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let mic = MicFeed()
    private var task: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var rate = 24_000.0
    private var playFormat: AVAudioFormat?
    private var configObservers: [NSObjectProtocol] = []
    /// Voice buffers scheduled and not played yet; `generation` moves on when they're dropped.
    private var queued = 0
    private var generation = 0
    /// For the diary: when your last words were written down, and when the agent started working.
    private var lastWords: Date?
    private var workingSince: Date?

    func connect(_ request: URLRequest) {
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 4 << 20
        self.task = task
        task.resume()
        reader = Task { [weak self] in await self?.read(task) }
    }

    /// Words for you, a request at once ("Quiz me").
    func say(_ text: String) { send(["type": "say", "text": text]) }

    /// Hangs up. The server ends the call and keeps what was said in the chat.
    func end() {
        guard let task else { return }
        send(["type": "end"])
        Task { // let "end" go out first; closing the socket would end the call too
            try? await Task.sleep(for: .milliseconds(400))
            task.cancel(with: .normalClosure, reason: nil)
        }
        close()
    }

    private func close() {
        reader?.cancel()
        reader = nil
        task = nil
        stopAudio()
    }

    private func send(_ message: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func read(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                guard !Task.isCancelled, self.task === task else { return }
                let why = switch task.closeCode {
                case .policyViolation: "The server didn't open a call in this chat."
                case .internalServerError: "Calls are off on the server."
                default: isStarted ? "The call dropped." : "Couldn't reach the server for a call."
                }
                close()
                onEvent(.error(why))
                return
            }
            switch message {
            case .data(let pcm): play(pcm)
            case .string(let text): if let event = Self.parse(Data(text.utf8)) { handle(event) }
            @unknown default: break
            }
        }
    }

    private func handle(_ event: Event) {
        switch event {
        case .started(let rate, _):
            self.rate = rate
            do {
                try startAudio()
                isStarted = true
            } catch {
                VoiceLog.note("call: couldn't start the microphone: \(error.localizedDescription)")
                end()
                onEvent(.error("Couldn't start the microphone."))
                return
            }
        case .interrupted:
            flush()
        case .caption(let who, _, _) where who == "you":
            lastWords = Date()
        case .state(let working, _):
            if working, workingSince == nil { workingSince = Date() }
        case .turn(let turn):
            if let since = workingSince {
                VoiceLog.note("call: reply in \(Int(-since.timeIntervalSinceNow * 1000)) ms, "
                              + "\(turn.reply.reply.split(separator: " ").count) words")
            }
            workingSince = nil
        case .error:
            if !isStarted { close() }
        default:
            break
        }
        onEvent(event)
        if case .ended = event { close() }
    }

    // MARK: Audio

    private func startAudio() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetooth]
        if #available(iOS 26, *) {
            // AirPods with the mic on drop to HFP: phone-call sound both ways, which made the voice robotic. Those
            // that can keep full-bandwidth audio both ways with this (HFP stays the fallback).
            options.insert(.bluetoothHighQualityRecording)
        }
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        if #available(iOS 18.2, *), session.isEchoCancelledInputAvailable {
            try? session.setPrefersEchoCancelledInput(true)
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        if configObservers.isEmpty {
            configObservers = [engine, voice].map { which in
                NotificationCenter.default.addObserver(
                    forName: .AVAudioEngineConfigurationChange, object: which, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.engineChanged() }
                }
            }
        }
        try startEngine()
    }

    /// Whether the microphone needs voice processing to keep the voice out: the phone's own speaker (or the Mac's),
    /// unless the system already cancels the echo there.
    private var needsProcessing: Bool {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 18.2, *), session.isEchoCancelledInputEnabled { return false }
        let outputs = session.currentRoute.outputs.map(\.portType)
        return outputs.contains(.builtInSpeaker) || outputs.contains(.builtInReceiver)
        #else
        return true
        #endif
    }

    private func startEngine() throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                                         interleaved: false) else { throw CallError.format }
        playFormat = format
        if player.engine == nil { voice.attach(player) }
        voice.connect(player, to: voice.mainMixerNode, format: format)
        voice.prepare()
        try voice.start()
        player.play()

        let input = engine.inputNode
        let processing = needsProcessing
        try input.setVoiceProcessingEnabled(processing)
        if processing, #available(iOS 17, macOS 14, *) {
            // Our voice is "other audio" to it now: not turned down
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }

        mic.framer = PCMFramer(rate: rate)
        let mic = mic
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let framer = mic.framer else { return }
            let frames = framer.append(buffer)
            let level = PCMFramer.level(buffer)
            Task { @MainActor in self?.heard(frames, level: level) }
        }
        engine.prepare()
        try engine.start()
        var echo = false
        #if os(iOS)
        if #available(iOS 18.2, *) { echo = AVAudioSession.sharedInstance().isEchoCancelledInputEnabled }
        var route = ""
        if let port = AVAudioSession.sharedInstance().currentRoute.inputs.first {
            route = ", mic \(port.portType.rawValue)"
            if #available(iOS 26, *), let bt = port.bluetoothMicrophoneExtension {
                route += bt.highQualityRecording.isEnabled ? " (full bandwidth)" : " (HFP)"
            }
        }
        #else
        let route = ""
        #endif
        VoiceLog.note("call: microphone on, \(input.outputFormat(forBus: 0)), voice processing "
                      + "\(input.isVoiceProcessingEnabled), echo-cancelled input \(echo), voice at \(Int(rate)) Hz"
                      + route)
    }

    /// iOS changed the audio setup (a route change, voice processing coming up) and stopped the engine.
    private func engineChanged() {
        guard isStarted, task != nil, !engine.isRunning || !voice.isRunning else { return }
        VoiceLog.note("call: audio setup changed, starting again")
        engine.inputNode.removeTap(onBus: 0)
        flush()
        if engine.isRunning { engine.stop() } // voice processing changes only while it's stopped
        if voice.isRunning { voice.stop() }
        do { try startEngine() } catch { VoiceLog.note("call: couldn't restart the microphone: \(error.localizedDescription)") }
    }

    private func heard(_ frames: [Data], level: CGFloat) {
        guard let task else { return }
        for frame in frames { task.send(.data(frame)) { _ in } }
        onLevel(level)
    }

    private func play(_ pcm: Data) {
        guard let format = playFormat, voice.isRunning else { return }
        let samples = Self.floats(pcm)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: samples.count) }
        if let last = lastWords {
            VoiceLog.note("call: voice \(Int(-last.timeIntervalSinceNow * 1000)) ms after your last words")
            lastWords = nil
        }
        queued += 1
        if queued == 1 { onSpeaking(true) }
        let generation = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.played(generation) }
        }
    }

    private func played(_ generation: Int) {
        guard generation == self.generation, queued > 0 else { return }
        queued -= 1
        if queued == 0 { onSpeaking(false) }
    }

    /// Drops the voice not played yet.
    private func flush() {
        generation += 1
        let wasSpeaking = queued > 0
        queued = 0
        player.stop()
        if voice.isRunning { player.play() }
        if wasSpeaking { onSpeaking(false) }
    }

    private func stopAudio() {
        mic.framer = nil
        flush()
        configObservers.forEach(NotificationCenter.default.removeObserver)
        configObservers = []
        guard isStarted else { return }
        isStarted = false
        player.stop()
        if voice.isRunning { voice.stop() }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        onLevel(0)
    }

    /// PCM16 little-endian samples as floats from -1 to 1.
    nonisolated static func floats(_ pcm: Data) -> [Float] {
        let count = pcm.count / 2
        return pcm.withUnsafeBytes { raw in
            (0..<count).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
    }

    private enum CallError: Error { case format }
}

/// The framer the microphone tap writes to, shared with the audio thread.
private final class MicFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var current: PCMFramer?

    var framer: PCMFramer? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// The microphone as PCM16 mono at the call's rate, cut into frames of `frameMs` to send as they fill.
final class PCMFramer: @unchecked Sendable {
    let frameBytes: Int
    private let format: AVAudioFormat
    private var converter: AVAudioConverter? // only touched on the audio thread
    private var pending = Data()

    init(rate: Double, frameMs: Int = 40) {
        format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
        frameBytes = Int(rate) * frameMs / 1000 * 2
    }

    /// On the audio thread: the buffer converted and added; the whole frames there now (the rest waits).
    func append(_ buffer: AVAudioPCMBuffer) -> [Data] {
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var given = false
        var failure: NSError?
        converter.convert(to: out, error: &failure) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard failure == nil, let pcm = out.int16ChannelData?[0], out.frameLength > 0 else { return [] }
        pending.append(Data(buffer: UnsafeBufferPointer(start: pcm, count: Int(out.frameLength))))
        var frames: [Data] = []
        while pending.count >= frameBytes {
            frames.append(Data(pending.prefix(frameBytes)))
            pending = Data(pending.dropFirst(frameBytes))
        }
        return frames
    }

    /// How loud the buffer is (0–1), as the Pebble's pulse elsewhere.
    static func level(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let db = SpeechDetector.decibels(samples, count: Int(buffer.frameLength))
        return CGFloat(min(1, 9 * pow(10, db / 20)))
    }
}
