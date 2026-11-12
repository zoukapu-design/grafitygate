import SwiftUI

/// ホーム：友達が残した新しいグラフィティ（24 時間だけ）。押すと GATE の概要へ。中を見るには現地で入る。
struct HomeView: View {
    @EnvironmentObject private var session: SessionModel
    @State private var cards: [FeedCard] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "ホーム") {
                List {
                    if let error {
                        NoticeText(text: error)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(cards) { card in
                        NavigationLink(value: GateRoute(id: card.gate_id)) {
                            FeedRow(card: card)
                        }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if loaded && cards.isEmpty && error == nil {
                        EmptyNote(title: "友達の新着はまだありません",
                                  message: "友達がどこかの GATE に残した記録が、24 時間ここに出ます。",
                                  systemImage: "sparkles")
                    }
                }
                .refreshable { await load() }
            }
            .task(id: session.state) { await load() }
        }
    }

    private func load() async {
        guard let api = session.api, session.state == .signedIn else { return }
        do {
            cards = try await api.friendFeed()
            error = nil
        } catch {
            self.error = ErrorText.of(error)
        }
        loaded = true
    }
}

private struct FeedRow: View {
    let card: FeedCard

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(card.author_name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(ServerDate.relative(card.created_at)).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                if !card.body.isEmpty {
                    Text(card.body).font(.body).foregroundStyle(Theme.text)
                }
                Label(card.gate_title, systemImage: "door.left.hand.open")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 4)
    }
}
