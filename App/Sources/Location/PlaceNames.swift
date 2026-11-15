import CoreLocation
import Foundation
import SwiftUI

/// 位置から場所の名前（「川口駅」「川口市 本町」など）を iPhone の中で調べて、覚えておく。
/// Apple の地図の仕組みを使う（サーバーには送らない）。調べるのは 1 秒に 1 回まで（Apple の決まり）、
/// 結果は端末に覚えるので、同じ場所は 2 回調べない。
@MainActor
final class PlaceNames: ObservableObject {
    static let shared = PlaceNames()

    @Published private(set) var names: [String: String]

    private let geocoder = CLGeocoder()
    private var queue: [(key: String, location: CLLocation)] = []
    private var running = false
    private static let storeKey = "gg.placeNames.v1"

    private init() {
        names = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
    }

    /// 同じ場所とみなす細かさ（約 10m）
    static func key(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.4f,%.4f", lat, lon)
    }

    /// 覚えていればその名前。無ければ調べ始めて nil（調べ終わると画面が描き直される）
    func name(lat: Double, lon: Double) -> String? {
        let key = Self.key(lat, lon)
        if let known = names[key] { return known.isEmpty ? nil : known }
        request(key: key, location: CLLocation(latitude: lat, longitude: lon))
        return nil
    }

    private func request(key: String, location: CLLocation) {
        guard !queue.contains(where: { $0.key == key }) else { return }
        queue.append((key, location))
        guard !running else { return }
        running = true
        Task { await pump() }
    }

    private func pump() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if names[next.key] != nil { continue }
            do {
                let marks = try await geocoder.reverseGeocodeLocation(next.location, preferredLocale: Locale(identifier: "ja_JP"))
                names[next.key] = marks.first.map(Self.format) ?? ""
            } catch {
                // 通信できないときは覚えない（次に開いたときにまた調べる）
                Trace.log("場所の名前を調べられませんでした")
            }
            save()
            try? await Task.sleep(nanoseconds: 1_100_000_000)
        }
        running = false
    }

    private func save() {
        // 覚えすぎない（新しい 400 か所まで）
        if names.count > 400 {
            names = Dictionary(uniqueKeysWithValues: names.suffix(400).map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(names, forKey: Self.storeKey)
    }

    /// 名所の名前があればそれ、無ければ「市区町村 町名」
    static func format(_ p: CLPlacemark) -> String {
        if let poi = p.areasOfInterest?.first, !poi.isEmpty { return poi }
        let parts = [p.locality, p.subLocality].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return p.administrativeArea ?? ""
    }
}

/// 場所の名前の 1 行（調べ終わるまでは「場所を調べています…」）
struct PlaceNameText: View {
    let lat: Double
    let lon: Double
    var font: Font = .caption

    @ObservedObject private var places = PlaceNames.shared

    var body: some View {
        let name = places.name(lat: lat, lon: lon)
        Label(name ?? "場所を調べています…", systemImage: "mappin.and.ellipse")
            .font(font)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
    }
}

/// 作った日時：「2026年11月15日（日）20:39」
enum GateDates {
    static let full: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日（E）H:mm"
        return f
    }()
    static let short: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M月d日（E）H:mm"
        return f
    }()
    static let month: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月"
        return f
    }()

    static func fullText(_ s: String) -> String {
        ServerDate.parse(s).map { full.string(from: $0) } ?? ""
    }

    static func shortText(_ s: String) -> String {
        guard let d = ServerDate.parse(s) else { return "" }
        if Calendar.current.component(.year, from: d) != Calendar.current.component(.year, from: Date()) {
            return full.string(from: d)
        }
        return short.string(from: d)
    }

    static func monthText(_ s: String) -> String {
        ServerDate.parse(s).map { month.string(from: $0) } ?? "日付なし"
    }
}
