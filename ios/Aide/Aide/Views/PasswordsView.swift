import LocalAuthentication
import SwiftUI

/// Settings → Passwords (docs/API.md, "Passwords"): logins the server's own code uses, like the UniTo login that reads
/// Esse3. Write-only: the server never sends a password back, so this page shows names, sites and usernames only.
/// Adding, changing or deleting one asks Face ID (or the passcode) first, and a password goes only over https.
struct PasswordsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @State private var list = PasswordList()
    @State private var loaded = false
    @State private var esse3: Esse3Status?
    @State private var reading = false
    @State private var editing: PasswordEditor.Mode?
    @State private var error: String?

    private var secure: Bool { Passwords.secure(settings.serverURL) }
    private var hasUnito: Bool { list.entries.contains { $0.sites.contains("unito.it") } }

    var body: some View {
        Form {
            if !secure {
                Section {
                    Label("Your server address starts with http, not https, so Aide won't send a password over it. "
                          + "`tailscale serve` gives the server an https address (Settings → Server).",
                          systemImage: "lock.slash")
                        .foregroundStyle(.orange)
                }
            }
            if loaded && list.locked {
                Section {
                    Text("The server has saved passwords but its key doesn't open them, so none are shown and none are used. Put the key back on the server (README, \"Passwords\"), or add them again.")
                        .foregroundStyle(.secondary)
                }
            } else if loaded && !list.enabled {
                Section {
                    Text("Passwords aren't on yet: the server has no key for them (README, \"Passwords\").")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if list.entries.isEmpty {
                    Text(loaded ? "None yet" : "Loading…").foregroundStyle(.secondary)
                }
                ForEach(list.entries) { entry in
                    Button { editing = .change(entry) } label: { PasswordRow(entry: entry) }
                        .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let gone = offsets.map { list.entries[$0] }
                    Task { await delete(gone) }
                }
                Button("Add a password") { editing = .add }
                    .disabled(!secure || !list.enabled || list.locked)
            } header: {
                Text("Saved")
            } footer: {
                Text("For Aide's own logins, like reading Esse3 with your UniTo account. They're encrypted on your server and given only to the site they're for, never to the agents. You can't see a password again here: to fix one, type it again.")
            }
            if hasUnito { esse3Section }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Passwords")
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { mode in
            PasswordEditor(mode: mode) { await load() }
        }
    }

    @ViewBuilder private var esse3Section: some View {
        Section {
            if let esse3 {
                if let problem = esse3.error {
                    Label(problem.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                LabeledContent("Read") {
                    Text(esse3.readAt.flatMap(Wire.parse).map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet")
                }
                if esse3.readAt != nil {
                    LabeledContent("Exam sessions", value: "\(esse3.exams.count)")
                    if esse3.credits.total > 0 {
                        LabeledContent("Credits", value: "\(Self.number(esse3.credits.passed)) of \(Self.number(esse3.credits.total))")
                    }
                    if let average = esse3.average {
                        LabeledContent("Average", value: average.formatted(.number.precision(.fractionLength(0...2))))
                    }
                }
            }
            Button {
                Task { await readEsse3() }
            } label: {
                HStack { Text("Read Esse3 now"); if reading { Spacer(); ProgressView() } }
            }
            .disabled(reading)
        } header: {
            Text("Esse3")
        } footer: {
            Text("With the UniTo login Aide reads your exam sessions, sign-ups and transcript four times a day. Read only: it never signs you up.")
        }
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func load() async {
        do {
            list = try await env.api.passwords()
            error = nil
        } catch APIError.server(404, _) {
            list = PasswordList() // an older server
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
        if hasUnito { esse3 = try? await env.api.esse3() }
    }

    private func readEsse3() async {
        reading = true
        defer { reading = false }
        do {
            esse3 = try await env.api.readEsse3()
            list = (try? await env.api.passwords()) ?? list // the entry's status may have moved
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ entries: [SavedPassword]) async {
        let names = entries.map(\.name).joined(separator: ", ")
        guard await Passwords.confirmOwner("Delete the password for \(names)") else {
            error = Passwords.notConfirmed
            await load() // the swiped row comes back
            return
        }
        for entry in entries {
            do {
                try await env.api.deletePassword(entry.id)
            } catch {
                self.error = error.localizedDescription
            }
        }
        await load()
    }
}

/// A saved login: name, username, sites, how it went last.
private struct PasswordRow: View {
    let entry: SavedPassword

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIcon(systemName: "key.fill", color: .gray)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.name).font(.body.weight(.medium))
                    Spacer()
                    if let status = Passwords.statusWord(entry.status) {
                        Text(status.word).font(.caption.weight(.semibold)).foregroundStyle(status.color)
                    }
                }
                Text(entry.username).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(usage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .multilineTextAlignment(.leading)
    }

    private var usage: String {
        let sites = entry.sites.joined(separator: ", ")
        guard let used = entry.usedAt.flatMap(Wire.parse) else { return "\(sites) · not used yet" }
        let when = used.formatted(.relative(presentation: .named))
        return entry.usedBy.map { "\(sites) · used by \($0) \(when)" } ?? "\(sites) · used \(when)"
    }
}

/// Adding a login, or changing one (a new password, the username, the name). The password lives only in this sheet's
/// state while it's typed, is cleared as soon as it's sent, and is never kept on the device.
struct PasswordEditor: View {
    enum Mode: Identifiable, Hashable {
        case add
        case change(SavedPassword)
        var id: String { if case .change(let e) = self { return e.id }; return "add" }
    }

    let mode: Mode
    let saved: () async -> Void
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var site = ""
    @State private var username = ""
    @State private var password = ""
    @State private var saving = false
    @State private var error: String?

    private var entry: SavedPassword? { if case .change(let e) = mode { return e }; return nil }

    var body: some View {
        NavigationStack {
            Form {
                if entry == nil {
                    Section {
                        Button("UniTo (Esse3, MyUniTo)") {
                            name = "UniTo"
                            site = "unito.it"
                        }
                        .disabled(name == "UniTo" && site == "unito.it")
                    } header: {
                        Text("Suggested")
                    }
                }
                Section {
                    TextField("Name", text: $name)
                    if let entry {
                        LabeledContent("Site", value: entry.sites.joined(separator: ", "))
                    } else {
                        TextField("Site, like unito.it", text: $site)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    if entry == nil {
                        Text("The server gives the password only to this site, over https. The site can't be changed later.")
                    }
                }
                Section {
                    TextField("Email or username", text: $username)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                    SecureField(entry == nil ? "Password" : "New password (empty: unchanged)", text: $password)
                        .textContentType(.password)
                        .privacySensitive()
                } footer: {
                    if let entry, let status = Passwords.statusWord(entry.status) {
                        Text(status.help)
                    } else if entry != nil {
                        Text("Aide can't show the saved password. Type a new one to replace it.")
                    }
                }
                if entry != nil {
                    Section {
                        Button("Delete", role: .destructive) { Task { await delete() } }
                    }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle(entry == nil ? "Add a password" : entry!.name)
            .navigationBarTitleDisplayMode(.inline)
            .macSheetTitle(entry == nil ? "Add a password" : entry!.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { close() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save") { Task { await save() } }.disabled(!canSave) }
                }
            }
            .onAppear {
                if let entry, name.isEmpty { name = entry.name; username = entry.username }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUser: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        guard Passwords.secure(settings.serverURL), !trimmedName.isEmpty, !trimmedUser.isEmpty else { return false }
        if let entry {
            return !password.isEmpty || trimmedName != entry.name || trimmedUser != entry.username
        }
        return !site.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }

    private func close() {
        password = ""
        dismiss()
    }

    private func save() async {
        guard canSave else { return }
        guard Passwords.secure(settings.serverURL) else { error = "The server address isn't https."; return }
        let what = entry.map { "Change the password for \($0.name)" } ?? "Save the password for \(trimmedName)"
        guard await Passwords.confirmOwner(what) else { error = Passwords.notConfirmed; return }
        saving = true
        defer { saving = false }
        do {
            if let entry {
                var change = PasswordChange()
                if trimmedName != entry.name { change.name = trimmedName }
                if trimmedUser != entry.username { change.username = trimmedUser }
                if !password.isEmpty { change.password = password }
                password = ""
                _ = try await env.api.changePassword(entry.id, change)
            } else {
                let body = NewPassword(name: trimmedName, sites: [site.trimmingCharacters(in: .whitespaces).lowercased()],
                                       username: trimmedUser, password: password)
                password = ""
                _ = try await env.api.addPassword(body)
            }
            await saved()
            dismiss()
        } catch {
            self.error = error.localizedDescription // the password is gone from the field: type it again
        }
    }

    private func delete() async {
        guard let entry else { return }
        guard await Passwords.confirmOwner("Delete the password for \(entry.name)") else {
            error = Passwords.notConfirmed
            return
        }
        do {
            try await env.api.deletePassword(entry.id)
            await saved()
            close()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum Passwords {
    static let notConfirmed = "Not done: Face ID or the passcode didn't confirm it's you."

    /// A password goes to the server only over https (`tailscale serve`'s tailnet-only certificate).
    static func secure(_ serverURL: String) -> Bool {
        URL(string: serverURL.trimmingCharacters(in: .whitespaces))?.scheme?.lowercased() == "https"
    }

    /// Face ID, Touch ID or the device's passcode. A device with no passcode can't confirm (the Simulator can).
    static func confirmOwner(_ reason: String) async -> Bool {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            #if targetEnvironment(simulator)
            return true
            #else
            return false
            #endif
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    static func statusWord(_ status: String) -> (word: String, color: Color, help: String)? {
        switch status {
        case "wrong": ("Wrong password", .red,
                       "The site said this password is wrong, so Aide stopped trying it (the account isn't locked). Type the right one.")
        case "needs_you": ("Needs you", .orange,
                           "The site asked for something Aide can't do, like a code or a new password. Log in once yourself, then Aide tries again.")
        case "unreadable": ("Can't be read", .red,
                            "The server can't decrypt its copy. Delete it and add it again.")
        default: nil
        }
    }
}
