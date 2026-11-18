#if DEBUG
import Foundation

/// 見本の画面の名前（起動のときの -GGDemoScreen <名前>。どの列からでも読める）
enum DemoMode {
    static let screen: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-GGDemoScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// 画面の名前の「@」より後ろ（例：gate-outside@door＝扉の札まで下げて撮る）
    static var scroll: String? {
        guard let screen, let at = screen.firstIndex(of: "@") else { return nil }
        return String(screen[screen.index(after: at)...])
    }
}

/// 画面の見本（シミュレーターの Debug の組み立てだけ）で、サーバーの代わりに見本の答えを返す。
/// アプリの部品はそのまま（ホーム・GATE・わたし・地図）で、つなぐ先だけをこの「見本のサーバー」にする。
/// 知らない問い合わせには空の一覧を返す（画面は「まだありません」になる）。
final class DemoServer: URLProtocol {
    static let host = "demo.supabase.co"
    static var url: URL { URL(string: "https://\(host)")! }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DemoServer.self] + (config.protocolClasses ?? [])
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        var status = 200
        var data = Data("[]".utf8)
        if path.hasPrefix("/rest/v1/rpc/") {
            let name = String(path.dropFirst("/rest/v1/rpc/".count))
            data = DemoData.rpc(name, params: Self.body(of: request))
        } else if path.hasPrefix("/rest/v1/") {
            let table = String(path.dropFirst("/rest/v1/".count))
            data = DemoData.table(table, query: url.query ?? "", method: request.httpMethod ?? "GET")
        } else {
            status = 404
            data = Data("{}".utf8)
        }
        FileHandle.standardError.write(Data("demo-server: \(request.httpMethod ?? "") \(path) → \(status) \(data.count)B\n".utf8))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                collected.append(buffer, count: n)
            }
            stream.close()
            data = collected
        }
        return (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
    }
}

/// 見本のデータ（人・GATE・グラフィティカード・掲示板・TRAIL など）
enum DemoData {
    static let me = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    static let misaki = UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!
    static let kenta = UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!
    static let yui = UUID(uuidString: "00000000-0000-0000-0000-0000000000d4")!
    static let hill = UUID(uuidString: "00000000-0000-0000-0000-00000000f001")!
    static let clock = UUID(uuidString: "00000000-0000-0000-0000-00000000f002")!
    static let tree = UUID(uuidString: "00000000-0000-0000-0000-00000000f003")!
    static let visit = UUID(uuidString: "00000000-0000-0000-0000-00000000e001")!
    static let trail = UUID(uuidString: "00000000-0000-0000-0000-00000000d001")!

    static func ago(_ seconds: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-seconds))
    }

    static func later(_ seconds: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(seconds))
    }

    static let names: [UUID: String] = [me: "あなた", misaki: "みさき", kenta: "けんた", yui: "ゆい"]

    struct Gate {
        let id: UUID, title: String, note: String, kind: String, owner: UUID, cover: String?, lat: Double, lon: Double
        let count: Int
    }

    static let gates: [Gate] = [
        Gate(id: hill, title: "夕焼けの見える丘", note: "西口から坂をのぼった先のベンチ。夕方がおすすめです。", kind: "view",
             owner: misaki, cover: "demo/sunset.jpg", lat: 35.6595, lon: 139.7005, count: 12),
        Gate(id: clock, title: "駅前の大時計", note: "待ち合わせの定番。", kind: "object", owner: me,
             cover: "demo/night.jpg", lat: 35.6581, lon: 139.7016, count: 5),
        Gate(id: tree, title: "公園の大きな木", note: "春は桜がきれい。", kind: "place", owner: kenta,
             cover: "demo/park.jpg", lat: 35.6572, lon: 139.7029, count: 8),
    ]

    /// 扉の外で見ている見本か（公園の大きな木はいつも外。「gate-away」の見本では全部外）
    static func outside(_ g: Gate) -> Bool {
        g.id == tree || (DemoMode.screen ?? "").hasPrefix("gate-away")
    }

    static func gate(_ id: Any?) -> Gate {
        let key = (id as? String).flatMap(UUID.init(uuidString:))
        return gates.first { $0.id == key } ?? gates[0]
    }

    static let handles: [UUID: String] = [me: "me_demo", misaki: "misaki", kenta: "kenta_k", yui: "yui_y"]

    static func profile(_ id: UUID) -> [String: Any] {
        ["id": id.uuidString, "display_name": names[id] ?? "だれか", "handle": handles[id] ?? "someone"]
    }

    /// 無い値は null（JSON に Swift の nil は入れられない）
    static func nn(_ value: String?) -> Any { value ?? NSNull() }

    static func card(_ id: Int, gate: UUID, author: UUID, body: String, photo: String?, ago seconds: TimeInterval) -> [String: Any] {
        ["id": String(format: "00000000-0000-0000-0000-0000000c%04d", id), "gate_id": gate.uuidString,
         "author": author.uuidString, "body": body, "photo_path": nn(photo), "visibility": "friends",
         "local_only": false, "created_at": ago(seconds), "in_atlas": author == me ? true : NSNull(),
         "edited_at": id == 3 ? ago(1800) : NSNull(),
         "finish": ["holo", "normal", "neon", "gold"][(id - 1) % 4],
         "title": id == 1 ? "夕焼けの約束" : (id == 2 ? "雲の日の丘" : NSNull())]
    }

    static var cards: [[String: Any]] {
        [card(1, gate: hill, author: misaki, body: "ここから見る夕焼けが一番好き。ベンチに座って待ってみて。", photo: "demo/sunset.jpg", ago: 3 * 3600),
         card(2, gate: hill, author: me, body: "今日は雲が多かったけど、それもきれいだった。", photo: "demo/park.jpg", ago: 5 * 3600),
         card(3, gate: hill, author: kenta, body: "初めて来た。坂がきつい！でも来てよかった。", photo: nil, ago: 26 * 3600),
         card(4, gate: hill, author: yui, body: "", photo: "demo/night.jpg", ago: 9 * 86400)]
    }

    // MARK: 関数の答え

    static func rpc(_ name: String, params: [String: Any]) -> Data {
        json(rpcValue(name, params: params))
    }

    private static func rpcValue(_ name: String, params: [String: Any]) -> Any {
        switch name {
        case "gf_my_terms":
            return ["accepted": 1, "current": 1]
        case "gf_unread_counts":
            return [["notifications": 2, "messages": 1]]
        case "gf_friend_feed", "gf_friend_feed2":
            if DemoMode.screen == "home-empty" { return [] }
            return [
                ["id": UUID().uuidString, "author": misaki.uuidString, "author_name": "みさき", "gate_id": hill.uuidString,
                 "gate_title": "夕焼けの見える丘", "approx_lat": 35.66, "approx_lon": 139.70,
                 "body": "ここから見る夕焼けが一番好き。ベンチに座って待ってみて。", "photo_path": "demo/sunset.jpg", "created_at": ago(3 * 3600),
                 "finish": "holo", "title": "夕焼けの約束"],
                ["id": UUID().uuidString, "author": kenta.uuidString, "author_name": "けんた", "gate_id": tree.uuidString,
                 "gate_title": "公園の大きな木", "approx_lat": 35.657, "approx_lon": 139.703,
                 "body": "春になったら、またみんなで来よう。", "photo_path": NSNull(), "created_at": ago(8 * 3600),
                 "finish": "neon"],
                ["id": UUID().uuidString, "author": misaki.uuidString, "author_name": "みさき", "gate_id": clock.uuidString,
                 "gate_title": "駅前の大時計", "approx_lat": 35.658, "approx_lon": 139.702,
                 "body": "待ち合わせ、ここにしよう。", "photo_path": "demo/night.jpg", "created_at": ago(20 * 3600),
                 "finish": "gold"],
            ]
        case "gf_gate_summary":
            let g = gate(params["p_gate"])
            return [["id": g.id.uuidString, "title": g.title, "note": g.note, "kind": g.kind, "owner": g.owner.uuidString,
                     "owner_name": names[g.owner] ?? "", "cover_path": nn(g.cover), "approx_lat": g.lat, "approx_lon": g.lon,
                     "visibility": "friends", "status": "open", "graffiti_count": g.count, "created_at": ago(40 * 86400),
                     // 公園の大きな木は、扉を開けていない（グラフィティボードだけ見ている）見本。
                     // 「gate-away」の見本では、夕焼けの丘も扉の外（前に開けたことがあるので遠くから読める）
                     "my_visit": outside(g) ? NSNull() as Any : visit.uuidString as Any,
                     "my_visit_expires_at": outside(g) ? NSNull() as Any : later(15 * 60) as Any]]
        case "gf_gate_stats":
            let g = gate(params["p_gate"])
            return [["visitor_count": g.id == tree ? 8 : 23, "last_activity_at": ago(3 * 3600), "my_visits": g.id == tree ? 0 : 3]]
        case "gf_gate_managers_of":
            return [["user_id": kenta.uuidString, "display_name": "けんた", "added_at": ago(10 * 86400)]]
        case "gf_card_extras":
            return cards.map { ["graffiti_id": $0["id"]!, "comments": ($0["author"] as? String) == misaki.uuidString ? 3 : 0,
                                "saved": ($0["author"] as? String) == misaki.uuidString] }
        case "gf_board_list4", "gf_board_list3", "gf_board_list2":
            return [
                ["id": UUID().uuidString, "author": me.uuidString, "author_name": "あなた", "topic": "investigation",
                 "title": "この丘の名前の由来", "body": "昔の地図で調べたい。", "pinned": true, "reply_count": 6,
                 "last_activity_at": ago(2 * 3600), "created_at": ago(5 * 86400), "unread": true, "edited_at": NSNull(),
                 "resolved": false, "progress": "narrowing", "conclusion": NSNull()],
                ["id": UUID().uuidString, "author": misaki.uuidString, "author_name": "みさき", "topic": "question",
                 "title": "夕焼けがいちばんきれいな季節は？", "body": "秋と冬、どっちがいいですか", "pinned": false, "reply_count": 4,
                 "last_activity_at": ago(6 * 3600), "created_at": ago(3 * 86400), "unread": false, "edited_at": NSNull(),
                 "resolved": true, "progress": "open", "conclusion": NSNull()],
                ["id": UUID().uuidString, "author": kenta.uuidString, "author_name": "けんた", "topic": "memory",
                 "title": "卒業式のあと、みんなでここに来た", "body": "10 年前の話です。", "pinned": false, "reply_count": 2,
                 "last_activity_at": ago(30 * 3600), "created_at": ago(30 * 3600), "unread": false, "edited_at": ago(28 * 3600),
                 "resolved": false, "progress": "open", "conclusion": NSNull()],
            ]
        case "gf_trail_list", "gf_user_trails", "gf_trail_search", "gf_trail_get":
            return [["id": trail.uuidString, "owner": misaki.uuidString, "owner_name": "みさき", "title": "夕焼けの散歩道",
                     "note": "駅から丘まで、夕方に歩くのがおすすめ", "visibility": "friends", "created_at": ago(12 * 86400),
                     "stop_count": 5, "cover_path": "demo/park.jpg", "reached": 2, "completed": false, "started": true]]
        case "gf_my_visit_history":
            return [["visited_at": ago(3600)], ["visited_at": ago(9 * 86400)], ["visited_at": ago(40 * 86400)]]
        case "gf_discover_nearby":
            // 駅前の大時計と同じ所に、ほかの GATE を 2 つ（地図の「重ねた印」の見本）
            let clock = gates[1]
            let sameSpot: [[String: Any]] = [
                ["id": "6A0B1C2D-0000-4000-8000-00000000A001", "title": "駅前のベンチ", "kind": "place",
                 "owner": misaki.uuidString, "owner_name": names[misaki] ?? "", "distance_m": 60.0,
                 "approx_lat": clock.lat, "approx_lon": clock.lon, "cover_path": "demo/park.jpg", "visibility": "friends",
                 "mine": false],
                ["id": "6A0B1C2D-0000-4000-8000-00000000A002", "title": "時計の下の落書き", "kind": "object",
                 "owner": me.uuidString, "owner_name": names[me] ?? "", "distance_m": 61.0,
                 "approx_lat": clock.lat, "approx_lon": clock.lon, "cover_path": NSNull() as Any, "visibility": "friends",
                 "mine": true]]
            return gates.enumerated().map { i, g in
                ["id": g.id.uuidString, "title": g.title, "kind": g.kind, "owner": g.owner.uuidString,
                 "owner_name": names[g.owner] ?? "", "distance_m": [24.0, 58.0, 91.0][i], "approx_lat": g.lat, "approx_lon": g.lon,
                 "cover_path": nn(g.cover), "visibility": "friends", "mine": g.owner == me] as [String: Any]
            } + sameSpot
        case "gf_nearby_cards":
            return [["id": UUID().uuidString, "gate_id": hill.uuidString, "gate_title": "夕焼けの見える丘", "gate_kind": "view",
                     "author": misaki.uuidString, "author_name": "みさき", "body": "ここから見る夕焼けが一番好き。",
                     "photo_path": "demo/sunset.jpg", "created_at": ago(3 * 3600), "approx_lat": 35.66, "approx_lon": 139.70,
                     "distance_m": 180.0]]
        case "gf_my_collection":
            return gates.map { g in
                ["gate_id": g.id.uuidString, "title": g.title, "owner": g.owner.uuidString, "owner_name": names[g.owner] ?? "",
                 "cover_path": nn(g.cover), "approx_lat": g.lat, "approx_lon": g.lon, "first_at": ago(40 * 86400),
                 "last_at": ago(86400), "visits": 3, "shared": true, "saved_at": ago(5 * 86400)]
            }
        case "gf_user_card_atlas":
            return gates.map { g in
                ["id": UUID().uuidString, "gate_id": g.id.uuidString, "gate_title": g.title, "gate_kind": g.kind,
                 "photo_path": g.cover ?? "demo/park.jpg", "approx_lat": g.lat, "approx_lon": g.lon, "created_at": ago(365 * 86400)]
            }
        case "gf_user_gates":
            return gates.filter { $0.owner != me }.map { g in
                ["id": g.id.uuidString, "title": g.title, "kind": g.kind, "cover_path": nn(g.cover), "approx_lat": g.lat,
                 "approx_lon": g.lon, "created_at": ago(40 * 86400), "graffiti_count": g.count]
            }
        case "gf_friend_atlas":
            return gates.map { g in
                ["gate_id": g.id.uuidString, "title": g.title, "owner": g.owner.uuidString, "owner_name": names[g.owner] ?? "",
                 "cover_path": nn(g.cover), "approx_lat": g.lat, "approx_lon": g.lon, "first_at": ago(30 * 86400), "visits": 2]
            }
        case "gf_my_saved_cards":
            return [["id": UUID().uuidString, "gate_id": hill.uuidString, "gate_title": "夕焼けの見える丘", "author": misaki.uuidString,
                     "author_name": "みさき", "body": NSNull(), "photo_path": "demo/sunset.jpg", "mine": false,
                     "created_at": ago(3 * 3600), "saved_at": ago(3600), "approx_lat": 35.66, "approx_lon": 139.70]]
        case "gf_my_notifications":
            return [
                ["kind": "card_comment", "actor": misaki.uuidString, "actor_name": "みさき", "gate_id": hill.uuidString,
                 "gate_title": "夕焼けの見える丘", "ref_id": UUID().uuidString, "created_at": ago(1200), "unread": true],
                ["kind": "card_link", "actor": kenta.uuidString, "actor_name": "けんた", "gate_id": tree.uuidString,
                 "gate_title": "公園の大きな木", "ref_id": UUID().uuidString, "created_at": ago(5 * 3600), "unread": true],
                ["kind": "like", "actor": yui.uuidString, "actor_name": "ゆい", "gate_id": hill.uuidString,
                 "gate_title": "夕焼けの見える丘", "ref_id": UUID().uuidString, "created_at": ago(26 * 3600), "unread": false],
            ]
        case "gf_dm_threads2", "gf_dm_threads":
            return [["other": misaki.uuidString, "other_name": "みさき", "last_body": "", "last_at": ago(1800),
                     "last_from_me": true, "unread": 0, "can_send": true, "last_kind": "card"],
                    ["other": kenta.uuidString, "other_name": "けんた", "last_body": "明日あの丘に行かない？", "last_at": ago(7200),
                     "last_from_me": false, "unread": 1, "can_send": true, "last_kind": "text"]]
        case "gf_gate_peek":
            let g = gate(params["p_gate"])
            if g.id == tree {
                return ["opened": false, "inside": false, "thread_count": 4,
                        "cards": [
                            ["id": UUID().uuidString, "author": kenta.uuidString, "author_name": "けんた",
                             "body": "今年の桜、満開でした。木の下でお弁当を食べました。", "photo_path": "demo/park.jpg",
                             "created_at": ago(5 * 3600), "finish": "holo", "title": "満開の木の下で"],
                            ["id": UUID().uuidString, "author": misaki.uuidString, "author_name": "みさき",
                             "body": "ここのベンチ、夕方に座るとちょうど木もれ日が当たる。", "photo_path": NSNull(),
                             "created_at": ago(2 * 86400)]],
                        "threads": [
                            ["id": UUID().uuidString, "topic": "question", "title": "この木は何年前からある？", "reply_count": 5,
                             "last_activity_at": ago(4 * 3600), "resolved": false],
                            ["id": UUID().uuidString, "topic": "memory", "title": "小学生のころ、ここで木登りした", "reply_count": 2,
                             "last_activity_at": ago(3 * 86400), "resolved": false]]]
            }
            return ["opened": true, "inside": !outside(g), "thread_count": 0, "cards": [Any](), "threads": [Any]()]
        case "gf_keep_open":
            return ["open": true, "expires_at": later(15 * 60), "near": true]
        case "gf_gate_ref_count":
            return ["count": 3, "max": 12]
        case "gf_gate_door":
            return ["scale": 1.0, "kind": "view", "style": "magic"]
        case "gf_my_notify_mutes":
            return ["like"]
        case "gf_trail_stops_of":
            return [
                ["seq": 1, "gate_id": clock.uuidString, "title": "駅前の大時計", "cover_path": "demo/night.jpg", "approx_lat": 35.6581,
                 "approx_lon": 139.7016, "visible": true, "reached": true],
                ["seq": 2, "gate_id": tree.uuidString, "title": "公園の大きな木", "cover_path": "demo/park.jpg", "approx_lat": 35.6572,
                 "approx_lon": 139.7029, "visible": true, "reached": true],
                ["seq": 3, "gate_id": hill.uuidString, "title": "夕焼けの見える丘", "cover_path": "demo/sunset.jpg", "approx_lat": 35.6595,
                 "approx_lon": 139.7005, "visible": true, "reached": false],
                ["seq": 4, "gate_id": NSNull(), "title": "見られない地点", "cover_path": NSNull(), "approx_lat": NSNull(),
                 "approx_lon": NSNull(), "visible": false, "reached": false],
            ]
        case "gf_memory_list":
            return [["id": UUID().uuidString, "owner": kenta.uuidString, "owner_name": "けんた", "title": "春のお花見",
                     "note": "毎年みんなで集まる日の写真と声", "visibility": "friends", "created_at": ago(200 * 86400), "item_count": 14,
                     "cover_path": "demo/park.jpg", "member_count": 5, "is_member": true, "can_add": true],
                    ["id": UUID().uuidString, "owner": misaki.uuidString, "owner_name": "みさき", "title": "卒業の日",
                     "note": "", "visibility": "friends", "created_at": ago(400 * 86400), "item_count": 3,
                     "cover_path": NSNull(), "member_count": 2, "is_member": false, "can_add": false]]
        case "gf_my_letters":
            return [
                ["id": UUID().uuidString, "gate_id": hill.uuidString, "gate_title": "夕焼けの見える丘", "author": misaki.uuidString,
                 "author_name": "みさき", "recipient": me.uuidString, "recipient_name": "あなた", "open_at": NSNull(), "onsite": true,
                 "opened_at": NSNull(), "created_at": ago(2 * 86400), "sent": false, "time_ok": true, "here": false],
                ["id": UUID().uuidString, "gate_id": clock.uuidString, "gate_title": "駅前の大時計", "author": me.uuidString,
                 "author_name": "あなた", "recipient": me.uuidString, "recipient_name": "あなた", "open_at": later(200 * 86400),
                 "onsite": false, "opened_at": NSNull(), "created_at": ago(20 * 86400), "sent": false, "time_ok": false, "here": false],
            ]
        case "gf_my_memories":
            return [["id": UUID().uuidString, "gate_id": tree.uuidString, "gate_title": "公園の大きな木", "owner": kenta.uuidString,
                     "owner_name": "けんた", "title": "春のお花見", "created_at": ago(200 * 86400), "item_count": 14,
                     "cover_path": "demo/park.jpg"]]
        case "gf_my_managed_gates":
            return [["id": tree.uuidString, "title": "公園の大きな木", "kind": "place", "cover_path": "demo/park.jpg",
                     "owner": kenta.uuidString, "owner_name": "けんた", "created_at": ago(60 * 86400), "added_at": ago(10 * 86400)]]
        default:
            return [Any]()
        }
    }

    // MARK: 表の答え

    static func table(_ table: String, query: String, method: String) -> Data {
        guard method == "GET" else { return json([Any]()) }
        let rows: [[String: Any]]
        switch table {
        case "profiles":
            rows = [me, misaki, kenta, yui].map(profile)
        case "follows":
            // あなた⇄みさき、あなた⇄けんたはお互いにフォロー、ゆいはあなたをフォローだけ
            rows = [(me, misaki), (me, kenta), (misaki, me), (kenta, me), (yui, me), (misaki, kenta)].map {
                ["follower": $0.0.uuidString, "followee": $0.1.uuidString]
            }
        case "gf_graffiti":
            rows = cards
        case "gf_reactions":
            rows = cards.prefix(2).flatMap { c in
                [["graffiti_id": c["id"]!, "user_id": kenta.uuidString], ["graffiti_id": c["id"]!, "user_id": yui.uuidString]]
            }
        case "gf_snapshots":
            rows = [["id": UUID().uuidString, "gate_id": hill.uuidString, "author": misaki.uuidString, "photo_path": "demo/sunset.jpg",
                     "visibility": "friends", "created_at": ago(300 * 86400)],
                    ["id": UUID().uuidString, "gate_id": hill.uuidString, "author": me.uuidString, "photo_path": "demo/night.jpg",
                     "visibility": "friends", "created_at": ago(2 * 86400)]]
        case "gf_gates":
            rows = gates.map { g in
                ["id": g.id.uuidString, "owner": g.owner.uuidString, "title": g.title, "visibility": "friends", "status": "open",
                 "created_at": ago(40 * 86400), "cover_path": nn(g.cover), "lat": g.lat, "lon": g.lon,
                 "kind": g.kind, "note": g.note]
            }
        default:
            rows = []
        }
        return json(filter(rows, query: query))
    }

    /// 表の問い合わせの「列=eq.値」「列=in.(値,値)」「列=is.null」だけを、本物のサーバーと同じように絞る
    private static func filter(_ rows: [[String: Any]], query: String) -> [[String: Any]] {
        let items = URLComponents(string: "x:/?" + query)?.queryItems ?? []
        let skip: Set<String> = ["select", "order", "limit", "offset", "or", "and"]
        func text(_ v: Any?) -> String {
            switch v {
            case nil, is NSNull: return "null"
            case let b as Bool: return b ? "true" : "false"
            default: return "\(v!)".lowercased()
            }
        }
        return rows.filter { row in
            items.allSatisfy { item in
                guard !skip.contains(item.name), let value = item.value else { return true }
                if value.hasPrefix("eq.") { return text(row[item.name]) == value.dropFirst(3).lowercased() }
                if value.hasPrefix("in.(") {
                    let list = value.dropFirst(4).dropLast().split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased() }
                    return list.contains(text(row[item.name]))
                }
                if value == "is.null" { return row[item.name] == nil || row[item.name] is NSNull }
                return true
            }
        }
    }

    private static func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("[]".utf8)
    }
}
#endif
