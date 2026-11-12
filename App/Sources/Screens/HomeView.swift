import SwiftUI

/// ホーム：友達が残した新しいグラフィティ（24 時間だけ）。押すと GATE の概要へ。中を見るには現地で入る。
struct HomeView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var inbox: InboxModel
    @State private var cards: [FeedCard] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var report: ReportItem?

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
                        .contextMenu {
                            Button {
                                report = ReportItem(id: card.id, target: .graffiti, userID: card.author,
                                                    userName: card.author_name, label: "\(card.author_name) さんの記憶")
                            } label: {
                                Label("通報する", systemImage: "exclamationmark.bubble")
                            }
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
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        MessagesView()
                    } label: {
                        BadgedIcon(systemImage: "bubble.left.and.bubble.right", count: inbox.messages)
                    }
                    .accessibilityLabel(inbox.messages > 0 ? "メッセージ（新しい \(inbox.messages) 件）" : "メッセージ")
                    NavigationLink {
                        NotificationsView()
                    } label: {
                        BadgedIcon(systemImage: "bell", count: inbox.notifications)
                    }
                    .accessibilityLabel(inbox.notifications > 0 ? "お知らせ（新しい \(inbox.notifications) 件）" : "お知らせ")
                }
            }
            .sheet(item: $report, onDismiss: { Task { await load() } }) { item in ReportSheet(item: item) }
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
        VStack(alignment: .leading, spacing: 0) {
            if let path = card.photo_path {
                RemotePhoto(path: path)
                    .frame(height: 260)
                    .frame(maxWidth: .infinity)
            }
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
            .padding(16)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.line))
        .padding(.vertical, 4)
    }
}

/// 右上に数の印が付くアイコン
struct BadgedIcon: View {
    let systemImage: String
    let count: Int

    var body: some View {
        Image(systemName: systemImage)
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Theme.alert, in: Capsule())
                        .offset(x: 10, y: -8)
                }
            }
    }
}
