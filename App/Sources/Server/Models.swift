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

/// GATE の数字（gf_gate_stats）
struct GateStats: Decodable, Hashable {
    let visitor_count: Int
    let last_activity_at: String?
    let my_visits: Int
}

/// 場所の記憶の見つかりやすさ（gf_place_map_health。作った本人だけ）
struct PlaceMapHealth: Decodable, Hashable {
    let has_map: Bool
    let map_saved_at: String?
    let attempts: Int
    let found: Int
    let recent_attempts: Int
    let recent_found: Int
    let last_found_at: String?

    /// 撮り直したほうがよいか（場所の記憶が無い・最近 3 回以上探して、半分も見つかっていない）
    var looksStale: Bool { !has_map || (recent_attempts >= 3 && Double(recent_found) / Double(recent_attempts) < 0.5) }
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
    /// 映像パネルの表紙の絵（0010 を入れる前のサーバーでは無い）
    var thumb_path: String? = nil
    /// 映像・声の長さ（秒）
    var duration: Double? = nil

    var artKind: ArtworkKind { ArtworkKind(rawValue: kind) ?? .light }
    /// 一覧や見本に使う絵（写真パネルは写真、映像パネルは表紙の絵）
    var picturePath: String? {
        switch artKind {
        case .photo: return photo_path
        case .video: return thumb_path
        default: return nil
        }
    }
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
    // 選ぶ画面の並び順（2 列）
    case photo, video, text, voice, petals, light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .photo: return "写真パネル"
        case .video: return "映像パネル"
        case .text: return "光る文字"
        case .voice: return "声の玉"
        case .petals: return "花びら"
        case .light: return "光の玉"
        }
    }

    var caption: String {
        switch self {
        case .photo: return "思い出の写真を宙に飾る"
        case .video: return "15 秒までの動画を、触れると流す"
        case .text: return "ひとことを光の文字で"
        case .voice: return "触れると、そこから声が聞こえる"
        case .petals: return "花びらがくるくる舞う"
        case .light: return "やわらかく光って波紋が広がる"
        }
    }

    var symbol: String {
        switch self {
        case .photo: return "photo.on.rectangle"
        case .video: return "play.rectangle"
        case .text: return "textformat"
        case .voice: return "waveform.circle"
        case .petals: return "leaf"
        case .light: return "sparkle"
        }
    }

    /// 映像・声（触れると流れる。動きは選ばない）
    var isMedia: Bool { self == .video || self == .voice }

    /// はじめに選んでおく「触れたときの動き」
    var defaultAction: ArtworkAction {
        switch self {
        case .photo: return .sway
        case .video, .voice: return .play
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
    case glow, sway, ripple, burst, bounce, chime
    /// 映像・声を流す（映像パネル・声の玉だけ）
    case play

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glow: return "光る"
        case .sway: return "ゆれる"
        case .ripple: return "波紋"
        case .burst: return "はじける"
        case .bounce: return "はねる"
        case .chime: return "鳴る"
        case .play: return "流す"
        }
    }

    /// 写真・文字などで選べる動き（「流す」は映像・声だけ）
    static var visual: [ArtworkAction] { allCases.filter { $0 != .play } }
}

// MARK: - GATE の中の機能

/// 掲示板の話題（gf_board_list）
struct BoardThread: Decodable, Identifiable, Hashable {
    let id: UUID
    let author: UUID
    let author_name: String
    let topic: String
    let title: String
    let body: String
    let pinned: Bool
    let reply_count: Int
    let last_activity_at: String
    let created_at: String
    let unread: Bool

    var boardTopic: BoardTopic { BoardTopic(rawValue: topic) ?? .other }
}

/// 掲示板の返信（gf_board_replies_of）
struct BoardReply: Decodable, Identifiable, Hashable {
    let id: UUID
    let author: UUID
    let author_name: String
    let body: String
    let created_at: String
    /// 調べる話題のしるし（fact / observation / hypothesis / rumor）
    var label: String?
    var source: String?

    var evidence: EvidenceLabel? { label.flatMap(EvidenceLabel.init(rawValue:)) }
}

/// 共同調査のしるし（書いた人が選ぶ。確かさをサーバーが決めるのではない）
enum EvidenceLabel: String, CaseIterable, Identifiable {
    case fact, observation, hypothesis, rumor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fact: return "事実"
        case .observation: return "観察"
        case .hypothesis: return "仮説"
        case .rumor: return "噂"
        }
    }

    var caption: String {
        switch self {
        case .fact: return "記録や出典で確かめられること"
        case .observation: return "自分の目で見た・聞いたこと"
        case .hypothesis: return "たぶんこうではないか、という考え"
        case .rumor: return "人から聞いた話（確かではない）"
        }
    }
}

enum BoardTopic: String, CaseIterable, Identifiable {
    case memory, question, notice, investigation, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .memory: return "思い出話"
        case .question: return "質問"
        case .notice: return "お知らせ・注意"
        case .investigation: return "調べる（歴史・謎）"
        case .other: return "そのほか"
        }
    }

    var symbol: String {
        switch self {
        case .memory: return "heart.text.square"
        case .question: return "questionmark.bubble"
        case .notice: return "exclamationmark.triangle"
        case .investigation: return "magnifyingglass"
        case .other: return "text.bubble"
        }
    }
}

/// 手紙の一覧の 1 行（gf_my_letters。中身は入っていない）
struct LetterInfo: Decodable, Identifiable, Hashable {
    let id: UUID
    let gate_id: UUID
    let gate_title: String
    let author: UUID
    let author_name: String
    let recipient: UUID
    let recipient_name: String
    let open_at: String?
    let onsite: Bool
    let opened_at: String?
    let created_at: String
    /// 自分がほかの人に書いた手紙
    let sent: Bool
    /// 開く日時を過ぎている（日時の条件がなければ true）
    let time_ok: Bool
    /// いまこの GATE に入場している
    let here: Bool

    var isOpened: Bool { opened_at != nil }
    var openDate: Date? { open_at.flatMap(ServerDate.parse) }
    var isToSelf: Bool { author == recipient }
    /// いま開けるか（宛先の人から見て）
    var canOpenNow: Bool { isOpened || (time_ok && (!onsite || here)) }

    /// 閉じている理由（開けるなら nil）
    var lockReason: String? {
        if canOpenNow { return nil }
        if !time_ok, let date = openDate {
            return "\(ServerDate.day(date)) に開けます" + (onsite ? "（現地で）" : "")
        }
        return "\(gate_title) で扉を開けると読めます"
    }
}

/// 開いた手紙（gf_open_letter）
struct LetterContent: Decodable, Identifiable, Hashable {
    let id: UUID
    let author_name: String
    let recipient_name: String
    let body: String
    let photo_path: String?
    let created_at: String
    let opened_at: String?
}

/// GATE の思い出（gf_memory_list）
struct MemorySummary: Decodable, Identifiable, Hashable {
    let id: UUID
    let owner: UUID
    let owner_name: String
    let title: String
    let note: String
    let visibility: String
    let created_at: String
    let item_count: Int
    let cover_path: String?
    let member_count: Int
    let is_member: Bool
    let can_add: Bool
}

/// 思い出の写真（表 gf_memory_items）
struct MemoryItem: Decodable, Identifiable, Hashable {
    let id: UUID
    let memory_id: UUID
    let author: UUID
    /// ファイルの置き場所（写真・動画・声）
    let photo_path: String
    let caption: String
    let created_at: String
    /// photo / video / voice（0009 を入れる前のサーバーでは無い＝写真）
    var media_kind: String?
    /// 動画の表紙の絵
    var thumb_path: String?
    /// 動画・声の長さ（秒）
    var duration: Double?

    var kind: MemoryMediaKind { MemoryMediaKind(rawValue: media_kind ?? "photo") ?? .photo }
    /// 一覧に並べる絵（動画は表紙の絵、声は無し）
    var picturePath: String? {
        switch kind {
        case .photo: return photo_path
        case .video: return thumb_path
        case .voice: return nil
        }
    }
}

enum MemoryMediaKind: String {
    case photo, video, voice

    var fileExtension: String {
        switch self {
        case .photo: return "jpg"
        case .video: return "mp4"
        case .voice: return "m4a"
        }
    }
}

/// 長さを「0:12」の形に
func durationText(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// 自分が作った・仲間に入っている思い出（gf_my_memories）
struct MyMemory: Decodable, Identifiable, Hashable {
    let id: UUID
    let gate_id: UUID
    let gate_title: String
    let owner: UUID
    let owner_name: String
    let title: String
    let created_at: String
    let item_count: Int
    let cover_path: String?
}

/// 保存・図鑑の 1 行（gf_my_collection）
struct CollectionGate: Decodable, Identifiable, Hashable {
    let gate_id: UUID
    let title: String
    let owner: UUID
    let owner_name: String
    let cover_path: String?
    let approx_lat: Double
    let approx_lon: Double
    let first_at: String?
    let last_at: String?
    let visits: Int
    let shared: Bool
    let saved_at: String?

    var id: UUID { gate_id }
}

/// 友達の図鑑の 1 行（gf_friend_atlas）
struct FriendAtlasGate: Decodable, Identifiable, Hashable {
    let gate_id: UUID
    let title: String
    let owner: UUID
    let owner_name: String
    let cover_path: String?
    let approx_lat: Double
    let approx_lon: Double
    let first_at: String
    let visits: Int

    var id: UUID { gate_id }
}

/// ブロックした人（gf_my_blocks）
struct BlockedUser: Decodable, Identifiable, Hashable {
    let user_id: UUID
    let display_name: String
    let handle: String
    let created_at: String

    var id: UUID { user_id }
}

/// 通報の理由（サーバーの gf_reports.reason と同じ）
enum ReportReason: String, CaseIterable, Identifiable {
    case harassment, inappropriate, privacy, dangerous, spam, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .harassment: return "いやがらせ・悪口"
        case .inappropriate: return "不適切な内容"
        case .privacy: return "人の顔・家・個人の情報が写っている"
        case .dangerous: return "危ない場所・立ち入り禁止の場所"
        case .spam: return "宣伝・迷惑"
        case .other: return "そのほか"
        }
    }
}

/// 通報できるもの（サーバーの gf_reports.target_kind と同じ）
enum ReportTarget: String {
    case gate, graffiti, artwork, thread, reply, memory, memory_item, letter, user, dm, trail, snapshot
}

// MARK: - TRAIL と今と昔

/// TRAIL の一覧の 1 行（gf_trail_list）
struct TrailSummary: Decodable, Identifiable, Hashable {
    let id: UUID
    let owner: UUID
    let owner_name: String
    let title: String
    let note: String
    let visibility: String
    let created_at: String
    let stop_count: Int
    let cover_path: String?
    let reached: Int
    let completed: Bool
    let started: Bool

    var inProgress: Bool { started && !completed }
}

/// TRAIL の地点（gf_trail_stops_of）。見られない GATE は名前・位置が入っていない
struct TrailStop: Decodable, Identifiable, Hashable {
    let seq: Int
    let gate_id: UUID?
    let title: String
    let cover_path: String?
    let approx_lat: Double?
    let approx_lon: Double?
    let visible: Bool
    let reached: Bool

    var id: Int { seq }
}

/// この入場で進んだ TRAIL（gf_trails_reached_by）
struct TrailReached: Decodable, Hashable {
    let trail_id: UUID
    let title: String
    let reached: Int
    let stop_count: Int
    let completed: Bool
}

/// 今と昔の写真（表 gf_snapshots）
struct Snapshot: Decodable, Identifiable, Hashable {
    let id: UUID
    let gate_id: UUID
    let author: UUID
    let photo_path: String
    let visibility: String
    let created_at: String
}

// MARK: - お知らせと DM

/// お知らせ（gf_my_notifications）。現地だけの中身は入っていない
struct NotificationItem: Decodable, Identifiable, Hashable {
    let kind: String
    let actor: UUID
    let actor_name: String
    let gate_id: UUID?
    let gate_title: String?
    let ref_id: UUID?
    let created_at: String
    let unread: Bool

    var id: String { "\(kind)-\(actor.uuidString)-\(ref_id?.uuidString ?? "")-\(created_at)" }

    var text: String {
        let who = "\(actor_name) さん"
        let gate = gate_title.map { "「\($0)」" } ?? "GATE"
        switch kind {
        case "place_map_stale":
            return "\(gate)の場所の記憶が、ほかの人の iPhone で見つかりにくくなっています。現地で扉を開けて「場所の記憶を撮り直す」を押してください"
        case "gate_graffiti": return "\(who)が\(gate)に記憶を残しました"
        case "gate_artwork": return "\(who)が\(gate)に作品を置きました"
        case "board_thread": return "\(who)が\(gate)の掲示板に話題を立てました"
        case "board_reply": return "\(who)があなたの話題に返信しました（\(gate)）"
        case "letter": return "\(who)から手紙が届きました。\(gate)で開けます"
        case "letter_opened": return "\(who)があなたの手紙を開きました（\(gate)）"
        case "memory_invite": return "\(who)が\(gate)の思い出の仲間に入れてくれました"
        case "memory_photo": return "\(who)が思い出に写真を足しました（\(gate)）"
        case "like": return "\(who)があなたの記憶にいいねしました（\(gate)）"
        case "follow": return "\(who)があなたをフォローしました"
        default: return "\(who)からのお知らせ"
        }
    }

    var symbol: String {
        switch kind {
        case "gate_graffiti": return "square.stack"
        case "gate_artwork": return "sparkles"
        case "board_thread", "board_reply": return "bubble.left.and.bubble.right"
        case "letter", "letter_opened": return "envelope"
        case "memory_invite", "memory_photo": return "photo.stack"
        case "like": return "heart"
        case "follow": return "person.badge.plus"
        case "place_map_stale": return "arrow.triangle.2.circlepath.camera"
        default: return "bell"
        }
    }

    /// 押したときに開く GATE の中の場所
    var gateTab: GateTab {
        switch kind {
        case "board_thread", "board_reply": return .board
        case "letter", "letter_opened": return .letters
        case "memory_invite", "memory_photo": return .memories
        default: return .graffiti
        }
    }
}

struct UnreadCounts: Decodable {
    let notifications: Int
    let messages: Int
}

/// DM の相手ごとの一覧（gf_dm_threads）
struct DMThread: Decodable, Identifiable, Hashable {
    let other: UUID
    let other_name: String
    let last_body: String
    let last_at: String
    let last_from_me: Bool
    let unread: Int
    let can_send: Bool

    var id: UUID { other }
}

/// DM のメッセージ（gf_dm_messages_with）
struct DMMessage: Decodable, Identifiable, Hashable {
    let id: UUID
    let sender: UUID
    let body: String
    let created_at: String
    let read_at: String?
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

    /// 「2027年4月1日 9:00」など
    static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日 H:mm"
        return f.string(from: d)
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
