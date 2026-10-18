import SwiftUI

/// The digest on its own page, reachable from any chat. The period (morning, evening, week, month)
/// sits in a menu in the corner rather than on the page.
struct DigestSheet: View {
    @EnvironmentObject private var digest: DigestViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                DigestView(digest: digest.digest)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .background(Theme.background)
            .navigationTitle(digest.kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Period", selection: $digest.kind) {
                            ForEach(DigestViewModel.Kind.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Period")
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onChange(of: digest.kind) { _, _ in Task { await digest.load() } }
            .task { await digest.load() }
        }
    }
}
