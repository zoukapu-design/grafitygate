import SwiftUI

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
