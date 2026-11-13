import CoreLocation
import MapKit
import SwiftUI

/// 歩いている TRAIL の「次の地点」への案内（地図の歩く道と、撮る画面の方向）。
/// 次の地点の位置は、ふだんはおおよそ（約 100m の丸め）。100m 以内に入ると、近くの GATE の少し細かい位置を使う。
enum TrailGuide {
    struct Target: Equatable {
        let trail: TrailSummary
        let stop: TrailStop
        let coordinate: CLLocationCoordinate2D
        /// 近くの GATE の細かい位置を使っているか（false はおおよその位置）
        let fine: Bool

        static func == (a: Target, b: Target) -> Bool {
            a.trail.id == b.trail.id && a.stop.seq == b.stop.seq && a.fine == b.fine
                && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
        }
    }

    /// 歩いている TRAIL の次の地点（なければ nil）
    static func load(api: GateAPI, nearby: [NearbyGate]) async -> Target? {
        guard let trail = (try? await api.trails())?.first(where: \.inProgress),
              let stop = (try? await api.trailStops(trail.id))?.first(where: { !$0.reached }) else { return nil }
        return target(trail: trail, stop: stop, nearby: nearby)
    }

    static func target(trail: TrailSummary, stop: TrailStop, nearby: [NearbyGate]) -> Target? {
        if let id = stop.gate_id, let near = nearby.first(where: { $0.id == id }) {
            return Target(trail: trail, stop: stop,
                          coordinate: CLLocationCoordinate2D(latitude: near.approx_lat, longitude: near.approx_lon), fine: true)
        }
        guard let lat = stop.approx_lat, let lon = stop.approx_lon else { return nil }
        return Target(trail: trail, stop: stop, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), fine: false)
    }

    /// 北から時計回りの方角（度）
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }

    static func distanceText(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "約 %.1fkm", meters / 1000) : "約 \(Int((meters / 10).rounded() * 10))m"
    }

    /// 歩く道（MapKit。取れなければ nil）
    static func walkingRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async -> MKRoute? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .walking
        do {
            let response = try await MKDirections(request: request).calculate()
            return response.routes.first
        } catch {
            Trace.log("TRAIL：歩く道を出せませんでした（\(error.localizedDescription)）")
            return nil
        }
    }
}

/// 撮る画面の上に出す、TRAIL の次の地点の方向と距離（矢印は iPhone の向きに合わせて回る）
struct TrailCompassPill: View {
    let target: TrailGuide.Target

    @EnvironmentObject private var location: LocationModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { _ in
            content
        }
    }

    @ViewBuilder private var content: some View {
        if let here = location.location {
            let distance = here.distance(from: CLLocation(latitude: target.coordinate.latitude,
                                                          longitude: target.coordinate.longitude))
            let bearing = TrailGuide.bearing(from: here.coordinate, to: target.coordinate)
            let arrived = distance < (target.fine ? 25 : 80)
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Theme.warm).frame(width: 34, height: 34)
                    if arrived {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    } else if let heading = location.heading {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(bearing - heading))
                            .animation(.easeOut(duration: 0.35), value: Int(bearing - heading))
                    } else {
                        Image(systemName: "figure.walk").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("TRAIL「\(target.trail.title)」\(target.trail.reached + 1)/\(target.trail.stop_count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(arrived ? "\(target.stop.title) のあたりです" : "次は \(target.stop.title)・\(TrailGuide.distanceText(distance))")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }
}
