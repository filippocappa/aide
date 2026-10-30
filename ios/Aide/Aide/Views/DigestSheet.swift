import SwiftUI

/// The briefing on its own page: the period as chips at the top (wake-up, evening, week, month), the note, then
/// its sections as cards. Refresh writes it again.
struct DigestSheet: View {
    @EnvironmentObject private var digest: DigestViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    periods
                    if let error = digest.refreshError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.red)
                    }
                    DigestView(digest: digest.digest)
                        .opacity(digest.isRefreshing ? 0.4 : 1)
                        .animation(.easeOut(duration: 0.2), value: digest.isRefreshing)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
            .previewAnchor()
            .pageGlow(Theme.accent)
            .background(Theme.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if digest.isRefreshing {
                        ProgressView()
                    } else {
                        Button { Task { await digest.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Write it again")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onChange(of: digest.kind) { _, _ in digest.refreshError = nil; Task { await digest.load() } }
            .task { await digest.load() }
        }
    }

    /// Wake-up · Evening · Week · Month; the picked one filled.
    private var periods: some View {
        HStack(spacing: 8) {
            ForEach(DigestViewModel.Kind.picked) { kind in
                let picked = digest.kind == kind
                Button { digest.kind = kind } label: {
                    Text(kind.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(picked ? Theme.background : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(picked ? Color.primary : Theme.chip, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(CardPress())
                .accessibilityAddTraits(picked ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.15), value: digest.kind)
    }
}
