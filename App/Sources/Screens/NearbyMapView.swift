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

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "地図") {
                VStack(spacing: 0) {
                    Map(position: $position) {
                        UserAnnotation()
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
                                Image(systemName: "door.left.hand.open")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(8)
                                    .background(gate.mine ? Theme.warm : Theme.accent, in: Circle())
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                            }
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
            Text("100m 以内の GATE").font(.headline).foregroundStyle(Theme.text)
            if location.fixProblem != nil, location.location == nil || location.needsSettings {
                LocationProblemView()
            } else if let error {
                NoticeText(text: error)
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(gates) { gate in
                            NavigationLink(value: GateRoute(id: gate.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(gate.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                    Text("\(gate.owner_name)・約 \(Int(gate.distance_m.rounded()))m")
                                        .font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                                .padding(12)
                                .frame(width: 200, alignment: .leading)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
                            }
                            .buttonStyle(.plain)
                        }
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
            gates = try await api.nearby(here)
            error = nil
            // 次の地点が 100m 以内に入ったら、少し細かい位置で案内し直す
            if let t = target, let refined = TrailGuide.target(trail: t.trail, stop: t.stop, nearby: gates), refined != t {
                target = refined
                await updateRoute(force: true)
            } else {
                await updateRoute(force: false)
            }
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}
