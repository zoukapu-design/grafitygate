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
    @State private var lastLoad = Date.distantPast
    /// 自分がカードを残した GATE（友達の新着に「あなたのカードと並べる」を出す）
    @State private var myCardGates: Set<UUID> = []
    @State private var comparing: CardCompareRequest?
    @Environment(\.scenePhase) private var scenePhase

    /// 友達を足す画面へ（List の中の NavigationLink は「>」が 2 つ出るので、ボタンから開く）
    @State private var showFriends = false
    /// 大きく見るカード
    @State private var opened: FeedCard?

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "ホーム") {
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if let error {
                                NoticeText(text: error)
                            }
                            if !loaded && error == nil && (session.state == .starting || session.state == .signedIn) {
                                // 読み込み中：カードの形だけ先に出す（白い画面で待たせない）
                                ForEach(0..<2, id: \.self) { _ in FeedRowPlaceholder() }
                            }
                            if loaded && cards.isEmpty {
                                HomeWelcome(friendCount: friendCount ?? 0,
                                            openFriends: { showFriends = true },
                                            go: { tab in nav.tab = tab })
                            }
                            if !cards.isEmpty {
                                // 新しいカードを残した友達（押すと、その人のカードへ）
                                FriendRing(cards: cards) { id in
                                    withAnimation(.easeInOut(duration: 0.4)) { scroller.scrollTo(id, anchor: .top) }
                                }
                                SectionHeader(title: "友達の新着", count: cards.count)
                                ForEach(cards) { card in
                                    FeedPost(card: card,
                                             onOpen: { opened = card },
                                             onCompare: myCardGates.contains(card.gate_id) ? { Task { await compare(card) } } : nil,
                                             onReport: { report = reportItem(card) })
                                        .id(card.id)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 28)
                    }
                    .refreshable { await load() }
                    // 上：しるしと、メッセージ・お知らせ（ナビゲーションの帯の代わり。スクロールしても残る）
                    .safeAreaInset(edge: .top, spacing: 0) { homeHeader }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showFriends) { FriendsView() }
            .fullScreenCover(item: $opened) { card in
                TradingCardViewer(content: FeedPost.content(card, me: session.userID)) {
                    report = reportItem(card)
                }
            }
            .sheet(item: $comparing) { request in
                CardCompareView(request: request).environmentObject(session)
            }
            .task(id: session.state) { await load() }
            // 新着は 24 時間だけなので、アプリに戻ったとき・ホームに戻ったときに 1 分より古ければ読み直す
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await loadIfStale() } }
            }
            .onChange(of: nav.tab) { _, tab in
                if tab == .home { Task { await loadIfStale() } }
            }
            .sheet(item: $report, onDismiss: { Task { await load() } }) { item in ReportSheet(item: item) }
        }
    }

    private var homeHeader: some View {
        TabHeader {
            BrandHeaderMark()
        } trailing: {
            NavigationLink {
                MessagesView()
            } label: {
                HeaderIcon(systemImage: "paperplane", count: inbox.messages)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(inbox.messages > 0 ? "メッセージ（新しい \(inbox.messages) 件）" : "メッセージ")
            NavigationLink {
                NotificationsView()
            } label: {
                HeaderIcon(systemImage: "bell", count: inbox.notifications)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(inbox.notifications > 0 ? "お知らせ（新しい \(inbox.notifications) 件）" : "お知らせ")
        }
    }

    private func reportItem(_ card: FeedCard) -> ReportItem {
        ReportItem(id: card.id, target: .graffiti, userID: card.author,
                   userName: card.author_name, label: "\(card.author_name) さんのグラフィティカード")
    }

    /// 友達の新着のカードと、同じ GATE の自分のカードを並べる
    private func compare(_ card: FeedCard) async {
        guard let api = session.api, let me = session.userID else { return }
        do {
            let mine = try await api.myGraffiti(in: card.gate_id, me: me)
            guard !mine.isEmpty else {
                myCardGates.remove(card.gate_id)
                return
            }
            let myName = session.profile?.display_name ?? ""
            comparing = CardCompareRequest(other: CardSnapshot(card),
                                           mine: mine.map { CardSnapshot($0, gateTitle: card.gate_title, authorName: myName) })
        } catch {
            self.error = ErrorText.of(error)
        }
    }

    private func loadIfStale() async {
        guard Date().timeIntervalSince(lastLoad) > 60 else { return }
        await load()
    }

    private func load() async {
        guard let api = session.api, session.state == .signedIn else { return }
        lastLoad = Date()
        do {
            cards = try await api.friendFeed()
            error = nil
        } catch {
            self.error = ErrorText.of(error)
        }
        if !cards.isEmpty, let me = session.userID, let gates = try? await api.myGraffitiGates(me: me) {
            myCardGates = gates
        }
        if cards.isEmpty, let me = session.userID {
            friendCount = (try? await api.friends(me: me).count) ?? friendCount
        }
        loaded = true
    }
}

/// 読み込み中のカードの形（ゆっくり明るさが変わる）
private struct FeedRowPlaceholder: View {
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.surfaceElevated).frame(height: 200)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Circle().fill(Theme.surfaceElevated).frame(width: 32, height: 32)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated).frame(width: 90, height: 12)
                }
                RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated).frame(height: 12)
                RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated).frame(width: 160, height: 12)
            }
            .padding(14)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.line))
        .opacity(dim ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityLabel("読み込んでいます")
    }
}

/// 新着がないとき：夜空の窓にカードの見本を扇に広げ、何が届くのかを見せる。その下に次にすること
private struct HomeWelcome: View {
    let friendCount: Int
    let openFriends: () -> Void
    let go: (AppNavigator.Tab) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                InsideBackground()
                // 見本のカード（だれのものでもない、飾りの 3 枚）
                ZStack {
                    sample(.neon, body: "待ち合わせ、ここにしよう。")
                        .rotationEffect(.degrees(-13))
                        .offset(x: -88, y: 14)
                    sample(.gold, body: "ここから見る夕焼けが好き。")
                        .rotationEffect(.degrees(13))
                        .offset(x: 88, y: 14)
                    sample(.holo, body: "また来ようね。")
                        .offset(y: -6)
                }
                .padding(.top, 10)
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(alignment: .topLeading) {
                Text("見本")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.white.opacity(0.15), in: Capsule())
                    .padding(14)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(friendCount == 0 ? "友達のグラフィティカードが、ここに届く" : "友達の新着は、まだありません")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Theme.text)
                Text(friendCount == 0
                     ? "友達が GATE に残したカードが、24 時間ここに並びます。キラやゴールドのカードも。まずは友達を足しましょう。"
                     : "友達がどこかの GATE でカードを残すと、24 時間ここに並びます。あなたも近くの GATE で 1 枚残してみましょう。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if friendCount == 0 {
                Button(action: openFriends) {
                    Label("友達を足す", systemImage: "person.badge.plus")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            Button { go(.map) } label: {
                GuideRow(systemImage: "map", title: "近くの GATE を探す", detail: "地図で、100m 以内の GATE を見られます。")
            }
            .buttonStyle(.plain)
            Button { go(.capture) } label: {
                GuideRow(systemImage: "door.left.hand.open", title: "最初の GATE を作る",
                         detail: "思い出の場所や物にカメラを向けて、記憶の扉を置きます。")
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    private func sample(_ finish: CardFinish, body: String) -> some View {
        TradingCard(content: TradingCardContent(id: UUID(), body: body, author: "友達", gateTitle: "あなたの街の GATE",
                                                createdAt: nil, likes: 0, finish: finish),
                    animated: finish == .holo)
            .frame(width: 140, height: 140 / TradingCard.aspect)
            .accessibilityHidden(true)
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

/// 新しいカードを残した友達の丸（ネオンの輪。押すと、その人のいちばん新しいカードへ）
private struct FriendRing: View {
    let cards: [FeedCard]
    let jump: (UUID) -> Void

    private struct Person: Identifiable {
        let id: UUID
        let name: String
        let first: UUID
        var count: Int
    }

    private var people: [Person] {
        var seen: [UUID: Int] = [:]
        var list: [Person] = []
        for card in cards {
            if let i = seen[card.author] {
                list[i].count += 1
            } else {
                seen[card.author] = list.count
                list.append(Person(id: card.author, name: card.author_name, first: card.id, count: 1))
            }
        }
        return list
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(people) { person in
                    Button {
                        jump(person.first)
                    } label: {
                        VStack(spacing: 6) {
                            PersonBadge(name: person.name, size: 56)
                                .padding(4)
                                .overlay(Circle().strokeBorder(Theme.neonBand, lineWidth: 3))
                                .overlay(alignment: .bottomTrailing) {
                                    if person.count > 1 {
                                        Text("\(person.count)")
                                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                                            .foregroundStyle(.white)
                                            .frame(minWidth: 20, minHeight: 20)
                                            .background(Theme.accent, in: Circle())
                                            .overlay(Circle().stroke(.white, lineWidth: 2))
                                    }
                                }
                            Text(person.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .frame(maxWidth: 72)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(person.name) さんの新しいカード \(person.count) 枚")
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
    }
}

/// 友達の新着 1 枚：上に書いた人と時間、まん中にカード（押すと大きく）、下に GATE と「並べる」
private struct FeedPost: View {
    let card: FeedCard
    let onOpen: () -> Void
    var onCompare: (() -> Void)?
    let onReport: () -> Void

    static func content(_ card: FeedCard, me: UUID?) -> TradingCardContent {
        TradingCardContent(id: card.id, photoPath: card.photo_path, body: card.body, author: card.author_name, title: card.title,
                           gateTitle: card.gate_title, createdAt: card.created_at,
                           finish: CardFinish(raw: card.finish), badge: card.author == me ? .mine : .friend)
    }

    @EnvironmentObject private var session: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PersonBadge(name: card.author_name, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.author_name).font(.subheadline.weight(.bold)).foregroundStyle(Theme.text)
                    Text(ServerDate.relative(card.created_at)).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Menu {
                    if let onCompare {
                        Button(action: onCompare) {
                            Label("あなたのカードと並べる", systemImage: "rectangle.split.2x1")
                        }
                    }
                    Button(role: .destructive, action: onReport) {
                        Label("通報する", systemImage: "exclamationmark.bubble")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("そのほか")
            }
            Button(action: onOpen) {
                TradingCard(content: Self.content(card, me: session.userID))
                    .frame(maxWidth: 300)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityHint("押すと大きく見られます")
            HStack(spacing: 10) {
                NavigationLink(value: GateRoute(id: card.gate_id)) {
                    Label(card.gate_title, systemImage: "door.left.hand.open")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .background(Theme.accentLight, in: Capsule())
                }
                .buttonStyle(.plain)
                if let onCompare {
                    Button(action: onCompare) {
                        Label("並べる", systemImage: "rectangle.split.2x1")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.warm)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 34)
                            .background(Theme.warm.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).stroke(Theme.line))
    }
}
