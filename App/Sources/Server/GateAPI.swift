import CoreLocation
import Foundation
import Supabase

/// gf_ の関数を呼ぶ窓口。判定はすべてサーバーが行い、ここは送って結果を受け取るだけ。
struct GateAPI {
    let client: SupabaseClient

    // MARK: 見つける

    func nearby(_ location: CLLocation) async throws -> [NearbyGate] {
        try await client.rpc("gf_discover_nearby", params: LatLon(location)).execute().value
    }

    func summary(_ gate: UUID) async throws -> GateSummary? {
        let rows: [GateSummary] = try await client.rpc("gf_gate_summary", params: GateParam(p_gate: gate)).execute().value
        return rows.first
    }

    func friendFeed() async throws -> [FeedCard] {
        do {
            return try await client.rpc("gf_friend_feed2").execute().value
        } catch let error where ErrorText.isMissingFunction(error) {
            // 0027 の前のサーバー（仕上げなし）
            return try await client.rpc("gf_friend_feed").execute().value
        }
    }

    func candidates(_ location: CLLocation, print: [Float]) async throws -> [MatchCandidate] {
        try await client.rpc("gf_match_candidates",
                             params: CandidateParams(p_lat: location.coordinate.latitude,
                                                     p_lon: location.coordinate.longitude,
                                                     p_print: print,
                                                     p_print_rev: FeaturePrint.revision)).execute().value
    }

    // MARK: 作る・入る・残す

    func requestChallenge() async throws -> UUID {
        let rows: [Challenge] = try await client.rpc("gf_request_challenge").execute().value
        guard let c = rows.first else { throw URLError(.badServerResponse) }
        return c.challenge_id
    }

    /// GATE を作る。clientKey が同じなら送り直しても 1 つしかできない。
    func createGate(clientKey: String, title: String, note: String, kind: String, visibility: Visibility,
                    location: CLLocation, heading: Double?, coverPath: String?, prints: [[Float]]) async throws -> UUID {
        let challenge = try await requestChallenge()
        let params = CreateGateParams(
            p_client_key: clientKey, p_challenge: challenge, p_title: title, p_note: note, p_kind: kind,
            p_lat: location.coordinate.latitude, p_lon: location.coordinate.longitude,
            p_accuracy: location.horizontalAccuracy,
            p_heading: heading,
            p_visibility: visibility.rawValue, p_cover_path: coverPath,
            p_refs: prints.map { RefPayload(print: $0, rev: FeaturePrint.revision) })
        return try await client.rpc("gf_create_gate", params: params).execute().value
    }

    /// 自分の GATE 1 つ（本人には正確な位置）
    func myGate(_ id: UUID) async throws -> MyGate? {
        let rows: [MyGate] = try await client.from("gf_gates")
            .select("id,title,visibility,status,created_at,cover_path,lat,lon,kind,note")
            .eq("id", value: id.uuidString)
            .limit(1)
            .execute().value
        return rows.first
    }

    /// 扉の大きさ（作った本人が決めたもの。1 = 人が通る大きさ）
    func doorScale(_ gate: UUID) async throws -> Float {
        let door: DoorInfo = try await client.rpc("gf_gate_door", params: GateParam(p_gate: gate)).execute().value
        return door.scale
    }

    /// 扉の大きさと見た目
    func doorInfo(_ gate: UUID) async throws -> (scale: Float, design: DoorDesign) {
        let door: DoorInfo = try await client.rpc("gf_gate_door", params: GateParam(p_gate: gate)).execute().value
        return (door.scale, DoorDesign(raw: door.style))
    }

    /// 扉の見た目を変える（作った本人だけ）
    func setDoorStyle(gate: UUID, design: DoorDesign) async throws {
        struct P: Encodable { let p_gate: UUID; let p_style: String }
        try await client.rpc("gf_set_door_style", params: P(p_gate: gate, p_style: design.rawValue)).execute()
    }

    func setDoorScale(gate: UUID, scale: Float) async throws {
        try await client.rpc("gf_set_door_scale", params: DoorScaleParams(p_gate: gate, p_scale: scale)).execute()
    }

    /// 見本の写真の特徴の数と上限（作った本人だけ）
    func gateRefCount(_ gate: UUID) async throws -> RefCount {
        try await client.rpc("gf_gate_ref_count", params: GateParam(p_gate: gate)).execute().value
    }

    /// 別の時間の見え方を足す（作った本人が現地で。足したあとの数を返す）
    func addGateRefs(gate: UUID, location: CLLocation, prints: [[Float]]) async throws -> Int {
        let challenge = try await requestChallenge()
        let params = AddRefsParams(p_gate: gate, p_challenge: challenge,
                                   p_lat: location.coordinate.latitude, p_lon: location.coordinate.longitude,
                                   p_accuracy: location.horizontalAccuracy,
                                   p_refs: prints.map { RefPayload(print: $0, rev: FeaturePrint.revision) })
        return try await client.rpc("gf_add_gate_refs", params: params).execute().value
    }

    /// GATE の位置の記録の置き場所（作った本人か、入場中だけ返る）
    func placeMap(_ gate: UUID) async throws -> PlaceMapInfo? {
        let rows: [PlaceMapInfo] = try await client.rpc("gf_place_map", params: GateParam(p_gate: gate)).execute().value
        return rows.first
    }

    func registerPlaceMap(gate: UUID, path: String, size: Int, anchorName: String) async throws {
        try await client.rpc("gf_register_place_map",
                             params: PlaceMapParams(p_gate: gate, p_path: path, p_size: size, p_anchor: anchorName))
            .execute()
    }

    /// 現地で入る（位置と、いま写した写真の特徴を送る）
    func enter(gate: UUID, location: CLLocation, print: [Float]) async throws -> EnterResult {
        let challenge = try await requestChallenge()
        let params = EnterParams(p_gate: gate, p_challenge: challenge,
                                 p_lat: location.coordinate.latitude, p_lon: location.coordinate.longitude,
                                 p_accuracy: location.horizontalAccuracy,
                                 p_print: print, p_print_rev: FeaturePrint.revision)
        return try await client.rpc("gf_enter", params: params).execute().value
    }

    func postGraffiti(visit: UUID, body: String, photoPath: String?, visibility: Visibility,
                      localOnly: Bool) async throws -> UUID {
        try await client.rpc("gf_post_graffiti",
                             params: PostParams(p_visit: visit, p_body: body, p_photo_path: photoPath,
                                                p_visibility: visibility.rawValue, p_local_only: localOnly))
            .execute().value
    }

    /// カードの仕上げを変える（書いた本人だけ）
    func setCardFinish(_ id: UUID, finish: CardFinish) async throws {
        struct P: Encodable { let p_card: UUID; let p_finish: String }
        try await client.rpc("gf_set_card_finish", params: P(p_card: id, p_finish: finish.rawValue)).execute()
    }

    func deleteGraffiti(_ id: UUID) async throws {
        try await client.rpc("gf_delete_graffiti", params: IDParam(p_id: id)).execute()
    }

    /// GATE の中のグラフィティ（入場中なら友達のものも、そうでなければ自分のものだけが返る）
    func graffiti(in gate: UUID) async throws -> [Graffiti] {
        do {
            return try await client.from("gf_graffiti")
                .select("id,gate_id,author,body,photo_path,visibility,local_only,created_at,in_atlas,edited_at,finish")
                .eq("gate_id", value: gate.uuidString)
                .order("created_at", ascending: false)
                .limit(200)
                .execute().value
        } catch let error where ErrorText.isMissingColumn(error) {
            // 0026 の前のサーバー（カードの仕上げの欄が無い）
        }
        do {
            return try await client.from("gf_graffiti")
                .select("id,gate_id,author,body,photo_path,visibility,local_only,created_at,in_atlas,edited_at")
                .eq("gate_id", value: gate.uuidString)
                .order("created_at", ascending: false)
                .limit(200)
                .execute().value
        } catch let error where ErrorText.isMissingColumn(error) {
            // 0019 の前のサーバー（直した時刻の欄が無い）
        }
        do {
            return try await client.from("gf_graffiti")
                .select("id,gate_id,author,body,photo_path,visibility,local_only,created_at,in_atlas")
                .eq("gate_id", value: gate.uuidString)
                .order("created_at", ascending: false)
                .limit(200)
                .execute().value
        } catch let error where ErrorText.isMissingColumn(error) {
            // 0017 の前のサーバー（図鑑に載せるかの欄が無い）
            return try await client.from("gf_graffiti")
                .select("id,gate_id,author,body,photo_path,visibility,local_only,created_at")
                .eq("gate_id", value: gate.uuidString)
                .order("created_at", ascending: false)
                .limit(200)
                .execute().value
        }
    }

    /// 自分がカードを残した GATE（ホームの新着で「並べる」を出すかを決める）
    func myGraffitiGates(me: UUID) async throws -> Set<UUID> {
        let rows: [GateIDRow] = try await client.from("gf_graffiti")
            .select("gate_id")
            .eq("author", value: me.uuidString)
            .order("created_at", ascending: false)
            .limit(1000)
            .execute().value
        return Set(rows.map(\.gate_id))
    }

    /// ある GATE の自分のカード（新しい順。自分のものはいつでも読める）
    func myGraffiti(in gate: UUID, me: UUID) async throws -> [Graffiti] {
        try await client.from("gf_graffiti")
            .select("id,gate_id,author,body,photo_path,visibility,local_only,created_at")
            .eq("gate_id", value: gate.uuidString)
            .eq("author", value: me.uuidString)
            .order("created_at", ascending: false)
            .limit(50)
            .execute().value
    }

    // MARK: AR の飾り

    /// GATE の AR の飾り（入場中なら公開範囲が合うもの、そうでなければ自分のものだけが返る）
    func artworks(in gate: UUID) async throws -> [Artwork] {
        let base = "id,gate_id,owner,kind,body,photo_path,color,px,py,pz,yaw,scale,rules,visibility,status,revision,created_at"
        // 新しいサーバーから順に試す（0011：置き直しの印、0010：映像・声、それより前）
        let attempts = [base + ",thumb_path,duration,needs_replace", base + ",thumb_path,duration", base]
        var lastError: Error?
        for columns in attempts {
            do {
                return try await client.from("gf_artworks")
                    .select(columns)
                    .eq("gate_id", value: gate.uuidString)
                    .order("created_at", ascending: true)
                    .limit(60)
                    .execute().value
            } catch let error where ErrorText.isMissingColumn(error) {
                lastError = error
            }
        }
        throw lastError ?? URLError(.badServerResponse)
    }

    /// AR の飾りを置く（入場中だけ）。置いた AR の飾りの ID を返す。
    /// 映像・声は path にファイル、映像は thumbPath に表紙の絵、duration に長さ（秒）
    func placeArtwork(visit: UUID, kind: ArtworkKind, body: String, photoPath: String?, thumbPath: String? = nil,
                      duration: Double? = nil, color: ArtworkColor, position: SIMD3<Float>, yaw: Float, scale: Float,
                      rules: [ArtworkRule], visibility: Visibility, draft: Bool = false) async throws -> UUID {
        let params = PlaceArtworkParams(p_visit: visit, p_kind: kind.rawValue, p_body: body,
                                        p_photo_path: photoPath, p_color: color.rawValue,
                                        p_px: position.x, p_py: position.y, p_pz: position.z,
                                        p_yaw: yaw, p_scale: scale, p_rules: rules,
                                        p_visibility: visibility.rawValue)
        do {
            return try await client.rpc("gf_place_artwork3",
                                        params: PlaceArtwork2Params(base: params, p_thumb: thumbPath,
                                                                    p_duration: duration.map { Float($0) },
                                                                    p_status: draft ? "draft" : "published"))
                .execute().value
        } catch let error where ErrorText.isMissingFunction(error) && !draft {
            // 0011 を入れる前のサーバー（下書きはまだ無い）
        }
        do {
            return try await client.rpc("gf_place_artwork2",
                                        params: PlaceArtwork2Params(base: params, p_thumb: thumbPath,
                                                                    p_duration: duration.map { Float($0) }))
                .execute().value
        } catch let error where ErrorText.isMissingFunction(error) && !kind.isMedia {
            // 0010 を入れる前のサーバー
            return try await client.rpc("gf_place_artwork", params: params).execute().value
        }
    }

    /// 自分の AR の飾りを置き直す。新しい版の番号を返す（ほかの端末で先に動かしていたら断られる）。
    func moveArtwork(_ id: UUID, visit: UUID, position: SIMD3<Float>, yaw: Float, scale: Float,
                     revision: Int) async throws -> Int {
        try await client.rpc("gf_move_artwork",
                             params: MoveArtworkParams(p_id: id, p_visit: visit, p_px: position.x, p_py: position.y,
                                                       p_pz: position.z, p_yaw: yaw, p_scale: scale,
                                                       p_revision: revision))
            .execute().value
    }

    func setArtworkStatus(_ id: UUID, hidden: Bool) async throws {
        try await setArtworkStatus(id, status: hidden ? "hidden" : "published")
    }

    /// 自分の AR の飾りの状態（draft 下書き／published 公開／hidden 非公開）
    func setArtworkStatus(_ id: UUID, status: String) async throws {
        try await client.rpc("gf_set_artwork_status", params: ArtworkStatusParams(p_id: id, p_status: status))
            .execute()
    }

    /// 「置き直しが必要」を、いまの位置のままで外す
    func keepArtworkPlace(_ id: UUID) async throws {
        try await client.rpc("gf_keep_artwork_place", params: IDParam(p_id: id)).execute()
    }

    /// 自分の AR の飾りを消す。消したファイルの名前を返す（映像は表紙の絵も。ファイルも消すため）
    func deleteArtwork(_ id: UUID, knownPaths: [String]) async throws -> [String] {
        do {
            return try await client.rpc("gf_delete_artwork2", params: IDParam(p_id: id)).execute().value
        } catch let error where ErrorText.isMissingFunction(error) {
            try await client.rpc("gf_delete_artwork", params: IDParam(p_id: id)).execute()
            return knownPaths
        }
    }

    func myGates(owner: UUID) async throws -> [MyGate] {
        try await client.from("gf_gates")
            .select("id,title,visibility,status,created_at,cover_path,lat,lon,kind,note")
            .eq("owner", value: owner.uuidString)
            .order("created_at", ascending: false)
            .execute().value
    }

    // MARK: 人

    func names(of ids: [UUID]) async throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        let rows: [ProfileRow] = try await client.from("profiles")
            .select("id,display_name,handle")
            .in("id", values: ids.map(\.uuidString))
            .execute().value
        return Dictionary(rows.map { ($0.id, $0.display_name) }, uniquingKeysWith: { a, _ in a })
    }

    func findProfile(handle: String) async throws -> ProfileRow? {
        let rows: [ProfileRow] = try await client.from("profiles")
            .select("id,display_name,handle")
            .eq("handle", value: handle.lowercased())
            .limit(1)
            .execute().value
        return rows.first
    }

    func follow(_ target: UUID, me: UUID) async throws {
        // すでにフォローしていれば何もしない（follows には書き換えの権限がないので、重なりは無視する）
        try await client.from("follows")
            .upsert(FollowRow(follower: me, followee: target), ignoreDuplicates: true)
            .execute()
    }

    func isFollowing(_ target: UUID, me: UUID) async throws -> Bool {
        let rows: [FollowRow] = try await client.from("follows")
            .select("follower,followee")
            .eq("follower", value: me.uuidString)
            .eq("followee", value: target.uuidString)
            .execute().value
        return !rows.isEmpty
    }
}

// MARK: - 送る形（関数の引数名に合わせる。値が無いものも null として必ず送る＝サーバーが関数を見分けるため）

private struct LatLon: Encodable {
    let p_lat: Double
    let p_lon: Double
    init(_ l: CLLocation) {
        p_lat = l.coordinate.latitude
        p_lon = l.coordinate.longitude
    }
}

private struct GateParam: Encodable { let p_gate: UUID }

private struct PlaceMapParams: Encodable {
    let p_gate: UUID
    let p_path: String
    let p_size: Int
    let p_anchor: String
}
private struct IDParam: Encodable { let p_id: UUID }

private struct CandidateParams: Encodable {
    let p_lat: Double
    let p_lon: Double
    let p_print: [Float]
    let p_print_rev: Int
}

private struct RefPayload: Encodable {
    let print: [Float]
    let rev: Int
}

private struct CreateGateParams: Encodable {
    let p_client_key: String
    let p_challenge: UUID
    let p_title: String
    let p_note: String
    let p_kind: String
    let p_lat: Double
    let p_lon: Double
    let p_accuracy: Double
    let p_heading: Double?
    let p_visibility: String
    let p_cover_path: String?
    let p_refs: [RefPayload]

    enum CodingKeys: String, CodingKey {
        case p_client_key, p_challenge, p_title, p_note, p_kind, p_lat, p_lon, p_accuracy, p_heading
        case p_visibility, p_cover_path, p_refs
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_client_key, forKey: .p_client_key)
        try c.encode(p_challenge, forKey: .p_challenge)
        try c.encode(p_title, forKey: .p_title)
        try c.encode(p_note, forKey: .p_note)
        try c.encode(p_kind, forKey: .p_kind)
        try c.encode(p_lat, forKey: .p_lat)
        try c.encode(p_lon, forKey: .p_lon)
        try c.encode(p_accuracy, forKey: .p_accuracy)
        try c.encode(p_heading, forKey: .p_heading)          // nil は null
        try c.encode(p_visibility, forKey: .p_visibility)
        try c.encode(p_cover_path, forKey: .p_cover_path)    // nil は null
        try c.encode(p_refs, forKey: .p_refs)
    }
}

private struct EnterParams: Encodable {
    let p_gate: UUID
    let p_challenge: UUID
    let p_lat: Double
    let p_lon: Double
    let p_accuracy: Double
    let p_print: [Float]
    let p_print_rev: Int
}

private struct PostParams: Encodable {
    let p_visit: UUID
    let p_body: String
    let p_photo_path: String?
    let p_visibility: String
    let p_local_only: Bool

    enum CodingKeys: String, CodingKey {
        case p_visit, p_body, p_photo_path, p_visibility, p_local_only
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_visit, forKey: .p_visit)
        try c.encode(p_body, forKey: .p_body)
        try c.encode(p_photo_path, forKey: .p_photo_path)    // nil は null
        try c.encode(p_visibility, forKey: .p_visibility)
        try c.encode(p_local_only, forKey: .p_local_only)
    }
}

private struct PlaceArtworkParams: Encodable {
    let p_visit: UUID
    let p_kind: String
    let p_body: String
    let p_photo_path: String?
    let p_color: String
    let p_px: Float
    let p_py: Float
    let p_pz: Float
    let p_yaw: Float
    let p_scale: Float
    let p_rules: [ArtworkRule]
    let p_visibility: String

    enum CodingKeys: String, CodingKey {
        case p_visit, p_kind, p_body, p_photo_path, p_color, p_px, p_py, p_pz, p_yaw, p_scale, p_rules, p_visibility
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_visit, forKey: .p_visit)
        try c.encode(p_kind, forKey: .p_kind)
        try c.encode(p_body, forKey: .p_body)
        try c.encode(p_photo_path, forKey: .p_photo_path)    // nil は null
        try c.encode(p_color, forKey: .p_color)
        try c.encode(p_px, forKey: .p_px)
        try c.encode(p_py, forKey: .p_py)
        try c.encode(p_pz, forKey: .p_pz)
        try c.encode(p_yaw, forKey: .p_yaw)
        try c.encode(p_scale, forKey: .p_scale)
        try c.encode(p_rules, forKey: .p_rules)
        try c.encode(p_visibility, forKey: .p_visibility)
    }
}

/// gf_place_artwork2：前の形に、表紙の絵と長さを足す（p_photo_path は p_path という名前で送る）
private struct PlaceArtwork2Params: Encodable {
    let base: PlaceArtworkParams
    let p_thumb: String?
    let p_duration: Float?
    /// gf_place_artwork3 のときだけ（draft / published）
    var p_status: String? = nil

    enum CodingKeys: String, CodingKey {
        case p_visit, p_kind, p_body, p_path, p_thumb, p_duration, p_color, p_px, p_py, p_pz, p_yaw, p_scale, p_rules,
             p_visibility, p_status
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(base.p_visit, forKey: .p_visit)
        try c.encode(base.p_kind, forKey: .p_kind)
        try c.encode(base.p_body, forKey: .p_body)
        try c.encode(base.p_photo_path, forKey: .p_path)    // nil は null
        try c.encode(p_thumb, forKey: .p_thumb)
        try c.encode(p_duration, forKey: .p_duration)
        try c.encode(base.p_color, forKey: .p_color)
        try c.encode(base.p_px, forKey: .p_px)
        try c.encode(base.p_py, forKey: .p_py)
        try c.encode(base.p_pz, forKey: .p_pz)
        try c.encode(base.p_yaw, forKey: .p_yaw)
        try c.encode(base.p_scale, forKey: .p_scale)
        try c.encode(base.p_rules, forKey: .p_rules)
        try c.encode(base.p_visibility, forKey: .p_visibility)
        if let p_status { try c.encode(p_status, forKey: .p_status) }
    }
}

private struct MoveArtworkParams: Encodable {
    let p_id: UUID
    let p_visit: UUID
    let p_px: Float
    let p_py: Float
    let p_pz: Float
    let p_yaw: Float
    let p_scale: Float
    let p_revision: Int
}

private struct ArtworkStatusParams: Encodable {
    let p_id: UUID
    let p_status: String
}

private struct FollowRow: Codable {
    let follower: UUID
    let followee: UUID
}


// MARK: 利用規約

struct TermsState: Decodable {
    let accepted: Int?
    let current: Int
}

private struct AcceptTermsParams: Encodable {
    let p_version: Int
}

extension GateAPI {
    /// 自分が同意した版と、いまの版
    func myTerms() async throws -> TermsState {
        try await client.rpc("gf_my_terms").execute().value
    }

    func acceptTerms(_ version: Int) async throws {
        try await client.rpc("gf_accept_terms", params: AcceptTermsParams(p_version: version)).execute()
    }
}


private struct GateIDRow: Decodable {
    let gate_id: UUID
}


struct RefCount: Decodable {
    let count: Int
    let max: Int
}

private struct AddRefsParams: Encodable {
    let p_gate: UUID
    let p_challenge: UUID
    let p_lat: Double
    let p_lon: Double
    let p_accuracy: Double
    let p_refs: [RefPayload]
}


private struct DoorInfo: Decodable {
    let scale: Float
    /// 扉の見た目（0028 の前のサーバーでは無い＝ネオン）
    var style: String? = nil
}

private struct DoorScaleParams: Encodable {
    let p_gate: UUID
    let p_scale: Float
}


// MARK: 友達の GATE・図鑑・「来たよ」

private struct UserParam: Encodable {
    let p_user: UUID
}

private struct AtlasToggleParams: Encodable {
    let p_id: UUID
    let p_on: Bool
}

private struct CardLinkParams: Encodable {
    let p_from: UUID
    let p_to: UUID
    let p_body: String
}

extension GateAPI {
    /// その人が作った GATE（見てよいものだけ・おおよその位置）
    func userGates(_ user: UUID) async throws -> [UserGate] {
        try await client.rpc("gf_user_gates", params: UserParam(p_user: user)).execute().value
    }

    /// その人のグラフィティ図鑑（本人が載せたカードの写真・場所・日付）
    func userCardAtlas(_ user: UUID) async throws -> [AtlasCard] {
        try await client.rpc("gf_user_card_atlas", params: UserParam(p_user: user)).execute().value
    }

    /// 自分のカードを図鑑に載せる・外す
    func setGraffitiAtlas(_ id: UUID, on: Bool) async throws {
        try await client.rpc("gf_set_graffiti_atlas", params: AtlasToggleParams(p_id: id, p_on: on)).execute()
    }

    /// 友達のカードに、自分のカードを添えて「来たよ」を送る
    func sendCardLink(from: UUID, to: UUID, body: String) async throws -> UUID {
        try await client.rpc("gf_send_card_link", params: CardLinkParams(p_from: from, p_to: to, p_body: body)).execute().value
    }

    /// 届いた・送った「来たよ」
    func myCardLinks() async throws -> [CardLink] {
        try await client.rpc("gf_my_card_links").execute().value
    }

    /// この GATE で、自分が関わる「来たよ」
    func cardLinks(in gate: UUID) async throws -> [CardLinkMark] {
        try await client.rpc("gf_card_links_in", params: GateParam(p_gate: gate)).execute().value
    }

    func markCardLinksSeen() async throws {
        try await client.rpc("gf_mark_card_links_seen").execute()
    }
}
