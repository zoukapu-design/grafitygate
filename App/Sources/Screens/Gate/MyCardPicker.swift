import SwiftUI

/// 自分のグラフィティカードから 1 枚選ぶ（手紙に添えるとき）。この GATE のカードを先に出す。
struct MyCardPicker: View {
    /// 先に出す GATE
    var preferGate: UUID?
    var title = "添えるカードを選ぶ"
    let onPick: (MyCard) -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var cards: [MyCard] = []
    @State private var loaded = false
    @State private var error: String?

    static func content(_ card: MyCard, author: String) -> TradingCardContent {
        TradingCardContent(id: card.id, photoPath: card.photo_path, body: card.body, author: author, title: card.title,
                           gateTitle: card.gate_title, createdAt: card.created_at, finish: CardFinish(raw: card.finish),
                           badge: .mine)
    }

    private var ordered: [MyCard] {
        guard let preferGate else { return cards }
        return cards.filter { $0.gate_id == preferGate } + cards.filter { $0.gate_id != preferGate }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error {
                        NoticeText(text: error)
                    } else if loaded && cards.isEmpty {
                        EmptyNote(title: "まだグラフィティカードがありません",
                                  message: "GATE の扉を開けて、カードを作ると添えられます。",
                                  systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                    } else if !loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                        ForEach(ordered) { card in
                            Button {
                                Haptics.tap()
                                onPick(card)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    TradingCard(content: Self.content(card, author: session.profile?.display_name ?? "あなた"),
                                                animated: false)
                                    if card.gate_id == preferGate {
                                        Text("この GATE のカード")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(Theme.warm)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let api = session.api else { return }
        defer { loaded = true }
        do {
            cards = try await api.myCards()
        } catch {
            self.error = ErrorText.isMissingFunction(error)
                ? "カードを選ぶのは、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
    }
}
