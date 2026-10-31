import SwiftUI

/// The sidebar's sections: the phone's tabs, with Today, Habits, Objectives and Activity as places of their own (on
/// the phone they open from Today or over the Team tab).
enum MacSection: String, CaseIterable, Identifiable, Hashable {
    case team, today, habits, objectives, activity, study, health, food, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .team: "Team"
        case .today: "Today"
        case .habits: "Habits"
        case .objectives: "Objectives"
        case .activity: "Activity"
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
        case .habits: "flame"
        case .objectives: "scope"
        case .activity: "bell"
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
    /// `-macSection study` at launch opens there (screenshots of each page).
    @Published var section: MacSection? = UserDefaults.standard.string(forKey: "macSection").flatMap(MacSection.init) ?? .team
}

struct MacRootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var push: PushService
    @EnvironmentObject private var digest: DigestViewModel
    @ObservedObject private var nav = MacNavigation.shared
    /// Things waiting for your OK, on the Team row's badge.
    @State private var waiting = 0
    @AppStorage("macSidebarCollapsed") private var collapsed = false
    @ObservedObject private var glance = MacGlance.shared

    var body: some View {
        // No system sidebar: its flat slab cuts the page in two. The page runs the full width of the window, its
        // glow behind everything, and the sections float over it on the left in glass.
        detail
            .id(nav.section)
            .safeAreaPadding(.leading, MacSidebar.inset(collapsed: collapsed))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The page's glow runs up under the title; no band of the toolbar's own with a hard edge under it.
            .modifier(SoftTitleBar())
            .overlay(alignment: .leading) {
                MacSidebar(section: Binding(get: { nav.section ?? .team }, set: { nav.section = $0 }),
                           waiting: waiting, collapsed: $collapsed, glance: glance)
                    .ignoresSafeArea()
            }
            // The window's title goes right of the sidebar, not over it.
            .toolbar {
                if !collapsed {
                    if #available(macOS 26, *) {
                        ToolbarItem(placement: .navigation) {
                            Color.clear.frame(width: MacSidebar.fullWidth - 70, height: 1)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                }
            }
        .onAppear {
            if !settings.isConfigured { nav.section = .settings }
        }
        .task(id: settings.isConfigured) {
            if settings.isConfigured, let a = try? await env.api.approvals() { waiting = a.waiting }
        }
        // The sidebar's glance: now, then every 5 minutes, and on each change of section (a meal or a habit logged).
        .task(id: settings.isConfigured) {
            while !Task.isCancelled {
                await glance.load(env)
                try? await Task.sleep(for: .seconds(300))
            }
        }
        .onChange(of: nav.section) { _, _ in Task { await glance.load(env) } }
        // As on the phone (`ContentView`): links and, later, notifications open their place.
        .onReceive(push.$route.compactMap { $0 }) { route in
            push.route = nil
            guard settings.isConfigured else { return }
            switch route {
            case .objectives: nav.section = .objectives; return
            case .today, .digest, .note: nav.section = .today
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
            .macSheet()
        }
        .sheet(item: $env.newFiles) { NewFilesSheet(ids: $0.ids).frame(minWidth: 480, minHeight: 480).macSheet() }
        .sheet(isPresented: $digest.isPresented) { DigestSheet().frame(minWidth: 560, minHeight: 640).macSheet() }
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
        case .habits: MacHabitsPage()
        case .objectives: TodayView(waiting: $waiting, objectivesOnly: true)
        case .activity: MacActivityPage()
        case .study: StudyView()
        case .health: HealthView()
        case .food: FoodView()
        case .settings: SettingsView()
        }
    }
}

/// The sections on the left, floating over the page in glass: a sidebar with each section's name, or folded into a
/// rail of icons (the button at the bottom, ⌃⌘S, or View → Show Section Names). The names are on hover too, and in
/// the Go menu (⌘1–9). Above Settings, the day at a glance (`MacGlance`).
struct MacSidebar: View {
    static let railWidth: CGFloat = 52
    static let fullWidth: CGFloat = 196
    static let margin: CGFloat = 10

    /// The room the page leaves on its left.
    static func inset(collapsed: Bool) -> CGFloat {
        collapsed ? railWidth + 2 * margin + 8 : fullWidth + 2 * margin
    }

    @Binding var section: MacSection
    var waiting: Int
    @Binding var collapsed: Bool
    @ObservedObject var glance: MacGlance
    @Namespace private var selection

    var body: some View {
        Group {
            if collapsed { rail } else { sidebar }
        }
        .animation(.snappy(duration: 0.25), value: section)
    }

    // MARK: The sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The window's traffic lights sit in the sidebar's top corner, as in the Mac's own apps.
            Color.clear.frame(height: 34)
            row(.team)
            row(.today)
            row(.habits)
            row(.objectives)
            row(.activity)
            header("Me")
            row(.study)
            row(.health)
            row(.food)
            Spacer(minLength: 12)
            if glance.scores != nil || glance.kcal != nil {
                MacGlanceCard(glance: glance) { section = $0 }
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
            HStack {
                row(.settings)
                toggle
            }
        }
        .padding(8)
        .frame(width: Self.fullWidth)
        .frame(maxHeight: .infinity)
        .modifier(GlassPanel(shape: RoundedRectangle(cornerRadius: 18, style: .continuous)))
        .padding(Self.margin)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 2)
    }

    private func row(_ item: MacSection) -> some View {
        let selected = item == section
        return Button { section = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .symbolVariant(selected ? .fill : .none)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .frame(width: 22)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
                if item == .activity, waiting > 0 { badge }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.primary.opacity(0.1))
                        .matchedGeometryEffect(id: "selected", in: selection)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("\(item.title) (⌘\(String(item.shortcut.character)))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var badge: some View {
        Text("\(waiting)")
            .font(.system(size: 10, weight: .bold)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
            .background(Capsule().fill(.red))
    }

    private var toggle: some View {
        Button { withAnimation(.snappy(duration: 0.3)) { collapsed.toggle() } } label: {
            Image(systemName: collapsed ? "sidebar.left" : "sidebar.squares.left")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show section names (⌃⌘S)" : "Icons only (⌃⌘S)")
    }

    // MARK: The rail

    private var rail: some View {
        VStack(spacing: 4) {
            icon(.team)
            icon(.today)
            icon(.habits)
            icon(.objectives)
            icon(.activity)
            divider
            icon(.study)
            icon(.health)
            icon(.food)
            divider
            if glance.scores != nil {
                Button { section = .health } label: { MacGlanceRings(glance: glance) }
                    .buttonStyle(.plain)
                    .help("Recovery, strain and sleep")
                divider
            }
            icon(.settings)
            toggle.frame(width: 40, height: 36)
        }
        .padding(.vertical, 8)
        .frame(width: Self.railWidth)
        .modifier(GlassPanel(shape: Capsule()))
        .padding(.leading, Self.margin)
        .frame(maxHeight: .infinity)
    }

    private var divider: some View {
        Capsule().fill(.secondary.opacity(0.25)).frame(width: 20, height: 1).padding(.vertical, 4)
    }

    private func icon(_ item: MacSection) -> some View {
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
                    if item == .activity, waiting > 0 { badge.scaleEffect(0.85).offset(x: 4, y: -2) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(item.title) (⌘\(String(item.shortcut.character)))")
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Liquid Glass where the system has it, else a material panel with a hairline and a soft shadow.
private struct GlassPanel<S: Shape>: ViewModifier {
    var shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
    }
}

/// The window toolbar over the page: no background of its own, and the page fading out softly under it instead of a
/// band with a line at its bottom.
private struct SoftTitleBar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else if #available(macOS 15, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}
