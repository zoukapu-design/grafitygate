import Foundation
import Supabase

/// GATE を直す・閉じる、一緒に管理する人、カードを直す（0019_gf_manage.sql）。判定はサーバー。
extension GateAPI {
    // MARK: 一緒に管理する人

    /// だれが一緒に管理しているか（0019 の前のサーバーでは空）
    func gateManagers(_ gate: UUID) async throws -> [GateManager] {
        do {
            return try await client.rpc("gf_gate_managers_of", params: ManageGateParam(p_gate: gate)).execute().value
        } catch let error where ErrorText.isMissingFunction(error) {
            return []
        }
    }

    func addGateManager(_ gate: UUID, user: UUID) async throws {
        try await client.rpc("gf_add_gate_manager", params: ManagerParam(p_gate: gate, p_user: user)).execute()
    }

    func removeGateManager(_ gate: UUID, user: UUID) async throws {
        try await client.rpc("gf_remove_gate_manager", params: ManagerParam(p_gate: gate, p_user: user)).execute()
    }

    /// 自分が一緒に管理している GATE（0019 の前のサーバーでは空）
    func myManagedGates() async throws -> [ManagedGate] {
        do {
            return try await client.rpc("gf_my_managed_gates").execute().value
        } catch let error where ErrorText.isMissingFunction(error) {
            return []
        }
    }

    // MARK: GATE を直す・閉じる

    /// 名前・紹介・表紙（管理する人）と見せる範囲（作った人だけ）。nil は変えない。差し替える前の表紙の名前を返す
    @discardableResult
    func editGate(_ gate: UUID, title: String?, note: String?, coverPath: String?,
                  visibility: Visibility?) async throws -> String? {
        try await client.rpc("gf_edit_gate", params: EditGateParam(p_gate: gate, p_title: title, p_note: note,
                                                                   p_cover_path: coverPath,
                                                                   p_visibility: visibility?.rawValue)).execute().value
    }

    func setGateOpen(_ gate: UUID, open: Bool) async throws {
        try await client.rpc("gf_set_gate_open", params: GateOpenParam(p_gate: gate, p_open: open)).execute()
    }

    // MARK: カードを直す

    func editGraffiti(_ id: UUID, body: String, visibility: Visibility, localOnly: Bool) async throws {
        try await client.rpc("gf_edit_graffiti", params: EditGraffitiParam(p_id: id, p_body: body,
                                                                          p_visibility: visibility.rawValue,
                                                                          p_local_only: localOnly)).execute()
    }
}

// MARK: - 形

struct GateManager: Decodable, Identifiable, Hashable {
    let user_id: UUID
    let display_name: String
    let added_at: String

    var id: UUID { user_id }
}

struct ManagedGate: Decodable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let kind: String
    let cover_path: String?
    let owner: UUID
    let owner_name: String
    let created_at: String
    let added_at: String
}

private struct ManageGateParam: Encodable { let p_gate: UUID }
private struct ManagerParam: Encodable { let p_gate: UUID; let p_user: UUID }
private struct GateOpenParam: Encodable { let p_gate: UUID; let p_open: Bool }
private struct EditGraffitiParam: Encodable {
    let p_id: UUID
    let p_body: String
    let p_visibility: String
    let p_local_only: Bool
}

/// nil も null として送る（関数の引数の形を 1 つにそろえる）
private struct EditGateParam: Encodable {
    let p_gate: UUID
    let p_title: String?
    let p_note: String?
    let p_cover_path: String?
    let p_visibility: String?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_gate, forKey: .p_gate)
        try c.encode(p_title, forKey: .p_title)
        try c.encode(p_note, forKey: .p_note)
        try c.encode(p_cover_path, forKey: .p_cover_path)
        try c.encode(p_visibility, forKey: .p_visibility)
    }

    enum CodingKeys: String, CodingKey { case p_gate, p_title, p_note, p_cover_path, p_visibility }
}
