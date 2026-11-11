import SwiftUI

/// Settings → This Mac → Course folders (#73): the folder with a folder per course, which course each one is, and
/// what the last look did. `MacCourseFolders` does the work.
struct MacCourseFoldersView: View {
    @ObservedObject private var folders = MacCourseFolders.shared

    var body: some View {
        List {
            Section {
                LabeledContent("Folder") {
                    Text(folders.root?.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "None")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Button(folders.root == nil ? "Choose Folder…" : "Change Folder…") { folders.chooseRoot() }
                if folders.root != nil {
                    Button("Stop Keeping Them in Step", role: .destructive) { folders.setRoot(nil) }
                }
            } footer: {
                Text("Each folder in it is a course. Aide gets the PDFs you put there (once; the ones it has already, "
                     + "from Moodle too, are skipped), and its Moodle files that aren't there yet go into the "
                     + "course's moodle folder. Delete one there and it isn't copied again.")
            }
            if folders.root != nil {
                Section {
                    ForEach(folders.subfolders, id: \.self) { name in
                        Picker(name, selection: Binding(
                            get: { folders.chosen[name] ?? -1 },
                            set: { folders.choose($0 == -1 ? nil : $0, for: name) })) {
                            Text(autoTitle(name)).tag(-1)
                            Text("Not a course").tag(0)
                            ForEach(folders.courses) { Text($0.title).tag($0.id) }
                        }
                    }
                } header: {
                    Text("Courses")
                }
                Section {
                    HStack {
                        if folders.running {
                            ProgressView().controlSize(.small)
                            Text("Looking…").foregroundStyle(.secondary)
                        } else {
                            Text(folders.lastResult ?? "Not looked yet").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Look Now") { Task { await folders.sync() } }.disabled(folders.running)
                    }
                } footer: {
                    if let at = folders.lastRun {
                        Text("Last look \(at.formatted(date: .omitted, time: .shortened)). Every 10 minutes while Aide runs.")
                    }
                }
            }
        }
        .navigationTitle("Course folders")
        .task { if folders.courses.isEmpty, folders.root != nil { await folders.sync() } }
    }

    private func autoTitle(_ folder: String) -> String {
        guard let id = folders.guess(folder), let c = folders.courses.first(where: { $0.id == id }) else {
            return "Automatic (none)"
        }
        return "Automatic (\(c.title))"
    }
}
