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

    var body: some View {
        stack
            .environment(\.macInStack, true)
            .safeAreaInset(edge: .top, spacing: 0) {
            if inSheet {
                HStack {
                    SheetCloseButton { dismiss() }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
        }
    }
}

extension EnvironmentValues {
    @Entry var macInStack = false
}

extension View {
    /// For a sheet whose stack isn't inside another: give it the close button.
    func macSheet() -> some View { environment(\.macInStack, true) }
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
