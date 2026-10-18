import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sync: ReminderSyncService
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.openURL) private var openURL

    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                remindersSection
                Section {
                    NavigationLink("Digests") { DigestSettingsView() }
                    NavigationLink("What Aide remembers") { MemoryView() }
                }
                Section("About") {
                    LabeledContent("Built", value: Self.buildTime)
                    LabeledContent("App version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                }
            }
            .scrollContentBackground(.hidden)
            .tint(Theme.toggle)
            .background(Theme.background)
            .navigationTitle("Settings")
            .onChange(of: settings.reminderListID) { _, _ in Task { await sync.sync() } }
        }
    }

    /// When this binary was linked, to tell a fresh build from an old install.
    private static var buildTime: String {
        guard let path = Bundle.main.executablePath,
              let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return "–" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private var serverSection: some View {
        Section {
            TextField("Server URL", text: $settings.serverURL)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("API token", text: $settings.token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("Test connection")
                    if testing { Spacer(); ProgressView() }
                }
            }
            .disabled(testing || !settings.isConfigured)
            if let testResult {
                Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(testResult.ok ? Color.green : Color.red)
                    .font(.footnote)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Reached over Tailscale, so the Tailscale app must be on. The token is kept in the Keychain.")
        }
    }

    @ViewBuilder
    private var remindersSection: some View {
        Section {
            if sync.hasAccess {
                Picker("List", selection: $settings.reminderListID) {
                    Text("Default list").tag("")
                    ForEach(sync.lists) { Text($0.title).tag($0.id) }
                }
                Button {
                    Task { await env.sync.sync() }
                } label: {
                    HStack {
                        Text("Sync now")
                        if sync.isSyncing { Spacer(); ProgressView() }
                    }
                }
                .disabled(sync.isSyncing || !settings.isConfigured)
                if let last = sync.lastSync {
                    LabeledContent("Last sync", value: last.formatted(date: .omitted, time: .shortened))
                }
            } else if sync.authorization == .notDetermined {
                Button("Allow access to Reminders") { Task { await sync.requestAccess() } }
            } else {
                Text("Reminders access is off.").foregroundStyle(.secondary)
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            if let error = sync.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
        } header: {
            Text("Apple Reminders")
        } footer: {
            Text("Aide mirrors its reminders into this one list, and Apple notifies you at the due time. Other lists stay private.")
        }
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            let health = try await env.api.health()
            _ = try await env.api.history(limit: 1) // health needs no token, this one does
            testResult = (true, "Connected. Server \(health.version).")
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }
}
