import CoreGraphics
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

/// GATE に置いた AR の作品（表 gf_artworks。見てよいものだけがサーバーから返る）。
/// 位置・向き・大きさは扉の足もとの中心が基準（+Z は扉の手前＝置いたときに扉を見ていた側）。
struct Artwork: Decodable, Identifiable, Hashable {
    let id: UUID
    let gate_id: UUID
    let owner: UUID
    let kind: String
    let body: String
    let photo_path: String?
    let color: String
    var px: Float
    var py: Float
    var pz: Float
    var yaw: Float
    var scale: Float
    let rules: [ArtworkRule]
    let visibility: String
    var status: String
    var revision: Int
    let created_at: String

    var artKind: ArtworkKind { ArtworkKind(rawValue: kind) ?? .light }
    var artColor: ArtworkColor { ArtworkColor(rawValue: color) ?? .warm }
    var position: SIMD3<Float> { [px, py, pz] }
}

/// 反応のルール：「きっかけ」と「動き」の組（プログラムではなく、決まった形だけ）
struct ArtworkRule: Codable, Hashable {
    let trigger: String
    let action: String
    var cooldown_ms: Int?

    init(_ trigger: ArtworkTrigger, _ action: ArtworkAction, cooldownMS: Int? = nil) {
        self.trigger = trigger.rawValue
        self.action = action.rawValue
        self.cooldown_ms = cooldownMS
    }

    enum CodingKeys: String, CodingKey { case trigger, action, cooldown_ms }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(cooldown_ms, forKey: .cooldown_ms)   // 無いときは項目ごと送らない（サーバーが許す形）
    }
}

enum ArtworkKind: String, CaseIterable, Identifiable {
    case photo, text, petals, light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .photo: return "写真パネル"
        case .text: return "光る文字"
        case .petals: return "花びら"
        case .light: return "光の玉"
        }
    }

    var caption: String {
        switch self {
        case .photo: return "思い出の写真を宙に飾る"
        case .text: return "ひとことを光の文字で"
        case .petals: return "花びらがくるくる舞う"
        case .light: return "やわらかく光って波紋が広がる"
        }
    }

    var symbol: String {
        switch self {
        case .photo: return "photo.on.rectangle"
        case .text: return "textformat"
        case .petals: return "leaf"
        case .light: return "sparkle"
        }
    }

    /// はじめに選んでおく「触れたときの動き」
    var defaultAction: ArtworkAction {
        switch self {
        case .photo: return .sway
        case .text: return .glow
        case .petals: return .burst
        case .light: return .ripple
        }
    }
}

enum ArtworkColor: String, CaseIterable, Identifiable {
    case warm, white, sakura, mint, sky

    var id: String { rawValue }

    var label: String {
        switch self {
        case .warm: return "夕日"
        case .white: return "白"
        case .sakura: return "桜"
        case .mint: return "若葉"
        case .sky: return "空"
        }
    }

    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .warm: return (1.0, 0.80, 0.52)
        case .white: return (1.0, 0.98, 0.94)
        case .sakura: return (1.0, 0.70, 0.79)
        case .mint: return (0.58, 0.94, 0.80)
        case .sky: return (0.60, 0.80, 1.0)
        }
    }
}

enum ArtworkTrigger: String {
    /// 近づいたとき（1.4m 以内）
    case approach
    /// 手で触れたとき
    case touch
    /// 画面で押したとき
    case tap
    /// 扉が開いたとき
    case open
}

enum ArtworkAction: String, CaseIterable, Identifiable {
    case glow, sway, ripple, burst, bounce

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glow: return "光る"
        case .sway: return "ゆれる"
        case .ripple: return "波紋"
        case .burst: return "はじける"
        case .bounce: return "はねる"
        }
    }
}

/// 場所の記憶の置き場所（gf_place_map）
struct PlaceMapInfo: Decodable {
    let path: String
    let anchor_name: String
    let byte_size: Int
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
