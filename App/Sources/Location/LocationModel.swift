import CoreLocation
import Foundation
import SwiftUI

/// 現在地。GATE を見つける・入るときの位置と精度に使う。
@MainActor
final class LocationModel: NSObject, ObservableObject {
    @Published private(set) var location: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// 「正確な位置情報」がオフ（おおよその位置しか分からない＝GATE に入れない・作れない）
    @Published private(set) var isReducedAccuracy = false
    /// 端末の向き（真北から時計回りの度。分からなければ nil）。GATE を作るときに扉の向きとして残す
    private(set) var heading: Double?

    private let manager = CLLocationManager()

    /// サーバーの決まり（gf_settings の max_accuracy_m）と同じ。これより粗いと作成・入場できない
    static let maxAccuracy: CLLocationAccuracy = 35

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 2
        authorization = manager.authorizationStatus
        isReducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
    }

    /// Info.plist の NSLocationTemporaryUsageDescriptionDictionary の鍵
    static let fullAccuracyPurpose = "GateEntry"

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        askFullAccuracyIfNeeded()
        if CLLocationManager.headingAvailable() {
            manager.headingFilter = 2
            manager.startUpdatingHeading()
        }
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    /// 「正確な位置情報」がオフなら、このときだけ正確な位置を使ってよいか聞く（GATE に入る・作るのに要る）
    func askFullAccuracyIfNeeded() {
        guard manager.accuracyAuthorization == .reducedAccuracy,
              authorization == .authorizedWhenInUse || authorization == .authorizedAlways else { return }
        Trace.log("位置：正確な位置情報がオフなので、一時的に使えるか聞きます")
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.fullAccuracyPurpose) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isReducedAccuracy = self.manager.accuracyAuthorization == .reducedAccuracy
            }
        }
    }

    /// 設定アプリでなければ直せない（許可していない・正確な位置情報がオフ）
    var needsSettings: Bool { isDenied || isReducedAccuracy }

    /// 作成・入場に使える新しさと精度の位置（30 秒以内・精度 35m 以内）
    var usableFix: CLLocation? {
        guard let l = location, l.horizontalAccuracy >= 0, l.horizontalAccuracy <= Self.maxAccuracy,
              abs(l.timestamp.timeIntervalSinceNow) < 30 else { return nil }
        return l
    }

    /// 使えないときの理由（画面に出す）
    var fixProblem: String? {
        if isDenied { return "位置情報が許可されていません。設定アプリの「Grafity Gate」→「位置情報」で「このAppの使用中」を選んでください。" }
        if isReducedAccuracy {
            return "「正確な位置情報」がオフなので、GATE に入る・作ることができません。設定アプリの「Grafity Gate」→「位置情報」で「正確な位置情報」を入れてください。"
        }
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
        let reduced = manager.accuracyAuthorization == .reducedAccuracy
        Task { @MainActor in
            self.authorization = status
            self.isReducedAccuracy = reduced
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.startUpdatingLocation()
                if reduced { self.askFullAccuracyIfNeeded() }
            }
            Trace.log("位置の許可：\(status.rawValue)・正確な位置情報 \(reduced ? "オフ" : "オン")")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : nil
        Task { @MainActor in self.heading = value }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 一時的に取れないだけのことが多いので、次の更新を待つ
    }
}

/// 位置情報の問題と、設定アプリを開くボタン（設定でしか直せないときだけボタンを出す）
struct LocationProblemView: View {
    @EnvironmentObject private var location: LocationModel

    var body: some View {
        if let problem = location.fixProblem {
            VStack(alignment: .leading, spacing: 8) {
                NoticeText(text: problem, isError: location.needsSettings)
                if location.needsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("設定アプリを開く") { UIApplication.shared.open(url) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }
}
