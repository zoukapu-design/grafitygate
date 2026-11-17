import MapKit
import SwiftUI

/// 自分の GATE を見返す：上に全部の GATE の地図（正確な位置）、下に月ごとの「いつ・どこで」の一覧。
/// 地図の印を押すと、その GATE のカードが出る。カードや一覧を押すと GATE の画面。
struct MyGatesView: View {
    let gates: [MyGate]

    @State private var selected: UUID?
    @State private var position: MapCameraPosition
    /// 地図の縮尺（近い印をまとめる）と、重ねた印から選ぶ一覧
    @State private var metersPerPoint: Double
    @State private var stack: PinStack?
    @State private var openGate: UUID?

    private static let mapHeight: CGFloat = 300
    private var placed: [MyGate] { gates.filter { $0.coordinate != nil } }

    init(gates: [MyGate]) {
        self.gates = gates
        let coords = gates.compactMap(\.coordinate)
        _position = State(initialValue: MapFraming.position(coords))
        _metersPerPoint = State(initialValue: MapFraming.region(coords)
            .map { MapClusters.metersPerPoint($0, height: Self.mapHeight) } ?? 2)
    }

    /// 月ごと（新しい月から）
    private var months: [(title: String, gates: [MyGate])] {
        var order: [String] = []
        var groups: [String: [MyGate]] = [:]
        for gate in gates {
            let m = GateDates.monthText(gate.created_at)
            if groups[m] == nil { order.append(m) }
            groups[m, default: []].append(gate)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if gates.isEmpty {
                        EmptyNote(title: "まだ GATE がありません",
                                  message: "「撮る」→「ここに GATE を作る」から作れます。",
                                  systemImage: "door.left.hand.open")
                            .padding(.top, 40)
                    } else {
                        map
                        ForEach(months, id: \.title) { month in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(month.title).font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                                    Text("\(month.gates.count) 個").font(.subheadline).foregroundStyle(Theme.textSecondary)
                                }
                                ForEach(month.gates) { gate in
                                    NavigationLink {
                                        GateDetailView(gateID: gate.id)
                                    } label: {
                                        GateJournalRow(gate: gate, highlighted: selected == gate.id)
                                    }
                                    .buttonStyle(.plain)
                                    .id(gate.id)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .gateStackSheet($stack, open: $openGate)
        .navigationDestination(item: $openGate) { id in
            GateDetailView(gateID: id)
        }
        .navigationTitle("わたしの GATE")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 全部の GATE の地図（印を押すと選ぶ）
    private var map: some View {
        MapReader { proxy in
        Map(position: $position) {
            UserAnnotation()
            // 同じ・近い所の GATE は 1 つの「重ねた印」にまとめる
            ForEach(MapClusters.group(MyGate.pins(placed), metersPerPoint: metersPerPoint)) { cluster in
                if cluster.isSingle, let gate = cluster.items.first {
                    Annotation(gate.title, coordinate: gate.coordinate, anchor: .bottom) {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                selected = selected == gate.id ? nil : gate.id
                            }
                        } label: {
                            GatePin(mine: true, selected: selected == gate.id, coverPath: gate.cover, showsName: false)
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(selected == gate.id ? .visible : .hidden)
                } else {
                    Annotation("\(cluster.items.count) 個の GATE", coordinate: cluster.coordinate, anchor: .bottom) {
                        Button {
                            Haptics.tap()
                            if let region = MapClusters.zoomRegion(for: cluster) {
                                withAnimation(.easeInOut(duration: 0.5)) { position = .region(region) }
                            } else {
                                stack = PinStack(items: cluster.items)
                            }
                        } label: {
                            GateStackPin(cluster: cluster, selected: cluster.contains(selected))
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            metersPerPoint = MapClusters.metersPerPoint(proxy, region: context.region, height: Self.mapHeight)
            Trace.log(String(format: "わたしの GATE の地図：1pt = %.1fm", metersPerPoint))
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        }
        .safeAreaPadding(EdgeInsets(top: 50, leading: 16, bottom: 8, trailing: 16))
        .frame(height: Self.mapHeight)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line))
        .overlay(alignment: .topLeading) {
            Label("\(placed.count) 個の GATE", systemImage: "door.left.hand.open")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.warm, in: Capsule())
                .padding(10)
        }
    }
}

/// 一覧の 1 行：表紙・名前・種類・場所の名前・作った日時・公開範囲
struct GateJournalRow: View {
    let gate: MyGate
    var highlighted = false

    var body: some View {
        HStack(spacing: 12) {
            GateCoverImage(path: gate.cover_path, markSize: 30)
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(gate.title).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                    let kind = GateKind(raw: gate.kind)
                    Image(systemName: kind.symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(kind == .view ? Theme.warm : Theme.accent)
                        .accessibilityLabel(kind.label)
                }
                Label(GateDates.shortText(gate.created_at), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                if let lat = gate.lat, let lon = gate.lon {
                    PlaceNameText(lat: lat, lon: lon)
                }
                Text(Visibility.label(of: gate.visibility))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.accentLight, in: Capsule())
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(highlighted ? Theme.warm : Theme.line, lineWidth: highlighted ? 2 : 1))
    }
}

/// 「わたし」の上に置く、自分の GATE の地図（さわれない小さな地図。押すと見返す画面）
struct MyGatesMapCard: View {
    let gates: [MyGate]
    @State private var metersPerPoint: Double?

    private var placed: [MyGate] { gates.filter { $0.coordinate != nil } }

    var body: some View {
        let coords = placed.compactMap(\.coordinate)
        let mpp = metersPerPoint ?? MapFraming.region(coords).map { MapClusters.metersPerPoint($0, height: 190) } ?? 2
        MapReader { proxy in
        Map(initialPosition: MapFraming.position(coords), interactionModes: []) {
            // 重なる印はまとめる（さわれない地図なので、数だけ見せる）
            ForEach(MapClusters.group(MyGate.pins(Array(placed.prefix(40))), metersPerPoint: mpp)) { cluster in
                Annotation(cluster.items[0].title, coordinate: cluster.coordinate, anchor: .bottom) {
                    if cluster.isSingle {
                        GatePin(mine: true, coverPath: cluster.items[0].cover, showsName: false)
                    } else {
                        GateStackPin(cluster: cluster)
                    }
                }
                .annotationTitles(.hidden)
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            metersPerPoint = MapClusters.metersPerPoint(proxy, region: context.region, height: 190)
        }
        }
        // 印は場所の上に立つので、上に余白をとって地図に収める（下の札にも重ならないように）
        .safeAreaPadding(EdgeInsets(top: 56, leading: 20, bottom: 40, trailing: 20))
        .id(placed.map(\.id))
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                Image(systemName: "map.fill")
                Text("地図といつ・どこでを見る")
                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(10)
        }
        .allowsHitTesting(false)
        .contentShape(Rectangle())
    }
}


extension MyGate {
    /// 地図の印にする（位置のあるものだけ）
    static func pins(_ gates: [MyGate]) -> [MapPinItem] {
        gates.compactMap { gate in
            gate.coordinate.map { MapPinItem(id: gate.id, title: gate.title, cover: gate.cover_path, coordinate: $0, mine: true) }
        }
    }
}
