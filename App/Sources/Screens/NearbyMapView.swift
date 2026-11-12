import CoreLocation
import MapKit
import SwiftUI

/// 地図：自分の周り 100m 以内で見てよい GATE。地図の表示の広さと、発見の範囲（100m）は別。
struct NearbyMapView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var location: LocationModel
    @State private var gates: [NearbyGate] = []
    @State private var error: String?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var lastQueried: CLLocation?

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "地図") {
                VStack(spacing: 0) {
                    Map(position: $position) {
                        UserAnnotation()
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
            .task(id: session.state) { await refresh(force: true) }
        }
    }

    private var nearbyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("100m 以内の GATE").font(.headline).foregroundStyle(Theme.text)
            if let problem = location.fixProblem, location.location == nil || location.isDenied {
                NoticeText(text: problem)
            } else if let error {
                NoticeText(text: error)
            } else if gates.isEmpty {
                Text("近くに GATE はありません。「撮る」から、この場所に GATE を作れます。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
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
