import AuthenticationServices
import SwiftUI

/// The university's Moodle (docs/API.md, "Moodle"): logging in through its own page, and which Aide course each
/// Moodle course's PDFs go to.
struct MoodleView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var status: MoodleStatus?
    @State private var courses: [StudyCourse] = []
    @State private var error: String?
    @State private var busy = false
    @State private var syncing = false
    @State private var confirmLogout = false
    @State private var webLogin = WebLogin()

    var body: some View {
        Form {
            if let status {
                if !status.enabled {
                    Section {
                        Text("Moodle isn't set up on the server.").foregroundStyle(.secondary)
                    } footer: {
                        Text("Add AIDE_MOODLE_URL to the server's .env (README, \"Moodle\").")
                    }
                } else if !status.connected {
                    loginSection(status)
                } else {
                    accountSection(status)
                    coursesSection(status)
                }
            } else if error == nil {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Moodle")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Log out of Moodle?", isPresented: $confirmLogout, titleVisibility: .visible) {
            Button("Log out", role: .destructive) { Task { await logout() } }
        } message: {
            Text("New files stop coming. The ones already in Aide stay.")
        }
    }

    private func loginSection(_ status: MoodleStatus) -> some View {
        Section {
            Button {
                Task { await logIn() }
            } label: {
                HStack {
                    Text("Log in to Moodle")
                    if busy { Spacer(); ProgressView() }
                }
            }
            .disabled(busy)
            if let site = status.site.flatMap(URL.init(string:))?.host() {
                LabeledContent("Site", value: site)
            }
        } footer: {
            Text("You log in on the university's own page, so your password stays with you. Aide keeps only Moodle's key for your account, on your server, and brings the PDFs of your courses every 4 hours.")
        }
    }

    @ViewBuilder
    private func accountSection(_ status: MoodleStatus) -> some View {
        Section {
            LabeledContent("Logged in as", value: status.user ?? "–")
            LabeledContent("Last sync", value: status.lastSync.flatMap(Wire.parse)?
                .formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
            if let problem = status.error {
                Label(problem.prefix(1).uppercased() + problem.dropFirst(), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.footnote)
                Button("Log in again") { Task { await logIn() } }.disabled(busy)
            }
            Button {
                Task { await syncNow() }
            } label: {
                HStack {
                    Text("Sync now")
                    if syncing { Spacer(); ProgressView() }
                }
            }
            .disabled(syncing)
            Button("Log out", role: .destructive) { confirmLogout = true }
        } header: {
            Text("Account")
        }
    }

    private func coursesSection(_ status: MoodleStatus) -> some View {
        Section {
            if status.courses.isEmpty {
                Text(status.lastSync == nil ? "Your courses show up after the first sync." : "No current courses on Moodle.")
                    .foregroundStyle(.secondary)
            }
            ForEach(status.courses) { course in
                Picker(selection: matchBinding(course)) {
                    Text("Don't sync").tag(Int?.none)
                    ForEach(courses) { Text($0.name).tag(Optional($0.id)) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(course.name)
                        Text(detail(course)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Courses")
        } footer: {
            Text("Only courses matched to one of yours are synced. Aide matches a course by itself when the names agree; pick the others here. A file you delete in Aide doesn't come back.")
        }
    }

    private func detail(_ course: MoodleCourse) -> String {
        guard course.course != nil else { return "Not synced" }
        let files = course.files ?? 0
        let count = files == 1 ? "1 file" : "\(files) files"
        return course.matched == "auto" ? "\(count) · matched by name" : count
    }

    private func matchBinding(_ course: MoodleCourse) -> Binding<Int?> {
        Binding(get: { course.course }, set: { new in
            Task { await match(course, to: new) }
        })
    }

    // MARK: Actions

    private func load() async {
        do {
            let loaded = try await env.api.moodle()
            status = loaded
            if loaded.connected, let study = try? await env.api.study() { courses = study.courses }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func logIn() async {
        busy = true
        defer { busy = false }
        do {
            let login = try await env.api.moodleLogin()
            guard let url = URL(string: login.url) else { throw APIError.badResponse }
            let callback = try await webLogin.start(url, scheme: login.scheme)
            status = try await env.api.moodleConnect(callback.absoluteString)
            error = nil
            if let study = try? await env.api.study() { courses = study.courses }
            await waitForSync(after: nil)
        } catch let cancelled as ASWebAuthenticationSessionError where cancelled.code == .canceledLogin {
            // Closed the sheet.
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func syncNow() async {
        syncing = true
        defer { syncing = false }
        do {
            let before = status?.lastSync
            status = try await env.api.moodleSync()
            await waitForSync(after: before)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Polls until `lastSync` moves on from `after`, for up to two minutes.
    private func waitForSync(after: String?) async {
        syncing = true
        defer { syncing = false }
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(2))
            guard let new = try? await env.api.moodle() else { continue }
            status = new
            if new.lastSync != nil && new.lastSync != after { return }
        }
    }

    private func match(_ course: MoodleCourse, to aideCourse: Int?) async {
        do {
            let updated = try await env.api.matchMoodleCourse(course.id, course: aideCourse)
            if let i = status?.courses.firstIndex(where: { $0.id == course.id }) { status?.courses[i] = updated }
            error = nil
            if aideCourse != nil { await waitForSync(after: status?.lastSync) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func logout() async {
        do {
            status = try await env.api.moodleLogout()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A login page in a browser sheet that returns the address it ends on (`ASWebAuthenticationSession`). It shares
/// Safari's cookies, so a recent university login skips the password.
@MainActor
final class WebLogin: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func start(_ url: URL, scheme: String) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume(throwing: APIError.transport("The login page couldn't open."))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}

/// What to type into Obsidian's Remotely Save plugin to sync the vault (docs/API.md, "Obsidian vault").
struct ObsidianView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var setup: VaultSetup?
    @State private var error: String?
    @State private var showPassword = false
    @State private var copied: String?

    var body: some View {
        Form {
            if let setup {
                if setup.enabled {
                    Section {
                        copyRow("Vault name", setup.vault)
                        copyRow("Server address", setup.url)
                        copyRow("Username", setup.user)
                        copyRow("Password", setup.password, secret: true)
                    } header: {
                        Text("Remotely Save, WebDAV")
                    } footer: {
                        Text(copied.map { "\($0) copied." } ?? "Tap a line to copy it.")
                    }
                    Section("Setting up Obsidian") {
                        step(1, "Install Obsidian and create a vault named \(setup.vault ?? "Uni").")
                        step(2, "Settings → Community plugins → turn them on → Browse → Remotely Save → Install → Enable.")
                        step(3, "Remotely Save's settings: remote service WebDAV; the address, username and password above; auth type basic. Check the connection.")
                        step(4, "Turn on sync at start and every few minutes. Tailscale must be on.")
                    }
                } else {
                    Section {
                        Text("The vault isn't set up on the server.").foregroundStyle(.secondary)
                    } footer: {
                        Text("See the README, \"Obsidian\".")
                    }
                }
            } else if error == nil {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Obsidian")
        .task {
            do {
                setup = try await env.api.vault()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func copyRow(_ label: String, _ value: String?, secret: Bool = false) -> some View {
        Button {
            guard let value else { return }
            // The password stays on this phone and leaves the clipboard after a few minutes.
            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: value]], options: secret
                ? [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)] : [:])
            copied = label
        } label: {
            LabeledContent(label) {
                Text(secret && !showPassword ? String(repeating: "•", count: 10) : value ?? "–")
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .tint(.primary)
        .swipeActions {
            if secret { Button(showPassword ? "Hide" : "Show") { showPassword.toggle() } }
        }
        .contextMenu {
            if secret { Button(showPassword ? "Hide" : "Show") { showPassword.toggle() } }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.subheadline)
        }
    }
}
