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
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "地図") {
                VStack(spacing: 0) {
                    Map(position: $position) {
                        UserAnnotation()
                        // GATE を見つけられる範囲（100m）
                        if let here = location.location {
                            MapCircle(center: here.coordinate, radius: 100)
                                .stroke(Theme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                                .foregroundStyle(Theme.accent.opacity(0.07))
                        }
                        if let route {
                            MapPolyline(route.polyline)
                                .stroke(Theme.warm, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round,
                                                                       dash: target?.fine == true ? [] : [2, 10]))
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
                        ForEach(gates) { gate in
                            Annotation(gate.title, coordinate: CLLocationCoordinate2D(latitude: gate.approx_lat,
                                                                                       longitude: gate.approx_lon)) {
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        selected = selected == gate.id ? nil : gate.id
                                    }
                                } label: {
                                    GatePin(mine: gate.mine, selected: selected == gate.id)
                                }
                                .buttonStyle(.plain)
                            }
                            .annotationTitles(selected == gate.id ? .visible : .hidden)
                        }
                    }
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                    }
                    .frame(maxHeight: .infinity)

                    nearbyList
                }
            }
            .task(id: location.location?.timestamp) { await refreshIfMoved() }
            .task(id: session.state) {
                await refresh(force: true)
                await loadWalking()
            }
            .toolbar {
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
        }
    }

    private var nearbyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let target {
                NavigationLink {
                    TrailDetailView(trailID: target.trail.id, title: target.trail.title)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "figure.walk").foregroundStyle(Theme.warm)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TRAIL「\(target.trail.title)」\(target.trail.reached)/\(target.trail.stop_count)")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                            Text("次は \(target.stop.seq). \(target.stop.title)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            if let route {
                                Text("歩いて約 \(max(1, Int((route.expectedTravelTime / 60).rounded()))) 分・\(TrailGuide.distanceText(route.distance))"
                                     + (target.fine ? "" : "（おおよその場所まで）"))
                                    .font(.caption).foregroundStyle(Theme.warm)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.warm.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("100m 以内の GATE").font(.headline).foregroundStyle(Theme.text)
                if !gates.isEmpty {
                    Text("\(gates.count)").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
                }
                Spacer()
            }
            if location.fixProblem != nil, location.location == nil || location.needsSettings {
                LocationProblemView()
            } else if let error {
                NoticeText(text: error)
            } else if !loaded {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(location.location == nil ? "いまの場所を調べています…" : "近くの GATE を探しています…")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                .frame(height: 64)
            } else if gates.isEmpty {
                Text("近くに GATE はありません。この場所に、最初の扉を置いてみませんか。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Button {
                    nav.tab = .capture
                } label: {
                    Label("ここに GATE を作る", systemImage: "door.left.hand.open")
                }
                .buttonStyle(SecondaryButtonStyle())
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(gates) { gate in
                                NavigationLink(value: GateRoute(id: gate.id)) {
                                    NearbyGateCard(gate: gate, selected: selected == gate.id)
                                }
                                .buttonStyle(.plain)
                                .id(gate.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: selected) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background)
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

/// 近くの GATE の横に並ぶカード（表紙・名前・作った人・距離）
private struct NearbyGateCard: View {
    let gate: NearbyGate
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            GateCoverImage(path: gate.cover_path, markSize: 26)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(gate.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(gate.mine ? "あなたの GATE" : gate.owner_name)
                    .font(.caption).foregroundStyle(gate.mine ? Theme.warm : Theme.textSecondary)
                    .lineLimit(1)
                Label("約 \(Int(gate.distance_m.rounded()))m", systemImage: "location.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                    .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 236, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Theme.accent : Theme.line, lineWidth: selected ? 2 : 1))
        .shadow(color: selected ? Theme.accent.opacity(0.18) : .clear, radius: 8, y: 3)
    }
}

/// 地図の GATE の印：アイコンと同じネオンの扉（自分の GATE は夕焼けの色の縁）
struct GatePin: View {
    let mine: Bool
    var selected = false

    var body: some View {
        VStack(spacing: 0) {
            Image("BrandMark")
                .resizable()
                .interpolation(.high)
                .frame(width: selected ? 46 : 34, height: selected ? 46 : 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(mine ? Theme.warm : .white, lineWidth: mine ? 3 : 2))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            Triangle()
                .fill(mine ? Theme.warm : .white)
                .frame(width: 10, height: 6)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
        }
        .accessibilityLabel(mine ? "自分の GATE" : "GATE")
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
