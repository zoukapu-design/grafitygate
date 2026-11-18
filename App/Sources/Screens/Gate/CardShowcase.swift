import SwiftUI

// GATE の画面のいちばん上に並べる「みんなのグラフィティカード」（2026-11-18 オーナー
// 「ゲートの最初の画面に、フォロワーや他に訪れた人のカードが表示されて、惹きつけるキャッチーな画面に」）。
// 友達のカード → ほかに訪れた人のカード → 自分のカードの順に、トレーディングカードの形で横に並べる。
// 読めない人（まだ扉を開けたことがない）には、サーバーが見せてよい新しい 3 枚（チラ見せ）と、鍵の札。

struct GateCardShowcase: View {
    let context: GateContext
    let refreshToken: Int
    /// 夜空の上（扉の中）か、白い画面の上（グラフィティボード）か
    var onDark = false
    let onReport: (ReportItem) -> Void
    /// 扉の中で「自分の 1 枚を作る」を押したとき
    var onMake: (() -> Void)?

    /// 並べるカードの大きさ（横に流す欄では高さを決めないと、カードが小さくつぶれる）
    static let cardWidth: CGFloat = 188
    static var cardHeight: CGFloat { cardWidth / TradingCard.aspect }

    @EnvironmentObject private var session: SessionModel
    @State private var cards: [TradingCardContent] = []
    @State private var authors: [UUID: UUID] = [:]
    @State private var friendCount = 0
    @State private var visitorCount = 0
    @State private var opened: TradingCardContent?
    @State private var loaded = false

    private var titleColor: Color { onDark ? .white : Theme.text }
    private var subColor: Color { onDark ? .white.opacity(0.7) : Theme.textSecondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("みんなのグラフィティカード")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(titleColor)
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(subColor)
            }
            .padding(.horizontal, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if context.isInside, let onMake {
                        MakeCardSlot(onDark: onDark, action: onMake)
                    }
                    ForEach(shown) { card in
                        Button {
                            opened = card
                        } label: {
                            TradingCard(content: card)
                                .frame(width: Self.cardWidth, height: Self.cardHeight)
                        }
                        .buttonStyle(.plain)
                        .scrollTransition(.interactive, axis: .horizontal) { view, phase in
                            view
                                .scaleEffect(phase.isIdentity ? 1 : 0.9)
                                .rotation3DEffect(.degrees(phase.value * -14), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                        }
                    }
                    if !context.canRead {
                        LockedCardSlot(onDark: onDark, hasCards: !shown.isEmpty)
                    } else if cards.isEmpty && loaded && !context.isInside {
                        EmptyCardSlot(onDark: onDark)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 10)
            }
            .scrollClipDisabled()
        }
        .task(id: "\(context.canRead)-\(context.isInside)-\(refreshToken)-\(context.peek?.cards.count ?? -1)") { await load() }
        .fullScreenCover(item: $opened) { card in
            TradingCardViewer(content: card, isMine: card.badge == .mine) {
                onReport(ReportItem(id: card.id, target: .graffiti, userID: authors[card.id],
                                    userName: card.author, label: "グラフィティカード"))
            }
        }
    }

    /// 並べるカード（まだ読めない人には、サーバーが見せてよいチラ見せの 3 枚。GATE の画面があとから受け取るので、ここで作る）
    private var shown: [TradingCardContent] {
        guard !context.canRead else { return cards }
        let me = session.userID
        return (context.peek?.cards ?? []).map {
            TradingCardContent(id: $0.id, photoPath: $0.photo_path, body: $0.body, author: $0.author_name,
                               title: $0.title, gateTitle: context.title, createdAt: $0.created_at,
                               finish: CardFinish(raw: $0.finish),
                               badge: $0.author == me ? .mine : .visitor)
        }
    }

    private var subtitle: String {
        if !context.canRead {
            let cards = shown
            return cards.isEmpty ? "扉を開けると、ここに残されたカードが見られます" : "新しい \(cards.count) 枚をチラ見せ。扉を開けると全部見られます"
        }
        var parts: [String] = []
        if friendCount > 0 { parts.append("友達 \(friendCount) 枚") }
        if visitorCount > 0 { parts.append("訪れた人 \(visitorCount) 枚") }
        return parts.isEmpty ? (cards.isEmpty ? "まだカードはありません" : "あなたのカード") : parts.joined(separator: "・")
    }

    private func load() async {
        defer { loaded = true }
        guard let api = session.api else { return }
        let me = session.userID
        if !context.canRead {
            // チラ見せは shown がその場で作る（通報のときの「だれのものか」だけ覚えておく）
            authors = Dictionary(uniqueKeysWithValues: (context.peek?.cards ?? []).map { ($0.id, $0.author) })
            return
        }
        guard let list = try? await api.graffiti(in: context.gateID) else { return }
        let names = (try? await api.names(of: Array(Set(list.map(\.author))))) ?? [:]
        var friends: Set<UUID> = []
        if let me, let r = try? await api.relations(me: me) { friends = r.following.intersection(r.followers) }
        var liked: [UUID: (count: Int, mine: Bool)] = [:]
        if let me { liked = (try? await api.likes(for: list.map(\.id), me: me)) ?? [:] }
        func rank(_ g: Graffiti) -> Int {
            if g.author == me { return 2 }
            return friends.contains(g.author) ? 0 : 1
        }
        let sorted = list.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.created_at > b.created_at
        }.prefix(15)
        cards = sorted.map { g in
            let badge: TradingCardContent.Badge = g.author == me ? .mine : (friends.contains(g.author) ? .friend : .visitor)
            let name = g.author == me ? (session.profile?.display_name ?? "あなた") : (names[g.author] ?? "")
            return TradingCardContent(id: g.id, photoPath: g.photo_path, body: g.body, author: name, title: g.title,
                                      gateTitle: context.title, createdAt: g.created_at,
                                      likes: liked[g.id]?.count ?? 0, finish: CardFinish(raw: g.finish), badge: badge)
        }
        authors = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0.author) })
        friendCount = list.filter { $0.author != me && friends.contains($0.author) }.count
        visitorCount = list.filter { $0.author != me && !friends.contains($0.author) }.count
        Trace.log("みんなのカード：友達 \(friendCount)・訪れた人 \(visitorCount)・並べた \(cards.count) 枚")
    }
}

/// 扉の中の「自分の 1 枚を作る」の札（カードと同じ形の、点線の枠）
private struct MakeCardSlot: View {
    let onDark: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Theme.neonBand, in: Circle())
                    .shadow(color: Color(hex: 0xFF3D7F).opacity(0.5), radius: 12)
                Text("あなたの 1 枚を\n作る")
                    .font(.headline.weight(.heavy))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(onDark ? .white : Theme.text)
                Text("その場の写真と\nひとことで")
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(onDark ? .white.opacity(0.7) : Theme.textSecondary)
            }
            .frame(width: GateCardShowcase.cardWidth, height: GateCardShowcase.cardHeight)
            .background((onDark ? Color.white.opacity(0.08) : Theme.accentLight),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                .foregroundStyle(onDark ? .white.opacity(0.5) : Theme.accent.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("グラフィティカードを作る")
    }
}

/// まだ扉を開けたことがない人への鍵の札
private struct LockedCardSlot: View {
    let onDark: Bool
    let hasCards: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(GateCoverImage.nightSky, in: Circle())
            Text(hasCards ? "ほかのカードは\n扉の向こう" : "カードは\n扉の向こう")
                .font(.headline.weight(.heavy))
                .multilineTextAlignment(.center)
                .foregroundStyle(onDark ? .white : Theme.text)
            Text("現地で扉を開けると\n全部見られます")
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(onDark ? .white.opacity(0.7) : Theme.textSecondary)
        }
        .frame(width: GateCardShowcase.cardWidth, height: GateCardShowcase.cardHeight)
        .background(onDark ? Color.white.opacity(0.08) : Theme.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(onDark ? Color.white.opacity(0.25) : Theme.line, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
    }
}

/// 読めるけれど、まだだれも残していないとき
private struct EmptyCardSlot: View {
    let onDark: Bool

    var body: some View {
        VStack(spacing: 10) {
            GateMark(size: 56, glowing: true)
            Text("まだカードは\nありません")
                .font(.headline.weight(.heavy))
                .multilineTextAlignment(.center)
                .foregroundStyle(onDark ? .white : Theme.text)
            Text("扉を開けて、最初の 1 枚を")
                .font(.caption.weight(.semibold))
                .foregroundStyle(onDark ? .white.opacity(0.7) : Theme.textSecondary)
        }
        .frame(width: GateCardShowcase.cardWidth, height: GateCardShowcase.cardHeight)
        .background(onDark ? Color.white.opacity(0.08) : Theme.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// AR カメラで撮った写真を、GATE の画面のカード作りへ渡す（端末の中だけ）
@MainActor
final class CardPhotoInbox: ObservableObject {
    static let shared = CardPhotoInbox()
    @Published private(set) var pending: (gate: UUID, image: UIImage)?

    func put(_ image: UIImage, gate: UUID) {
        pending = (gate, image)
        Trace.log("カードの写真：AR カメラの写真を預かった")
    }

    /// その GATE の写真があれば受け取る（受け取ったら空にする）
    func take(for gate: UUID) -> UIImage? {
        guard let p = pending, p.gate == gate else { return nil }
        pending = nil
        return p.image
    }

    func has(for gate: UUID) -> Bool { pending?.gate == gate }
}
