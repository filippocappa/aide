import SwiftUI

/// GTT tram alerts (docs/API.md, "Transit (GTT)"): made in chat, listed, changed and deleted here.
struct TransitAlertsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var alerts: [TransitAlert] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote) }
            }
            Section {
                if alerts.isEmpty && loaded {
                    Text("No alerts yet.").foregroundStyle(.secondary)
                }
                ForEach($alerts) { $alert in
                    NavigationLink {
                        TransitAlertEditor(alert: alert) { changed in
                            if let changed {
                                alert = changed
                            } else {
                                alerts.removeAll { $0.id == alert.id }
                            }
                        }
                    } label: {
                        TransitAlertRow(alert: alert) { on in Task { await setEnabled(alert, on) } }
                    }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { alerts[$0] }
                    Task { for alert in doomed { await remove(alert) } }
                }
            } footer: {
                Text("Ask in chat to add one: \"every weekday, tell me when to leave for the 4 at Porta Nuova around 8:10\", "
                     + "or \"let me know when the next 15 is 10 minutes away\". A one-off goes once it has fired.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle("Tram alerts")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            alerts = try await env.api.transitAlerts()
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
        loaded = true
    }

    private func setEnabled(_ alert: TransitAlert, _ on: Bool) async {
        guard let i = alerts.firstIndex(where: { $0.id == alert.id }) else { return }
        alerts[i].enabled = on
        do {
            let changed = try await env.api.updateTransitAlert(alert.id, TransitAlertPatch(enabled: on))
            if let i = alerts.firstIndex(where: { $0.id == alert.id }) { alerts[i] = changed }
        } catch {
            if let i = alerts.firstIndex(where: { $0.id == alert.id }) { alerts[i].enabled = !on }
            self.error = Self.describe(error)
        }
    }

    private func remove(_ alert: TransitAlert) async {
        do {
            try await env.api.deleteTransitAlert(alert.id)
            alerts.removeAll { $0.id == alert.id }
        } catch {
            self.error = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        if case APIError.server(404, _) = error { return "The server doesn't have tram alerts (or the alert is gone)." }
        return error.localizedDescription
    }
}

/// Line and direction, the stop, when, and a switch.
private struct TransitAlertRow: View {
    let alert: TransitAlert
    let setEnabled: (Bool) -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                Text(alert.stopLabel).font(.subheadline).foregroundStyle(.secondary)
                Text("\(alert.when) · \(alert.lead)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(alert.title, isOn: Binding(get: { alert.enabled }, set: setEnabled))
                .labelsHidden()
                .tint(Theme.toggle)
        }
        .opacity(alert.enabled ? 1 : 0.6)
    }
}

/// Change an alert's time, days and how early it comes, or delete it. The stop and line are changed in chat.
private struct TransitAlertEditor: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let alert: TransitAlert
    /// The saved alert, or nil once deleted.
    let done: (TransitAlert?) -> Void

    @State private var time: Date
    @State private var days: Set<Int>
    /// nil: when it's time to leave.
    @State private var minutes: Int?
    @State private var enabled: Bool
    @State private var isBusy = false
    @State private var error: String?

    static let choices = [3, 5, 8, 10, 15, 20, 30]

    init(alert: TransitAlert, done: @escaping (TransitAlert?) -> Void) {
        self.alert = alert
        self.done = done
        _time = State(initialValue: RoutineEditor.date(from: alert.time ?? "08:00"))
        _days = State(initialValue: Set(alert.days ?? []))
        _minutes = State(initialValue: alert.minutes)
        _enabled = State(initialValue: alert.enabled)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Stop", value: alert.stopLabel)
                if !alert.towards.isEmpty {
                    LabeledContent("Towards", value: alert.towards.joined(separator: " / "))
                }
            }
            .listRowBackground(Theme.row)
            Section {
                if alert.time != nil {
                    DatePicker("Around", selection: $time, displayedComponents: .hourAndMinute)
                }
                if !alert.once {
                    DayPicker(days: $days, tint: Theme.accent)
                }
                Picker("Alert", selection: $minutes) {
                    Text("When it's time to leave").tag(Int?.none)
                    ForEach(Self.choices + (alert.minutes.map { Self.choices.contains($0) ? [] : [$0] } ?? []),
                            id: \.self) { Text("\($0) min before").tag(Int?.some($0)) }
                }
                Toggle("On", isOn: $enabled).tint(Theme.toggle)
            } footer: {
                Text(minutes == nil
                     ? "When the \(alert.vehicle.lowercased()) is as far away as your walk to the stop, plus two minutes. "
                        + "The walk is from where your phone is (Settings → Location)."
                     : "When the \(alert.vehicle.lowercased()) is \(minutes!) minutes from the stop, live from GTT.")
            }
            .listRowBackground(Theme.row)
            Section {
                Button("Delete alert", role: .destructive) { Task { await delete() } }
            }
            .listRowBackground(Theme.row)
            .disabled(isBusy)
            if let error {
                Text(error).foregroundStyle(.red).listRowBackground(Theme.row)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.grouped)
        .navigationTitle(alert.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isBusy { ProgressView() } else { Button("Save") { Task { await save() } } }
            }
        }
    }

    private func save() async {
        isBusy = true
        defer { isBusy = false }
        var patch = TransitAlertPatch(enabled: enabled)
        if alert.time != nil { patch.time = RoutineEditor.string(from: time) }
        if !alert.once { patch.days = days.sorted() }
        if minutes != alert.minutes { patch.minutes = .some(minutes) }
        do {
            done(try await env.api.updateTransitAlert(alert.id, patch))
            dismiss()
        } catch {
            self.error = TransitAlertsView.describe(error)
        }
    }

    private func delete() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await env.api.deleteTransitAlert(alert.id)
            done(nil)
            dismiss()
        } catch {
            self.error = TransitAlertsView.describe(error)
        }
    }
}
