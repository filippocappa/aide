import SwiftUI

/// The Money tab, Finance's area: a placeholder until the payments from #31 come in. Finance's line on top (tap: its
/// chat) and what the page will hold. No server calls yet.
struct MoneyView: View {
    @EnvironmentObject private var chat: ChatViewModel
    @EnvironmentObject private var push: PushService
    @EnvironmentObject private var settings: AppSettings

    private var finance: Agent { chat.agent("finance") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TopBlock("Money", overline: Date.now.formatted(.dateTime.month(.wide).year())) { EmptyView() }
                    AgentLine(agent: finance,
                              text: "Nothing to count yet. Payments from your banks and cards will come in here, sorted. Until then, ask me anything about money.") {
                        push.route = .agent(finance.id)
                    }
                    .disabled(!settings.isConfigured)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Coming here").font(.headline).padding(.bottom, 10)
                        ForEach(Self.coming, id: \.title) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.icon)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(finance.tint)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.subheadline.weight(.semibold))
                                    Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .card()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .pageColumn()
            }
            .pageGlow(finance.tint)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private static let coming: [(icon: String, title: String, detail: String)] = [
        ("chart.bar.fill", "The month", "What you spent, by category, against last month and your budgets."),
        ("list.bullet.rectangle", "Payments", "Every Apple Pay tap and bank payment, sorted on its own."),
        ("arrow.triangle.2.circlepath", "Subscriptions", "What renews, its price and when."),
        ("building.columns.fill", "Accounts", "Revolut, Intesa, UniCredit, Hype and Carta YOU, with their balances."),
    ]
}
