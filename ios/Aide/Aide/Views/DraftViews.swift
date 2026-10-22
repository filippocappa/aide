import SwiftUI

/// A reply Secretary drafted (docs/API.md, "Mail drafts"): who it answers, what they asked, and the reply, with
/// Send, Edit and Dismiss. Send is the confirmation: the mail goes out at once.
struct DraftRow: View {
    let draft: MailDraft
    let agent: Agent
    let busy: Bool
    let send: () -> Void
    let edit: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                AgentMark(agent: agent, size: 22).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reply to \(draft.from)")
                    Text(draft.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Text(draft.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture(perform: edit)
            HStack(spacing: 10) {
                Button(action: send) { Label("Send", systemImage: "paperplane.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                Button(action: edit) { Text("Edit").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                Button(role: .destructive, action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Dismiss the draft")
            }
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }
}

/// The draft in full, to edit before sending. `send` and `dismiss` return a problem to show, or nil when done,
/// and the sheet closes.
struct DraftEditor: View {
    let draft: MailDraft
    let send: (String) async -> String?
    let dismiss: () async -> String?

    @Environment(\.dismiss) private var close
    @State private var text: String
    @State private var busy = false
    @State private var problem: String?

    init(draft: MailDraft, send: @escaping (String) async -> String?, dismiss: @escaping () async -> String?) {
        self.draft = draft
        self.send = send
        self.dismiss = dismiss
        _text = State(initialValue: draft.body)
    }

    private var to: String {
        draft.fromAddress.map { "\(draft.from) <\($0)>" } ?? draft.from
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("To", value: to)
                    LabeledContent("Subject", value: draft.replySubject)
                } footer: {
                    if let why = draft.why, !why.isEmpty { Text(why) }
                }
                Section("Reply") {
                    TextEditor(text: $text).frame(minHeight: 220)
                }
                if let preview = draft.preview, !preview.isEmpty {
                    Section("Their message") {
                        Text(preview).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                    }
                }
                Section {
                    Button("Dismiss the draft", role: .destructive) { Task { await run(dismiss) } }
                }
            }
            .navigationTitle("Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Send") { Task { await run { await send(text) } } }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .disabled(busy)
        }
    }

    private func run(_ call: () async -> String?) async {
        busy = true
        defer { busy = false }
        problem = await call()
        if problem == nil { close() }
    }
}

/// The evening digest's "Replies to send": each opens the editor; sent or dismissed ones say so.
struct DigestDraftRows: View {
    @EnvironmentObject private var model: DigestViewModel
    let drafts: [MailDraft]
    @State private var editing: MailDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(drafts) { draft in
                let done = model.draftOutcomes[draft.id]
                Button { editing = draft } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: done == "sent" ? "checkmark.circle.fill" : "arrowshape.turn.up.left")
                            .foregroundStyle(done == "sent" ? Theme.accent : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(draft.from).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(draft.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(done == "sent" ? "Sent" : done == "dismissed" ? "Dismissed" : draft.body)
                                .font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        if done == nil {
                            Text("Review").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(done != nil)
                .opacity(done == "dismissed" ? 0.5 : 1)
            }
        }
        .sheet(item: $editing) { draft in
            DraftEditor(draft: draft, send: { await model.send(draft, body: $0) }, dismiss: { await model.dismiss(draft) })
        }
    }
}
