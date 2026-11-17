import MapKit
import SwiftUI

/// プロフィールの下の「作った GATE・グラフィティ・訪れた」。
/// 作った GATE はサーバーが見せてよいものだけ（位置はおおよそ）。グラフィティは本人がカード図鑑に載せたカードの写真・場所・日付
/// （ひとことの文は現地だけ）。訪れたは本人が見せると選んだカード図鑑。中身はどれも現地で扉を開けた人だけ。
struct FriendWorks: View {
    let userID: UUID
    let name: String
    let isFriend: Bool
    let isMe: Bool

    @EnvironmentObject private var session: SessionModel
    @State private var tab: Tab = .gates
    @State private var gates: [UserGate] = []
    @State private var cards: [AtlasCard] = []
    @State private var visited: [FriendAtlasGate] = []
    @State private var trails: [TrailSummary] = []
    @State private var loaded = false
    @State private var unsupported = false
    /// 地図の印から開く GATE（印の中から直接画面を開くと、アプリ全体の情報が届かず落ちることがある）
    @State private var openGate: UUID?
    /// 地図の縮尺（近い印をまとめる）と、重ねた印から選ぶ一覧
    @State private var metersPerPoint: Double?
    @State private var stack: PinStack?

    enum Tab: String, CaseIterable, Identifiable {
        case gates = "GATE"
        case cards = "カード図鑑"
        case trails = "TRAIL"
        case visited = "訪れた GATE"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("見るもの", selection: $tab) {
                ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)

            switch tab {
            case .gates: gatesView
            case .cards: cardsView
            case .trails: trailsView
            case .visited: visitedView
            }
        }
        .task(id: userID) { await load() }
    }

    // MARK: 作った TRAIL（見てよいものだけ。地点の中身は現地で）

    @ViewBuilder private var trailsView: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
        } else if trails.isEmpty {
            Text(isMe ? "まだ TRAIL を作っていません。扉を開けた GATE が 2 つ以上あれば、TRAIL を作れます。"
                      : "\(name)さんが見せている TRAIL はまだありません。")
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("GATE をつないだ「思い出を歩く道」。順番に現地で扉を開けると進みます。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            ForEach(trails) { trail in
                NavigationLink {
                    TrailDetailView(trailID: trail.id, title: trail.title)
                } label: {
                    TrailCard(trail: trail)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 作った GATE（地図と一覧）

    @ViewBuilder private var gatesView: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
        } else if gates.isEmpty {
            note(unsupported ? "サーバーの準備がまだです（SQL を貼り直すと見られます）。"
                             : (isMe ? "まだ GATE を作っていません。" : "\(name) さんが見せている GATE はまだありません。"))
        } else {
            let pins = gates.map {
                MapPinItem(id: $0.id, title: $0.title, cover: $0.cover_path, coordinate: $0.coordinate,
                           mine: isMe, ownerName: name)
            }
            let mpp = metersPerPoint
                ?? MapFraming.region(gates.map(\.coordinate)).map { MapClusters.metersPerPoint($0, height: 230) } ?? 2
            MapReader { proxy in
            Map(initialPosition: MapFraming.position(gates.map(\.coordinate))) {
                // 同じ・近い所の GATE は 1 つの「重ねた印」にまとめる（押すと一覧）
                ForEach(MapClusters.group(pins, metersPerPoint: mpp)) { cluster in
                    Annotation(cluster.items[0].title, coordinate: cluster.coordinate, anchor: .bottom) {
                        Button {
                            if cluster.isSingle {
                                openGate = cluster.items[0].id
                            } else {
                                stack = PinStack(items: cluster.items)
                            }
                        } label: {
                            if cluster.isSingle {
                                GatePin(mine: isMe, coverPath: cluster.items[0].cover, ownerName: name, showsName: false)
                            } else {
                                GateStackPin(cluster: cluster)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(.hidden)
                }
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                metersPerPoint = MapClusters.metersPerPoint(proxy, region: context.region, height: 230)
            }
            }
            // 印は場所の上に立つので、上に余白をとって地図に収める（左上の札にも重ならないように）
            .safeAreaPadding(EdgeInsets(top: 72, leading: 28, bottom: 12, trailing: 28))
            .id(gates.map(\.id))
            .frame(height: 230)
            .navigationDestination(item: $openGate) { id in
                GateDetailView(gateID: id)
            }
            .gateStackSheet($stack, open: $openGate)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line))
            .overlay(alignment: .topLeading) {
                Text("位置はおおよそ（約 100m）")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
            ForEach(gates) { gate in
                NavigationLink {
                    GateDetailView(gateID: gate.id)
                } label: {
                    HStack(spacing: 12) {
                        GateCoverImage(path: gate.cover_path, markSize: 26)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(gate.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                Image(systemName: GateKind(raw: gate.kind).symbol)
                                    .font(.caption2.weight(.bold)).foregroundStyle(Theme.accent)
                            }
                            Label(GateDates.shortText(gate.created_at), systemImage: "calendar")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                            PlaceNameText(lat: gate.approx_lat, lon: gate.approx_lon)
                        }
                        Spacer(minLength: 0)
                        Text("\(gate.graffiti_count) 枚")
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.line))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: グラフィティカード図鑑（写真・場所・日付）

    @ViewBuilder private var cardsView: some View {
        if !isFriend && !isMe {
            note("お互いにフォローすると、\(name) さんがカード図鑑に載せたグラフィティの写真が見られます。")
        } else if !loaded {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
        } else if cards.isEmpty {
            note(isMe ? "写真つきのカードを残すと、ここに並びます。友達に見せるかは、カードごとに「カード図鑑に載せる」で選べます。"
                      : "\(name) さんがカード図鑑に載せたカードはまだありません。")
        } else {
            Text(isMe ? "友達には、「カード図鑑に載せる」を選んだカードだけが見えます。ひとことの文は現地だけです。"
                      : "ひとことの文は、現地で扉を開けると読めます。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(cards) { card in
                    NavigationLink {
                        GateDetailView(gateID: card.gate_id)
                    } label: {
                        AtlasCardTile(card: card)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: 訪れた（本人が見せると選んだカード図鑑）

    @ViewBuilder private var visitedView: some View {
        if !isFriend && !isMe {
            note("お互いにフォローすると、\(name) さんが見せると選んだ「訪れた GATE」が見られます。")
        } else if !loaded {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
        } else if visited.isEmpty {
            note(isMe ? "「わたし」→「訪れた GATE」で、友達に見せる GATE を選べます。" : "見せている GATE はまだありません。")
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(visited) { gate in
                    NavigationLink {
                        GateDetailView(gateID: gate.gate_id)
                    } label: {
                        MemoryTile(title: gate.title, subtitle: "\(gate.visits) 回・\(GateDates.shortText(gate.first_at))",
                                   cover: gate.cover_path)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            gates = try await api.userGates(userID)
        } catch {
            unsupported = ErrorText.isMissingFunction(error)
            gates = []
        }
        if isFriend || isMe {
            cards = (try? await api.userCardAtlas(userID)) ?? []
            visited = isMe ? [] : ((try? await api.friendAtlas(userID)) ?? [])
        }
        // TRAIL は全員に公開したものなら友達でなくても見える（判定はサーバー）
        trails = (try? await api.userTrails(userID)) ?? []
        loaded = true
    }
}

/// グラフィティカード図鑑の 1 枚：写真に GATE の名前と日付・場所を重ねる
struct AtlasCardTile: View {
    let card: AtlasCard

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RemotePhoto(path: card.photo_path)
                .aspectRatio(3 / 4, contentMode: .fit)
                .frame(maxWidth: .infinity)
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.gate_title).font(.caption.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                Text(GateDates.shortText(card.created_at)).font(.caption2).foregroundStyle(.white.opacity(0.85))
                PlaceNameText(lat: card.approx_lat, lon: card.approx_lon, font: .caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .environment(\.colorScheme, .dark)
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
    }
}
