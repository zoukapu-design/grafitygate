import SwiftUI

// MARK: - あの日（1 年前・1 か月前・1 週間前の今ごろに、自分が作った GATE・残したカード）

/// 「あの日」の中身。自分の GATE と、自分のカード（写真つき）から、いまと同じころの記録を選ぶ（iPhone の中だけで決める）
enum OnThisDay {
    struct Item: Identifiable, Hashable {
        let id: UUID
        let gateID: UUID
        let title: String
        let photoPath: String?
        let date: Date
        /// GATE を作った／カードを残した
        let isGate: Bool
    }

    struct Pick: Hashable {
        let headline: String
        let items: [Item]
    }

    static func pick(gates: [MyGate], cards: [AtlasCard], now: Date = Date()) -> Pick? {
        var all: [Item] = []
        for g in gates {
            guard let d = ServerDate.parse(g.created_at) else { continue }
            all.append(Item(id: g.id, gateID: g.id, title: g.title, photoPath: g.cover_path, date: d, isGate: true))
        }
        for c in cards {
            guard let d = ServerDate.parse(c.created_at) else { continue }
            all.append(Item(id: c.id, gateID: c.gate_id, title: c.gate_title, photoPath: c.photo_path, date: d, isGate: false))
        }
        guard !all.isEmpty else { return nil }
        let cal = Calendar.current
        func days(_ a: Date, _ b: Date) -> Int {
            abs(cal.dateComponents([.day], from: cal.startOfDay(for: a), to: cal.startOfDay(for: b)).day ?? 999)
        }
        func matches(_ unit: Calendar.Component, _ n: Int, within: Int) -> [Item] {
            all.filter { item in
                guard let then = cal.date(byAdding: unit, value: n, to: item.date) else { return false }
                return days(then, now) <= within
            }
        }
        for years in 1...10 {
            let hit = matches(.year, years, within: 3)
            if !hit.isEmpty { return Pick(headline: "\(years) 年前の今ごろ", items: Array(sorted(hit).prefix(6))) }
        }
        for months in 1...11 {
            let hit = matches(.month, months, within: 2)
            if !hit.isEmpty { return Pick(headline: "\(months) か月前の今ごろ", items: Array(sorted(hit).prefix(6))) }
        }
        let week = matches(.day, 7, within: 1)
        if !week.isEmpty { return Pick(headline: "1 週間前の今日", items: Array(sorted(week).prefix(6))) }
        return nil
    }

    /// 写真のあるものを先に、同じ GATE は 1 つに
    private static func sorted(_ items: [Item]) -> [Item] {
        var seen = Set<UUID>()
        return items.sorted { ($0.photoPath != nil ? 0 : 1, $0.date) < ($1.photoPath != nil ? 0 : 1, $1.date) }
            .filter { seen.insert($0.gateID).inserted }
    }
}

/// わたしの画面の「あの日」：同じころに作った GATE・残したカード。押すとその GATE へ。
/// 2026-11-21 オーナー「あの日というのは何の機能？よくわからず」：見出しを「1 週間前の今日」など、いつの何かがそのまま
/// 分かる言葉にし、1 つだけのときは「「○○」の GATE を作りました」と横長の 1 枚で見せる（前は小さな札が 1 枚と空白）
struct OnThisDayCard: View {
    let pick: OnThisDay.Pick

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pick.items.count == 1, let item = pick.items.first {
                NavigationLink {
                    GateDetailView(gateID: item.gateID)
                } label: {
                    single(item)
                }
                .buttonStyle(.plain)
            } else {
                header(subtitle: "あなたの記録が \(pick.items.count) つあります")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(pick.items) { item in
                            NavigationLink {
                                GateDetailView(gateID: item.gateID)
                            } label: {
                                tile(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Theme.warm.opacity(0.14), Theme.accentLight.opacity(0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Theme.radiusCard)
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.warm.opacity(0.25)))
    }

    private func header(subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.warm, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(pick.headline).font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.footnote.weight(.semibold)).foregroundStyle(Theme.warm)
            }
            Spacer()
        }
    }

    private static func what(_ item: OnThisDay.Item) -> String {
        item.isGate ? "「\(item.title)」の GATE を作りました" : "「\(item.title)」にカードを残しました"
    }

    private static func day(_ date: Date) -> String {
        GateDates.full.string(from: date).components(separatedBy: "（").first ?? ""
    }

    /// 1 つだけのとき：写真と「何をした日か」を横長に
    private func single(_ item: OnThisDay.Item) -> some View {
        HStack(spacing: 14) {
            photo(item)
                .frame(width: 96, height: 124)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .rotationEffect(.degrees(-3))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.warm)
                    Text(pick.headline).font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                }
                Text(Self.what(item))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.day(item.date)).font(.caption).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 4) {
                    Text("見に行く")
                    Image(systemName: "chevron.right")
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private func photo(_ item: OnThisDay.Item) -> some View {
        if let path = item.photoPath {
            Color.clear.overlay { RemotePhoto(path: path) }
        } else {
            ZStack {
                Theme.surfaceElevated
                GateMark(size: 44, glowing: false)
            }
        }
    }

    private func tile(_ item: OnThisDay.Item) -> some View {
        ZStack(alignment: .bottomLeading) {
            photo(item)
                .frame(width: 132, height: 168)
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.isGate ? "GATE を作った" : "カードを残した")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                Text(item.title).font(.caption.weight(.bold)).foregroundStyle(.white).lineLimit(2)
                Text(Self.day(item.date))
                    .font(.caption2).foregroundStyle(.white.opacity(0.85))
            }
            .padding(10)
        }
        .frame(width: 132, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - お気に入りにしたカード

/// お気に入りにしたカード：写真・GATE・場所・日付（文は自分のカードだけ。ほかの人の文は現地で）
struct SavedCardsView: View {
    @EnvironmentObject private var session: SessionModel
    @State private var cards: [SavedCard] = []
    @State private var loaded = false
    @State private var message: String?

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let message { NoticeText(text: message) }
                if loaded && cards.isEmpty && message == nil {
                    EmptyNote(title: "まだ保存したカードはありません",
                              message: "GATE の中のカードの 🔖 を押すと、ここに集まります。",
                              systemImage: "bookmark")
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(cards) { card in
                        NavigationLink {
                            GateDetailView(gateID: card.gate_id)
                        } label: {
                            tile(card)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                Task { await remove(card) }
                            } label: {
                                Label("保存をやめる", systemImage: "bookmark.slash")
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("保存したグラフィティカード")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    /// トレーディングカードの形（ひとことが読めないときは鍵の案内）と、その下に場所
    private func tile(_ card: SavedCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TradingCard(content: card.tradingContent, animated: false)
            HStack(spacing: 4) {
                Image(systemName: "bookmark.fill").foregroundStyle(Theme.warm)
                PlaceNameText(lat: card.approx_lat, lon: card.approx_lon, font: .caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .font(.caption2)
            .padding(.horizontal, 4)
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            cards = try await api.mySavedCards()
            message = nil
        } catch {
            message = ErrorText.isMissingFunction(error)
                ? "カードの保存は、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
        loaded = true
    }

    private func remove(_ card: SavedCard) async {
        guard let api = session.api else { return }
        do {
            try await api.saveCard(card.id, on: false)
            cards.removeAll { $0.id == card.id }
        } catch {
            message = ErrorText.of(error)
        }
    }
}

// MARK: - 自分がこの GATE に来た日

struct MyVisitsSheet: View {
    let gateID: UUID
    let title: String

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var days: [Date] = []
    @State private var loaded = false
    @State private var message: String?

    /// 年ごと（新しい年から）
    private var byYear: [(year: Int, days: [Date])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: days) { cal.component(.year, from: $0) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let first = days.last, let last = days.first {
                    Section {
                        LabeledContent("訪れた回数", value: "\(days.count) 回")
                        LabeledContent("はじめて", value: GateDates.full.string(from: first))
                        if days.count > 1 {
                            LabeledContent("前回", value: GateDates.full.string(from: last))
                        }
                    }
                }
                ForEach(byYear, id: \.year) { group in
                    Section("\(group.year) 年") {
                        ForEach(group.days, id: \.self) { day in
                            Label(GateDates.full.string(from: day), systemImage: "door.left.hand.open")
                                .font(.subheadline)
                        }
                    }
                }
                if loaded && days.isEmpty {
                    Text(message ?? "まだこの GATE に入った記録はありません。")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
            }
            .navigationTitle("あなたが訪れた日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .safeAreaInset(edge: .top) {
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            days = try await api.myVisitHistory(gateID)
            message = nil
        } catch {
            message = ErrorText.isMissingFunction(error)
                ? "訪れた日の一覧は、サーバーの準備（setup_all.sql の貼り直し）のあとで見られます。" : ErrorText.of(error)
        }
        loaded = true
    }
}

// MARK: - お知らせの設定

/// 種類ごとにお知らせを止める（止めた種類はサーバーが作らない）。DM の未読は別。
struct NotificationSettingsView: View {
    @EnvironmentObject private var session: SessionModel
    @State private var muted: Set<String> = []
    @State private var loaded = false
    @State private var unsupported = false
    @State private var message: String?

    struct NotifyGroup: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let kinds: [String]
    }

    static let groups: [NotifyGroup] = [
        NotifyGroup(id: "gate", title: "自分の GATE にグラフィティカード・AR の飾り", detail: "あなたの GATE に、だれかがカードや AR の飾りを残したとき",
              symbol: "square.stack", kinds: ["gate_graffiti", "gate_artwork"]),
        NotifyGroup(id: "cards", title: "グラフィティカードへの返信・来たよ", detail: "あなたのグラフィティカードに返信や「来たよ」が届いたとき",
              symbol: "bubble.left", kinds: ["card_comment", "card_link"]),
        NotifyGroup(id: "like", title: "いいね", detail: "あなたのグラフィティカードにいいねが付いたとき", symbol: "heart", kinds: ["like"]),
        NotifyGroup(id: "board", title: "掲示板", detail: "あなたの GATE に話題が立った・あなたの話題に返信があったとき",
              symbol: "bubble.left.and.bubble.right", kinds: ["board_thread", "board_reply"]),
        NotifyGroup(id: "letters", title: "手紙", detail: "手紙が届いた・あなたの手紙が開かれたとき",
              symbol: "envelope", kinds: ["letter", "letter_opened"]),
        NotifyGroup(id: "memories", title: "アルバム", detail: "アルバムの仲間に入った・写真が足されたとき",
              symbol: "photo.stack", kinds: ["memory_invite", "memory_photo"]),
        NotifyGroup(id: "managers", title: "一緒に管理", detail: "友達があなたを GATE の「一緒に管理する人」に入れたとき",
                    symbol: "person.2.badge.gearshape", kinds: ["gate_manager"]),
        NotifyGroup(id: "maps", title: "GATE の位置の記録の撮り直し", detail: "あなたの GATE が、ほかの人の iPhone で見つかりにくくなったとき",
              symbol: "arrow.triangle.2.circlepath.camera", kinds: ["place_map_stale"]),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.groups) { group in
                    Toggle(isOn: binding(for: group)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title).font(.subheadline.weight(.semibold))
                                Text(group.detail).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        } icon: {
                            Image(systemName: group.symbol).foregroundStyle(Theme.accent)
                        }
                    }
                    .tint(Theme.accent)
                    .disabled(!loaded || unsupported)
                }
            }
            if let message {
                Section { NoticeText(text: message) }
            }
        }
        .navigationTitle("お知らせ")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func binding(for group: NotifyGroup) -> Binding<Bool> {
        Binding {
            !group.kinds.allSatisfy { muted.contains($0) }
        } set: { on in
            Task { await set(group, on: on) }
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            muted = try await api.notifyMutes()
            message = nil
        } catch {
            unsupported = ErrorText.isMissingFunction(error)
            message = unsupported
                ? "お知らせの設定は、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
        loaded = true
    }

    private func set(_ group: NotifyGroup, on: Bool) async {
        guard let api = session.api else { return }
        let before = muted
        if on { muted.subtract(group.kinds) } else { muted.formUnion(group.kinds) }
        do {
            muted = try await api.setNotifyMute(group.kinds, muted: !on)
            Trace.log("お知らせの設定：\(group.id) を\(on ? "入れた" : "切った")")
        } catch {
            muted = before
            message = ErrorText.of(error)
        }
    }
}
