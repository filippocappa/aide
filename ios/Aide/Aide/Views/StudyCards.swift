import SwiftUI

/// A study file as a row: its name and what it is, opening the PDF when tapped.
struct StudyFileRow: View {
    let file: StudyFile
    let open: (StudyFile) -> Void

    var body: some View {
        Button { open(file) } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.richtext.fill")
                    .font(.title3)
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(file)).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading).lineLimit(2)
                    Text(Self.detail(file)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the PDF")
    }

    static func title(_ file: StudyFile) -> String {
        file.name.hasSuffix(".pdf") || file.name.hasSuffix(".PDF") ? String(file.name.dropLast(4)) : file.name
    }

    /// "24 pages · Week 3 · from Moodle"
    static func detail(_ file: StudyFile) -> String {
        var parts: [String] = []
        if let pages = file.pages { parts.append(pages == 1 ? "1 page" : "\(pages) pages") }
        if let section = file.section, !section.isEmpty { parts.append(section) }
        if file.lecture != nil { parts.append("a lecture's slides") }
        if file.source == "moodle" { parts.append("from Moodle") }
        return parts.isEmpty ? "PDF" : parts.joined(separator: " · ")
    }
}

/// The files a chat message is about (a `files` card): tap one to read it.
struct FilesCard: View {
    let files: [StudyFile]
    @State private var open: StudyFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(files) { file in
                StudyFileRow(file: file) { open = $0 }
            }
        }
        .sheet(item: $open) { PDFSheet(file: $0) }
    }
}

/// Professor's notebook proposal under its message (a `proposal` card): tick the items to add, then Apply or Not now.
/// Once answered it says how it went; the chat's bar shows the writing.
struct ProposalAnswerCard: View {
    let proposal: NotebookProposal
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var chat: ChatViewModel
    /// The proposal as the last answer here left it, until the history brings it again.
    @State private var answered: NotebookProposal?
    /// The items ticked; nil: all of them.
    @State private var picked: Set<Int>?
    @State private var working = false
    @State private var error: String?

    private var shown: NotebookProposal { answered ?? proposal }
    private var items: [ProposalItem] { shown.items ?? [] }
    private var pending: Bool { (shown.status ?? "pending") == "pending" }
    private var chosen: Set<Int> { picked ?? Set(items.map(\.n)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(shown.kind == "outline" ? "Topics to write" : "To add to the notes", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
            ForEach(items) { item in row(item) }
            if pending {
                buttons
            } else {
                status
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: proposal) { answered = nil }
    }

    private func row(_ item: ProposalItem) -> some View {
        Button {
            var set = chosen
            if set.contains(item.n) { set.remove(item.n) } else { set.insert(item.n) }
            picked = set
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if pending {
                    Image(systemName: chosen.contains(item.n) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(chosen.contains(item.n) ? Theme.toggle : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Text(item.topic == nil ? "New" : "Expand")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(item.topic == nil ? Theme.toggle : .secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((item.topic == nil ? Theme.toggle : Color.secondary).opacity(0.14), in: Capsule())
                    }
                    if let add = item.add, !add.isEmpty {
                        Text(add.markdown).font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    if let sources = item.sources, !sources.isEmpty {
                        Text("From " + sources.joined(separator: "; ")).font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!pending || working)
        .accessibilityAddTraits(pending && chosen.contains(item.n) ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: chosen.contains(item.n))
    }

    private var buttons: some View {
        HStack {
            Button {
                answer(apply: true)
            } label: {
                Text(chosen.count == items.count ? "Apply all" : "Apply \(chosen.count)").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .foregroundStyle(Theme.onAccent)
            .disabled(chosen.isEmpty)
            Button {
                answer(apply: false)
            } label: {
                Text("Not now").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .disabled(working)
        .padding(.top, 2)
    }

    @ViewBuilder private var status: some View {
        switch shown.status {
        case "applying":
            Label("Writing them now", systemImage: "pencil.and.scribble").font(.footnote).foregroundStyle(.secondary)
        case "applied":
            Label(shown.result ?? "Added to the notes", systemImage: "checkmark.circle.fill")
                .font(.footnote).foregroundStyle(Theme.toggle)
        case "declined":
            Label("Not now", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.secondary)
        case "superseded":
            Label("Replaced by a newer proposal", systemImage: "arrow.uturn.right").font(.footnote)
                .foregroundStyle(.secondary)
        default:
            Label(shown.result ?? "It didn't work: ask Professor to try again", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange)
        }
    }

    private func answer(apply: Bool) {
        working = true
        error = nil
        Task {
            do {
                if apply {
                    let items = chosen.count == self.items.count ? nil : chosen.sorted()
                    answered = try await env.api.applyProposal(shown.id, items: items)
                    chat.watchNotebook()
                } else {
                    answered = try await env.api.declineProposal(shown.id)
                }
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// What a `moodle` notification brought: the new files by course, each opening its PDF.
struct NewFilesSheet: View {
    let ids: [String]
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var files: [StudyFile]?
    @State private var courses: [Int: String] = [:]
    @State private var open: StudyFile?

    private var byCourse: [(name: String, files: [StudyFile])] {
        let groups = Dictionary(grouping: files ?? []) { $0.course.flatMap { courses[$0] } ?? "Other files" }
        return groups.map { (name: $0.key.prefix(1).uppercased() + $0.key.dropFirst(), files: $0.value) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            List {
                if let files {
                    if files.isEmpty {
                        Text("These files aren't on the server any more.").foregroundStyle(.secondary)
                    }
                    ForEach(byCourse, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.files) { file in
                                StudyFileRow(file: file) { open = $0 }
                            }
                        }
                        .listRowBackground(Theme.row)
                    }
                    Section {} footer: {
                        Text("Professor reads new files and, for a course with a notebook, proposes what to add to it, in a chat of its own.")
                    }
                } else {
                    SkeletonSections(sections: 1, rows: min(max(ids.count, 1), 4))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle(ids.count == 1 ? "New from Moodle" : "\(ids.count) new from Moodle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $open) { PDFSheet(file: $0) }
        }
        .task { await load() }
    }

    private func load() async {
        if let study = try? await env.api.study() {
            courses = Dictionary(study.courses.map { ($0.id, $0.name) }) { first, _ in first }
        }
        var found: [StudyFile] = []
        await withTaskGroup(of: StudyFile?.self) { group in
            for id in ids { group.addTask { try? await env.api.file(id) } }
            for await file in group { if let file { found.append(file) } }
        }
        files = ids.compactMap { id in found.first { $0.id == id } }
    }
}

/// The ids a `moodle` notification carried, for `.sheet(item:)`.
struct NewFiles: Identifiable, Equatable {
    let ids: [String]
    var id: String { ids.joined(separator: ",") }
}
