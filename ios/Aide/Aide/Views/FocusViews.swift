import SwiftUI

/// Focus sessions (docs/API.md, "Focus sessions"; #54): rounds of study with breaks, each round a strict Screen Time
/// lock over everything but the apps allowed for focus, on the phone and on the Mac. Started from a course, a topic or
/// a review session (or by asking Professor); the card shows the one on now, with End.

/// What a focus session is started on: a course, perhaps a topic or a review session.
struct FocusTarget: Identifiable {
    let id = UUID()
    let course: Int
    let name: String
    var topic: String?
    var topicTitle: String?
    var review: String?
}

/// The rhythm (25/5, 50/10 or your own), how many rounds, strict or not, then Start.
struct FocusStartSheet: View {
    let target: FocusTarget
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var screenTime: ScreenTimeService
    @Environment(\.dismiss) private var dismiss
    @State private var presets: [FocusPreset] = FocusStartSheet.fallback
    @State private var passes: EmergencyPasses?
    @State private var preset: String? = "25/5"
    @State private var focusMin = 25
    @State private var breakMin = 5
    @State private var rounds = 4
    @State private var strict = true
    @State private var working = false
    @State private var error: String?

    static let fallback = [FocusPreset(name: "25/5", focusMin: 25, breakMin: 5, rounds: 4),
                           FocusPreset(name: "50/10", focusMin: 50, breakMin: 10, rounds: 2)]

    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Picker("Rhythm", selection: $preset) {
                        ForEach(presets, id: \.name) { Text($0.name).tag(Optional($0.name)) }
                        Text("Your own").tag(String?.none)
                    }
                    .pickerStyle(.segmented)
                    if preset == nil {
                        Stepper("Focus \(focusMin) min", value: $focusMin, in: 15...120, step: 5)
                        Stepper("Break \(breakMin) min", value: $breakMin, in: 1...30)
                    }
                    Stepper(rounds == 1 ? "1 round" : "\(rounds) rounds", value: $rounds, in: 1...8)
                } header: {
                    Text(target.topicTitle.map { "\(target.name) · \($0)" } ?? target.name)
                } footer: {
                    Text(plan)
                }
                Section {
                    Toggle("Strict", isOn: $strict)
                } footer: {
                    Text(strict ? "A round ends early only with an emergency pass (\(passes?.left ?? 3) left this month). "
                                    + "Breaks end freely."
                                : "A round ends early with a reason, which Professor and Coach see. Breaks end freely.")
                }
                Section {
                    Label(lockLine, systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                } footer: {
                    Text("At the end, five quick questions on what you studied, and Professor writes it up in the "
                         + "course chat.")
                }
            }
            #if os(macOS)
            .toggleStyle(.phoneSwitch)
            #endif
            .navigationTitle("Focus")
            .navigationBarTitleDisplayMode(.inline)
            .macSheetTitle("Focus")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else { Button("Start") { Task { await start() } } }
                }
            }
            .onChange(of: preset) { _, name in
                guard let p = presets.first(where: { $0.name == name }) else { return }
                focusMin = p.focusMin; breakMin = p.breakMin; rounds = p.rounds
            }
            .task { await load() }
        }
        .tint(Theme.study)
    }

    /// "4 rounds of 25 min, 5 min breaks: done at 11:40, 1h40 of focus."
    private var plan: String {
        let total = rounds * focusMin + (rounds - 1) * breakMin
        let end = Date().addingTimeInterval(TimeInterval(total * 60)).formatted(date: .omitted, time: .shortened)
        let focus = Self.length(rounds * focusMin)
        if rounds == 1 { return "One round of \(focusMin) min: done at \(end)." }
        return "\(rounds) rounds of \(focusMin) min, \(breakMin) min breaks: done at \(end), \(focus) of focus."
    }

    private var lockLine: String {
        #if os(macOS)
        "In a round this Mac closes every app but the focus ones (Settings → This Mac → Screen Time) and Aide; the "
            + "phone locks too."
        #else
        guard screenTime.isAuthorized else {
            return "Screen Time isn't allowed for Aide, so the phone won't lock. Settings → Screen Time."
        }
        return screenTime.focusAllowedCount == 0
            ? "In a round everything is locked but calls. Pick what stays open (Aide, Notes…) in Settings → Screen Time."
            : "In a round everything is locked but the \(screenTime.focusAllowedCount) apps picked for focus "
                + "(Settings → Screen Time); the Mac closes its apps too."
        #endif
    }

    static func length(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h == 0 ? "\(m) min" : m == 0 ? "\(h)h" : "\(h)h\(String(format: "%02d", m))"
    }

    private func load() async {
        guard let list = try? await env.api.focusSessions(days: 1, course: target.course) else { return }
        if !list.presets.isEmpty { presets = list.presets }
        passes = list.passes
    }

    private func start() async {
        working = true
        defer { working = false }
        do {
            let body = FocusStartBody(courseId: target.course, focusMin: focusMin, breakMin: breakMin, rounds: rounds,
                                      topic: target.topic, topicTitle: target.topicTitle, strict: strict,
                                      review: target.review)
            env.focus = try await env.api.startFocus(body)
            await screenTime.sync()  // the first round's lock, now rather than at the sync push
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The session on now: the phase and its countdown, the topic, "Round 2 of 4", a bar through the phase, and End.
struct FocusCard: View {
    let session: FocusSession
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var screenTime: ScreenTimeService
    @State private var ending: Ending?
    @State private var confirmBreak = false
    @State private var error: String?

    struct Ending: Identifiable {
        let pass: Bool
        var id: Bool { pass }
    }

    private var phase: FocusSession.Phase { session.phase }

    var body: some View {
        if session.isOn { running } else { finished }
    }

    /// Over: what it came to, and the five questions.
    private var finished: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark").font(.title2.weight(.semibold)).foregroundStyle(Theme.study)
                    .frame(width: 44, height: 44).background(Theme.study.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Focus done · \(FocusStartSheet.length(session.minutes))").font(.headline)
                    Text(session.topicTitle ?? session.course).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Button {
                if let url = URL(string: session.checkUrl), let route = PushRoute(url: url) {
                    Task { await env.open(route) }
                }
            } label: {
                Label("What stuck? Five questions", systemImage: "checklist")
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .foregroundStyle(.white).background(Theme.study, in: Capsule())
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(CardPress())
        }
        .card()
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: phase.isFocus ? "brain.head.profile" : "cup.and.saucer")
                    .font(.title2).foregroundStyle(phase.isFocus ? Theme.study : .mint)
                    .frame(width: 44, height: 44)
                    .background((phase.isFocus ? Theme.study : Color.mint).opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let ends = phase.endsDate, ends > Date() {
                    Text(timerInterval: Date()...ends, countsDown: true, showsHours: false)
                        .font(.title2.weight(.bold)).monospacedDigit().multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
            }
            if let since = phase.sinceDate, let ends = phase.endsDate, since < ends {
                ProgressView(timerInterval: since...ends, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.linear)
                    .tint(phase.isFocus ? Theme.study : .mint)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            HStack {
                Text(session.rhythm + (session.strict ? " · strict" : "")).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button(phase.isFocus ? "End early…" : "End the session") {
                    if phase.isFocus { ending = Ending(pass: session.strict) } else { confirmBreak = true }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(phase.isFocus ? Color.secondary : Theme.study)
            }
        }
        .card()
        .task(id: phase.ends) {
            // At the switch, the next phase (the server moves the lock and the Live Activity itself).
            guard let ends = phase.endsDate else { return }
            try? await Task.sleep(for: .seconds(max(1, ends.timeIntervalSinceNow + 2)))
            guard !Task.isCancelled else { return }
            await env.refreshFocus()
            await screenTime.sync()
        }
        .sheet(item: $ending) { item in
            FocusEndSheet(session: session, pass: item.pass)
        }
        .confirmationDialog("End the session now?", isPresented: $confirmBreak, titleVisibility: .visible) {
            Button("End it") { Task { await end() } }
        } message: {
            Text("It's a break, so nothing is locked: the rounds left are dropped, and the check comes now.")
        }
    }

    /// "Focus · round 2 of 4", "Break, then round 3 of 4".
    private var title: String {
        if phase.isFocus { return session.rounds == 1 ? "Focus" : "Focus · round \(phase.round) of \(session.rounds)" }
        return "Break, then round \(phase.round + 1) of \(session.rounds)"
    }

    private var subtitle: String {
        let what = session.topicTitle ?? session.course
        return session.minutes > 0 ? "\(what) · \(FocusStartSheet.length(session.minutes)) so far" : what
    }

    private func end() async {
        do {
            _ = try await env.api.endFocus(session.id, reason: nil)
            await env.refreshFocus()
            await screenTime.sync()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Ending a round early: a reason, or an emergency pass for a strict session, after a short wait.
private struct FocusEndSheet: View {
    let session: FocusSession
    let pass: Bool
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var screenTime: ScreenTimeService
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var left = 10
    @State private var working = false
    @State private var error: String?

    private var trimmed: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(pass ? "What's the emergency?" : "Why now?", text: $reason, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text((pass ? "Uses one of your \(screenTime.passes?.left ?? 0) passes left this month. " : "")
                         + "The session ends here, the rounds left are dropped. Professor and Coach see the reason.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(pass ? "Emergency pass" : "End focus early")
            .navigationBarTitleDisplayMode(.inline)
            .macSheetTitle(pass ? "Emergency pass" : "End focus early")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Keep going") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button(left > 0 ? "End (\(left))" : "End") { Task { await end() } }
                            .disabled(left > 0 || trimmed.isEmpty)
                    }
                }
            }
            .task {
                while left > 0 {
                    try? await Task.sleep(for: .seconds(1))
                    left -= 1
                }
            }
        }
        .tint(Theme.study)
    }

    private func end() async {
        working = true
        defer { working = false }
        do {
            _ = try await env.api.endFocus(session.id, reason: trimmed, pass: pass)
            await env.refreshFocus()
            await screenTime.sync()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
