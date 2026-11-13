import Foundation
import Supabase

/// GATE の中の機能（掲示板・手紙・思い出）と、保存・図鑑・友達・通報・ブロック・自分のデータ。
/// どれも判定はサーバー（0004_gf_inside.sql）で、ここは送って結果を受け取るだけ。
extension GateAPI {
    // MARK: いいね（グラフィティ）

    /// 見えるグラフィティのいいねの数と、自分が押したか
    func likes(for ids: [UUID], me: UUID) async throws -> [UUID: (count: Int, mine: Bool)] {
        guard !ids.isEmpty else { return [:] }
        let rows: [LikeRow] = try await client.from("gf_reactions")
            .select("graffiti_id,user_id")
            .in("graffiti_id", values: ids.map(\.uuidString))
            .eq("kind", value: "like")
            .execute().value
        var result: [UUID: (count: Int, mine: Bool)] = [:]
        for row in rows {
            let current = result[row.graffiti_id] ?? (0, false)
            result[row.graffiti_id] = (current.count + 1, current.mine || row.user_id == me)
        }
        return result
    }

    func setLike(_ graffiti: UUID, me: UUID, on: Bool) async throws {
        if on {
            try await client.from("gf_reactions")
                .upsert(LikeRow(graffiti_id: graffiti, user_id: me), ignoreDuplicates: true)
                .execute()
        } else {
            try await client.from("gf_reactions").delete()
                .eq("graffiti_id", value: graffiti.uuidString)
                .eq("user_id", value: me.uuidString)
                .execute()
        }
    }

    // MARK: 掲示板

    func boardThreads(in gate: UUID) async throws -> [BoardThread] {
        try await client.rpc("gf_board_list", params: InsideGateParam(p_gate: gate)).execute().value
    }

    /// 返信（共同調査のしるし・出典つき。0007 を入れる前のサーバーでは、しるしなしで読む）
    func boardReplies(_ thread: UUID) async throws -> [BoardReply] {
        do {
            return try await client.rpc("gf_board_replies_of2", params: ThreadParam(p_thread: thread)).execute().value
        } catch let error where ErrorText.isMissingFunction(error) {
            return try await client.rpc("gf_board_replies_of", params: ThreadParam(p_thread: thread)).execute().value
        }
    }

    func postThread(visit: UUID, topic: BoardTopic, title: String, body: String) async throws -> UUID {
        try await client.rpc("gf_board_post",
                             params: BoardPostParams(p_visit: visit, p_topic: topic.rawValue, p_title: title, p_body: body))
            .execute().value
    }

    func reply(visit: UUID, thread: UUID, body: String, label: EvidenceLabel? = nil, source: String? = nil) async throws -> UUID {
        if label == nil && (source ?? "").isEmpty {
            return try await client.rpc("gf_board_reply", params: BoardReplyParams(p_visit: visit, p_thread: thread, p_body: body))
                .execute().value
        }
        return try await client.rpc("gf_board_reply2",
                                    params: EvidenceReplyParams(p_visit: visit, p_thread: thread, p_body: body,
                                                                p_label: label?.rawValue,
                                                                p_source: (source ?? "").isEmpty ? nil : source))
            .execute().value
    }

    func pinThread(_ thread: UUID, pinned: Bool) async throws {
        try await client.rpc("gf_board_pin", params: PinParams(p_thread: thread, p_pinned: pinned)).execute()
    }

    func deleteBoard(kind: String, id: UUID) async throws {
        try await client.rpc("gf_board_delete", params: KindIDParams(p_kind: kind, p_id: id)).execute()
    }

    // MARK: 手紙

    /// 自分あて・自分が書いた手紙（中身なし）。gate を渡すとその GATE のものだけ
    func letters(at gate: UUID? = nil) async throws -> [LetterInfo] {
        try await client.rpc("gf_my_letters", params: OptionalGateParam(p_gate: gate)).execute().value
    }

    func writeLetter(visit: UUID, to recipient: UUID?, body: String, photoPath: String?, openAt: Date?,
                     onsite: Bool) async throws -> UUID {
        try await client.rpc("gf_write_letter",
                             params: LetterParams(p_visit: visit, p_recipient: recipient, p_body: body,
                                                  p_photo_path: photoPath,
                                                  p_open_at: openAt.map { ISO8601DateFormatter().string(from: $0) },
                                                  p_onsite: onsite))
            .execute().value
    }

    func openLetter(_ id: UUID) async throws -> LetterContent? {
        let rows: [LetterContent] = try await client.rpc("gf_open_letter", params: LetterIDParam(p_letter: id))
            .execute().value
        return rows.first
    }

    func deleteLetter(_ id: UUID) async throws {
        try await client.rpc("gf_delete_letter", params: LetterIDParam(p_letter: id)).execute()
    }

    // MARK: 思い出

    func memories(in gate: UUID) async throws -> [MemorySummary] {
        try await client.rpc("gf_memory_list", params: InsideGateParam(p_gate: gate)).execute().value
    }

    func memoryItems(_ memory: UUID) async throws -> [MemoryItem] {
        try await client.from("gf_memory_items")
            .select("id,memory_id,author,photo_path,caption,created_at")
            .eq("memory_id", value: memory.uuidString)
            .order("created_at", ascending: true)
            .limit(100)
            .execute().value
    }

    func memoryMembers(_ memory: UUID) async throws -> [UUID] {
        let rows: [MemberRow] = try await client.from("gf_memory_members")
            .select("user_id")
            .eq("memory_id", value: memory.uuidString)
            .execute().value
        return rows.map(\.user_id)
    }

    func myMemories() async throws -> [MyMemory] {
        try await client.rpc("gf_my_memories").execute().value
    }

    func createMemory(visit: UUID, title: String, note: String, visibility: Visibility) async throws -> UUID {
        try await client.rpc("gf_create_memory",
                             params: MemoryParams(p_visit: visit, p_title: title, p_note: note,
                                                  p_visibility: visibility.rawValue))
            .execute().value
    }

    func inviteToMemory(_ memory: UUID, user: UUID) async throws {
        try await client.rpc("gf_invite_to_memory", params: InviteParams(p_memory: memory, p_user: user)).execute()
    }

    func addMemoryItem(_ memory: UUID, photoPath: String, caption: String) async throws -> UUID {
        try await client.rpc("gf_add_memory_item",
                             params: MemoryItemParams(p_memory: memory, p_photo_path: photoPath, p_caption: caption))
            .execute().value
    }

    func deleteMemory(_ memory: UUID) async throws {
        try await client.rpc("gf_delete_memory", params: MemoryIDParam(p_memory: memory)).execute()
    }

    /// 写真を消す。消した写真の置き場所の名前を返す（ファイルも消すため）
    func deleteMemoryItem(_ item: UUID) async throws -> String? {
        try await client.rpc("gf_delete_memory_item", params: ItemIDParam(p_item: item)).execute().value
    }

    func leaveMemory(_ memory: UUID) async throws {
        try await client.rpc("gf_leave_memory", params: MemoryIDParam(p_memory: memory)).execute()
    }

    // MARK: 保存と図鑑

    func setBookmark(_ gate: UUID, on: Bool) async throws {
        try await client.rpc("gf_set_bookmark", params: BookmarkParams(p_gate: gate, p_on: on)).execute()
    }

    /// saved（保存）／ visited（図鑑）
    func collection(_ kind: String) async throws -> [CollectionGate] {
        try await client.rpc("gf_my_collection", params: KindParam(p_kind: kind)).execute().value
    }

    func setAtlasShared(_ gate: UUID, shared: Bool) async throws {
        try await client.rpc("gf_set_atlas_shared", params: AtlasParams(p_gate: gate, p_shared: shared)).execute()
    }

    func friendAtlas(_ user: UUID) async throws -> [FriendAtlasGate] {
        try await client.rpc("gf_friend_atlas", params: UserParam(p_user: user)).execute().value
    }

    // MARK: 友達

    /// フォローしている人・フォローされている人・お互い（友達）
    func relations(me: UUID) async throws -> (following: Set<UUID>, followers: Set<UUID>) {
        let out: [FollowPair] = try await client.from("follows")
            .select("follower,followee").eq("follower", value: me.uuidString).execute().value
        let incoming: [FollowPair] = try await client.from("follows")
            .select("follower,followee").eq("followee", value: me.uuidString).execute().value
        return (Set(out.map(\.followee)), Set(incoming.map(\.follower)))
    }

    /// お互いにフォローしている友達
    func friends(me: UUID) async throws -> [ProfileRow] {
        let r = try await relations(me: me)
        let ids = r.following.intersection(r.followers)
        return try await profiles(Array(ids))
    }

    func profiles(_ ids: [UUID]) async throws -> [ProfileRow] {
        guard !ids.isEmpty else { return [] }
        let rows: [ProfileRow] = try await client.from("profiles")
            .select("id,display_name,handle")
            .in("id", values: ids.map(\.uuidString))
            .execute().value
        return rows.sorted { $0.display_name < $1.display_name }
    }

    func unfollow(_ target: UUID, me: UUID) async throws {
        try await client.from("follows").delete()
            .eq("follower", value: me.uuidString)
            .eq("followee", value: target.uuidString)
            .execute()
    }

    // MARK: 通報とブロック

    func report(_ target: ReportTarget, id: UUID, reason: ReportReason, note: String) async throws {
        if target == .dm {
            try await client.rpc("gf_report_dm",
                                 params: ReportDMParams(p_id: id, p_reason: reason.rawValue, p_note: note.isEmpty ? nil : note))
                .execute()
            return
        }
        try await client.rpc("gf_report",
                             params: ReportParams(p_kind: target.rawValue, p_id: id, p_reason: reason.rawValue,
                                                  p_note: note.isEmpty ? nil : note))
            .execute()
    }

    func block(_ user: UUID) async throws {
        try await client.rpc("gf_block", params: UserParam(p_user: user)).execute()
    }

    func unblock(_ user: UUID) async throws {
        try await client.rpc("gf_unblock", params: UserParam(p_user: user)).execute()
    }

    func blocks() async throws -> [BlockedUser] {
        try await client.rpc("gf_my_blocks").execute().value
    }

    // MARK: お知らせと DM

    func notifications() async throws -> [NotificationItem] {
        try await client.rpc("gf_my_notifications").execute().value
    }

    func unreadCounts() async throws -> UnreadCounts {
        let rows: [UnreadCounts] = try await client.rpc("gf_unread_counts").execute().value
        return rows.first ?? UnreadCounts(notifications: 0, messages: 0)
    }

    func markNotificationsSeen() async throws {
        try await client.rpc("gf_mark_notifications_seen").execute()
    }

    func dmThreads() async throws -> [DMThread] {
        try await client.rpc("gf_dm_threads").execute().value
    }

    func dmMessages(with other: UUID) async throws -> [DMMessage] {
        try await client.rpc("gf_dm_messages_with", params: OtherParam(p_other: other)).execute().value
    }

    func sendDM(to other: UUID, body: String) async throws -> UUID {
        try await client.rpc("gf_dm_send", params: DMSendParams(p_to: other, p_body: body)).execute().value
    }

    func deleteDM(_ id: UUID) async throws {
        try await client.rpc("gf_dm_delete", params: IDOnlyParam(p_id: id)).execute()
    }

    // MARK: TRAIL

    /// 自分の・友達の・歩いている TRAIL。gate を渡すと、その GATE をふくむ見てよい TRAIL
    func trails(including gate: UUID? = nil) async throws -> [TrailSummary] {
        try await client.rpc("gf_trail_list", params: OptionalGateParam(p_gate: gate)).execute().value
    }

    func trailStops(_ trail: UUID) async throws -> [TrailStop] {
        try await client.rpc("gf_trail_stops_of", params: TrailParam(p_trail: trail)).execute().value
    }

    func createTrail(title: String, note: String, visibility: Visibility, gates: [UUID]) async throws -> UUID {
        try await client.rpc("gf_create_trail",
                             params: TrailCreateParams(p_title: title, p_note: note, p_visibility: visibility.rawValue,
                                                       p_gates: gates))
            .execute().value
    }

    func startTrail(_ trail: UUID) async throws {
        try await client.rpc("gf_trail_start", params: TrailParam(p_trail: trail)).execute()
    }

    func quitTrail(_ trail: UUID) async throws {
        try await client.rpc("gf_trail_quit", params: TrailParam(p_trail: trail)).execute()
    }

    func deleteTrail(_ trail: UUID) async throws {
        try await client.rpc("gf_delete_trail", params: TrailParam(p_trail: trail)).execute()
    }

    /// この入場で進んだ TRAIL
    func trailsReached(visit: UUID) async throws -> [TrailReached] {
        try await client.rpc("gf_trails_reached_by", params: VisitParam(p_visit: visit)).execute().value
    }

    // MARK: 今と昔

    func snapshots(in gate: UUID) async throws -> [Snapshot] {
        try await client.from("gf_snapshots")
            .select("id,gate_id,author,photo_path,visibility,created_at")
            .eq("gate_id", value: gate.uuidString)
            .order("created_at", ascending: true)
            .limit(200)
            .execute().value
    }

    func addSnapshot(visit: UUID, photoPath: String, visibility: Visibility) async throws -> UUID {
        try await client.rpc("gf_add_snapshot",
                             params: SnapshotParams(p_visit: visit, p_photo_path: photoPath, p_visibility: visibility.rawValue))
            .execute().value
    }

    /// 消す。消した写真の置き場所の名前を返す
    func deleteSnapshot(_ id: UUID) async throws -> String? {
        try await client.rpc("gf_delete_snapshot", params: IDOnlyParam(p_id: id)).execute().value
    }

    // MARK: 場所の記憶の見つかりやすさと GATE の数字

    /// 場所の記憶が見つかったか・探した秒数だけを送る（写真・位置は送らない）
    func reportRelocalize(visit: UUID, found: Bool, seconds: Double) async throws {
        try await client.rpc("gf_report_relocalize",
                             params: RelocalizeParams(p_visit: visit, p_found: found, p_seconds: Float(seconds)))
            .execute()
    }

    func placeMapHealth(_ gate: UUID) async throws -> PlaceMapHealth? {
        let rows: [PlaceMapHealth] = try await client.rpc("gf_place_map_health", params: InsideGateParam(p_gate: gate))
            .execute().value
        return rows.first
    }

    func gateStats(_ gate: UUID) async throws -> GateStats? {
        let rows: [GateStats] = try await client.rpc("gf_gate_stats", params: InsideGateParam(p_gate: gate))
            .execute().value
        return rows.first
    }

    // MARK: 自分のデータ

    /// 自分のデータを 1 つの JSON にしたもの
    func exportMe() async throws -> Data {
        let response = try await client.rpc("gf_export_me_social").execute()
        return response.data
    }

    /// アカウントを消す（先に自分のファイルを消しておく）
    func deleteMe() async throws {
        try await client.rpc("gf_delete_me").execute()
    }
}

// MARK: - 送る形

private struct InsideGateParam: Encodable { let p_gate: UUID }
private struct ThreadParam: Encodable { let p_thread: UUID }
private struct LetterIDParam: Encodable { let p_letter: UUID }
private struct MemoryIDParam: Encodable { let p_memory: UUID }
private struct ItemIDParam: Encodable { let p_item: UUID }
private struct UserParam: Encodable { let p_user: UUID }
private struct KindParam: Encodable { let p_kind: String }
private struct OtherParam: Encodable { let p_other: UUID }
private struct TrailParam: Encodable { let p_trail: UUID }
private struct RelocalizeParams: Encodable {
    let p_visit: UUID
    let p_found: Bool
    let p_seconds: Float
}
private struct VisitParam: Encodable { let p_visit: UUID }
private struct TrailCreateParams: Encodable {
    let p_title: String
    let p_note: String
    let p_visibility: String
    let p_gates: [UUID]
}
private struct SnapshotParams: Encodable {
    let p_visit: UUID
    let p_photo_path: String
    let p_visibility: String
}
private struct IDOnlyParam: Encodable { let p_id: UUID }
private struct DMSendParams: Encodable {
    let p_to: UUID
    let p_body: String
}

private struct ReportDMParams: Encodable {
    let p_id: UUID
    let p_reason: String
    let p_note: String?

    enum CodingKeys: String, CodingKey { case p_id, p_reason, p_note }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_id, forKey: .p_id)
        try c.encode(p_reason, forKey: .p_reason)
        try c.encode(p_note, forKey: .p_note)               // nil は null
    }
}
private struct MemberRow: Decodable { let user_id: UUID }
private struct LikeRow: Codable {
    let graffiti_id: UUID
    let user_id: UUID
}
private struct FollowPair: Decodable {
    let follower: UUID
    let followee: UUID
}

private struct OptionalGateParam: Encodable {
    let p_gate: UUID?

    enum CodingKeys: String, CodingKey { case p_gate }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_gate, forKey: .p_gate)   // nil は null
    }
}

private struct BoardPostParams: Encodable {
    let p_visit: UUID
    let p_topic: String
    let p_title: String
    let p_body: String
}

private struct BoardReplyParams: Encodable {
    let p_visit: UUID
    let p_thread: UUID
    let p_body: String
}

private struct EvidenceReplyParams: Encodable {
    let p_visit: UUID
    let p_thread: UUID
    let p_body: String
    let p_label: String?
    let p_source: String?

    enum CodingKeys: String, CodingKey { case p_visit, p_thread, p_body, p_label, p_source }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_visit, forKey: .p_visit)
        try c.encode(p_thread, forKey: .p_thread)
        try c.encode(p_body, forKey: .p_body)
        try c.encode(p_label, forKey: .p_label)              // nil は null
        try c.encode(p_source, forKey: .p_source)            // nil は null
    }
}

private struct PinParams: Encodable {
    let p_thread: UUID
    let p_pinned: Bool
}

private struct KindIDParams: Encodable {
    let p_kind: String
    let p_id: UUID
}

private struct LetterParams: Encodable {
    let p_visit: UUID
    let p_recipient: UUID?
    let p_body: String
    let p_photo_path: String?
    let p_open_at: String?
    let p_onsite: Bool

    enum CodingKeys: String, CodingKey { case p_visit, p_recipient, p_body, p_photo_path, p_open_at, p_onsite }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_visit, forKey: .p_visit)
        try c.encode(p_recipient, forKey: .p_recipient)     // nil は null（自分あて）
        try c.encode(p_body, forKey: .p_body)
        try c.encode(p_photo_path, forKey: .p_photo_path)
        try c.encode(p_open_at, forKey: .p_open_at)
        try c.encode(p_onsite, forKey: .p_onsite)
    }
}

private struct MemoryParams: Encodable {
    let p_visit: UUID
    let p_title: String
    let p_note: String
    let p_visibility: String
}

private struct InviteParams: Encodable {
    let p_memory: UUID
    let p_user: UUID
}

private struct MemoryItemParams: Encodable {
    let p_memory: UUID
    let p_photo_path: String
    let p_caption: String
}

private struct BookmarkParams: Encodable {
    let p_gate: UUID
    let p_on: Bool
}

private struct AtlasParams: Encodable {
    let p_gate: UUID
    let p_shared: Bool
}

private struct ReportParams: Encodable {
    let p_kind: String
    let p_id: UUID
    let p_reason: String
    let p_note: String?

    enum CodingKeys: String, CodingKey { case p_kind, p_id, p_reason, p_note }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_kind, forKey: .p_kind)
        try c.encode(p_id, forKey: .p_id)
        try c.encode(p_reason, forKey: .p_reason)
        try c.encode(p_note, forKey: .p_note)               // nil は null
    }
}
