#if DEBUG
import SwiftUI
import UIKit

/// 画面の見本（シミュレーターの Debug の組み立てだけ。TestFlight には入らない）。
/// クラウドの Mac が `-GGDemoScreen <名前>` で開いて画面を撮り、文字やボタンの重なりを確かめる（.github/workflows/shots.yml）。
/// サーバーにはつながず、見本のデータだけで部品を並べる。
struct DemoGallery: View {
    let screen: String

    static var requestedScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-GGDemoScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static let screens = ["cards", "nearby", "nearby-detail", "chat", "lookback", "goal", "board", "edit-card",
                          "edit-gate", "progress", "notifications", "onboarding"]

    @StateObject private var nearby = NearbyCardsModel()

    init(screen: String) {
        self.screen = screen
        Demo.seedPhotos()
    }

    var body: some View {
        content
            .tint(Theme.accent)
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case "cards":
            NavigationStack {
                ScrollView {
                    VStack(spacing: 14) {
                        GraffitiCard(item: Demo.card(mine: true, photo: "demo/sunset.jpg", body: "夕焼けがきれいだった。また来たい。"),
                                     author: "あなた", isMine: true, likeCount: 4, liked: false,
                                     onLike: {}, onDelete: {}, onReport: {}, onShare: {}, inAtlas: true,
                                     commentCount: 2, onComments: {}, saved: true, onEdit: {}, onSendToFriend: {})
                        GraffitiCard(item: Demo.card(mine: false, photo: nil,
                                                     body: "ここで初めて会った日のこと、ずっと覚えてる。ベンチの横の桜が満開だった。"),
                                     author: "みさき", isMine: false, likeCount: 12, liked: true,
                                     onLike: {}, onDelete: {}, onReport: {}, onCompare: {}, onCardLink: {},
                                     linkNote: "あなたが「来たよ」を送りました", commentCount: 0, onComments: {}, saved: false)
                        GraffitiCard(item: Demo.card(mine: true, photo: "demo/night.jpg", body: "夜の駅前。"),
                                     author: "あなた", isMine: true, likeCount: 1, liked: false,
                                     onLike: {}, onDelete: {}, onReport: {}, inAtlas: false,
                                     commentCount: 1, onComments: {}, saved: false, startFlipped: true)
                    }
                    .padding(16)
                }
                .background(Theme.background)
                .navigationTitle("夕焼けの見える丘")
                .navigationBarTitleDisplayMode(.inline)
            }
        case "nearby":
            NavigationStack {
                NearbyCardsView(model: nearby)
                    .navigationTitle("地図")
                    .navigationBarTitleDisplayMode(.inline)
                    .onAppear { nearby.showDemo(Demo.nearbyCards) }
            }
        case "nearby-detail":
            NearbyCardDetail(card: Demo.nearbyCards[0])
        case "chat":
            NavigationStack {
                ScrollView {
                    VStack(alignment: .trailing, spacing: 10) {
                        Text("いま丘の上！")
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .foregroundStyle(.white)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18))
                        ChatCardBubble(message: Demo.cardMessage)
                        HStack {
                            ChatCardBubble(message: Demo.goneMessage(friend: true))
                            Spacer()
                        }
                    }
                    .padding(16)
                }
                .background(Theme.background)
                .navigationTitle("みさき")
                .navigationBarTitleDisplayMode(.inline)
            }
        case "lookback":
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        OnThisDayCard(pick: Demo.onThisDay)
                        TrailCard(trail: Demo.trail)
                    }
                    .padding(16)
                }
                .background(Theme.background)
                .navigationTitle("わたし")
            }
        case "goal":
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1A2340), Color(hex: 0x6B4A3A)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                TrailGoalOverlay(goal: TrailReached(trail_id: UUID(), title: "夕焼けの散歩道", reached: 5, stop_count: 5,
                                                    completed: true)) {}
            }
        case "board":
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Label("調べる", systemImage: "magnifyingglass").font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                            ProgressBadge(progress: .narrowing)
                        }
                        Text("この丘の名前の由来").font(.title3.weight(.semibold))
                        ForEach(Demo.replies) { reply in
                            ReplyRow(reply: reply, canDelete: false, isMine: false, canVote: true, onVote: {},
                                     onEdit: {}, onDelete: {}, onReport: {})
                        }
                    }
                    .padding(16)
                }
                .background(Theme.background)
                .navigationTitle("掲示板")
                .navigationBarTitleDisplayMode(.inline)
            }
        case "edit-card":
            GraffitiEditSheet(item: Demo.card(mine: true, photo: "demo/sunset.jpg", body: "夕焼けがきれいだった。")) {}
        case "edit-gate":
            GateEditSheet(summary: Demo.gate, isOwner: false) {}
        case "progress":
            InvestigationProgressSheet(thread: Demo.thread) { _, _ in }
        case "notifications":
            NavigationStack { NotificationSettingsView() }
        case "onboarding":
            OnboardingView {}
        default:
            List(Self.screens, id: \.self) { Text($0) }
        }
    }
}

/// 見本のデータ
private enum Demo {
    static let me = UUID()
    static let friend = UUID()
    static let gateID = UUID()
    static let now = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600))

    static func card(mine: Bool, photo: String?, body: String) -> Graffiti {
        Graffiti(id: UUID(), gate_id: gateID, author: mine ? me : friend, body: body, photo_path: photo,
                 visibility: "friends", local_only: false, created_at: now, in_atlas: mine ? true : nil, edited_at: nil)
    }

    static let nearbyCards: [NearbyCard] = [
        NearbyCard(id: UUID(), gate_id: gateID, gate_title: "夕焼けの見える丘", gate_kind: "view", author: friend,
                   author_name: "みさき", body: "ここから見る夕焼けが一番好き。ベンチに座って待ってみて。",
                   photo_path: "demo/sunset.jpg", created_at: now, approx_lat: 35.659, approx_lon: 139.700, distance_m: 180),
        NearbyCard(id: UUID(), gate_id: UUID(), gate_title: "駅前の大時計", gate_kind: "object", author: UUID(),
                   author_name: "けんた", body: "待ち合わせはいつもここ。", photo_path: "demo/night.jpg", created_at: now,
                   approx_lat: 35.658, approx_lon: 139.701, distance_m: 260),
        NearbyCard(id: UUID(), gate_id: UUID(), gate_title: "公園の大きな木", gate_kind: "place", author: UUID(),
                   author_name: "ゆい", body: "春になったら、またみんなで来よう。", photo_path: nil, created_at: now,
                   approx_lat: 35.657, approx_lon: 139.702, distance_m: 90),
    ]

    static let cardMessage = DMMessage(id: UUID(), sender: me, body: "", photo_path: nil, created_at: now, read_at: nil,
                                       card_id: UUID(), card_body: "夕焼けがきれいだった。", card_photo: "demo/sunset.jpg",
                                       card_gate_id: gateID, card_gate_title: "夕焼けの見える丘", card_created_at: now,
                                       card_gone: false)

    static func goneMessage(friend: Bool) -> DMMessage {
        DMMessage(id: UUID(), sender: friend ? Demo.friend : me, body: "", photo_path: nil, created_at: now, read_at: nil,
                  card_id: UUID(), card_body: "公園の大きな木の下で。春になったら、またみんなで来よう。", card_photo: nil,
                  card_gate_id: gateID, card_gate_title: "公園の大きな木", card_created_at: now, card_gone: false)
    }

    static var onThisDay: OnThisDay.Pick {
        let year = Date().addingTimeInterval(-365 * 86400)
        return OnThisDay.Pick(headline: "1 年前の今ごろ", items: [
            OnThisDay.Item(id: UUID(), gateID: gateID, title: "夕焼けの見える丘", photoPath: "demo/sunset.jpg", date: year, isGate: true),
            OnThisDay.Item(id: UUID(), gateID: UUID(), title: "駅前の大時計", photoPath: "demo/night.jpg", date: year, isGate: false),
            OnThisDay.Item(id: UUID(), gateID: UUID(), title: "公園の大きな木", photoPath: nil, date: year, isGate: false),
        ])
    }

    static let trail = TrailSummary(id: UUID(), owner: friend, owner_name: "みさき", title: "夕焼けの散歩道",
                                    note: "駅から丘まで、夕方に歩くのがおすすめ", visibility: "friends", created_at: now,
                                    stop_count: 5, cover_path: "demo/park.jpg", reached: 2, completed: false, started: true)

    static let replies: [BoardReply] = [
        BoardReply(id: UUID(), author: friend, author_name: "みさき", body: "昔の地図だと、ここに「物見台」と書いてある。",
                   created_at: now, label: "fact", source: "市立図書館『町の古地図』", edited_at: nil, votes: 5, my_vote: true),
        BoardReply(id: UUID(), author: UUID(), author_name: "けんた", body: "見張りの場所だったから、この名前になったのでは。",
                   created_at: now, label: "hypothesis", source: nil, edited_at: nil, votes: 2, my_vote: false),
        BoardReply(id: UUID(), author: UUID(), author_name: "ゆい", body: "おばあちゃんは、狐が出る丘と呼んでいた。",
                   created_at: now, label: "rumor", source: nil, edited_at: nil, votes: 0, my_vote: false),
    ]

    static let thread = BoardThread(id: UUID(), author: me, author_name: "あなた", topic: "investigation",
                                    title: "この丘の名前の由来", body: "", pinned: false, reply_count: 3,
                                    last_activity_at: now, created_at: now, unread: false, edited_at: nil, resolved: false,
                                    progress: "narrowing", conclusion: "昔の地図に「物見台」とある。")

    static let gate = GateSummary(id: gateID, title: "夕焼けの見える丘", note: "西口から坂をのぼった先のベンチ。",
                                  kind: "view", owner: friend, owner_name: "みさき", cover_path: "demo/sunset.jpg",
                                  approx_lat: 35.659, approx_lon: 139.700, visibility: "friends", status: "open",
                                  graffiti_count: 12, created_at: now, my_visit: nil, my_visit_expires_at: nil)

    // MARK: 見本の写真（その場で描く）

    private static var seeded = false

    static func seedPhotos() {
        guard !seeded else { return }
        seeded = true
        MediaStore.seedDemoPhoto(scene(top: 0xF59E5B, bottom: 0x7A3E6B, sun: true, city: false), path: "demo/sunset.jpg")
        MediaStore.seedDemoPhoto(scene(top: 0x0B1030, bottom: 0x2E2A5C, sun: false, city: true), path: "demo/night.jpg")
        MediaStore.seedDemoPhoto(scene(top: 0x9ED3F0, bottom: 0x5E9E6B, sun: false, city: false), path: "demo/park.jpg")
    }

    private static func scene(top: UInt32, bottom: UInt32, sun: Bool, city: Bool) -> UIImage {
        let size = CGSize(width: 900, height: 1200)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(rgb: top).cgColor, UIColor(rgb: bottom).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            if sun {
                UIColor(rgb: 0xFFE0A0).withAlphaComponent(0.9).setFill()
                cg.fillEllipse(in: CGRect(x: 520, y: 520, width: 220, height: 220))
            }
            if city {
                for i in 0..<12 {
                    let w = CGFloat(50 + (i * 37) % 60), h = CGFloat(200 + (i * 91) % 380)
                    UIColor(white: 0.08, alpha: 1).setFill()
                    cg.fill(CGRect(x: CGFloat(i) * 78, y: size.height - h, width: w, height: h))
                    UIColor(rgb: 0xFFD27A).withAlphaComponent(0.8).setFill()
                    for j in 0..<Int(h / 60) {
                        cg.fill(CGRect(x: CGFloat(i) * 78 + 12, y: size.height - h + CGFloat(j) * 60 + 20, width: 10, height: 14))
                    }
                }
            } else {
                let hill = UIBezierPath()
                hill.move(to: CGPoint(x: 0, y: size.height * 0.72))
                hill.addCurve(to: CGPoint(x: size.width, y: size.height * 0.68),
                              controlPoint1: CGPoint(x: size.width * 0.3, y: size.height * 0.58),
                              controlPoint2: CGPoint(x: size.width * 0.6, y: size.height * 0.8))
                hill.addLine(to: CGPoint(x: size.width, y: size.height))
                hill.addLine(to: CGPoint(x: 0, y: size.height))
                hill.close()
                UIColor(white: 0.1, alpha: 0.55).setFill()
                hill.fill()
            }
        }
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}
#endif
