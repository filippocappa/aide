import SwiftUI

/// When the digests run (server zone). Changes save as you make them.
struct DigestSettingsView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var settings: DigestSettings?
    @State private var error: String?

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        Form {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
            if let binding = Binding($settings) {
                // One list, details only for the ones that are on.
                Section {
                    DigestRow(title: "Morning", detail: "Your day ahead", isOn: binding.daily.enabled) {
                        TimeRow(time: binding.daily.time)
                    }
                    if binding.wrappedValue.evening != nil {
                        DigestRow(title: "Evening", detail: "Tomorrow, and what's still open",
                                  isOn: Binding(get: { binding.wrappedValue.evening?.enabled ?? false },
                                                set: { binding.wrappedValue.evening?.enabled = $0 })) {
                            TimeRow(time: Binding(get: { binding.wrappedValue.evening?.time ?? "22:00" },
                                                  set: { binding.wrappedValue.evening?.time = $0 }))
                        }
                    }
                    DigestRow(title: "Weekly", detail: "The week ahead", isOn: binding.weekly.enabled) {
                        Picker("Day", selection: Binding(get: { binding.wrappedValue.weekly.weekday ?? 7 },
                                                         set: { binding.wrappedValue.weekly.weekday = $0 })) {
                            ForEach(1...7, id: \.self) { Text(Self.weekdays[$0 - 1]).tag($0) }
                        }
                        TimeRow(time: binding.weekly.time)
                    }
                    DigestRow(title: "Monthly", detail: "The month ahead", isOn: binding.monthly.enabled) {
                        let day = binding.wrappedValue.monthly.day ?? 1
                        // 29 to 31 means the last day of shorter months.
                        Stepper(day > 28 ? "Day \(day) or the last" : "Day \(day)",
                                value: Binding(get: { day }, set: { binding.wrappedValue.monthly.day = $0 }), in: 1...31)
                        TimeRow(time: binding.monthly.time)
                    }
                }
                Section {
                    Toggle("Also send to Discord", isOn: binding.discord)
                }
            } else if error == nil {
                ProgressView()
            }
        }
        .scrollContentBackground(.hidden)
        .tint(Theme.toggle)
        .background(Theme.background)
        .navigationTitle("Digests")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: settings) { old, new in
            guard old != nil, let new else { return } // the first load isn't an edit
            Task { await save(new) }
        }
    }

    private func load() async {
        do { settings = try await env.api.digestSettings(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func save(_ new: DigestSettings) async {
        do { _ = try await env.api.saveDigestSettings(new); error = nil } catch { self.error = error.localizedDescription }
    }
}

/// A digest's switch, with its schedule rows underneath while it's on.
private struct DigestRow<Details: View>: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    @ViewBuilder let details: () -> Details

    var body: some View {
        Toggle(isOn: $isOn.animation()) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        if isOn { details() }
    }
}

private struct TimeRow: View {
    @Binding var time: String

    var body: some View {
        DatePicker("Time", selection: Binding(
            get: {
                let parts = time.split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(bySettingHour: parts.first ?? 8, minute: parts.count > 1 ? parts[1] : 0,
                                             second: 0, of: Date()) ?? Date()
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                time = String(format: "%02d:%02d", c.hour ?? 8, c.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
    }
}
