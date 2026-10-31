import SwiftUI

/// The phone's lists are grouped: rounded cards of rows on a plain background. The Mac's `List` has no such style and
/// draws every row as a strip from edge to edge, with heavy lines under the section headers. So in the Mac app
/// `List` is this: the same rows in a grouped `Form`, which the Mac draws as rounded sections, as in System Settings.
/// The shared views keep writing `List`; `SwiftUI.List` is still there by its full name.
struct List<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    init<Data: RandomAccessCollection, ID: Hashable, Row: View>(
        _ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder rowContent: @escaping (Data.Element) -> Row
    ) where Content == ForEach<Data, ID, Row> {
        content = ForEach(data, id: id, content: rowContent)
    }

    init<Data: RandomAccessCollection, Row: View>(
        _ data: Data, @ViewBuilder rowContent: @escaping (Data.Element) -> Row
    ) where Data.Element: Identifiable, Content == ForEach<Data, Data.Element.ID, Row> {
        content = ForEach(data, content: rowContent)
    }

    /// The widest the sections get.
    private static var width: CGFloat { 820 }

    var body: some View {
        GeometryReader { window in
            Form { content }
                .formStyle(.grouped)
                // A button in a row is the accent's text, as on the phone, not a push button or a glass pill.
                .buttonStyle(.borderless)
                .multilineTextAlignment(.leading)
                // The Mac keeps a grouped form to a narrow column; a page of cards gets a wider one, in the middle.
                .contentMargins(.horizontal, max(20, (window.size.width - Self.width) / 2), for: .scrollContent)
        }
    }
}
