import SwiftUI

/// The digest on its own page, reachable from any chat. The period (wake-up, evening, week, month)
/// sits in a menu in the corner rather than on the page; Refresh writes it again.
struct DigestSheet: View {
    @EnvironmentObject private var digest: DigestViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let error = digest.refreshError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 12)
                }
                DigestView(digest: digest.digest)
                    .opacity(digest.isRefreshing ? 0.4 : 1)
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
                            ForEach(DigestViewModel.Kind.picked) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Period")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if digest.isRefreshing {
                        ProgressView()
                    } else {
                        Button { Task { await digest.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Refresh")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onChange(of: digest.kind) { _, _ in digest.refreshError = nil; Task { await digest.load() } }
            .task { await digest.load() }
        }
    }
}
