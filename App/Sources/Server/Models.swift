import Foundation

// サーバー（Supabase の gf_ 関数）が返す形。名前はサーバーの列名に合わせている。

/// 周りの GATE（gf_discover_nearby）
struct NearbyGate: Decodable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let kind: String
    let owner: UUID
    let owner_name: String
    let distance_m: Double
    let approx_lat: Double
    let approx_lon: Double
    let cover_path: String?
    let visibility: String
    let mine: Bool
}

/// GATE の概要（gf_gate_summary）
struct GateSummary: Decodable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let note: String
    let kind: String
    let owner: UUID
    let owner_name: String
    let cover_path: String?
    let approx_lat: Double
    let approx_lon: Double
    let visibility: String
    let status: String
    let graffiti_count: Int
    let created_at: String
    let my_visit: UUID?
    let my_visit_expires_at: String?

    var visitExpiresAt: Date? { my_visit_expires_at.flatMap(ServerDate.parse) }
}

/// 写真が近い候補（gf_match_candidates）。similarity は strong / weak / none / unknown
struct MatchCandidate: Decodable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let owner_name: String
    let distance_m: Double
    let cover_path: String?
    let similarity: String
}

/// 友達の新着（gf_friend_feed）
struct FeedCard: Decodable, Identifiable, Hashable {
    let id: UUID
    let author: UUID
    let author_name: String
    let gate_id: UUID
    let gate_title: String
    let approx_lat: Double
    let approx_lon: Double
    let body: String
    let photo_path: String?
    let created_at: String
}

/// グラフィティ（表 gf_graffiti。見てよいものだけがサーバーから返る）
struct Graffiti: Decodable, Identifiable, Hashable {
    let id: UUID
    let gate_id: UUID
    let author: UUID
    let body: String
    let photo_path: String?
    let visibility: String
    let local_only: Bool
    let created_at: String
}

/// 自分の GATE（表 gf_gates。自分のものだけ読める）
struct MyGate: Decodable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let visibility: String
    let status: String
    let created_at: String
}

struct Challenge: Decodable {
    let challenge_id: UUID
    let expires_at: String
}

/// 入場の結果（gf_enter）
struct EnterResult: Decodable {
    let ok: Bool
    let reason: String?
    let visit_id: UUID?
    let expires_at: String?
}

struct ProfileRow: Codable, Hashable {
    let id: UUID
    var display_name: String
    var handle: String
}

/// 公開範囲
enum Visibility: String, CaseIterable, Identifiable {
    case `private`, friends, `public`

    var id: String { rawValue }

    var label: String {
        switch self {
        case .private: return "自分だけ"
        case .friends: return "友達"
        case .public: return "全員"
        }
    }

    static func label(of raw: String) -> String { Visibility(rawValue: raw)?.label ?? raw }
}

/// サーバーの時刻（ISO 8601、小数の秒あり・なしの両方）
enum ServerDate {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func parse(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s)
    }

    /// 「3 分前」「2 時間前」など
    static func relative(_ s: String) -> String {
        guard let d = parse(s) else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}
