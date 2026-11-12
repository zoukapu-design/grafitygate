import CoreLocation
import Foundation

/// 現在地。GATE を見つける・入るときの位置と精度に使う。
@MainActor
final class LocationModel: NSObject, ObservableObject {
    @Published private(set) var location: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    /// サーバーの決まり（gf_settings の max_accuracy_m）と同じ。これより粗いと作成・入場できない
    static let maxAccuracy: CLLocationAccuracy = 35

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
        authorization = manager.authorizationStatus
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// 作成・入場に使える新しさと精度の位置（30 秒以内・精度 35m 以内）
    var usableFix: CLLocation? {
        guard let l = location, l.horizontalAccuracy >= 0, l.horizontalAccuracy <= Self.maxAccuracy,
              abs(l.timestamp.timeIntervalSinceNow) < 30 else { return nil }
        return l
    }

    /// 使えないときの理由（画面に出す）
    var fixProblem: String? {
        if isDenied { return "位置情報が許可されていません。設定アプリの「GRAFITYGATE」→「位置情報」で許可してください。" }
        guard let l = location else { return "現在地を確かめています…" }
        if l.horizontalAccuracy < 0 || l.horizontalAccuracy > Self.maxAccuracy {
            return String(format: "位置の精度が足りません（いま ±%.0fm）。空の開けた所で少し待ってください。", l.horizontalAccuracy)
        }
        if abs(l.timestamp.timeIntervalSinceNow) >= 30 { return "現在地を確かめています…" }
        return nil
    }
}

extension LocationModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.location = last }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 一時的に取れないだけのことが多いので、次の更新を待つ
    }
}
