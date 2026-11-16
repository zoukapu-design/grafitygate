import MapKit
import SwiftUI

/// 地図の見せる範囲。印が 1 つだけでも、まわりの道や駅の名前が分かる広さ（いちばん狭くて約 600m）にする。
/// 「全部が入るように」（.automatic）だけだと、GATE が 1 つのとき建物の中まで寄ってしまい、場所が分からなかった
enum MapFraming {
    static func region(_ coordinates: [CLLocationCoordinate2D], minMeters: Double = 600) -> MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates.dropFirst() {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        // 緯度 1 度は約 111km。経度は緯度で縮む
        let minLatSpan = minMeters / 111_000
        let minLonSpan = minMeters / (111_000 * max(0.2, cos(center.latitude * .pi / 180)))
        let span = MKCoordinateSpan(latitudeDelta: max(minLatSpan, (maxLat - minLat) * 1.5),
                                    longitudeDelta: max(minLonSpan, (maxLon - minLon) * 1.5))
        return MKCoordinateRegion(center: center, span: span)
    }

    static func position(_ coordinates: [CLLocationCoordinate2D], minMeters: Double = 600) -> MapCameraPosition {
        region(coordinates, minMeters: minMeters).map { .region($0) } ?? .automatic
    }
}
