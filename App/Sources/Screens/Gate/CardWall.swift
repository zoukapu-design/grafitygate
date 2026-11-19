import SwiftUI

// みんなのグラフィティカード（2026-11-19 オーナー「カードは 2 列で、下にスクロールして見られるように。友人のカードが上」）。
// GATE の画面のまん中に 2 列で並べ、押すと 1 枚を大きく見る（いいね・返信・保存・来たよ・見比べる・直す・通報は、そこで）。
// 並びは 友達 → ほかの人 → 自分（それぞれ新しい順）。まだ扉を開けたことのない人には、チラ見せのカードと鍵の札。

struct GateCardWall: View {
    let context: GateContext
    let refreshToken: Int
    /// 夜空の画面（扉の中）に置くか
    var onDark = false

    @EnvironmentObject private var session: SessionModel
    @State private var graffiti: [Graffiti] = []
    @State private var names: [UUID: String] = [:]
    @State private var likes: [UUID: (count: Int, mine: Bool)] = [:]
    @State private var friendIDs: Set<UUID> = []
    /// この GATE で、自分が関わる「来たよ」
    @State private var links: [CardLinkMark] = []
    /// カードごとの返信の数・保存（nil＝サーバーがまだ 0018 の前なので出さない）
    @State private var extras: [UUID: CardExtra]?
    @State private var error: String?
    @State private var note: String?
    @State private var filter: WallFilter = .all
    @State private var selected: Graffiti?
    @State private var peekViewing: TradingCardContent?
    @State private var report: ReportItem?
    @State private var loaded = false

    enum WallFilter: String, CaseIterable, Identifiable {
        case all, friends, mine
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "すべて"
            case .friends: return "友達"
            case .mine: return "あなた"
            }
        }
    }

    private var ink: Color { onDark ? .white : Theme.text }
    private var subInk: Color { onDark ? .white.opacity(0.7) : Theme.textSecondary }

    // MARK: 並び

    private func rank(_ g: Graffiti) -> Int {
        if g.author == session.userID { return 2 }
        return friendIDs.contains(g.author) ? 0 : 1
    }

    /// 友達 → ほかの人 → 自分（それぞれ新しい順）
    private var ordered: [Graffiti] {
        graffiti.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.created_at > b.created_at
        }
    }

    private var shown: [Graffiti] {
        switch filter {
        case .all: return ordered
        case .friends: return ordered.filter { friendIDs.contains($0.author) && $0.author != session.userID }
        case .mine: return ordered.filter { $0.author == session.userID }
        }
    }

    private var myCards: [Graffiti] { graffiti.filter { $0.author == session.userID }.sorted { $0.created_at > $1.created_at } }
    private var otherCards: [Graffiti] { ordered.filter { $0.author != session.userID } }

    private func count(_ f: WallFilter) -> Int {
        switch f {
        case .all: return graffiti.count
        case .friends: return graffiti.filter { friendIDs.contains($0.author) && $0.author != session.userID }.count
        case .mine: return myCards.count
        }
    }

    private func name(of item: Graffiti) -> String {
        item.author == session.userID ? (session.profile?.display_name ?? "あなた") : (names[item.author] ?? "")
    }

    private func content(_ item: Graffiti) -> TradingCardContent {
        let badge: TradingCardContent.Badge = item.author == session.userID ? .mine
            : (friendIDs.contains(item.author) ? .friend : .visitor)
        return TradingCardContent(id: item.id, photoPath: item.photo_path, body: item.body, author: name(of: item),
                                  title: item.title, gateTitle: context.title, createdAt: item.created_at,
                                  likes: likes[item.id]?.count ?? 0, finish: CardFinish(raw: item.finish), badge: badge)
    }

    private func snapshot(_ item: Graffiti) -> CardSnapshot {
        CardSnapshot(item, gateTitle: context.title, authorName: name(of: item))
    }

    // MARK: 画面

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading
            if context.canRead {
                if graffiti.count > 1 {
                    filterChips
                }
                if loaded && shown.isEmpty {
                    emptyNote
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        Button {
                            selected = item
                            Haptics.soft()
                        } label: {
                            TradingCard(content: content(item), animated: index < 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("押すと大きく見られます")
                    }
                }
                if !context.isInside && context.opened && !graffiti.isEmpty {
                    Label("一度開けた GATE なので、遠くからも読めます。いいね・保存・返信は GATE の中で。", systemImage: "key.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(subInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                peekGrid
            }
            if let note {
                Text(note)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(onDark ? .white : Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error { NoticeText(text: error) }
        }
        .task(id: "\(context.isInside)-\(context.canRead)-\(refreshToken)") { await load() }
        .sheet(item: $selected) { item in
            detail(item)
        }
        .fullScreenCover(item: $peekViewing) { content in
            TradingCardViewer(content: content, isMine: content.badge == .mine) {
                if let card = context.peek?.cards.first(where: { $0.id == content.id }) {
                    report = ReportItem(id: card.id, target: .graffiti, userID: card.author,
                                        userName: card.author_name, label: "グラフィティカード")
                }
            }
        }
        .sheet(item: $report) { item in ReportSheet(item: item) }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("みんなのグラフィティカード")
                .font(.title3.weight(.heavy))
                .foregroundStyle(ink)
            Text(subtitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(subInk)
        }
    }

    private var subtitle: String {
        guard context.canRead else {
            return "GATE を開けると、ぜんぶ見られます"
        }
        if graffiti.isEmpty { return loaded ? "まだありません" : "読み込んでいます…" }
        var parts: [String] = []
        let friends = count(.friends)
        let mine = count(.mine)
        let others = graffiti.count - friends - mine
        if friends > 0 { parts.append("友達 \(friends) 枚") }
        if others > 0 { parts.append("訪れた人 \(others) 枚") }
        if mine > 0 { parts.append("あなた \(mine) 枚") }
        return parts.joined(separator: "・") + "・押すと大きく見られます"
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(WallFilter.allCases) { f in
                let selectedNow = filter == f
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { filter = f }
                    Haptics.tap()
                } label: {
                    Text("\(f.label) \(count(f))")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(selectedNow ? (onDark ? Color(hex: 0x1B1235) : .white) : ink)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 34)
                        .background(selectedNow ? AnyShapeStyle(onDark ? Color.white : Theme.accent)
                                                : AnyShapeStyle(onDark ? Color.white.opacity(0.14) : Theme.surfaceElevated),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(count(f) == 0 && f != .all)
                .opacity(count(f) == 0 && f != .all ? 0.5 : 1)
            }
            Spacer(minLength: 0)
        }
    }

    private var emptyNote: some View {
        Text(filter == .all
             ? (context.isInside ? "まだグラフィティカードはありません。最初の 1 枚を残しましょう。" : "まだグラフィティカードはありません。")
             : "ここに出るカードはまだありません。")
            .font(.subheadline)
            .foregroundStyle(subInk)
            .padding(.vertical, 8)
    }

    /// まだ扉を開けたことのない人へ：新しいカード（3 枚まで）と、鍵の札
    @ViewBuilder private var peekGrid: some View {
        let cards = context.peek?.cards ?? []
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 16) {
            ForEach(cards) { card in
                let content = TradingCardContent(id: card.id, photoPath: card.photo_path, body: card.body,
                                                 author: card.author_name, title: card.title, gateTitle: context.title,
                                                 createdAt: card.created_at, finish: CardFinish(raw: card.finish),
                                                 badge: card.author == session.userID ? .mine : .visitor)
                Button {
                    peekViewing = content
                } label: {
                    TradingCard(content: content, animated: false)
                }
                .buttonStyle(.plain)
            }
            WallLockCell(onDark: onDark, empty: cards.isEmpty)
        }
    }

    @ViewBuilder private func detail(_ item: Graffiti) -> some View {
        let isMine = item.author == session.userID
        CardDetailSheet(item: item, context: context, author: names[item.author] ?? "",
                        likeCount: likes[item.id]?.count ?? 0, liked: likes[item.id]?.mine ?? false,
                        commentCount: extras?[item.id]?.comments ?? 0, commentsOn: extras != nil,
                        saved: extras == nil ? nil : (extras?[item.id]?.saved ?? false),
                        linkNote: linkNote(for: item), canLink: canLink(to: item),
                        inAtlas: isMine && item.photo_path != nil && !item.local_only ? item.in_atlas : nil,
                        myCards: myCards.map(snapshot), others: otherCards.map(snapshot), snapshot: snapshot(item),
                        onLike: {
                            if context.isInside { Task { await toggleLike(item) } } else { insideOnly("いいね") }
                        },
                        onToggleSave: {
                            if context.isInside || extras?[item.id]?.saved == true {
                                Task { await toggleSave(item) }
                            } else {
                                insideOnly("保存")
                            }
                        },
                        onToggleAtlas: { Task { await toggleAtlas(item) } },
                        onDelete: {
                            selected = nil
                            Task { await delete(item) }
                        },
                        onChanged: { Task { await load() } },
                        onCommentCount: { count in
                            extras?[item.id, default: CardExtra(graffiti_id: item.id, comments: 0, saved: false)].comments = count
                        },
                        hint: note)
        .environmentObject(session)
    }

    // MARK: 動き

    private func insideOnly(_ what: String) {
        note = "\(what)は、現地で GATE を開けているあいだにできます。"
        Haptics.tap()
    }

    /// 「来たよ」を送れるか：GATE の中で、友達のカードに、自分のカードがあって、まだ送っていない
    private func canLink(to item: Graffiti) -> Bool {
        guard context.isInside, item.author != session.userID, friendIDs.contains(item.author), !myCards.isEmpty else { return false }
        return !links.contains { $0.to_card == item.id && $0.sender == session.userID }
    }

    private func linkNote(for item: Graffiti) -> String? {
        if item.author == session.userID {
            let from = links.filter { $0.to_card == item.id && $0.recipient == session.userID }
            guard let first = from.first else { return nil }
            let who = names[first.sender] ?? "友達"
            return from.count > 1 ? "\(who) さんたちが「来たよ」" : "\(who) さんが「来たよ」"
        }
        return links.contains { $0.to_card == item.id && $0.sender == session.userID } ? "「来たよ」を送りました" : nil
    }

    private func load() async {
        guard let api = session.api else { return }
        defer { loaded = true }
        do {
            let list = try await api.graffiti(in: context.gateID)
            // 読めないとき（まだ扉を開けていない）は、自分のカードだけが返る
            graffiti = context.canRead ? list : list.filter { $0.author == session.userID }
            names = try await api.names(of: Array(Set(graffiti.map(\.author))))
            if let me = session.userID, let r = try? await api.relations(me: me) {
                friendIDs = r.following.intersection(r.followers)
            }
            if let me = session.userID {
                likes = (try? await api.likes(for: graffiti.map(\.id), me: me)) ?? [:]
            }
            if let loaded = try? await api.cardExtras(in: context.gateID) {
                extras = loaded
            }
            links = (try? await api.cardLinks(in: context.gateID)) ?? []
            error = nil
            if let selectedID = selected?.id, let fresh = graffiti.first(where: { $0.id == selectedID }) {
                selected = fresh
            }
        } catch {
            self.error = ErrorText.of(error)
        }
    }

    private func toggleLike(_ item: Graffiti) async {
        guard let api = session.api, let me = session.userID else { return }
        let current = likes[item.id] ?? (0, false)
        let next = !current.mine
        likes[item.id] = (max(0, current.count + (next ? 1 : -1)), next)
        do {
            try await api.setLike(item.id, me: me, on: next)
            if next { Haptics.tap() }
        } catch {
            likes[item.id] = current
            note = ErrorText.of(error)
        }
    }

    /// 保存する・外す（先に見た目を変え、だめなら戻す）
    private func toggleSave(_ item: Graffiti) async {
        guard let api = session.api, extras != nil else { return }
        let was = extras?[item.id]?.saved ?? false
        extras?[item.id, default: CardExtra(graffiti_id: item.id, comments: 0, saved: false)].saved = !was
        Haptics.tap()
        do {
            try await api.saveCard(item.id, on: !was)
            Trace.log("カード：保存を\(was ? "外した" : "付けた")")
        } catch {
            extras?[item.id]?.saved = was
            note = ErrorText.of(error)
        }
    }

    private func toggleAtlas(_ item: Graffiti) async {
        guard let api = session.api else { return }
        let next = !(item.in_atlas ?? false)
        do {
            try await api.setGraffitiAtlas(item.id, on: next)
            if let i = graffiti.firstIndex(where: { $0.id == item.id }) { graffiti[i].in_atlas = next }
            note = next ? "友達のカード図鑑に載せました（写真・場所・日付。ひとことは現地だけ）。" : "カード図鑑から外しました。"
        } catch {
            note = ErrorText.isMissingFunction(error) ? "サーバーの準備がまだです（SQL を貼り直すと使えます）。" : ErrorText.of(error)
        }
    }

    private func delete(_ item: Graffiti) async {
        guard let api = session.api else { return }
        do {
            try await api.deleteGraffiti(item.id)
            if let path = item.photo_path { await session.media?.removePhoto(path: path) }
            Trace.log("カード：消した")
            await load()
        } catch {
            note = ErrorText.of(error)
        }
    }
}

/// 鍵の札（まだ扉を開けていない人に。カードと同じ大きさ）
private struct WallLockCell: View {
    let onDark: Bool
    let empty: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(onDark ? .white : Theme.accent)
            Text(empty ? "GATE を開けて、最初の 1 枚を" : "ほかのカードは、GATE を開けると見られます")
                .font(.footnote.weight(.bold))
                .foregroundStyle(onDark ? .white : Theme.text)
                .multilineTextAlignment(.center)
            Text("一度開ければ、遠くからも読めます")
                .font(.caption2)
                .foregroundStyle(onDark ? .white.opacity(0.7) : Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .aspectRatio(TradingCard.aspect, contentMode: .fit)
        .background(onDark ? AnyShapeStyle(Color.white.opacity(0.08)) : AnyShapeStyle(Theme.accentLight.opacity(0.6)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .foregroundStyle(onDark ? .white.opacity(0.35) : Theme.accent.opacity(0.4)))
    }
}

/// 1 枚を大きく見る（いいね・返信・保存・来たよ・見比べる・直す・送る・消す・通報）
struct CardDetailSheet: View {
    let item: Graffiti
    let context: GateContext
    let author: String
    let likeCount: Int
    let liked: Bool
    let commentCount: Int
    let commentsOn: Bool
    let saved: Bool?
    let linkNote: String?
    let canLink: Bool
    let inAtlas: Bool?
    let myCards: [CardSnapshot]
    let others: [CardSnapshot]
    let snapshot: CardSnapshot
    let onLike: () -> Void
    let onToggleSave: () -> Void
    let onToggleAtlas: () -> Void
    let onDelete: () -> Void
    let onChanged: () -> Void
    let onCommentCount: (Int) -> Void
    var hint: String?

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var commenting: Graffiti?
    @State private var editing: Graffiti?
    @State private var sending: Graffiti?
    @State private var linking: CardSnapshot?
    @State private var sharing: CardSnapshot?
    @State private var comparing: CardCompareRequest?
    @State private var report: ReportItem?
    @State private var message: String?

    private var isMine: Bool { item.author == session.userID }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GraffitiCard(item: item, author: author, isMine: isMine,
                                 likeCount: likeCount, liked: liked,
                                 onLike: onLike,
                                 onDelete: onDelete,
                                 onReport: {
                                     report = ReportItem(id: item.id, target: .graffiti, userID: item.author,
                                                         userName: author, label: "グラフィティカード")
                                 },
                                 onShare: isMine ? { sharing = snapshot } : nil,
                                 onCompare: (!isMine && !myCards.isEmpty) ? {
                                     comparing = CardCompareRequest(others: others, mine: myCards, start: item.id)
                                 } : nil,
                                 onCardLink: canLink ? { linking = snapshot } : nil,
                                 linkNote: linkNote,
                                 inAtlas: inAtlas,
                                 onToggleAtlas: onToggleAtlas,
                                 commentCount: commentCount,
                                 onComments: commentsOn ? { commenting = item } : nil,
                                 saved: saved,
                                 onToggleSave: onToggleSave,
                                 onEdit: isMine ? { editing = item } : nil,
                                 onSendToFriend: isMine ? { sending = item } : nil,
                                 gateTitle: context.title)
                    if let text = message ?? hint {
                        NoticeText(text: text, isError: false)
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("グラフィティカード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
        .sheet(item: $commenting) { card in
            CardCommentsSheet(card: card, authorName: author,
                              canWrite: context.isInside || card.author == session.userID) { count in
                onCommentCount(count)
            }
            .environmentObject(session)
        }
        .sheet(item: $editing) { card in
            GraffitiEditSheet(item: card) { onChanged() }
                .environmentObject(session)
        }
        .sheet(item: $sending) { card in
            SendCardSheet(card: card, gateTitle: context.title) { text in message = text }
                .environmentObject(session)
        }
        .sheet(item: $linking) { card in
            CardLinkComposer(friendCard: card, myCards: myCards) { onChanged() }
                .environmentObject(session)
        }
        .sheet(item: $sharing) { card in
            CardShareSheet(card: card).environmentObject(session)
        }
        .sheet(item: $comparing) { request in
            CardCompareView(request: request).environmentObject(session)
        }
        .sheet(item: $report) { item in ReportSheet(item: item) }
    }
}
