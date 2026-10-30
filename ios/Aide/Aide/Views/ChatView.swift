import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var voice: VoiceController
    @EnvironmentObject private var digest: DigestViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var showPastChats = false
    /// Picked in Past chats; run once the sheet is gone.
    @State private var pastChoice: PastChatsSheet.Choice?
    @State private var showRoutines = false
    /// A button on the agent's profile; run once the sheet is gone.
    @State private var infoAction: AgentInfoSheet.Action?
    @State private var showInfo = false
    @State private var showPractice = false
    @State private var justReplied = false
    /// Photos to go with the next message, shrunk and ready.
    @State private var photos: [PickedPhoto] = []
    @State private var showCamera = false
    @State private var showLibrary = false
    /// Coach's chats: Aide's meal camera instead of the system one, and what it ended with.
    @State private var showMealCamera = false
    @State private var mealCameraResult: MealCameraResult?
    /// A barcode read in a lone photo in Coach's chat: its "How much?" sheet.
    @State private var scanned: ScannedCode?
    /// The scanned photo goes into the message instead ("Ask Coach instead").
    @State private var coachInstead: PickedPhoto?
    /// Bumped on every send: the message box starts a new text field (`MessageBox.reset`).
    @State private var sent = 0
    @FocusState private var composerFocused: Bool

    /// Pebble's expression follows what's happening (brand/README.md).
    private var mood: String {
        if !settings.isConfigured || chat.loadError != nil { return "sleeping" }
        if voice.isListening { return "awake" }
        if voice.isSpeaking { return "happy" }
        if chat.isSending || chat.isActing || chat.isOpening { return "thinking" }
        if justReplied { return "happy" }
        return composerFocused ? "awake" : "calm"
    }

    private static let headerPebble: CGFloat = 44
    private static let headerHeight: CGFloat = 56
    private static let voicePebble: CGFloat = 250

    private var isEmpty: Bool { chat.messages.isEmpty && !chat.isSending && !chat.isOpening && !chat.isLoadingHistory }

    private var replying: Bool { (chat.isSending || chat.isActing) && !voice.isActive }

    private static let maxPhotos = 4

    var body: some View {
        ZStack(alignment: .top) {
            // The chat fills the screen and scrolls under Pebble. In a voice chat the voice panel takes its
            // place: the old one fades out quickly, then the new one fades in, so the End button and the
            // message box are never half-faded on top of each other.
            Group {
                if voice.isActive {
                    VoicePanel()
                        .padding(.top, Self.voiceHeader)
                        .transition(Self.swap)
                } else {
                    VStack(spacing: 0) {
                        transcript
                        if !chat.pending.isEmpty { PendingCard() }
                        composer
                    }
                    .transition(Self.swap)
                }
            }
            header
            if let writing = chat.writing, !voice.isActive {
                NotebookBar(progress: writing, step: chat.writingStep)
                    .padding(.top, Self.headerHeight + 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.78), value: voice.isActive)
        .animation(.easeInOut(duration: 0.3), value: chat.writing)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: replying)
        .animation(.easeInOut(duration: 0.3), value: isEmpty)
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar) // Pebble and its buttons are the header
        .toolbar(.hidden, for: .tabBar) // a chat has the whole screen
        .sheet(isPresented: $showInfo, onDismiss: {
            guard let action = infoAction else { return }
            infoAction = nil
            switch action {
            case .newChat: Task { await chat.startChat(with: chat.agent) }
            case .starter(let text): Task { await chat.startChat(with: chat.agent); await chat.send(text) }
            case .pastChats: showPastChats = true
            case .routines: showRoutines = true
            case .quiz: Task { await voice.start(saying: "Quiz me") }
            case .practiceExam: showPractice = true
            case .activity: break
            }
        }) {
            AgentInfoSheet(agent: chat.agent, act: { infoAction = $0; showInfo = false }, showsActivity: false,
                           inChat: true,
                           smart: chat.conversationID == nil ? nil
                               : Binding(get: { chat.smart }, set: { on in Task { await chat.setSmart(on) } }),
                           course: chat.course != nil)
        }
        .fullScreenCover(isPresented: $showPractice, onDismiss: {
            Task { await chat.loadHistory() } // Professor's note on the result
        }) {
            if let course = chat.course { PracticeExamView(course: course.id, courseName: course.name) }
        }
        .sheet(isPresented: $showPastChats, onDismiss: {
            guard let picked = pastChoice else { return }
            pastChoice = nil
            Task { await chat.run(picked) }
        }) {
            PastChatsSheet(agent: chat.agent) { pastChoice = $0; showPastChats = false }
        }
        .sheet(isPresented: $showRoutines, onDismiss: {
            guard let picked = pastChoice else { return }
            pastChoice = nil
            Task { await chat.run(picked) }
        }) {
            RoutinesSheet(agent: chat.agent) { pastChoice = $0; showRoutines = false }
        }
        .onChange(of: voice.isActive) { _, active in
            if active { composerFocused = false } // no keyboard in voice
            UIApplication.shared.isIdleTimerDisabled = active // locking would cut off the microphone
        }
        .onAppear {
            chat.isOnScreen = true
            if chat.typeOnOpen {
                chat.typeOnOpen = false
                Task {
                    try? await Task.sleep(for: .milliseconds(350)) // once the push has settled
                    composerFocused = true
                }
            }
            if let id = chat.conversationID { chat.live?.chatOpened(conversation: id) }
        }
        .onChange(of: chat.conversationID) { _, id in
            if chat.isOnScreen, let id { chat.live?.chatOpened(conversation: id) }
        }
        .onDisappear {
            chat.isOnScreen = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .photoSources(camera: $showCamera, library: $showLibrary, limit: Self.maxPhotos - photos.count,
                      barcodes: chat.agent.id == "coach") { picked in
            // A packet on its own in Coach's chat: say how much and it's logged, no model call.
            if picked.count == 1, photos.isEmpty, let code = picked[0].barcodes.first {
                scanned = ScannedCode(code: code, photo: picked[0])
            } else {
                photos = Array((photos + picked).prefix(Self.maxPhotos))
            }
        }
        .fullScreenCover(isPresented: $showMealCamera, onDismiss: afterMealCamera) {
            MealCameraView(tint: chat.agent.tint, conversation: chat.conversationID) { mealCameraResult = $0 }
        }
        .sheet(item: $scanned, onDismiss: {
            if let photo = coachInstead { photos = [photo] }
            coachInstead = nil
        }) { code in
            ScanSheet(barcode: code.code, date: nil, conversation: chat.conversationID, tint: chat.agent.tint,
                      logged: { _ in Task { await chat.loadHistory() } },
                      askCoach: code.photo.map { photo in { coachInstead = photo } })
        }
    }

    private static let voiceHeader: CGFloat = 330
    private static let swap = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.25).delay(0.15)),
        removal: .opacity.animation(.easeIn(duration: 0.15)))

    /// One small Pebble, always centred between floating buttons, over a soft blur the messages slide under. In a
    /// voice chat it grows and the blur goes; in an empty chat it sits big in the middle instead (`emptyState`).
    /// It's laid out once at full size and only scaled, so growing can't shift it sideways.
    private var header: some View {
        ZStack(alignment: .top) {
            // The fade reaches up under the status bar as well as covering the header itself.
            HeaderBackdrop()
                .ignoresSafeArea(edges: .top)
                .frame(height: Self.headerHeight + 28)
                .opacity(voice.isActive ? 0 : 1)
                .allowsHitTesting(false)
            HeaderPebble(mood: mood, size: Self.voicePebble, energy: voice.isListening ? voice.level : 0,
                         messages: chat.messages.count, agent: chat.agent)
                // a little bigger while it answers
                .scaleEffect((voice.isActive ? 1 : Self.headerPebble / Self.voicePebble) * (replying ? 1.3 : 1), anchor: .top)
                // level with the buttons
                .offset(y: voice.isActive ? 40 : 4)
                .frame(maxWidth: .infinity)
                .frame(height: voice.isActive ? Self.voiceHeader : Self.headerHeight, alignment: .top)
                .opacity(isEmpty && !voice.isActive ? 0 : 1)
                // In a voice chat, tapping Pebble while it listens sends what you said without waiting for the pause.
                .simultaneousGesture(TapGesture().onEnded {
                    if voice.phase == .waiting || voice.phase == .hearing { voice.sendNow() }
                })
            if !voice.isActive { buttons.transition(.opacity) }
        }
    }

    /// Chat controls on either side of Pebble.
    private var buttons: some View {
        HStack(spacing: 8) {
            headerButton("chevron.left", label: "Chats") { dismiss() }
            Spacer()
            headerButton("ellipsis", label: "About \(chat.agent.name)") { showInfo = true }
            .disabled(!settings.isConfigured)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func headerButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { headerIcon(icon) }.accessibilityLabel(label)
    }

    private func headerIcon(_ name: String) -> some View { HeaderIcon(name: name) }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    if isEmpty { emptyState }
                    ForEach(chat.messages) { message in
                        VStack(alignment: .leading, spacing: 8) {
                            if let routine = message.routine {
                                Label(routine.title, systemImage: "alarm")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 2)
                            }
                            if !message.team.isEmpty {
                                TeamThread(messages: message.team)
                            } else if !message.consulted.isEmpty {
                                ConsultedRow(agents: message.consulted.map { chat.agent($0) })
                            }
                            MessageRow(message: message, foldedErrands: chat.errandsAgain(after: message))
                            if chat.startsWithDigest, message.id == chat.messages.first?.id { digestDetails }
                        }
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                    }
                    if chat.isOpening { ThinkingRow(label: "Getting your digest…") }
                    if chat.isSending, !chat.liveTeam.isEmpty {
                        TeamThread(messages: chat.liveTeam, live: true).transition(.opacity)
                    }
                    let draft = chat.liveReply.trimmingCharacters(in: .whitespacesAndNewlines)
                    if chat.isSending, !draft.isEmpty {
                        HStack {
                            RichText(text: draft, isError: false)
                            Spacer(minLength: 32)
                        }
                        .padding(.horizontal, 2)
                    } else if chat.isSending, chat.liveTeam.last?.from != chat.orchestrator.id {
                        // While an agent works on its answer, the thread shows it thinking instead.
                        ThinkingRow()
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .animation(.easeOut(duration: 0.28), value: chat.messages)
            }
            .scrollDismissesKeyboard(.immediately)
            .contentMargins(.top, Self.headerHeight, for: .scrollContent) // starts below Pebble, scrolls under it
            .defaultScrollAnchor(isEmpty ? .center : .bottom)
            .onTapGesture { composerFocused = false }
            .onChange(of: chat.messages) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.pending) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.liveTeam) { _, _ in scrollToBottom(proxy) }
            .onChange(of: chat.liveReply) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.isSending) { _, sending in
                scrollToBottom(proxy)
                if !sending, chat.messages.last?.role == .assistant, chat.messages.last?.isError == false {
                    justReplied = true
                    Task { try? await Task.sleep(for: .seconds(2)); justReplied = false }
                }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    /// Under Pebble's digest greeting: the cards it was written from.
    private var digestDetails: some View {
        Button {
            digest.kind = DigestViewModel.Kind(rawValue: chat.openedDigest ?? ChatViewModel.digestKind()) ?? .wake
            digest.isPresented = true
        } label: {
            Label("Details", systemImage: "sun.horizon")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
    }

    /// Pebble big in the middle, what to say, and a few ways to start.
    private var emptyState: some View {
        VStack(spacing: 20) {
            LivePebble(mood: mood, size: 120, figure: chat.agent.figure)
                .foregroundStyle(chat.agent.tint)
                .allowsHitTesting(false)
            if settings.isConfigured {
                // The digest lives behind the sun button, so a new chat starts clean.
                if let error = chat.loadError {
                    Text(error).font(.title3.weight(.medium))
                } else if chat.agent.orchestrator {
                    Text("What can I do for you?").font(.title3.weight(.semibold))
                } else {
                    VStack(spacing: 4) {
                        Text(chat.agent.name).font(.title3.weight(.semibold))
                        Text(chat.agent.role).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 8) {
                    ForEach(chat.agent.starters.isEmpty && chat.agent.orchestrator ? Agent.aide.starters : chat.agent.starters,
                            id: \.self) { starter in
                        suggestion(starter, send: !starter.hasSuffix(" "))
                    }
                }
            } else {
                Text("Add your server token in Settings to start.").foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, 24)
    }

    private func suggestion(_ text: String, send: Bool) -> some View {
        Button {
            if send { Task { await chat.send(text) } } else { draft = text; composerFocused = true }
        } label: {
            Text(text.trimmingCharacters(in: .whitespaces) + (send ? "" : "…"))
                .font(.subheadline)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The message box: Talk starts a voice chat while it's empty, send once there's something to send. Photos to
    /// send sit above it.
    private var composer: some View {
        VStack(spacing: 0) {
            if !photos.isEmpty { photoStrip }
            MessageBox("Message \(chat.agent.name)", text: $draft, focused: $composerFocused, reset: sent) {
                attachMenu
                sendOrTalk
            }
        }
        .animation(.easeOut(duration: 0.2), value: photos)
    }

    /// What the meal camera ended with, once it's gone: shots go into the message, a logged packet's card is in the
    /// chat already.
    private func afterMealCamera() {
        guard let result = mealCameraResult else { return }
        mealCameraResult = nil
        switch result {
        case .photos(let picked): photos = Array((photos + picked).prefix(Self.maxPhotos))
        case .logged: Task { await chat.loadHistory() }
        case .library: showLibrary = true
        case .describe: composerFocused = true
        }
    }

    /// Take a photo or pick some, up to four a message.
    private var attachMenu: some View {
        Menu {
            if chat.agent.id == "coach", MealCamera.isAvailable {
                Button("Take photo", systemImage: "camera") { showMealCamera = true }
            } else if CameraPicker.isAvailable {
                Button("Take photo", systemImage: "camera") { showCamera = true }
            }
            Button("Choose photos", systemImage: "photo.on.rectangle") { showLibrary = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .background(Theme.chip, in: Circle())
        }
        .disabled(!settings.isConfigured || chat.isSending || photos.count >= Self.maxPhotos)
        .accessibilityLabel("Add photos")
    }

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(photos) { photo in
                    Image(uiImage: photo.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { photos.removeAll { $0.id == photo.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 18))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(3)
                            .accessibilityLabel("Remove photo")
                        }
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
    }

    @ViewBuilder private var sendOrTalk: some View {
        if showsMic {
                Button { Task { await voice.toggle() } } label: {
                    Label("Talk", systemImage: voice.isActive ? "stop.fill" : "waveform")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(voice.isActive ? "Stop voice chat" : "Talk to \(chat.agent.name)")
            } else {
                SendButton(enabled: canSend) {
                    let text = draft, sending = photos
                    $draft.clearMessage()
                    sent += 1
                    photos = []
                    Task { await chat.send(text, photos: sending) }
                }
            }
    }

    /// An empty message box offers the microphone instead of send.
    private var showsMic: Bool {
        settings.isConfigured && !chat.isSending && !chat.isOpening
            && (voice.isActive || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty))
    }

    private var canSend: Bool {
        settings.isConfigured && !chat.isSending && !chat.isOpening
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty)
    }
}

/// A rounded box with the text and, at its bottom right, its buttons. Shared by every chat.
struct MessageBox<Buttons: View>: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    /// Changed by the chat on every send: the text field is made anew, so the keyboard has nothing left to write a
    /// pending prediction or autocorrection back into (it put the sent message back in the box).
    var reset = 0
    let buttons: Buttons

    init(_ placeholder: String, text: Binding<String>, focused: FocusState<Bool>.Binding, reset: Int = 0,
         @ViewBuilder buttons: () -> Buttons) {
        self.placeholder = placeholder
        _text = text
        self.focused = focused
        self.reset = reset
        self.buttons = buttons()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused(focused)
                .id(reset)
                .padding(.leading, 8)
                .padding(.vertical, 7)
            buttons
        }
        .padding(7)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Theme.line, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { focused.wrappedValue = true } // the whole box, not just the line of text
        .onChange(of: reset) {
            guard focused.wrappedValue else { return }
            Task { @MainActor in focused.wrappedValue = true } // the keyboard stays, on the new field
        }
        // No background of its own around the box: the page's shows through, and an opaque band here would fade
        // out over the voice panel's End button as a visible stripe.
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

extension Binding where Value == String {
    /// Empties a message box after sending. The keyboard can write a pending autocorrection or predicted word back
    /// into the box just after it's cleared, so the message seemed to stay there: it's cleared once more a moment later.
    @MainActor func clearMessage() {
        wrappedValue = ""
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            wrappedValue = ""
        }
    }
}

/// The round send button in a message box.
struct SendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(enabled ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.tertiary))
                .frame(width: 34, height: 34)
                .background(enabled ? Theme.accent : Theme.chip, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Send")
    }
}

/// Your messages sit in soft grey bubbles; the reply is plain text on the page, like Pebble speaking, with copy
/// and share underneath.
private struct MessageRow: View {
    let message: ChatViewModel.Message
    var foldedErrands: Set<Int> = []
    @State private var copied = false

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 56)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.photos.isEmpty || !message.localPhotos.isEmpty { MessagePhotos(message: message) }
                    if !message.text.isEmpty {
                        Text(message.text.markdown)
                            .textSelection(.enabled)
                            .foregroundStyle(Theme.userBubbleText)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(Theme.userBubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RichText(text: message.text, isError: message.isError)
                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 2)
                ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                    AttachmentCard(attachment: attachment, foldedErrands: foldedErrands)
                }
                if !message.isError, !message.text.isEmpty { actions }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 20) {
            Button {
                UIPasteboard.general.string = message.text
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel("Copy")
            ShareLink(item: message.text) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
        .sensoryFeedback(.success, trigger: copied) { _, now in now }
    }
}

/// The photos you sent with a message, above its text: one at its own shape, more as squares two by two.
private struct MessagePhotos: View {
    let message: ChatViewModel.Message

    private static let width: CGFloat = 220

    /// The ones sent from here show from memory; the rest come from the server.
    private var items: [(id: String?, local: Data?)] {
        message.localPhotos.isEmpty ? message.photos.map { ($0, nil) } : message.localPhotos.map { (nil, $0) }
    }

    var body: some View {
        let items = items
        if items.count == 1 {
            ServerPhoto(id: items[0].id, local: items[0].local, fit: true)
                .frame(maxWidth: Self.width, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            let side = (Self.width - 4) / 2
            LazyVGrid(columns: [GridItem(.fixed(side), spacing: 4), GridItem(.fixed(side), spacing: 4)], spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    ServerPhoto(id: item.id, local: item.local)
                        .frame(width: side, height: side)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .frame(width: Self.width)
        }
    }
}

/// The reminders, events, meals, departures, routes or study files a reply was about, as a card: reminders tick off right
/// here, events show on a week, files open, a notebook proposal is answered. A long list shows its first few until you ask for the rest.
struct AttachmentCard: View {
    let attachment: Attachment
    /// Errands shown again further down: one line here.
    var foldedErrands: Set<Int> = []
    @State private var expanded = false
    private static let fold = 5

    var body: some View {
        switch attachment {
        case .reminders(let all):
            let reminders = all.filter { !$0.deleted } // deleted since the reply
            if !reminders.isEmpty { card(reminders.count) { ReminderRows(reminders: shown(reminders)) } }
        case .events(let events):
            card { EventWeekCard(events: events) }
        case .meals(let meals):
            if !meals.isEmpty { card(meals.count) { ForEach(shown(meals)) { MealRow(meal: $0) } } }
        case .departures(let boards):
            VStack(spacing: 10) { ForEach(boards) { DeparturesCard(board: $0) } }
        case .routes(let routes):
            VStack(spacing: 10) { ForEach(routes) { RouteCard(route: $0) } }
        case .files(let files):
            if !files.isEmpty { card { FilesCard(files: files) } }
        case .proposal(let proposal):
            card { ProposalAnswerCard(proposal: proposal) }
        case .errands(let errands):
            VStack(spacing: 10) {
                ForEach(errands) { ErrandCard(errand: $0, folded: foldedErrands.contains($0.id)) }
            }
        case .purchases(let purchases):
            VStack(spacing: 10) { ForEach(purchases) { PurchaseCard(purchase: $0) } }
        case .products(let products):
            if !products.isEmpty { ProductsCard(products: products) }
        case .videos(let videos):
            VStack(spacing: 10) { ForEach(videos) { VideoCardView(card: $0) } }
        case .unknown:
            EmptyView()
        }
    }

    /// Folded only when it saves more than a couple of rows.
    private func folds(_ count: Int) -> Bool { count > Self.fold + 2 }

    private func shown<T>(_ items: [T]) -> [T] {
        expanded || !folds(items.count) ? items : Array(items.prefix(Self.fold))
    }

    private func card<Content: View>(_ count: Int = 0, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
            if folds(count) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    Label(expanded ? "Show less" : "Show all \(count)", systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Above a reply: the specialists Aide asked for it, as small Pebbles in their colours.
struct ConsultedRow: View {
    let agents: [Agent]

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -6) {
                ForEach(agents) { AgentMark(agent: $0, size: 22) }
            }
            Text("Asked " + agents.map(\.name).formatted(.list(type: .and)))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }
}

/// What Aide and the agents it asked said to each other, as a little group chat above Aide's reply. While Aide is
/// still working it fills in live, with the asked agent thinking until its answer comes. Tap to read it all.
struct TeamThread: View {
    @EnvironmentObject private var chat: ChatViewModel
    let messages: [TeamMessage]
    var live = false
    @State private var expanded = false

    /// The agent Aide asked last, still working on its answer.
    private var working: Agent? {
        guard live, let last = messages.last, last.from == chat.orchestrator.id else { return nil }
        return chat.agent(last.to)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Team", systemImage: "person.3.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                row(message).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let working {
                HStack(spacing: 10) {
                    LivePebble(mood: "thinking", size: 26, figure: working.figure)
                        .foregroundStyle(working.tint)
                        .allowsHitTesting(false)
                    Text("\(working.name) is thinking…").font(.footnote).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: messages.count)
        .accessibilityElement(children: .combine)
        .accessibilityHint(expanded ? "Shows less" : "Shows all of it")
    }

    private func row(_ message: TeamMessage) -> some View {
        let from = chat.agent(message.from), to = chat.agent(message.to)
        return HStack(alignment: .top, spacing: 10) {
            AgentMark(agent: from, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(from.name)
                    Image(systemName: "arrow.right").imageScale(.small).foregroundStyle(.tertiary)
                    Text(to.name).foregroundStyle(.secondary)
                }
                .font(.caption.weight(.semibold))
                Text(message.text.markdown)
                    .font(.callout)
                    .lineLimit(expanded ? nil : 4)
            }
        }
    }
}

private struct ThinkingRow: View {
    var label = "Thinking…"

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 2)
    }
}

/// Actions waiting for the user's yes, worded by the server's code rather than the model.
struct PendingCard: View {
    @EnvironmentObject private var chat: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(chat.pending.count == 1 ? "Waiting for your OK" : "\(chat.pending.count) changes waiting for your OK")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(chat.pending) { Text($0.summary).font(.callout) }
            HStack(spacing: 10) {
                Button { Task { await chat.confirm() } } label: { Text("Confirm").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                Button(role: .cancel) { Task { await chat.cancel() } } label: { Text("Cancel").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            }
            .disabled(chat.isActing)
        }
        .padding(14)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }
}

/// The chat's Pebble, bouncing at every touch on screen and every new message. The touch count lives here, not in
/// ChatView: a touch that re-rendered the whole chat would rebuild the ••• menu while it's open, and the menu would
/// drop the tap on its item.
private struct HeaderPebble: View {
    let mood: String
    let size: CGFloat
    let energy: CGFloat
    let messages: Int
    let agent: Agent
    @State private var tapCount = 0

    var body: some View {
        LivePebble(mood: mood, size: size, energy: energy, bounceTrigger: tapCount + messages, figure: agent.figure)
            .foregroundStyle(agent.tint)
            .animation(.easeInOut(duration: 0.3), value: agent.id)
            .background(TouchTracker(tapCount: $tapCount))
    }
}

/// With the navigation bar hidden, UIKit turns off the swipe from the left edge that goes back. This keeps it.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

/// The page fading in from the top, over a blur, so messages dissolve as they slide under Pebble and the buttons.
/// A round glass header button's face.
struct HeaderIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .glass(in: Circle())
    }
}

/// Behind a chat's header: the page colour under the status bar, then a blur that thins out, so messages slide
/// softly under the buttons instead of being cut off by a solid band.
struct HeaderBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.45),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            LinearGradient(stops: [.init(color: Theme.background, location: 0),
                                   .init(color: Theme.background, location: 0.3),
                                   .init(color: Theme.background.opacity(0.8), location: 0.55),
                                   .init(color: Theme.background.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}

/// A chat's name in the header, on the same glass as its buttons.
struct HeaderTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16)
            .frame(height: 44)
            .glass(in: Capsule())
    }
}

/// Under Pebble in a course's chat while its notebook is being written: how many topics are done, filling up as each
/// one finishes (docs/API.md, "Notebook"). Topics take a few minutes each, so the spinner shows it's still going,
/// and the step line which topics are being written.
private struct NotebookBar: View {
    let progress: NotebookProgress
    var step: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing the notes").font(.footnote.weight(.semibold))
                Spacer()
                if progress.total > 0 {
                    Text("\(progress.done) of \(progress.total)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            if let step, !step.isEmpty {
                Text(step).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .contentTransition(.numericText()).animation(.default, value: step)
            }
        }
        .tint(Theme.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line, lineWidth: 0.5))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Writing the notes, \(progress.done) of \(progress.total) topics done. \(step ?? "")")
    }
}
