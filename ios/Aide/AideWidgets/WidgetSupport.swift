import SwiftUI
import WidgetKit

/// The widgets' way to the server: the app's own client and settings, read from the App Group's keychain.
@MainActor
enum WidgetAPI {
    /// Settings are read on every call, so a token changed in the app applies to the next refresh.
    static let client = APIClient(config: { AppSettings().apiConfig })

    static var isConfigured: Bool { AppSettings().isConfigured }
}

/// What a widget draws: the server's answer, or the last good one when the server can't be reached.
struct Loaded<T> {
    let value: T
    /// false: from the cache, the server didn't answer this time.
    let fresh: Bool
}

/// The last good answer per endpoint, as the server sent it, in the App Group's container.
@MainActor
enum WidgetCache {
    private static var folder: URL? {
        guard let group = Keychain.group else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appending(path: "Widgets", directoryHint: .isDirectory)
    }

    private static func file(_ path: String) -> URL? {
        folder?.appending(path: path.trimmingCharacters(in: ["/"]).replacingOccurrences(of: "/", with: "_") + ".json")
    }

    /// GET `path`, keep it, decode it; on failure the kept one. Nil when there's neither (or no settings yet).
    static func load<T: Decodable>(_ type: T.Type, _ path: String) async -> Loaded<T>? {
        if WidgetAPI.isConfigured, let data = try? await WidgetAPI.client.raw(path),
           let value = try? JSONDecoder.api.decode(T.self, from: data) {
            if let url = file(path), let folder {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? data.write(to: url, options: .atomic)
            }
            return Loaded(value: value, fresh: true)
        }
        guard let url = file(path), let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder.api.decode(T.self, from: data) else { return nil }
        return Loaded(value: value, fresh: false)
    }

    /// The agents, for names and colours; Aide alone before the first answer.
    static func agents() async -> [Agent] {
        let list = await load(AgentList.self, "/v1/agents")?.value.agents ?? []
        return list.isEmpty ? [.aide] : list
    }
}

extension [Agent] {
    func agent(_ id: String) -> Agent { first { $0.id == id } ?? first { $0.orchestrator } ?? .aide }
}

/// Runs an async load on the main actor and hands WidgetKit its timeline.
func provide<Entry: TimelineEntry>(_ completion: @escaping (Timeline<Entry>) -> Void,
                                   _ make: @escaping @MainActor () async -> Timeline<Entry>) {
    Task { @MainActor in completion(await make()) }
}

/// A widget's plain background: the app's white (black in dark mode).
extension View {
    func widgetBackground() -> some View {
        containerBackground(for: .widget) { Theme.background }
    }
}

/// What a widget says before the app has a server, or when there's nothing at all to show.
struct WidgetNote: View {
    let text: String
    var symbol = "exclamationmark.icloud"

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static let setUp = "Open Aide and add your server in Settings."
}

/// A small header in the widget's colour: a symbol, a title, a count on the right and, when the server didn't
/// answer, a hint that this is the last copy.
struct WidgetHeader: View {
    let title: String
    var symbol: String?
    var tint: Color = .secondary
    var trailing: String?
    var fresh = true

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption.weight(.bold)) }
            Text(title).font(.caption.weight(.bold)).lineLimit(1)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            if !fresh { Image(systemName: "icloud.slash").font(.caption2).foregroundStyle(.tertiary) }
        }
        .foregroundStyle(tint)
    }
}
