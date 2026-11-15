import CoreLocation
import Foundation
import Supabase

/// カードのお気に入り・返信、掲示板の「解決しました」、名前で探す、友達の TRAIL、TRAIL を直す・開く、
/// 自分の訪問の記録、お知らせの設定（0018_gf_cards_trails_search.sql）。判定はサーバーで、ここは送って受け取るだけ。
extension GateAPI {
    // MARK: カード

    /// GATE の中のカードごとの返信の数と、自分のお気に入りか（0018 の前のサーバーでは nil＝出さない）
    func cardExtras(in gate: UUID) async throws -> [UUID: CardExtra]? {
        do {
            let rows: [CardExtra] = try await client.rpc("gf_card_extras", params: MoreGateParam(p_gate: gate)).execute().value
            return Dictionary(rows.map { ($0.graffiti_id, $0) }, uniquingKeysWith: { a, _ in a })
        } catch let error where ErrorText.isMissingFunction(error) {
            return nil
        }
    }

    @discardableResult
    func saveCard(_ card: UUID, on: Bool) async throws -> Bool {
        try await client.rpc("gf_save_card", params: SaveCardParam(p_card: card, p_on: on)).execute().value
    }

    func mySavedCards() async throws -> [SavedCard] {
        try await client.rpc("gf_my_saved_cards").execute().value
    }

    func cardComments(_ card: UUID) async throws -> [CardComment] {
        try await client.rpc("gf_card_comments_of", params: CardParam(p_card: card)).execute().value
    }

    @discardableResult
    func addCardComment(_ card: UUID, body: String) async throws -> UUID {
        try await client.rpc("gf_card_comment", params: CardCommentParam(p_card: card, p_body: body)).execute().value
    }

    func deleteCardComment(_ id: UUID) async throws {
        try await client.rpc("gf_delete_card_comment", params: IDParam(p_id: id)).execute()
    }

    // MARK: 掲示板

    func resolveThread(_ thread: UUID, on: Bool) async throws {
        try await client.rpc("gf_board_resolve", params: ResolveParam(p_thread: thread, p_on: on)).execute()
    }

    // MARK: 名前で探す

    func searchGates(_ query: String, near: (lat: Double, lon: Double)?) async throws -> [GateSearchHit] {
        try await client.rpc("gf_search_gates",
                             params: SearchParam(p_query: query, p_lat: near?.lat, p_lon: near?.lon)).execute().value
    }

    func searchTrails(_ query: String, near: (lat: Double, lon: Double)?) async throws -> [TrailSummary] {
        try await client.rpc("gf_trail_search",
                             params: SearchParam(p_query: query, p_lat: near?.lat, p_lon: near?.lon)).execute().value
    }

    // MARK: TRAIL

    /// その人が作った TRAIL のうち、自分が見てよいもの
    func userTrails(_ user: UUID) async throws -> [TrailSummary] {
        try await client.rpc("gf_user_trails", params: UserParam(p_user: user)).execute().value
    }

    /// リンクで開いた TRAIL（見てよくなければ nil）
    func trail(_ id: UUID) async throws -> TrailSummary? {
        let rows: [TrailSummary] = try await client.rpc("gf_trail_get", params: MoreTrailParam(p_trail: id)).execute().value
        return rows.first
    }

    func updateTrail(_ id: UUID, title: String, note: String, visibility: Visibility) async throws {
        try await client.rpc("gf_update_trail", params: UpdateTrailParam(p_trail: id, p_title: title, p_note: note,
                                                                          p_visibility: visibility.rawValue)).execute()
    }

    // MARK: 近くにある友達のカード（0020）

    /// いまいる所から 300m 以内の GATE にある、友達のカード（近いもの・新しいものから）
    func nearbyCards(at location: CLLocation) async throws -> [NearbyCard] {
        try await client.rpc("gf_nearby_cards",
                             params: NearbyCardsParam(p_lat: location.coordinate.latitude,
                                                      p_lon: location.coordinate.longitude,
                                                      p_accuracy: Float(max(location.horizontalAccuracy, 0))))
            .execute().value
    }

    // MARK: 自分の訪問・お知らせの設定

    /// 自分がその GATE に入った日（新しい順）
    func myVisitHistory(_ gate: UUID) async throws -> [Date] {
        let rows: [VisitDay] = try await client.rpc("gf_my_visit_history", params: MoreGateParam(p_gate: gate)).execute().value
        return rows.compactMap { ServerDate.parse($0.visited_at) }
    }

    func notifyMutes() async throws -> Set<String> {
        let rows: [String] = try await client.rpc("gf_my_notify_mutes").execute().value
        return Set(rows)
    }

    @discardableResult
    func setNotifyMute(_ kinds: [String], muted: Bool) async throws -> Set<String> {
        let rows: [String] = try await client.rpc("gf_set_notify_mute",
                                                  params: MuteParam(p_kinds: kinds, p_muted: muted)).execute().value
        return Set(rows)
    }
}

// MARK: - 形

/// カードごとの返信の数と、自分のお気に入りか（gf_card_extras）
struct CardExtra: Decodable, Hashable {
    let graffiti_id: UUID
    var comments: Int
    var saved: Bool
}

/// カードへの返信（gf_card_comments_of）
struct CardComment: Decodable, Identifiable, Hashable {
    let id: UUID
    let author: UUID
    let author_name: String
    let body: String
    let created_at: String
    let mine: Bool
    let can_delete: Bool
}

/// お気に入りにしたカード（gf_my_saved_cards）。文は自分のカードだけ、写真は見てよいときだけ
struct SavedCard: Decodable, Identifiable, Hashable {
    let id: UUID
    let gate_id: UUID
    let gate_title: String
    let author: UUID
    let author_name: String
    let body: String?
    let photo_path: String?
    let mine: Bool
    let created_at: String
    let saved_at: String
    let approx_lat: Double
    let approx_lon: Double
}

/// 名前で探した GATE（gf_search_gates）。場所はおおよそだけ
struct GateSearchHit: Decodable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let kind: String
    let cover_path: String?
    let owner: UUID
    let owner_name: String
    let mine: Bool
    let friend: Bool
    let approx_lat: Double
    let approx_lon: Double
    let distance_m: Double?
    let created_at: String

    var gateKind: GateKind { GateKind(rawValue: kind) ?? .place }
}

/// 近くにある友達のカード（gf_nearby_cards）。GATE の場所はおおよそ、距離もおおよそ
struct NearbyCard: Decodable, Identifiable, Hashable {
    let id: UUID
    let gate_id: UUID
    let gate_title: String
    let gate_kind: String
    let author: UUID
    let author_name: String
    let body: String
    let photo_path: String?
    let created_at: String
    let approx_lat: Double
    let approx_lon: Double
    let distance_m: Double

    var gateCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: approx_lat, longitude: approx_lon) }
}

private struct NearbyCardsParam: Encodable { let p_lat: Double; let p_lon: Double; let p_accuracy: Float }
private struct VisitDay: Decodable { let visited_at: String }
private struct MoreGateParam: Encodable { let p_gate: UUID }
private struct MoreTrailParam: Encodable { let p_trail: UUID }
private struct UserParam: Encodable { let p_user: UUID }
private struct CardParam: Encodable { let p_card: UUID }
private struct IDParam: Encodable { let p_id: UUID }
private struct SaveCardParam: Encodable { let p_card: UUID; let p_on: Bool }
private struct CardCommentParam: Encodable { let p_card: UUID; let p_body: String }
private struct ResolveParam: Encodable { let p_thread: UUID; let p_on: Bool }
private struct MuteParam: Encodable { let p_kinds: [String]; let p_muted: Bool }
private struct UpdateTrailParam: Encodable {
    let p_trail: UUID
    let p_title: String
    let p_note: String
    let p_visibility: String
}
private struct SearchParam: Encodable {
    let p_query: String
    let p_lat: Double?
    let p_lon: Double?

    // 位置が無いときも null として送る（関数の引数の形を 1 つにそろえる）
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_query, forKey: .p_query)
        try c.encode(p_lat, forKey: .p_lat)
        try c.encode(p_lon, forKey: .p_lon)
    }

    enum CodingKeys: String, CodingKey { case p_query, p_lat, p_lon }
}
