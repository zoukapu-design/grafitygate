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
        if !week.isEmpty { return Pick(headline: "1 週間前", items: Array(sorted(week).prefix(6))) }
        return nil
    }

    /// 写真のあるものを先に、同じ GATE は 1 つに
    private static func sorted(_ items: [Item]) -> [Item] {
        var seen = Set<UUID>()
        return items.sorted { ($0.photoPath != nil ? 0 : 1, $0.date) < ($1.photoPath != nil ? 0 : 1, $1.date) }
            .filter { seen.insert($0.gateID).inserted }
    }
}

/// わたしの画面の「あの日」：同じころに作った GATE・残したカード。押すとその GATE へ
struct OnThisDayCard: View {
    let pick: OnThisDay.Pick

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.warm)
                VStack(alignment: .leading, spacing: 1) {
                    Text("あの日").font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                    Text(pick.headline).font(.caption.weight(.semibold)).foregroundStyle(Theme.warm)
                }
                Spacer()
            }
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
        .padding(16)
        .background(
            LinearGradient(colors: [Theme.warm.opacity(0.14), Theme.accentLight.opacity(0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Theme.radiusCard)
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.warm.opacity(0.25)))
    }

    private func tile(_ item: OnThisDay.Item) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let path = item.photoPath {
                    RemotePhoto(path: path)
                } else {
                    ZStack {
                        Theme.surfaceElevated
                        GateMark(size: 44, glowing: false)
                    }
                }
            }
            .frame(width: 132, height: 168)
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.isGate ? "GATE を作った" : "カードを残した")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                Text(item.title).font(.caption.weight(.bold)).foregroundStyle(.white).lineLimit(2)
                Text(GateDates.full.string(from: item.date).components(separatedBy: "（").first ?? "")
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

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("GATE の中で 🔖 を押したカードです。写真・場所・日付はいつでも、ひとことは現地で読めます。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                if let message { NoticeText(text: message) }
                if loaded && cards.isEmpty && message == nil {
                    EmptyNote(title: "まだお気に入りはありません",
                              message: "GATE の中のカードの 🔖 を押すと、ここに集まります。",
                              systemImage: "bookmark")
                }
                LazyVGrid(columns: columns, spacing: 10) {
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
                                Label("お気に入りから外す", systemImage: "bookmark.slash")
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("お気に入りのカード")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func tile(_ card: SavedCard) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let path = card.photo_path {
                    RemotePhoto(path: path)
                } else {
                    ZStack {
                        LinearGradient(colors: [Theme.accentLight, Theme.surface], startPoint: .top, endPoint: .bottom)
                        VStack(spacing: 6) {
                            Image(systemName: "text.quote").font(.title3).foregroundStyle(Theme.accent)
                            Text(card.body ?? "ひとことは現地で")
                                .font(.caption)
                                .foregroundStyle(Theme.text)
                                .multilineTextAlignment(.center)
                                .lineLimit(4)
                                .padding(.horizontal, 10)
                        }
                    }
                }
            }
            .aspectRatio(3 / 4, contentMode: .fit)
            .frame(maxWidth: .infinity)
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.gate_title).font(.caption.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                Text("\(card.mine ? "あなた" : card.author_name)・\(GateDates.shortText(card.created_at))")
                    .font(.caption2).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                PlaceNameText(lat: card.approx_lat, lon: card.approx_lon, font: .caption2)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            Image(systemName: "bookmark.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(6)
                .background(Theme.warm, in: Circle())
                .padding(8)
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            cards = try await api.mySavedCards()
            message = nil
        } catch {
            message = ErrorText.isMissingFunction(error)
                ? "お気に入りは、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
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
                        LabeledContent("来た回数", value: "\(days.count) 回")
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
            .navigationTitle("あなたが来た日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .safeAreaInset(edge: .top) {
                Text("「\(title)」に扉を開けて入った日です。見られるのはあなただけです。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.background)
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
                ? "来た日の一覧は、サーバーの準備（setup_all.sql の貼り直し）のあとで見られます。" : ErrorText.of(error)
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
        NotifyGroup(id: "gate", title: "自分の GATE に記憶・作品", detail: "あなたの GATE に、だれかがカードや AR の作品を残したとき",
              symbol: "square.stack", kinds: ["gate_graffiti", "gate_artwork"]),
        NotifyGroup(id: "cards", title: "カードへの返信・来たよ", detail: "あなたのカードに返信や「来たよ」が届いたとき",
              symbol: "bubble.left", kinds: ["card_comment", "card_link"]),
        NotifyGroup(id: "like", title: "いいね", detail: "あなたのカードにいいねが付いたとき", symbol: "heart", kinds: ["like"]),
        NotifyGroup(id: "board", title: "掲示板", detail: "あなたの GATE に話題が立った・あなたの話題に返信があったとき",
              symbol: "bubble.left.and.bubble.right", kinds: ["board_thread", "board_reply"]),
        NotifyGroup(id: "letters", title: "手紙", detail: "手紙が届いた・あなたの手紙が開かれたとき",
              symbol: "envelope", kinds: ["letter", "letter_opened"]),
        NotifyGroup(id: "memories", title: "思い出", detail: "思い出の仲間に入った・写真が足されたとき",
              symbol: "photo.stack", kinds: ["memory_invite", "memory_photo"]),
        NotifyGroup(id: "managers", title: "一緒に管理", detail: "友達があなたを GATE の「一緒に管理する人」に入れたとき",
                    symbol: "person.2.badge.gearshape", kinds: ["gate_manager"]),
        NotifyGroup(id: "maps", title: "場所の記憶の撮り直し", detail: "あなたの GATE が、ほかの人の iPhone で見つかりにくくなったとき",
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
            } footer: {
                Text("切った種類のお知らせは、あとから入れ直しても届きません（切っているあいだのものは作られません）。メッセージの未読は、ここでは止まりません。")
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
