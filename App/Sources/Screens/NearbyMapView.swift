import CoreLocation
import MapKit
import SwiftUI

/// 地図：自分の周り 100m 以内で見てよい GATE。地図の表示の広さと、発見の範囲（100m）は別。
struct NearbyMapView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var location: LocationModel
    @EnvironmentObject private var nav: AppNavigator
    @State private var gates: [NearbyGate] = []
    @State private var error: String?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var lastQueried: CLLocation?
    /// 歩いている TRAIL の次の地点と、そこまでの歩く道
    @State private var target: TrailGuide.Target?
    @State private var route: MKRoute?
    @State private var routeFrom: CLLocation?
    @State private var selected: UUID?
    /// 横にめくって前に出ているグラフィティボード
    @State private var scrolledID: UUID?
    @State private var loaded = false
    /// 「探す」
    @State private var showSearch = false
    /// 探して選んだ場所（地図に印を出し、歩いて行く道を開ける）
    @State private var place: MKMapItem?
    /// 上の切り替え：地図／近くの友達のカード
    @State private var mode: Mode = .map
    /// 地図の縮尺（1pt が何 m か。近い印をまとめるのに使う）
    @State private var metersPerPoint: Double = 2
    /// 重ねた印から選ぶ一覧と、そこで選んだ GATE
    @State private var stack: PinStack?
    @State private var openGate: UUID?
    @StateObject private var nearbyCards = NearbyCardsModel()

    enum Mode: Hashable { case map, cards }

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "地図") {
                VStack(spacing: 0) {
                    Picker("見るもの", selection: $mode) {
                        Text("地図").tag(Mode.map)
                        Text(nearbyCards.deck.isEmpty ? "近くの友達のカード" : "近くの友達のカード \(nearbyCards.deck.count)")
                            .tag(Mode.cards)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    if mode == .cards {
                        NearbyCardsView(model: nearbyCards)
                    } else {
                        mapContent
                    }
                }
            }
            .task(id: location.location?.timestamp) {
                await refreshIfMoved()
                await nearbyCards.refresh(api: session.api, location: location.location)
            }
            .task(id: session.state) {
                await refresh(force: true)
                await loadWalking()
            }
            .sheet(isPresented: $showSearch) {
                MapSearchSheet { item in
                    mode = .map
                    place = item
                    withAnimation(.easeInOut(duration: 0.6)) {
                        position = .region(MKCoordinateRegion(center: MapSearchSheet.coordinate(of: item),
                                                              latitudinalMeters: 700, longitudinalMeters: 700))
                    }
                }
                .environmentObject(session)
                .environmentObject(location)
                .environmentObject(nav)
            }
            .toolbar { toolbarContent }
        }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showSearch = true
            } label: {
                Label("探す", systemImage: "magnifyingglass")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityLabel("GATE や場所を名前で探す")
        }
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink {
                TrailListView()
            } label: {
                Label("TRAIL", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    /// 地図を画面いっぱいに出し、下に「近くのグラフィティボード」を重ねる（横にめくると、地図の印も選ばれる）
    private var mapContent: some View {
        GeometryReader { geo in
            // 小さい iPhone（地図の欄が低い）では、ボードを低くして地図を広く見せる
            let compact = geo.size.height < 560
            ZStack(alignment: .bottom) {
                map
                    // 下に重ねた札の上に、いまいる所や印が来るように。札の高さは測らず、決まった高さで空ける
                    .safeAreaPadding(.bottom, reservedBottom(compact: compact) + geo.safeAreaInsets.bottom)
                    .ignoresSafeArea(edges: .bottom)
                overlayCards(compact: compact)
            }
        }
        .gateStackSheet($stack, open: $openGate)
        .navigationDestination(item: $openGate) { id in
            GateDetailView(gateID: id)
        }
    }

    private var pinItems: [MapPinItem] {
        gates.map {
            MapPinItem(id: $0.id, title: $0.title, cover: $0.cover_path,
                       coordinate: CLLocationCoordinate2D(latitude: $0.approx_lat, longitude: $0.approx_lon),
                       mine: $0.mine, ownerName: $0.owner_name)
        }
    }

    /// 重ねた印を押した：散らばっていれば寄って分け、同じ所なら一覧
    private func tapCluster(_ cluster: PinCluster) {
        Haptics.tap()
        if let region = MapClusters.zoomRegion(for: cluster) {
            withAnimation(.easeInOut(duration: 0.5)) {
                position = .region(region)
                selected = cluster.items[0].id
                scrolledID = cluster.items[0].id
            }
        } else {
            stack = PinStack(items: cluster.items)
        }
    }

    private var map: some View {
        MapReader { proxy in
        Map(position: $position) {
            UserAnnotation()
            // GATE を見つけられる範囲（100m）
            if let here = location.location {
                MapCircle(center: here.coordinate, radius: 100)
                    .stroke(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                    .foregroundStyle(Theme.accent.opacity(0.08))
            }
            if let route {
                MapPolyline(route.polyline)
                    .stroke(Theme.warm, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round,
                                                           dash: target?.fine == true ? [] : [2, 10]))
            }
            if let place {
                Marker(place.name ?? "探した場所", systemImage: "mappin",
                       coordinate: MapSearchSheet.coordinate(of: place))
                    .tint(Theme.accent)
            }
            if let target {
                Annotation("次：\(target.stop.title)", coordinate: target.coordinate) {
                    Text("\(target.stop.seq)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Theme.warm, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            // 近すぎて重なる印は、1 つの「重ねた印」にまとめる（数を出し、押すと分ける・一覧）
            ForEach(MapClusters.group(pinItems, metersPerPoint: metersPerPoint)) { cluster in
                if cluster.isSingle, let gate = cluster.items.first {
                    Annotation(gate.title, coordinate: gate.coordinate) {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                selected = selected == gate.id ? nil : gate.id
                                if let id = selected { scrolledID = id }
                            }
                        } label: {
                            GatePin(mine: gate.mine, selected: selected == gate.id,
                                    coverPath: gate.cover, ownerName: gate.ownerName)
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(selected == gate.id ? .visible : .hidden)
                } else {
                    Annotation("\(cluster.items.count) 個の GATE", coordinate: cluster.coordinate) {
                        Button {
                            tapCluster(cluster)
                        } label: {
                            GateStackPin(cluster: cluster, selected: cluster.contains(selected))
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
        // 地図の色をおさえて、GATE の印とボードを目立たせる
        .mapStyle(.standard(emphasis: .muted))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            let next = MapClusters.metersPerPoint(proxy, region: context.region, height: 600)
            if abs(next - metersPerPoint) > metersPerPoint * 0.1 {
                Trace.log(String(format: "地図の縮尺：1pt = %.1fm（印をまとめる距離 %.0fm）", next, next * MapClusters.pinPoints))
            }
            metersPerPoint = next
        }
        }
    }

    /// 下に重ねた札のおおよその高さ（地図の中身をその上に寄せる）
    private func reservedBottom(compact: Bool) -> CGFloat {
        let showsCarousel = loaded && error == nil && !gates.isEmpty
        // 棚：上の余白・見出し・すき間・中身・下の余白
        let shelf: CGFloat = (compact ? 10 : 14) + 34 + (compact ? 8 : 10)
            + (showsCarousel ? GraffitiBoardCard.size(compact: compact).height + 12 : 76) + (compact ? 8 : 10)
        var h: CGFloat = 10 + shelf
        if place != nil { h += 74 + 10 }
        if target != nil { h += (compact ? 58 : 80) + 10 }
        return h
    }

    /// 地図の下に重ねる札：探した場所・TRAIL の次の地点・近くのグラフィティボード
    private func overlayCards(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let place {
                placeCard(place).padding(.horizontal, 16)
            }
            if let target {
                trailCard(target, compact: compact).padding(.horizontal, 16)
            }
            boardShelf(compact: compact)
        }
        .padding(.bottom, 10)
    }

    /// 「近くのグラフィティボード」の棚：すりガラスの板に、光る扉のしるし・見出し・数、その下に横にめくるボード
    private func boardShelf(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(spacing: 10) {
                GateMark(size: compact ? 28 : 32, glowing: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("近くのグラフィティボード")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("半径 100m・着いたら扉を開けられます")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                if !gates.isEmpty {
                    Text("\(gates.count)")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 32, minHeight: 32)
                        .padding(.horizontal, 2)
                        .background(Theme.neonBand, in: Capsule())
                        .shadow(color: Color(hex: 0xFF3D7F).opacity(0.35), radius: 6, y: 2)
                        .accessibilityLabel("\(gates.count) 個")
                }
            }
            .frame(height: 34)
            .padding(.horizontal, 16)
            boards(compact: compact)
        }
        .padding(.top, compact ? 10 : 14)
        .padding(.bottom, compact ? 8 : 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(alignment: .top) {
            // 上の縁に、ネオンの帯（夕焼け → 夜空）
            Capsule().fill(Theme.neonBand).frame(width: 56, height: 4).padding(.top, 5)
        }
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
        .padding(.horizontal, 10)
    }

    @ViewBuilder private func boards(compact: Bool) -> some View {
        if location.fixProblem != nil, location.location == nil || location.needsSettings {
            LocationProblemView()
                .padding(.horizontal, 16)
        } else if let error {
            NoticeText(text: error)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
        } else if !loaded {
            HStack(spacing: 10) {
                ProgressView()
                Text(location.location == nil ? "いまの場所を調べています…" : "近くのグラフィティボードを探しています…")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .padding(.horizontal, 16)
        } else if gates.isEmpty {
            HStack(spacing: 12) {
                GateMark(size: 44, glowing: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text("近くに GATE はありません").font(.subheadline.weight(.bold)).foregroundStyle(Theme.text)
                    Text("この場所に、最初の扉を置いてみませんか。").font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
                Button {
                    nav.tab = .capture
                } label: {
                    Text("作る")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Theme.neonBand, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("ここに GATE を作る")
            }
            .padding(12)
            .background(Theme.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 12)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(gates) { gate in
                        NavigationLink(value: GateRoute(id: gate.id)) {
                            GraffitiBoardCard(gate: gate, selected: selected == gate.id, compact: compact)
                        }
                        .buttonStyle(.plain)
                        .id(gate.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 6)
            }
            // 高さは札の高さに決める（決めないと横に流す欄が縦にのび、地図の上まで広がっていた）
            .frame(height: GraffitiBoardCard.size(compact: compact).height + 12)
            .scrollTargetBehavior(.viewAligned)
            .safeAreaPadding(.horizontal, 16)
            .scrollPosition(id: $scrolledID)
            .onChange(of: scrolledID) { _, id in
                // めくったボードの印を地図で選ぶ
                guard let id, id != selected, gates.count > 1 else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selected = id }
            }
        }
    }

    /// 歩いている TRAIL の次の地点
    private func trailCard(_ target: TrailGuide.Target, compact: Bool) -> some View {
        NavigationLink {
            TrailDetailView(trailID: target.trail.id, title: target.trail.title)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "figure.walk")
                    .font(compact ? .subheadline : .headline)
                    .foregroundStyle(.white)
                    .frame(width: compact ? 28 : 34, height: compact ? 28 : 34)
                    .background(Theme.warm, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    if !compact {
                        Text("TRAIL「\(target.trail.title)」\(target.trail.reached)/\(target.trail.stop_count)")
                            .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    Text("次は \(target.stop.seq). \(target.stop.title)").font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    if let route {
                        Text("歩いて約 \(max(1, Int((route.expectedTravelTime / 60).rounded()))) 分・\(TrailGuide.distanceText(route.distance))"
                             + (target.fine || compact ? "" : "（おおよその場所まで）"))
                            .font(.caption).foregroundStyle(Theme.warm).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            }
            .padding(compact ? 9 : 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.warm.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    /// 探して選んだ場所：名前と、歩いて行く道。GATE が見つかるのは、いまいる所の 100m 以内のまま
    private func placeCard(_ item: MKMapItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "探した場所").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("GATE が見つかるのは、着いてからその場の 100m 以内です")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Button {
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
            } label: {
                Label("歩いて行く", systemImage: "figure.walk")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            Button {
                withAnimation {
                    place = nil
                    position = .userLocation(fallback: .automatic)
                }
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("探した場所を消す")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.accent.opacity(0.4)))
    }

    /// 歩いている TRAIL があれば、次の地点を地図に出す
    private func loadWalking() async {
        guard let api = session.api, session.state == .signedIn else { return }
        target = await TrailGuide.load(api: api, nearby: gates)
        await updateRoute(force: true)
    }

    /// 次の地点までの歩く道（40m 以上動いたか、行き先が変わったら引き直す）
    private func updateRoute(force: Bool) async {
        guard let target, let here = location.location else {
            if self.target == nil { route = nil }
            return
        }
        if !force, let from = routeFrom, here.distance(from: from) < 40 { return }
        routeFrom = here
        route = await TrailGuide.walkingRoute(from: here.coordinate, to: target.coordinate)
    }

    /// 15m 以上動いたか、30 秒たったら探し直す（サーバーへの問い合わせを減らす）
    private func refreshIfMoved() async {
        guard let here = location.location else { return }
        if let last = lastQueried, here.distance(from: last) < 15,
           here.timestamp.timeIntervalSince(last.timestamp) < 30 {
            return
        }
        await refresh(force: false)
    }

    private func refresh(force: Bool) async {
        guard let api = session.api, session.state == .signedIn, let here = location.location,
              here.horizontalAccuracy >= 0 else { return }
        lastQueried = here
        do {
            gates = try await api.nearby(here).sorted { $0.distance_m < $1.distance_m }
            if let selected, !gates.contains(where: { $0.id == selected }) { self.selected = nil }
            error = nil
            loaded = true
            // 次の地点が 100m 以内に入ったら、少し細かい位置で案内し直す
            if let t = target, let refined = TrailGuide.target(trail: t.trail, stop: t.stop, nearby: gates), refined != t {
                target = refined
                await updateRoute(force: true)
            } else {
                await updateRoute(force: false)
            }
        } catch {
            self.error = ErrorText.of(error)
            loaded = true
        }
    }
}

/// 地図の GATE の印：アイコンと同じネオンの扉（自分の GATE は夕焼けの色の縁）
/// 地図の GATE の印：表紙の写真（無ければ扉のしるし）に、作った人の顔の丸と名前。自分のものはだいだいの縁で「あなた」
struct GatePin: View {
    let mine: Bool
    var selected = false
    var coverPath: String? = nil
    var ownerName: String? = nil
    /// 名前の札を出すか（たくさん並ぶ地図では選んだものだけ）
    var showsName = true

    private var size: CGFloat { selected ? 52 : 40 }
    private var border: Color { mine ? Theme.warm : .white }
    private var nameText: String { mine ? "あなた" : (ownerName ?? "") }

    var body: some View {
        VStack(spacing: 2) {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let coverPath {
                            RemotePhoto(path: coverPath)
                        } else {
                            Image("BrandMark").resizable().interpolation(.high)
                        }
                    }
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(border, lineWidth: mine ? 3 : 2.5))
                    .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                    if !nameText.isEmpty {
                        // 作った人の顔の丸
                        NeonAvatar(name: mine ? (SessionModel.current?.profile?.display_name ?? "あなた") : nameText, size: selected ? 24 : 20)
                            .background(Circle().fill(.white))
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .offset(x: 7, y: 7)
                    }
                }
                Triangle()
                    .fill(border)
                    .frame(width: 10, height: 6)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
            if showsName && !nameText.isEmpty {
                Text(nameText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(mine ? .white : Theme.text)
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(mine ? Theme.warm : Color.white.opacity(0.92), in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(maxWidth: 90)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mine ? "あなたの GATE" : "\(ownerName ?? "だれか") さんの GATE")
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
