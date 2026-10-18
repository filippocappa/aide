import SwiftUI

/// The digest on its own page, reachable from any chat.
struct DigestSheet: View {
    @EnvironmentObject private var digest: DigestViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                DigestView(digest: digest.digest)
                    .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Digest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await digest.load() }
        }
    }
}
