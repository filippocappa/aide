import SwiftUI

/// On the phone a sheet goes away with a swipe down, so many have no Close or Done of their own; on the Mac that
/// leaves only Esc, which nobody sees. In the Mac app `NavigationStack` is this: the same stack, and when it's a
/// sheet's, a close button in its top-left corner (where iOS 26 puts its own). The shared views keep writing
/// `NavigationStack`; `SwiftUI.NavigationStack` is still there by its full name.
///
/// A stack is a sheet's when it sits inside another stack (the sheet carries the environment of the page that opened
/// it), or when `MacRootView` says so for the sheets it opens itself. `isPresented` can't tell: the window's own
/// pages count as presented too.
struct NavigationStack<Root: View>: View {
    private let stack: AnyView
    @Environment(\.macInStack) private var inSheet
    @Environment(\.dismiss) private var dismiss

    init(@ViewBuilder root: () -> Root) {
        stack = AnyView(SwiftUI.NavigationStack(root: root))
    }

    init(path: Binding<NavigationPath>, @ViewBuilder root: () -> Root) {
        stack = AnyView(SwiftUI.NavigationStack(path: path, root: root))
    }

    init<Data: MutableCollection & RandomAccessCollection & RangeReplaceableCollection>(
        path: Binding<Data>, @ViewBuilder root: () -> Root
    ) where Data.Element: Hashable {
        stack = AnyView(SwiftUI.NavigationStack(path: path, root: root))
    }

    @State private var title: String?

    var body: some View {
        if inSheet {
            stack
                .environment(\.macInStack, true)
                .onPreferenceChange(MacSheetTitleKey.self) { title = $0 }
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        SheetCloseButton { dismiss() }
                        Spacer()
                    }
                    .overlay {
                        if let title { Text(title).font(.headline).lineLimit(1).padding(.horizontal, 56) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                }
                // Phone sheets fill the screen; on the Mac a sheet would shrink to its content. Most of the window.
                .frame(minWidth: 620, idealWidth: 760, maxWidth: .infinity,
                       minHeight: 560, idealHeight: 760, maxHeight: .infinity)
        } else {
            stack.environment(\.macInStack, true)
        }
    }
}

/// A sheet's title, in the middle of the row with the close button (the Mac shows no navigation title in a sheet).
struct MacSheetTitleKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) { value = value ?? nextValue() }
}

extension EnvironmentValues {
    @Entry var macInStack = false
}

extension View {
    /// For a sheet whose stack isn't inside another: give it the close button.
    func macSheet() -> some View { environment(\.macInStack, true) }

    /// The title shown next to a sheet's close button.
    func macSheetTitle(_ title: String) -> some View { preference(key: MacSheetTitleKey.self, value: title) }
}

private struct SheetCloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(CloseBackground())
        .keyboardShortcut(.cancelAction)
        .help("Close (Esc)")
        .accessibilityLabel("Close")
    }
}

private struct CloseBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.regularMaterial, in: Circle())
        }
    }
}
