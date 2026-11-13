import SwiftUI

/// ホーム：友達が残した新しいグラフィティ（24 時間だけ）。押すと GATE の概要へ。中を見るには現地で入る。
struct HomeView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var inbox: InboxModel
    @EnvironmentObject private var nav: AppNavigator
    @State private var cards: [FeedCard] = []
    @State private var friendCount: Int?
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
                    if loaded && cards.isEmpty {
                        HomeStartGuide(friendCount: friendCount ?? 0) { tab in nav.tab = tab }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
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
        if cards.isEmpty, let me = session.userID {
            friendCount = (try? await api.friends(me: me).count) ?? friendCount
        }
        loaded = true
    }
}

/// 新着がないとき：次にすること（友達を足す・近くを探す・作る）
private struct HomeStartGuide: View {
    let friendCount: Int
    let go: (AppNavigator.Tab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(friendCount == 0 ? "はじめよう" : "友達の新着はまだありません")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.text)
                Text(friendCount == 0
                     ? "友達が GATE に残した記録が、24 時間ここに届きます。まずは友達を足すか、近くの GATE を探してみましょう。"
                     : "友達がどこかの GATE に記録を残すと、24 時間ここに出ます。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)
            if friendCount == 0 {
                NavigationLink {
                    FriendsView()
                } label: {
                    GuideRow(systemImage: "person.badge.plus", title: "友達を足す",
                             detail: "QR を見せる・読むだけ。お互いにフォローすると友達になります。")
                }
                .buttonStyle(.plain)
            }
            Button { go(.map) } label: {
                GuideRow(systemImage: "map", title: "近くの GATE を探す", detail: "地図で、100m 以内の扉を見られます。")
            }
            .buttonStyle(.plain)
            Button { go(.capture) } label: {
                GuideRow(systemImage: "door.left.hand.open", title: "最初の GATE を作る",
                         detail: "思い出の場所や物にカメラを向けて、記憶の扉を置きます。")
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 8)
    }
}

private struct GuideRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accentLight, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(Theme.text)
                Text(detail).font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
        .contentShape(Rectangle())
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
                HStack(spacing: 10) {
                    PersonBadge(name: card.author_name, size: 32)
                    Text(card.author_name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(ServerDate.relative(card.created_at)).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                if !card.body.isEmpty {
                    Text(card.body).font(.body).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(card.gate_title, systemImage: "door.left.hand.open")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Theme.accentLight, in: Capsule())
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
