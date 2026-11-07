import SwiftUI

// The lecture recorder's screen and its cards on the Study pages (Support/LectureRecorder.swift). iPhone only.

/// The recorder: the course, the time, the microphone's waveform, Pause, Stop and send. Closing it keeps recording.
struct RecorderSheet: View {
    @ObservedObject private var recorder = LectureRecorder.shared
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 8)
                VStack(spacing: 6) {
                    Text(recorder.session?.name.map(Self.capitalized) ?? "Lecture")
                        .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    Text(status).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                Text(RecorderClock.text(recorder.elapsed))
                    .font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Waveform(levels: recorder.levels, live: recorder.state == .recording)
                    .frame(height: 64).padding(.horizontal, 8)
                if let error = recorder.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Spacer(minLength: 8)
                controls
                Text("It keeps going with the screen locked, and stops by itself after 4 hours. "
                     + "When you stop, it's sent to Professor, who writes the notes.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(Theme.background)
            .navigationTitle("Recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hide") { dismiss() }
                }
                if recorder.isActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Throw it away", systemImage: "trash", role: .destructive) { confirmDiscard = true }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
            .confirmationDialog("Throw the recording away?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Throw it away", role: .destructive) { recorder.discard() }
            } message: {
                Text("It isn't sent and can't be brought back.")
            }
        }
        .presentationDetents([.large])
    }

    private var status: String {
        switch recorder.state {
        case .idle: recorder.error == nil ? "Starting…" : "Not recording"
        case .recording: "Recording"
        case .paused: recorder.interrupted ? "Paused for the call: it picks up again after" : "Paused"
        case .finishing: "Getting it ready to send…"
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 40) {
            Button {
                recorder.state == .paused ? recorder.resume() : recorder.pause()
            } label: {
                Image(systemName: recorder.state == .paused ? "play.fill" : "pause.fill")
                    .font(.title2).frame(width: 64, height: 64)
                    .background(Theme.card, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(recorder.state != .recording && recorder.state != .paused)
            .accessibilityLabel(recorder.state == .paused ? "Resume" : "Pause")

            Button {
                Task { await recorder.stop() }
            } label: {
                VStack(spacing: 6) {
                    Group {
                        if recorder.state == .finishing {
                            ProgressView().tint(.white)
                        } else {
                            RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 26, height: 26)
                        }
                    }
                    .frame(width: 84, height: 84)
                    .background(.red, in: Circle())
                    Text("Stop and send").font(.footnote.weight(.medium))
                }
            }
            .buttonStyle(.plain)
            .disabled(recorder.state != .recording && recorder.state != .paused)
        }
    }

    static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}

enum RecorderClock {
    /// 4:05, 1:02:09.
    static func text(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The microphone's level over the last few seconds, newest on the right.
struct Waveform: View {
    let levels: [Float]
    var live = true
    var bars = 40

    var body: some View {
        GeometryReader { geo in
            let shown = Array(levels.suffix(bars))
            let padded = Array(repeating: Float(0), count: max(0, bars - shown.count)) + shown
            let width = geo.size.width / CGFloat(bars)
            HStack(alignment: .center, spacing: 0) {
                ForEach(padded.indices, id: \.self) { i in
                    Capsule()
                        .fill(live ? Color.red.opacity(0.85) : Color.secondary.opacity(0.5))
                        .frame(width: max(2, width * 0.55), height: max(3, CGFloat(padded[i]) * geo.size.height))
                        .frame(width: width)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .animation(.linear(duration: 0.1), value: levels)
    }
}

/// On the Study page and a course's page while recording: the course, the time, the level; a tap opens the recorder.
struct RecordingCard: View {
    @ObservedObject private var recorder = LectureRecorder.shared

    var body: some View {
        Button { recorder.showSheet = true } label: {
            HStack(spacing: 12) {
                Circle().fill(recorder.state == .recording ? .red : .orange).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recorder.state == .paused ? "Paused" : recorder.state == .finishing ? "Getting it ready…" : "Recording")
                        .font(.subheadline.weight(.semibold))
                    Text(recorder.session?.name.map(RecorderSheet.capitalized) ?? "Lecture")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Waveform(levels: recorder.levels, live: recorder.state == .recording, bars: 16)
                    .frame(width: 60, height: 24)
                Text(RecorderClock.text(recorder.elapsed)).font(.subheadline.weight(.medium)).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card()
    }
}

/// "Macroeconomics is on now" with Record, on the Study page when the timetable has a lecture on.
struct RecordNowCard: View {
    let now: StudyNow
    /// The server can transcribe (`transcription` on /v1/study; nil from an older server).
    var transcription: Bool?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label("\(RecorderSheet.capitalized(now.name)) is on now", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.toggle)
                if let ends = now.ends.flatMap(Wire.parse) {
                    Text("Until \(ends.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if transcription != false {
                Button {
                    Task {
                        await LectureRecorder.shared.start(course: now.course, name: now.name,
                                                           ends: now.ends.flatMap(Wire.parse))
                    }
                } label: {
                    Label("Record", systemImage: "record.circle").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .card()
    }
}

/// Recordings not yet on the server (no signal in the hall), and the one just sent.
struct LectureUploadsCard: View {
    @ObservedObject private var uploads = LectureUploads.shared
    @State private var removing: LectureUploads.Item?

    var body: some View {
        if !uploads.items.isEmpty || uploads.sent != nil {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(uploads.items) { item in
                    HStack(spacing: 10) {
                        if uploads.sending == item.id {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up.circle").foregroundStyle(item.error == nil ? Theme.study : .orange)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(item)).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(uploads.sending == item.id ? "Sending…" : item.error.map { "Not sent yet: \($0)" }
                                 ?? "Waiting to send")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        if uploads.sending == nil {
                            Menu {
                                Button("Send now", systemImage: "arrow.clockwise") { Task { await uploads.flush() } }
                                Button("Throw it away", systemImage: "trash", role: .destructive) { removing = item }
                            } label: {
                                Image(systemName: "ellipsis.circle").font(.title3)
                            }
                        }
                    }
                }
                if uploads.items.isEmpty, let sent = uploads.sent {
                    Label("\(title(sent)) is with Professor: the notes come in the course's chat.",
                          systemImage: "checkmark.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .card()
            .confirmationDialog("Throw this recording away?", isPresented: Binding(get: { removing != nil },
                                                                                  set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { item in
                Button("Throw it away", role: .destructive) { uploads.remove(item) }
            } message: { _ in
                Text("It hasn't reached the server, so it can't be brought back.")
            }
        }
    }

    private func title(_ item: LectureUploads.Item) -> String {
        let name = item.name.map(RecorderSheet.capitalized) ?? "Lecture"
        return "\(name), \(RecorderClock.text(item.duration))"
    }
}
