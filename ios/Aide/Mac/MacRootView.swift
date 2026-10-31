import SwiftUI

/// The sidebar's sections: the phone's tabs, with Today and Activity as places of their own (on the phone they
/// open over the Team tab).
enum MacSection: String, CaseIterable, Identifiable, Hashable {
    case team, today, study, health, food, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .team: "Team"
        case .today: "Today"
        case .study: "Study"
        case .health: "Health"
        case .food: "Food"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .team: "person.3"
        case .today: "sun.max"
        case .study: "book"
        case .health: "heart.text.square"
        case .food: "fork.knife"
        case .settings: "gearshape"
        }
    }

    var shortcut: KeyEquivalent {
        KeyEquivalent(Character(String((MacSection.allCases.firstIndex(of: self) ?? 0) + 1)))
    }
}

/// Which section is showing; the menu bar's Go menu sets it too.
@MainActor
final class MacNavigation: ObservableObject {
    static let shared = MacNavigation()
    @Published var section: MacSection? = .team
}

struct MacRootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var push: PushService
    @EnvironmentObject private var digest: DigestViewModel
    @ObservedObject private var nav = MacNavigation.shared
    /// Things waiting for your OK, on the Team row's badge.
    @State private var waiting = 0

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.section) {
                Section {
                    ForEach([MacSection.team, .today]) { row($0) }
                }
                Section {
                    ForEach([MacSection.study, .health, .food]) { row($0) }
                }
                Section {
                    row(.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
                .id(nav.section)
        }
        .onAppear {
            if !settings.isConfigured { nav.section = .settings }
        }
        .task(id: settings.isConfigured) {
            if settings.isConfigured, let a = try? await env.api.approvals() { waiting = a.waiting }
        }
        // As on the phone (`ContentView`): links and, later, notifications open their place.
        .onReceive(push.$route.compactMap { $0 }) { route in
            push.route = nil
            guard settings.isConfigured else { return }
            switch route {
            case .today, .digest, .note, .objectives: nav.section = .today
            case .health: nav.section = .health; return
            case .food, .meal: nav.section = .food; return
            case .chats: nav.section = .team; return
            case .moodle: break
            default: nav.section = .team
            }
            Task { await env.open(route) }
        }
        .sheet(isPresented: $env.showMoodle) {
            NavigationStack {
                MoodleView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { env.showMoodle = false } } }
            }
            .frame(minWidth: 520, minHeight: 560)
        }
        .sheet(item: $env.newFiles) { NewFilesSheet(ids: $0.ids).frame(minWidth: 480, minHeight: 480) }
        .sheet(isPresented: $digest.isPresented) { DigestSheet().frame(minWidth: 560, minHeight: 640) }
        // On the phone Today is a sheet over the Team tab; here it's a section of its own.
        .onChange(of: env.showToday) { _, show in
            if show { nav.section = .today; env.showToday = false }
        }
        .stage(item: $env.browser)
    }

    private func row(_ section: MacSection) -> some View {
        Label(section.title, systemImage: section.icon)
            .badge(section == .team ? waiting : 0)
            .tag(section)
    }

    @ViewBuilder private var detail: some View {
        switch nav.section ?? .team {
        case .team: ChatsView(waiting: $waiting)
        case .today: TodayView(waiting: $waiting)
        case .study: StudyView()
        case .health: HealthView()
        case .food: FoodView()
        case .settings: SettingsView()
        }
    }
}
