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
    @State private var walking: TrailSummary?
    @State private var nextStop: TrailStop?

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "地図") {
                VStack(spacing: 0) {
                    Map(position: $position) {
                        UserAnnotation()
                        if let next = nextStop, let lat = next.approx_lat, let lon = next.approx_lon {
                            Annotation("次：\(next.title)", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)) {
                                Text("\(next.seq)")
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
            if let walking, let next = nextStop {
                NavigationLink {
                    TrailDetailView(trailID: walking.id, title: walking.title)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "figure.walk").foregroundStyle(Theme.warm)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TRAIL「\(walking.title)」\(walking.reached)/\(walking.stop_count)")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                            Text("次は \(next.seq). \(next.title)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
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
            if let problem = location.fixProblem, location.location == nil || location.isDenied {
                NoticeText(text: problem)
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
        guard let trail = (try? await api.trails())?.first(where: \.inProgress) else {
            walking = nil
            nextStop = nil
            return
        }
        walking = trail
        nextStop = (try? await api.trailStops(trail.id))?.first { !$0.reached }
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
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}
