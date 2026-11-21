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
    /// 届いた位置をならす（ゆれ・古い位置・一瞬だけ粗くなった位置を外す）
    private var filter = FixFilter()

    /// サーバーの決まり（gf_settings の max_accuracy_m）と同じ。これより粗いと作成・入場できない
    static let maxAccuracy: CLLocationAccuracy = 35

    override init() {
        super.init()
        manager.delegate = self
        // いちばん細かい設定（2026-11-21 オーナー「iPhone の地図と比べて位置の精度が悪い」）：
        // 前は Best だった。BestForNavigation は GPS に加えて iPhone の動きのセンサーも合わせて位置を出すので、
        // ビルの多い街・駅のまわりでも位置が落ち着きやすい（電気は少し多く使う。アプリが裏に回ると iOS が止める）
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        // 止まっていても、iOS に位置の受け取りを休ませない（休むと、こちらから始め直すまで位置が古いままになる）
        manager.pausesLocationUpdatesAutomatically = false
        // 止まっていても位置を受け取る。前は「2m 動いたときだけ」にしていたので、家の中でじっと写していると位置が来ず、
        // 30 秒で「古い位置」になって、入る・作るが「現在地を確かめています…」のまま進めなかった（2026-11-15）。
        // 位置を使う画面は自分で問い合わせを間引く（地図は 15m か 30 秒ごと）。アプリが裏に回ると iOS が止める。
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
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
        guard !locations.isEmpty else { return }
        Task { @MainActor in
            // まとめて届いたときも 1 つずつならす（いちばん新しいものが、いちばん正確とは限らない）
            var next: CLLocation?
            for raw in locations {
                if let fixed = self.filter.accept(raw) { next = fixed }
            }
            guard let last = next else { return }
            let first = self.location == nil
            let wasUsable = self.usableFix != nil
            self.location = last
            let usable = self.usableFix != nil
            // 調べもの用：はじめて位置が来たとき・使える精度になった／足りなくなったときだけ残す
            if first || usable != wasUsable {
                Trace.log(String(format: "位置：精度 ±%.0fm（%@）", last.horizontalAccuracy,
                                 usable ? "入る・作るに使える" : "まだ使えない"))
            }
        }
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

/// 届いた位置をならす（2026-11-21 オーナー「iPhone の地図と比べて位置の精度が悪い」）。
/// - 古い位置（届いた時点で 10 秒より前）は、まだ何も無いときの目安にだけ使う（アプリを開いた直後に、前にいた所の位置が届く）
/// - 止まっているあいだに、一瞬だけ粗くなった位置が届いても、少し前（10 秒以内）のより正確な位置を持ち続ける
///   （精度が ±20m → ±45m → ±20m とゆれて、GATE を開ける・作るが「精度が足りません」と行ったり来たりしないように）
/// - 位置そのものは、精度に合わせて少しずつならす（歩く速さより速くは動かさないが、大きく離れたらすぐに追う）
/// 精度の数字は、届いた位置の数字をそのまま使う（ならしたぶん小さく見せない＝サーバーの「精度 35m」の決まりを甘くしない）
struct FixFilter {
    private(set) var current: CLLocation?
    /// 位置のならし具合（m の 2 乗）
    private var variance: Double = 0
    private var stale = false

    mutating func accept(_ raw: CLLocation) -> CLLocation? {
        guard raw.horizontalAccuracy >= 0, CLLocationCoordinate2DIsValid(raw.coordinate) else { return nil }
        let age = -raw.timestamp.timeIntervalSinceNow
        if age > 10 {
            // 古い位置：まだ何も無いときだけ、目安として使う（入る・作るには使えない＝30 秒より古い）
            guard current == nil else { return nil }
            current = raw
            stale = true
            return raw
        }
        guard let cur = current, !stale else { return reset(raw) }
        let dt = raw.timestamp.timeIntervalSince(cur.timestamp)
        guard dt > 0 else { return nil }
        let moved = raw.distance(from: cur)
        let rawVar = raw.horizontalAccuracy * raw.horizontalAccuracy
        // 歩く・走る速さ（m/秒）。速さが分かればそれを使う
        let speed = max(2.5, raw.speed > 0 ? raw.speed * 1.5 : 0)
        let predicted = variance + (speed * dt) * (speed * dt)
        // 大きく離れた（電車・地下から出た など）：すぐに新しい位置へ
        if moved > 3 * (predicted + rawVar).squareRoot() + 15 { return reset(raw) }
        // 止まっていて、新しい位置のほうがずっと粗い：少し前の正確な位置を持ち続ける（時刻だけ新しく）
        // （基準の current と、ならし具合は変えない＝10 秒たったら、新しい位置を受け入れる）
        if raw.horizontalAccuracy > cur.horizontalAccuracy * 1.6, dt < 10, moved <= raw.horizontalAccuracy {
            return CLLocation(coordinate: cur.coordinate, altitude: cur.altitude, horizontalAccuracy: cur.horizontalAccuracy,
                              verticalAccuracy: cur.verticalAccuracy, course: raw.course, speed: raw.speed, timestamp: raw.timestamp)
        }
        // 精度に合わせて、新しい位置のほうへ寄せる
        let k = predicted / (predicted + rawVar)
        let lat = cur.coordinate.latitude + k * (raw.coordinate.latitude - cur.coordinate.latitude)
        let lon = cur.coordinate.longitude + k * (raw.coordinate.longitude - cur.coordinate.longitude)
        variance = (1 - k) * predicted
        let fixed = CLLocation(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), altitude: raw.altitude,
                               horizontalAccuracy: raw.horizontalAccuracy, verticalAccuracy: raw.verticalAccuracy,
                               course: raw.course, speed: raw.speed, timestamp: raw.timestamp)
        current = fixed
        return fixed
    }

    private mutating func reset(_ raw: CLLocation) -> CLLocation {
        current = raw
        variance = raw.horizontalAccuracy * raw.horizontalAccuracy
        stale = false
        return raw
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
