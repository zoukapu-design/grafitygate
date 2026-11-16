import Foundation
import Supabase

/// サーバーの場所と鍵（GitHub Secrets から組み立て時に入る。無ければサーバーなしで起動する）
enum ServerConfig {
    /// サーバーのアドレス。組み立てのときにホスト名（xxxx.supabase.co）だけを入れ、ここで https:// を付ける。
    /// ホスト名の無いアドレスを Supabase の部品に渡すと、部品がその場でアプリを止める（2026-11-15 に起動してすぐ落ちた）ので、
    /// 形を確かめてから渡す。おかしければ「サーバーなし」として動かす。
    static var url: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SupabaseHost") as? String else { return nil }
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains("$("), host.contains("."),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }),
              let u = URL(string: "https://\(host)"), u.scheme == "https",
              let h = u.host(percentEncoded: false), !h.isEmpty else {
            if !raw.isEmpty { Trace.log("サーバーのアドレスの形がおかしいので、サーバーなしで動かします") }
            return nil
        }
        return u
    }

    static var anonKey: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains("$("), !s.contains(where: \.isWhitespace) else { return nil }
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

    /// いま動いている入り口（地図の印の中など、EnvironmentObject が届かない所から使う）
    private(set) weak static var current: SessionModel?

    init() {
        #if DEBUG
        if DemoGallery.requestedScreen != nil {
            // 画面の見本：つなぐ先を「見本のサーバー」にする（本物のサーバーには送らない）
            let c = SupabaseClient(supabaseURL: DemoServer.url, supabaseKey: "demo",
                                   options: SupabaseClientOptions(global: .init(session: URLSession(configuration: DemoServer.configuration()))))
            client = c
            api = GateAPI(client: c)
            media = MediaStore(client: c)
            Self.current = self
            return
        }
        #endif
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
        Self.current = self
    }

    #if DEBUG
    /// 画面の見本：見本の人として入ったことにする
    func startDemo() {
        userID = DemoData.me
        profile = ProfileRow(id: DemoData.me, display_name: "あなた", handle: "me_demo")
        termsToAccept = nil
        state = .signedIn
    }
    #endif

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
