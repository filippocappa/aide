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
        // No system sidebar: its flat slab cuts the page in two. The page runs the full width of the window, its
        // glow behind everything, and the sections float over it on the left as a glass rail.
        detail
            .id(nav.section)
            // The rail, with as much room again on its right: the Mac's lists run their rows to the edge.
            .safeAreaPadding(.leading, MacRail.width + 2 * MacRail.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) {
                MacRail(section: Binding(get: { nav.section ?? .team }, set: { nav.section = $0 }), waiting: waiting)
                    .padding(.leading, MacRail.margin)
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

/// The sections as a floating glass capsule on the left: icons only, the name on hover and in the Go menu (⌘1–6).
struct MacRail: View {
    static let width: CGFloat = 52
    static let margin: CGFloat = 12

    @Binding var section: MacSection
    var waiting: Int
    @Namespace private var selection

    var body: some View {
        VStack(spacing: 4) {
            button(.team)
            button(.today)
            divider
            button(.study)
            button(.health)
            button(.food)
            divider
            button(.settings)
        }
        .padding(.vertical, 8)
        .frame(width: Self.width)
        .modifier(RailBackground())
        .animation(.snappy(duration: 0.25), value: section)
    }

    private var divider: some View {
        Capsule().fill(.secondary.opacity(0.25)).frame(width: 20, height: 1).padding(.vertical, 4)
    }

    private func button(_ item: MacSection) -> some View {
        let selected = item == section
        return Button { section = item } label: {
            Image(systemName: item.icon)
                .symbolVariant(selected ? .fill : .none)
                .font(.system(size: 16, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(width: 40, height: 40)
                .background {
                    if selected {
                        Circle().fill(.primary.opacity(0.12)).matchedGeometryEffect(id: "selected", in: selection)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item == .team, waiting > 0 {
                        Text("\(waiting)")
                            .font(.system(size: 9, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(.red))
                            .offset(x: 2, y: -1)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(item.title) (⌘\(String(item.shortcut.character)))")
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Liquid Glass where the system has it, else a material capsule with a hairline and a soft shadow.
private struct RailBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
    }
}
