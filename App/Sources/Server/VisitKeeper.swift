import CoreLocation
import Foundation

/// 扉は、その場にいるあいだ開いたまま（0021・オーナー 2026-11-15）。
/// 開いている扉を覚えて、45 秒ごとに「いまの位置」をサーバーへ送る（`gf_keep_open`）。GATE から 150m 以内なら
/// 5 分先まで延び、はっきり離れたら 2 分で閉じる。決めるのはサーバーで、ここは位置を送って結果を覚えるだけ。
@MainActor
final class VisitKeeper: ObservableObject {
    static let shared = VisitKeeper()

    struct Entry: Equatable {
        let gate: UUID
        var expires: Date
        /// いま GATE のそばにいるか（nil＝まだ分からない・位置が不確か）
        var near: Bool?
    }

    /// 開いている扉（入場の ID ごと）
    @Published private(set) var entries: [UUID: Entry] = [:]
    private weak var session: SessionModel?
    private weak var location: LocationModel?
    private var loop: Task<Void, Never>?
    /// サーバーがまだ 0021 の前（このときは前のまま 20 分で閉じる）
    private var unsupported = false

    private init() {}

    /// 扉を開けた（入場した）ときに呼ぶ
    func track(visit: UUID, gate: UUID, expires: Date?, session: SessionModel, location: LocationModel) {
        guard let expires, expires > Date() else { return }
        self.session = session
        self.location = location
        if let known = entries[visit], known.expires >= expires {
            // サーバーで延びた分を覚えているほうを使う
        } else {
            entries[visit] = Entry(gate: gate, expires: expires, near: entries[visit]?.near)
        }
        start()
    }

    /// 延びた分を足した、扉が閉じる時刻
    func expires(visit: UUID?) -> Date? {
        visit.flatMap { entries[$0]?.expires }
    }

    private func start() {
        guard loop == nil, !unsupported else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let keeper = self else { return }
                await keeper.tick()
                if keeper.entries.isEmpty || keeper.unsupported {
                    keeper.loop = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 45_000_000_000)
            }
        }
    }

    private func tick() async {
        let now = Date()
        entries = entries.filter { $0.value.expires > now }
        guard let api = session?.api, let here = location?.location, here.horizontalAccuracy >= 0,
              now.timeIntervalSince(here.timestamp) < 120 else { return }
        for (visit, entry) in entries {
            do {
                let result = try await api.keepOpen(visit: visit, at: here)
                guard result.open else {
                    entries[visit] = nil
                    Trace.log("扉が閉じました（GATE から離れた・閉じられた）")
                    continue
                }
                if let e = result.expires_at.flatMap(ServerDate.parse) {
                    entries[visit]?.expires = e
                }
                if result.near != entry.near, let near = result.near {
                    Trace.log(near ? "扉を開けたまま（GATE のそば）" : "GATE から離れたので、まもなく扉が閉じます")
                }
                entries[visit]?.near = result.near
            } catch let error where ErrorText.isMissingFunction(error) {
                unsupported = true
                return
            } catch {
                // 電波が悪いときなど。次の回にまた送る
            }
        }
    }
}

struct KeepOpenResult: Decodable {
    let open: Bool
    let expires_at: String?
    let near: Bool?
}

extension GateAPI {
    func keepOpen(visit: UUID, at location: CLLocation) async throws -> KeepOpenResult {
        try await client.rpc("gf_keep_open",
                             params: KeepOpenParam(p_visit: visit, p_lat: location.coordinate.latitude,
                                                   p_lon: location.coordinate.longitude,
                                                   p_accuracy: Float(max(location.horizontalAccuracy, 0))))
            .execute().value
    }
}

private struct KeepOpenParam: Encodable {
    let p_visit: UUID
    let p_lat: Double
    let p_lon: Double
    let p_accuracy: Float
}
