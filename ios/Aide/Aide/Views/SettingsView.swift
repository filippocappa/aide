import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sync: ReminderSyncService
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var push: PushService
    @Environment(\.openURL) private var openURL

    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var pushTesting = false
    @State private var pushResult: (ok: Bool, text: String)?

    var body: some View {
        NavigationStack {
            Form {
                serverSection
                remindersSection
                notificationsSection
                Section {
                    Picker("I speak", selection: $settings.voiceLanguage) {
                        Text("English").tag("en-US")
                        Text("Italiano").tag("it-IT")
                    }
                    Toggle("Read replies aloud", isOn: $settings.speakReplies)
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Tap the microphone in a chat to talk. Aide answers out loud and keeps listening until you tap stop.")
                }
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

    @ViewBuilder
    private var notificationsSection: some View {
        Section {
            switch push.authorization {
            case .denied:
                Text("Notifications are off for Aide.").foregroundStyle(.secondary)
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            case .notDetermined:
                Button("Allow notifications") { Task { await push.refresh() } }
            default:
                LabeledContent("This device", value: push.isRegistered ? "Registered" : "Not registered")
                Button {
                    Task {
                        pushTesting = true
                        pushResult = await push.sendTest()
                        pushTesting = false
                    }
                } label: {
                    HStack {
                        Text("Send a test notification")
                        if pushTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(pushTesting || !push.isRegistered)
                if let pushResult {
                    Label(pushResult.text, systemImage: pushResult.ok ? "checkmark.circle" : "xmark.octagon")
                        .foregroundStyle(pushResult.ok ? Color.green : Color.red)
                        .font(.footnote)
                }
            }
            if let error = push.lastError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Aide sends digests and reminders that haven't reached Apple Reminders yet, and quietly syncs reminders in the background. Without push, they go to Discord.")
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
