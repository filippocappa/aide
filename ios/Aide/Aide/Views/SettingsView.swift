import AppIntents
import SwiftUI

/// Settings, laid out like the iPhone's own: Aide's connection on top, then a short list where each row says how
/// things stand and opens a page of its own.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sync: ReminderSyncService
    @EnvironmentObject private var push: PushService
    @EnvironmentObject private var health: HealthService
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var connection = ConnectionCheck()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { ConnectionSettingsView(connection: connection) } label: { ConnectionHeader(connection: connection) }
                }
                Section("Aide") {
                    row("Digests", "sun.horizon.fill", .orange) { DigestSettingsView() }
                    row("Memory", "brain.head.profile", .pink) { MemoryView() }
                    row("Voice", "waveform", .purple, value: settings.voiceLanguage == "it-IT" ? "Italiano" : "English") {
                        VoiceSettingsView()
                    }
                    row("Claude plan", "sparkles", Color(red: 0.85, green: 0.47, blue: 0.34)) { NotesWriterView() }
                }
                Section("This iPhone") {
                    row("Notifications", "bell.badge.fill", .red, value: notificationsValue, off: push.authorization != .authorized && push.authorization != .provisional) {
                        NotificationSettingsView()
                    }
                    row("Reminders", "checklist", .blue, value: remindersValue, off: !sync.hasAccess) { ReminderSettingsView() }
                    row("Apple Health", "heart.fill", .pink, value: healthValue, off: health.isAvailable && !health.hasAsked) {
                        HealthSettingsView()
                    }
                    row("Location and trams", "tram.fill", .green, value: locationValue, off: !location.isOn) { LocationSettingsView() }
                }
                Section {
                    row("Moodle", "graduationcap.fill", .orange) { MoodleView() }
                    row("Obsidian", "doc.richtext.fill", .indigo) { ObsidianView() }
                } header: {
                    Text("Study")
                }
                Section {
                } footer: {
                    Text("Aide \(Self.version) · built \(Self.buildTime)")
                        .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.grouped)
            .navigationTitle("Settings")
            .task(id: settings.serverURL + settings.token) {
                if connection.state != .unset { try? await Task.sleep(for: .milliseconds(700)) } // typing
                guard !Task.isCancelled else { return }
                await connection.check(env.api, configured: settings.isConfigured)
            }
            .task { await health.refreshStatus() }
        }
    }

    private func row<Destination: View>(_ title: String, _ icon: String, _ color: Color, value: String? = nil, off: Bool = false,
                                        @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            LabeledContent {
                if let value { Text(value).foregroundStyle(off ? Color.orange : .secondary) }
            } label: {
                Label { Text(title) } icon: { SettingsIcon(systemName: icon, color: color) }
            }
        }
    }

    private var notificationsValue: String {
        switch push.authorization {
        case .notDetermined: "Not set up"
        case .denied: "Off"
        default: "On"
        }
    }

    private var remindersValue: String {
        if sync.hasAccess { return sync.lists.first { $0.id == settings.reminderListID }?.title ?? "On" }
        return sync.authorization == .notDetermined ? "Not set up" : "Off"
    }

    private var healthValue: String? {
        if !health.isAvailable { return nil }
        if !health.hasAsked { return "Not set up" }
        return "On"
    }

    private var locationValue: String {
        switch location.authorization {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While using"
        case .notDetermined: "Not set up"
        default: "Off"
        }
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    /// When this binary was linked, to tell a fresh build from an old install.
    static var buildTime: String {
        guard let path = Bundle.main.executablePath,
              let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return "–" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The coloured rounded square in front of a settings row, as in the iPhone's Settings.
private struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Opens iOS Settings at Aide's page, where a permission turned off can be turned back on.
private struct OpenSettingsButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open iOS Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
    }
}

private struct ErrorRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
    }
}

/// A button with a spinner beside its title while it works.
private struct BusyButton: View {
    let title: String
    let busy: Bool
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack {
                Text(title)
                if busy { Spacer(); ProgressView() }
            }
        }
        .disabled(busy)
    }
}

// MARK: Connection

/// Whether the server answers with this URL and token. Checked when Settings opens and when either changes.
@MainActor
final class ConnectionCheck: ObservableObject {
    enum State: Equatable { case unset, checking, connected(version: String), failed(String) }
    @Published private(set) var state = State.unset

    func check(_ api: APIClient, configured: Bool) async {
        guard configured else { state = .unset; return }
        if case .connected = state {} else { state = .checking }
        do {
            let health = try await api.health()
            _ = try await api.history(limit: 1) // health needs no token, this one does
            state = .connected(version: health.version)
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private struct ConnectionHeader: View {
    @ObservedObject var connection: ConnectionCheck
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 14) {
            LivePebble(mood: mood, size: 54)
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text("Aide").font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 8, height: 8)
                    Text(status).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var host: String { URL(string: settings.serverURL)?.host()?.components(separatedBy: ".").first ?? "the server" }

    private var mood: String {
        switch connection.state {
        case .connected: "happy"
        case .checking: "thinking"
        case .unset, .failed: "sleeping"
        }
    }

    private var dot: Color {
        switch connection.state {
        case .connected: Theme.toggle
        case .checking: .secondary
        case .unset: .orange
        case .failed: .red
        }
    }

    private var status: String {
        switch connection.state {
        case .unset: "Not set up: add the server and token"
        case .checking: "Connecting…"
        case .connected: "Connected to \(host)"
        case .failed: "Can't reach \(host)"
        }
    }
}

private struct ConnectionSettingsView: View {
    @ObservedObject var connection: ConnectionCheck
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    switch connection.state {
                    case .unset: Text("Not set up")
                    case .checking: ProgressView()
                    case .connected(let version): Text("Connected, server \(version)").foregroundStyle(Theme.toggle)
                    case .failed: Text("Not connected").foregroundStyle(.red)
                    }
                }
                if case .failed(let text) = connection.state { ErrorRow(text: text) }
                BusyButton(title: "Check again", busy: connection.state == .checking) {
                    await connection.check(env.api, configured: settings.isConfigured)
                }
                .disabled(!settings.isConfigured)
            }
            Section {
                TextField("https://cappa.….ts.net", text: $settings.serverURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Server address")
            } footer: {
                Text("Aide runs on your computer and is reached over Tailscale, so keep the Tailscale app on.")
            }
            Section {
                SecureField("Token", text: $settings.token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("API token")
            } footer: {
                Text("AIDE_API_TOKEN from the server's .env. Kept in the Keychain.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Voice

private struct VoiceSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("I speak", selection: $settings.voiceLanguage) {
                    Text("English").tag("en-US")
                    Text("Italiano").tag("it-IT")
                }
            } footer: {
                Text("For the live preview of your words. Aide understands both, even mixed.")
            }
            Section {
                Toggle("Read replies aloud", isOn: $settings.speakReplies).tint(Theme.toggle)
            } footer: {
                Text("Tap the microphone in a chat to talk. Aide answers out loud and keeps listening until you tap stop.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Notifications

private struct NotificationSettingsView: View {
    @EnvironmentObject private var push: PushService
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        Form {
            Section {
                switch push.authorization {
                case .denied:
                    LabeledContent("Notifications", value: "Off")
                    OpenSettingsButton()
                case .notDetermined:
                    Button("Allow notifications") { Task { await push.refresh() } }
                default:
                    LabeledContent("Notifications", value: "On")
                    LabeledContent("This iPhone", value: push.isRegistered ? "Registered" : "Not registered")
                }
                if let error = push.lastError { ErrorRow(text: error) }
            } footer: {
                Text("Digests, notes from the team's watches and routines, tram alerts, and reminders that haven't reached Apple Reminders yet.")
            }
            if push.authorization == .authorized || push.authorization == .provisional {
                Section {
                    BusyButton(title: "Send a test notification", busy: testing) {
                        testing = true
                        result = await push.sendTest()
                        testing = false
                    }
                    .disabled(!push.isRegistered)
                    if let result {
                        Label(result.text, systemImage: result.ok ? "checkmark.circle" : "xmark.octagon")
                            .foregroundStyle(result.ok ? Color.green : Color.red)
                            .font(.footnote)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: Reminders

private struct ReminderSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sync: ReminderSyncService

    var body: some View {
        Form {
            if sync.hasAccess {
                Section {
                    Picker("New reminders go to", selection: $settings.reminderListID) {
                        Text("Default list").tag("")
                        ForEach(sync.lists) { Text($0.title).tag($0.id) }
                    }
                } footer: {
                    Text("Aide and the team see every list and can add to any of them (\"milk to Groceries\"). A reminder without a list goes here.")
                }
                Section {
                    BusyButton(title: "Sync now", busy: sync.isSyncing) { await sync.sync() }
                        .disabled(!settings.isConfigured)
                    if let last = sync.lastSync {
                        LabeledContent("Last sync", value: last.formatted(date: .omitted, time: .shortened))
                    }
                    if let error = sync.lastError { ErrorRow(text: error) }
                } footer: {
                    Text("Each reminder gets an alarm at its due time, so the iPhone notifies you even with Aide closed.")
                }
            } else {
                Section {
                    if sync.authorization == .notDetermined {
                        Button("Allow access to Reminders") { Task { await sync.requestAccess() } }
                    } else {
                        LabeledContent("Access", value: "Off")
                        OpenSettingsButton()
                    }
                } footer: {
                    Text("Aide keeps your reminders in Apple Reminders, so they show up everywhere and ring on time.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings.reminderListID) { _, _ in Task { await sync.sync() } }
    }
}

// MARK: Apple Health

private struct HealthSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var health: HealthService

    var body: some View {
        Form {
            if !health.isAvailable {
                Section { Text("Apple Health isn't available on this device.").foregroundStyle(.secondary) }
            } else if !health.hasAsked {
                Section {
                    Button("Allow Apple Health") { Task { await health.requestAccess() } }
                } footer: {
                    Text("Aide gets one summary a day: sleep, heart rate, HRV, steps and workouts.")
                }
            } else {
                Section {
                    LabeledContent("Last sent", value: health.lastUpload?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
                    BusyButton(title: "Send now", busy: health.isUploading) { await health.upload() }
                        .disabled(!settings.isConfigured)
                    if let error = health.lastError { ErrorRow(text: error) }
                } footer: {
                    Text("One summary a day: sleep, heart rate, HRV, steps and workouts. What Aide may read is in the Health app, Sharing → Apps.")
                }
                Section {
                    step(1, "Open Shortcuts → Automation → New → Sleep → Waking Up.")
                    step(2, "Choose Run Immediately.")
                    step(3, "Add Aide's \"I'm up\".")
                    ShortcutsLink()
                } header: {
                    Text("Wake-up briefing")
                } footer: {
                    Text("Without it, the briefing comes with the first health upload of the morning.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .task { await health.refreshStatus() }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.subheadline)
        }
    }
}

// MARK: Location and trams

private struct LocationSettingsView: View {
    @EnvironmentObject private var location: LocationService

    var body: some View {
        Form {
            Section {
                LabeledContent("Location", value: access)
                if location.canAsk {
                    Button(location.authorization == .notDetermined ? "Share location" : "Allow always") {
                        location.requestAccess()
                    }
                } else if !location.isAlways {
                    OpenSettingsButton()
                }
                if location.isOn {
                    LabeledContent("Last sent", value: location.lastSent?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
                }
                if let error = location.lastError { ErrorRow(text: error) }
            } footer: {
                Text("With Always, the iPhone sends where it is when you move about 500 m or a tram alert is about to fire, also with Aide closed.")
            }
            Section {
                NavigationLink("Tram alerts") { TransitAlertsView() }
            } footer: {
                Text("When to leave for your GTT tram: the walk from where you are to the stop, plus two minutes.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Location and trams")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var access: String {
        switch location.authorization {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While using the app"
        case .notDetermined: "Not shared"
        default: "Off"
        }
    }
}
