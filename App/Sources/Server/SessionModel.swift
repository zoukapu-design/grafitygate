import Foundation
import Supabase

/// サーバーの場所と鍵（GitHub Secrets から組み立て時に入る。無ければサーバーなしで起動する）
enum ServerConfig {
    static var url: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String, !s.isEmpty,
              let u = URL(string: s), u.scheme == "https" else { return nil }
        return u
    }

    static var anonKey: String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String, !s.isEmpty else { return nil }
        return s
    }
}

/// ログインと自分のプロフィール。はじめて開いたときは、名前なしのアカウント（匿名）で入る。
@MainActor
final class SessionModel: ObservableObject {
    enum State: Equatable {
        case starting
        case noServer
        case signedIn
        case failed(String)
    }

    /// はじめの案内で決めた名前（サーバーにつながってプロフィールが「ゲスト」のままなら、この名前にする）
    static let pendingNameKey = "gg.pendingName"
    /// はじめの案内で同意した規約の版（サーバーにつながったら、そのまま送る）
    static let agreedTermsKey = "gg.agreedTerms"

    /// 同意してもらう必要がある規約の版（nil なら同意済み、またはサーバーがまだ対応していない）
    @Published private(set) var termsToAccept: Int?

    @Published private(set) var state: State = .starting
    @Published private(set) var userID: UUID?
    @Published private(set) var profile: ProfileRow?

    let client: SupabaseClient?
    let api: GateAPI?
    let media: MediaStore?

    init() {
        if let url = ServerConfig.url, let key = ServerConfig.anonKey {
            let c = SupabaseClient(supabaseURL: url, supabaseKey: key)
            client = c
            api = GateAPI(client: c)
            media = MediaStore(client: c)
        } else {
            client = nil
            api = nil
            media = nil
        }
    }

    func start() async {
        guard let client else {
            state = .noServer
            return
        }
        do {
            let user: User
            if let existing = try? await client.auth.session {
                user = existing.user
            } else {
                user = try await client.auth.signInAnonymously().user
            }
            userID = user.id
            profile = try await ensureProfile(client: client, id: user.id)
            state = .signedIn
            await applyPendingName()
            await syncTerms()
        } catch {
            state = .failed(ErrorText.of(error))
        }
    }

    /// プロフィールが無ければ作る（Lyric Path と共通の表。ハンドルは英小文字・数字・_ の 3〜20 文字）
    private func ensureProfile(client: SupabaseClient, id: UUID) async throws -> ProfileRow {
        let rows: [ProfileRow] = try await client.from("profiles")
            .select("id,display_name,handle")
            .eq("id", value: id.uuidString)
            .execute().value
        if let row = rows.first { return row }
        let handle = "gg_" + id.uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased()
        let row = ProfileRow(id: id, display_name: "ゲスト", handle: handle)
        try await client.from("profiles").insert(row).execute()
        return row
    }

    /// アカウントを消したあと：ログアウトして、新しい名前なしのアカウントで始め直す
    func restartAfterDeletion() async {
        try? await client?.auth.signOut(scope: .local)
        userID = nil
        profile = nil
        state = .starting
        await start()
    }

    /// はじめの案内で決めた名前を、まだ「ゲスト」なら使う（失敗しても、次に開いたときにもう一度）
    func applyPendingName() async {
        let pending = (UserDefaults.standard.string(forKey: Self.pendingNameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pending.isEmpty, profile?.display_name == "ゲスト" else { return }
        do {
            try await rename(pending)
            UserDefaults.standard.removeObject(forKey: Self.pendingNameKey)
            Trace.log("はじめに決めた名前を使いました")
        } catch {
            Trace.log("はじめに決めた名前を保存できませんでした：\(ErrorText.of(error))")
        }
    }

    /// 規約に同意しているか確かめる。はじめの案内で同意した版がいまの版なら、そのまま送る
    func syncTerms() async {
        guard let api else { return }
        do {
            let terms = try await api.myTerms()
            if let accepted = terms.accepted, accepted >= terms.current {
                termsToAccept = nil
                return
            }
            if UserDefaults.standard.integer(forKey: Self.agreedTermsKey) >= terms.current {
                try await api.acceptTerms(terms.current)
                termsToAccept = nil
                Trace.log("はじめの案内で同意した規約（\(terms.current) 版）を送りました")
            } else {
                termsToAccept = terms.current
                Trace.log("規約（\(terms.current) 版）への同意をお願いします")
            }
        } catch {
            // サーバーがまだ 0013 の前なら、同意の画面は出さない
            if !ErrorText.isMissingFunction(error) {
                Trace.log("規約の同意を確かめられませんでした：\(ErrorText.of(error))")
            }
        }
    }

    /// はじめの案内で同意した（サーバーにはつながったときに送る）
    func agreedInOnboarding(version: Int) {
        UserDefaults.standard.set(version, forKey: Self.agreedTermsKey)
        if let needed = termsToAccept, version >= needed { termsToAccept = nil }
        Task { await syncTerms() }
    }

    func acceptTerms(_ version: Int) async throws {
        guard let api else { return }
        try await api.acceptTerms(version)
        UserDefaults.standard.set(version, forKey: Self.agreedTermsKey)
        termsToAccept = nil
        Trace.log("規約（\(version) 版）に同意しました")
    }

    func rename(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, let id = userID, !trimmed.isEmpty, trimmed.count <= 30 else { return }
        try await client.from("profiles")
            .update(["display_name": trimmed])
            .eq("id", value: id.uuidString)
            .execute()
        profile?.display_name = trimmed
    }

    /// 画面の上に出す、サーバーの状態（問題がないときは nil）
    var problem: String? {
        switch state {
        case .starting: return "サーバーにつないでいます…"
        case .noServer: return "サーバーの設定がまだです。組み立てのときに Supabase の鍵を入れると使えるようになります。"
        case .failed(let message): return "サーバーにつながりませんでした：\(message)"
        case .signedIn: return nil
        }
    }
}
