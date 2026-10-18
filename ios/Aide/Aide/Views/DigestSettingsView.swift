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
                Section {
                    Toggle("Morning", isOn: binding.daily.enabled)
                    TimeRow(time: binding.daily.time)
                } header: {
                    Text("Start of the day")
                } footer: {
                    Text("Today's calendar, reminders, unread mail and habits.")
                }
                if binding.wrappedValue.evening != nil {
                    Section {
                        Toggle("Evening", isOn: Binding(get: { binding.wrappedValue.evening?.enabled ?? false },
                                                        set: { binding.wrappedValue.evening?.enabled = $0 }))
                        TimeRow(time: Binding(get: { binding.wrappedValue.evening?.time ?? "22:00" },
                                              set: { binding.wrappedValue.evening?.time = $0 }))
                    } header: {
                        Text("Before bed")
                    } footer: {
                        Text("Tomorrow's calendar, what's still open today, and habits you haven't ticked.")
                    }
                }
                Section("Every week") {
                    Toggle("Weekly digest", isOn: binding.weekly.enabled)
                    Picker("Day", selection: Binding(get: { binding.wrappedValue.weekly.weekday ?? 7 },
                                                     set: { binding.wrappedValue.weekly.weekday = $0 })) {
                        ForEach(1...7, id: \.self) { Text(Self.weekdays[$0 - 1]).tag($0) }
                    }
                    TimeRow(time: binding.weekly.time)
                }
                Section("Every month") {
                    Toggle("Monthly digest", isOn: binding.monthly.enabled)
                    Stepper("Day \(binding.wrappedValue.monthly.day ?? 1)",
                            value: Binding(get: { binding.wrappedValue.monthly.day ?? 1 },
                                           set: { binding.wrappedValue.monthly.day = $0 }), in: 1...31)
                    TimeRow(time: binding.monthly.time)
                }
                Section {
                    Toggle("Also send to Discord", isOn: binding.discord)
                } footer: {
                    Text("Day 29 to 31 means the last day of shorter months.")
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
