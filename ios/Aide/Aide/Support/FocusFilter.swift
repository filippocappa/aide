import AppIntents
import Foundation

/// A Focus filter (docs/API.md, "Work Focus"): Settings → Focus → Work → Add Filter → Aide, and an app list. While
/// that Focus is on, the device locks the list's apps; when it ends (or a Focus without the filter comes on), iOS
/// runs it again with no list. The phone shields its own pick of the list (`LockBook.applyFocusFilter`), the Mac
/// quits its apps (`MacScreenTime`). No server part: each device has its own filter.
struct AideFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Lock an app list"
    static var description: IntentDescription? = "While this Focus is on, Aide locks the apps of a list you pick (Work)."

    @Parameter(title: "List")
    var list: ScreenListEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: list.map { "Lock \($0.name)" } ?? "Lock nothing",
                              subtitle: "Aide's app lists")
    }

    func perform() async throws -> some IntentResult {
        FocusFilterState.set(list?.id)
        return .result()
    }
}

struct ScreenListEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "App list"
    static var defaultQuery = Query()

    let id: Int
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    struct Query: EntityQuery {
        func entities(for identifiers: [Int]) async throws -> [ScreenListEntity] {
            FocusFilterState.lists.filter { identifiers.contains($0.id) }
        }

        func suggestedEntities() async throws -> [ScreenListEntity] { FocusFilterState.lists }
    }
}

/// Where each device keeps the lists it last synced and the list the Focus filter asks for.
enum FocusFilterState {
    static let changed = Notification.Name("AideFocusFilterChanged")

    static var lists: [ScreenListEntity] {
        #if os(iOS)
        LockBook.lists.map { ScreenListEntity(id: $0.id, name: $0.name) }
        #else
        MacLockApps.lists.map { ScreenListEntity(id: $0.id, name: $0.name) }
        #endif
    }

    static func set(_ id: Int?) {
        #if os(iOS)
        LockBook.focusFilterList = id
        LockBook.applyFocusFilter()
        #else
        MacLockApps.focusFilterList = id
        #endif
        NotificationCenter.default.post(name: changed, object: nil)
    }
}
