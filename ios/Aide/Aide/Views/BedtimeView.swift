import SwiftUI

/// Settings → Bedtime (docs/API.md, "Apple Health", "Bedtime"): tonight's plan on top, then the wake times (learnt
/// or set), getting ready, the reminder, the wind-down lock, and the last nights against their plans.
struct BedtimeView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var overview: BedtimeOverview?
    @State private var settings: BedtimeSettings?
    @State private var error: String?

    var body: some View {
        Form {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
            }
            if let binding = Binding($settings) {
                if binding.wrappedValue.enabled, let plan = overview?.tonight {
                    Section { BedtimeCard(plan: plan) } header: { Text("Tonight") }
                }
                Section {
                    Toggle("Bedtime plan", isOn: binding.enabled)
                } footer: {
                    Text("Waking at about the same time every day matters as much as the hours. Aide keeps the wake "
                         + "time steady and works the bedtime back from it: your sleep need, the time you're usually "
                         + "awake in the night, and 15 minutes to fall asleep.")
                }
                if binding.wrappedValue.enabled {
                    Section {
                        WakeRow(title: "Weekdays", time: binding.wakeWeekdays, learnt: overview?.usual?.weekdays)
                        WakeRow(title: "Weekends", time: binding.wakeWeekends, learnt: overview?.usual?.weekends)
                    } header: {
                        Text("Wake up")
                    } footer: {
                        Text("Learnt from the last four weeks of mornings unless you set it. An early start moves it "
                             + "earlier only when it has to, never later.")
                    }
                    Section {
                        Stepper(value: binding.readyMin, in: 0...180, step: 5) {
                            LabeledContent("Getting ready", value: "\(binding.wrappedValue.readyMin) min")
                        }
                        Stepper(value: binding.leadMin, in: 0...180, step: 5) {
                            LabeledContent("Remind me", value: "\(binding.wrappedValue.leadMin) min before")
                        }
                    } footer: {
                        Text("Getting ready: from waking to leaving, for a morning with an early event. The reminder "
                             + "is a countdown on the Lock Screen, or a notification.")
                    }
                    Section {
                        Toggle("Lock apps at bedtime", isOn: binding.windDown)
                    } footer: {
                        Text("A Screen Time lock from the bedtime to the wake time, with the apps your locks cover. "
                             + "The Mac holds it too.")
                    }
                    if let nights = overview?.nights, !nights.isEmpty {
                        Section("Last nights") {
                            ForEach(nights) { BedtimeNightRow(night: $0) }
                        }
                    }
                }
            } else if error == nil {
                ProgressView()
            }
        }
        .scrollContentBackground(.hidden)
        .tint(Theme.toggle)
        .background(Theme.grouped)
        .navigationTitle("Bedtime")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: settings) { old, new in
            guard old != nil, let new, new != overview?.settings else { return } // the first load isn't an edit
            Task { await save(new) }
        }
    }

    private func load() async {
        do {
            let o = try await env.api.bedtime()
            overview = o; settings = o.settings; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func save(_ new: BedtimeSettings) async {
        do {
            var o = try await env.api.saveBedtimeSettings(new)
            if o.nights == nil { o.nights = overview?.nights }
            overview = o; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

/// "Learnt (7:15)" or a time of its own.
private struct WakeRow: View {
    let title: String
    @Binding var time: String?
    let learnt: String?

    var body: some View {
        Picker(title, selection: Binding(get: { time == nil }, set: { learn in
            time = learn ? nil : (learnt ?? "07:30")
        })) {
            Text(learnt.map { "Learnt (\(BedtimeCard.clock($0)))" } ?? "Learnt").tag(true)
            Text("Set").tag(false)
        }
        if let value = time {
            DatePicker("At", selection: Binding(
                get: {
                    let p = value.split(separator: ":").compactMap { Int($0) }
                    return Calendar.current.date(bySettingHour: p.first ?? 7, minute: p.count > 1 ? p[1] : 0,
                                                 second: 0, of: Date()) ?? Date()
                },
                set: {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                    time = String(format: "%02d:%02d", c.hour ?? 7, c.minute ?? 0)
                }), displayedComponents: .hourAndMinute)
        }
    }
}

/// Tonight's plan: in bed by, asleep by, up at, and why (also the evening digest's card).
struct BedtimeCard: View {
    let plan: BedtimePlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                stat("In bed", plan.bedtimeDate, big: true)
                stat("Asleep by", plan.asleepDate)
                stat("Up at", plan.wakeDate)
                Spacer(minLength: 0)
            }
            Text(plan.why).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private func stat(_ label: String, _ date: Date?, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(date.map(Self.time) ?? "–")
                .font(big ? .title2.weight(.bold) : .title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(big ? ScoreColors.sleep[0] : .primary)
        }
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "07:15" from the server, in the phone's clock style.
    static func clock(_ hhmm: String) -> String {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, let d = Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: Date())
        else { return hhmm }
        return time(d)
    }
}

/// "Wed 4 Nov · asleep 23:50, 25 min late · up 7:20, on time"
private struct BedtimeNightRow: View {
    let night: BedtimeNight

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day).font(.subheadline.weight(.semibold))
            HStack(spacing: 14) {
                part("moon.zzz.fill", night.asleep, night.asleepOffMin)
                part("sunrise.fill", night.wake, night.wakeOffMin)
            }
            .font(.footnote)
        }
    }

    private var day: String {
        guard let d = Wire.day(night.date) else { return night.date }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func part(_ icon: String, _ at: String?, _ off: Int?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(ScoreColors.sleep[0])
            Text(at.flatMap(Wire.parse).map(BedtimeCard.time) ?? "–").monospacedDigit()
            if let off { Text(Self.off(off)).foregroundStyle(abs(off) >= 30 ? Color.orange : .secondary) }
        }
    }

    static func off(_ minutes: Int) -> String {
        if abs(minutes) < 10 { return "on time" }
        let n = abs(minutes), text = n >= 60 ? "\(n / 60)h\(String(format: "%02d", n % 60))" : "\(n) min"
        return minutes > 0 ? "\(text) late" : "\(text) early"
    }
}
