import SwiftUI
import UIKit

/// 共有・比べるときに使う、記憶のカード 1 枚の中身（GATE の中の一覧・ホームの新着のどちらからでも作れる）
struct CardSnapshot: Identifiable, Hashable {
    let id: UUID
    let gateID: UUID
    let gateTitle: String
    let author: UUID
    let authorName: String
    let body: String
    let photoPath: String?
    let createdAt: String

    var date: Date? { ServerDate.parse(createdAt) }

    init(id: UUID, gateID: UUID, gateTitle: String, author: UUID, authorName: String, body: String,
         photoPath: String?, createdAt: String) {
        self.id = id
        self.gateID = gateID
        self.gateTitle = gateTitle
        self.author = author
        self.authorName = authorName
        self.body = body
        self.photoPath = photoPath
        self.createdAt = createdAt
    }

    init(_ g: Graffiti, gateTitle: String, authorName: String) {
        id = g.id
        gateID = g.gate_id
        self.gateTitle = gateTitle
        author = g.author
        self.authorName = authorName
        body = g.body
        photoPath = g.photo_path
        createdAt = g.created_at
    }

    init(_ f: FeedCard) {
        id = f.id
        gateID = f.gate_id
        gateTitle = f.gate_title
        author = f.author
        authorName = f.author_name
        body = f.body
        photoPath = f.photo_path
        createdAt = f.created_at
    }

    /// 「2026年11月14日」
    var dayText: String {
        guard let date else { return "" }
        return CardDates.day.string(from: date)
    }
}

enum CardDates {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()
    static let dotted: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy.M.d"
        return f
    }()

    /// 2 つの日のへだたり：「2 年 3 か月」「5 日」「同じ日」
    static func gap(_ a: Date, _ b: Date) -> String {
        let (from, to) = a < b ? (a, b) : (b, a)
        let cal = Calendar.current
        if cal.isDate(from, inSameDayAs: to) { return "同じ日" }
        let c = cal.dateComponents([.year, .month, .day], from: cal.startOfDay(for: from), to: cal.startOfDay(for: to))
        var parts: [String] = []
        if let y = c.year, y > 0 { parts.append("\(y) 年") }
        if let m = c.month, m > 0 { parts.append("\(m) か月") }
        if parts.isEmpty, let d = c.day, d > 0 { parts.append("\(d) 日") }
        return parts.joined(separator: " ")
    }
}

// MARK: - カードを共有する

/// 自分のカードを 1 枚の絵（写真・ひとこと・GATE の名前・ネオンの枠）にして送る。
/// 絵にできるのは自分のカードだけ。リンクを開いた人に見えるのは GATE の名前と表紙までで、中身は現地でしか見られない。
struct CardShareSheet: View {
    let card: CardSnapshot

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false

    private var shareText: String {
        "Grafity Gate の「\(card.gateTitle)」にグラフィティカードを残しました。\n\(AppNavigator.gateURL(card.gateID).absoluteString)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: Color(hex: 0x9B5CFF).opacity(0.35), radius: 18, y: 8)
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    } else if failed {
                        Text("カードの絵を作れませんでした。もう一度お試しください。")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    } else {
                        ProgressView("カードの絵を作っています…")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 28)


                if let image {
                    ShareLink(item: Image(uiImage: image),
                              message: Text(shareText),
                              preview: SharePreview("「\(card.gateTitle)」のグラフィティカード", image: Image(uiImage: image))) {
                        Label("送る・保存する", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .simultaneousGesture(TapGesture().onEnded {
                        Trace.log("カードの共有を開いた")
                    })
                }
            }
            .padding(20)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("カードを共有")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
        .task { await render() }
    }

    private func render() async {
        var photo: UIImage?
        if let path = card.photoPath {
            photo = await session.media?.photo(path: path)
            if photo == nil {
                failed = true
                return
            }
        }
        let made = MainWatch.run("カードの絵") { CardShareArt.render(card: card, photo: photo) }
        withAnimation(.easeOut(duration: 0.25)) {
            image = made
            failed = made == nil
        }
    }
}

/// 共有するカードの絵（4:5。360×450 の大きさで並べ、3 倍で 1080×1350 の絵にする）
struct CardShareArt: View {
    let card: CardSnapshot
    let photo: UIImage?

    static let size = CGSize(width: 360, height: 450)

    @MainActor
    static func render(card: CardSnapshot, photo: UIImage?) -> UIImage? {
        let renderer = ImageRenderer(content: CardShareArt(card: card, photo: photo)
            .frame(width: size.width, height: size.height))
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }

    private var neon: LinearGradient {
        LinearGradient(colors: Brand.neon, startPoint: .bottomLeading, endPoint: .topTrailing)
    }

    var body: some View {
        ZStack {
            GateCoverImage.nightSky
            // 足もとからもれる光
            RadialGradient(colors: [Color(hex: 0xFF3D7F).opacity(0.35), .clear],
                           center: .bottom, startRadius: 10, endRadius: 260)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    GateMark(size: 22, glowing: false)
                    Text("Grafity Gate")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: Brand.neon, startPoint: .leading, endPoint: .trailing))
                    Spacer()
                    if let date = card.date {
                        Text(CardDates.dotted.string(from: date))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }

                if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: Self.size.width - 40, height: 236)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(neon, lineWidth: 2))
                        .shadow(color: Color(hex: 0xFF3D7F).opacity(0.45), radius: 10)
                    if !card.body.isEmpty {
                        Text(card.body)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .lineSpacing(2)
                            .lineLimit(3)
                    }
                } else {
                    // 文字だけのカード：ひとことを大きく
                    Text(card.body)
                        .font(.system(size: card.body.count > 80 ? 16 : 21, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineSpacing(4)
                        .lineLimit(9)
                        .minimumScaleFactor(0.7)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(neon, lineWidth: 2))
                }

                Spacer(minLength: 0)

                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(card.gateTitle, systemImage: "door.left.hand.open")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(card.authorName.isEmpty ? " " : "— \(card.authorName)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("場所に、記憶の扉を。")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: Brand.neon, startPoint: .leading, endPoint: .trailing))
                }
            }
            .padding(20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - 同じ GATE で、自分のカードとみんなのカードを見比べる

/// 見比べる組み合わせ：同じ GATE の自分のカードと、ほかの人のカード（友達を先に）。はじめに見せるほかの人のカード
struct CardCompareRequest: Identifiable {
    let others: [CardSnapshot]
    let mine: [CardSnapshot]
    var startID: UUID?

    init(others: [CardSnapshot], mine: [CardSnapshot], start: UUID? = nil) {
        self.others = others
        self.mine = mine
        startID = start ?? others.first?.id
    }

    /// 1 枚だけと見比べる（ホームの新着・届いた「来たよ」から）
    init(other: CardSnapshot, mine: [CardSnapshot]) {
        self.init(others: [other], mine: mine, start: other.id)
    }

    var id: UUID { startID ?? UUID() }
}

/// 同じ場所の、みんなのグラフィティカード。上に自分のカード（何枚もあれば選べる）、下にほかの人のカードを横にスワイプして見比べる。
/// どちらも写真があるときは「重ねる」で、2 枚の写真を指でなぞって入れ替えられる。
struct CardCompareView: View {
    let request: CardCompareRequest

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var mineID: UUID
    @State private var otherID: UUID?
    @State private var mode: Mode = .side
    @State private var wipe: CGFloat = 0.5
    @State private var viewer: PhotoViewerItem?

    enum Mode: String, CaseIterable, Identifiable {
        case side = "並べる"
        case overlay = "重ねる"
        var id: String { rawValue }
    }

    init(request: CardCompareRequest) {
        self.request = request
        let start = request.others.first { $0.id == request.startID } ?? request.others.first
        // はじめは、ほかの人のカードにいちばん近い日の自分のカード
        let target = start?.date ?? Date()
        let nearest = request.mine.min {
            abs(($0.date ?? .distantPast).timeIntervalSince(target)) < abs(($1.date ?? .distantPast).timeIntervalSince(target))
        }
        _mineID = State(initialValue: nearest?.id ?? request.mine.first?.id ?? UUID())
        _otherID = State(initialValue: start?.id)
    }

    private var mine: CardSnapshot? { request.mine.first { $0.id == mineID } ?? request.mine.first }
    private var other: CardSnapshot? { request.others.first { $0.id == otherID } ?? request.others.first }
    private var otherIndex: Int { request.others.firstIndex { $0.id == other?.id } ?? 0 }
    private var canOverlay: Bool { other?.photoPath != nil && mine?.photoPath != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if request.mine.count > 1 { minePicker }
                    Picker("見せ方", selection: $mode) {
                        ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!canOverlay)
                    if mode == .overlay && canOverlay, let mine, let other, let a = mine.photoPath, let b = other.photoPath {
                        overlay(minePath: a, otherPath: b, otherName: name(of: other))
                            .id("\(a)|\(b)")
                        othersStrip
                    } else {
                        if let mine { myCard(mine) }
                        othersPager
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("みんなのグラフィティカード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .fullScreenCover(item: $viewer) { item in
                PhotoViewer(path: item.path, caption: item.caption)
                    .environmentObject(session)
            }
            .onChange(of: canOverlay) { _, can in if !can { mode = .side } }
        }
        .onAppear {
            Trace.log("カードを見比べる：自分 \(request.mine.count) 枚・ほかの人 \(request.others.count) 枚")
        }
    }

    private func name(of card: CardSnapshot) -> String {
        card.authorName.isEmpty ? "だれか" : card.authorName
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let gateTitle = (mine ?? other)?.gateTitle {
                Label(gateTitle, systemImage: "door.left.hand.open")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.accentLight, in: Capsule())
            }
            Text(request.others.count > 1 ? "同じ場所の、みんなのグラフィティカード" : "同じ場所の、ふたりのグラフィティカード")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.text)
            if let a = mine?.date, let other, let b = other.date {
                Text(gapText(mine: a, other: b, name: name(of: other)))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeInOut, value: other.id)
            }
        }
    }

    private func gapText(mine a: Date, other b: Date, name: String) -> String {
        let who = "\(name) さん"
        let gap = CardDates.gap(a, b)
        if gap == "同じ日" { return "あなたと \(who) は、同じ日にここでグラフィティカードを残しました。" }
        return a < b
            ? "あなたが残してから \(gap) あとに、\(who) がここに来ました。"
            : "\(who) が残してから \(gap) あとに、あなたがここに来ました。"
    }

    /// 自分のカードが何枚もあるときに選ぶ
    private var minePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(request.mine) { card in
                    Button {
                        withAnimation(.snappy) { mineID = card.id }
                    } label: {
                        Text(card.dayText).font(.caption.weight(.semibold))
                            .foregroundStyle(card.id == mineID ? .white : Theme.text)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(card.id == mineID ? Theme.warm : Theme.surfaceElevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 上：自分のカード（横長）
    private func myCard(_ card: CardSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let path = card.photoPath {
                Button {
                    viewer = PhotoViewerItem(path: path, caption: card.body)
                } label: {
                    RemotePhoto(path: path)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.warm, lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("あなた").font(.caption.weight(.bold)).foregroundStyle(Theme.warm)
                Text(card.dayText).font(.caption2).foregroundStyle(Theme.textSecondary)
                if !card.body.isEmpty {
                    Text(card.body).font(.subheadline).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
    }

    /// 下：ほかの人のカード（横にスワイプ）
    private var othersPager: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(request.others.count > 1 ? "みんなのカード" : "\(other.map(name(of:)) ?? "") さんのカード")
                    .font(.headline).foregroundStyle(Theme.text)
                Spacer()
                if request.others.count > 1 {
                    Text("\(otherIndex + 1)/\(request.others.count)・横にスワイプ")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(request.others) { card in
                        otherCard(card)
                            .padding(.horizontal, 2)
                            .containerRelativeFrame(.horizontal)
                            .id(card.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $otherID)
            if request.others.count > 1 {
                HStack(spacing: 6) {
                    ForEach(request.others.prefix(12)) { card in
                        Circle()
                            .fill(card.id == other?.id ? Theme.accent : Theme.line)
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func otherCard(_ card: CardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PersonBadge(name: name(of: card), size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name(of: card)).font(.caption.weight(.bold)).foregroundStyle(Theme.accent).lineLimit(1)
                    Text(card.dayText).font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            if let path = card.photoPath {
                Button {
                    viewer = PhotoViewerItem(path: path, caption: card.body)
                } label: {
                    RemotePhoto(path: path)
                        .aspectRatio(4 / 3, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.accent, lineWidth: 2))
                }
                .buttonStyle(.plain)
            }
            if !card.body.isEmpty {
                Text(card.body).font(.subheadline).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
    }

    /// 重ねるときに、だれのカードと重ねるかを選ぶ小さな写真の並び
    private var othersStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(request.others.filter { $0.photoPath != nil }) { card in
                    Button {
                        withAnimation(.snappy) { otherID = card.id }
                    } label: {
                        VStack(spacing: 3) {
                            RemotePhoto(path: card.photoPath ?? "")
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .stroke(card.id == other?.id ? Theme.accent : .clear, lineWidth: 2.5))
                            Text(name(of: card)).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                .frame(width: 58)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 重ねる：下にほかの人の写真、上に自分の写真。白い線を左右になぞって入れ替える
    private func overlay(minePath: String, otherPath: String, otherName: String) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RemotePhoto(path: otherPath)
                    .frame(width: w, height: geo.size.height)
                RemotePhoto(path: minePath)
                    .frame(width: w, height: geo.size.height)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(0, min(w, w * wipe)))
                    }
                Rectangle()
                    .fill(.white)
                    .frame(width: 3)
                    .shadow(color: .black.opacity(0.35), radius: 3)
                    .overlay {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 34, height: 34)
                            .background(.white, in: Circle())
                            .shadow(color: .black.opacity(0.25), radius: 4)
                    }
                    .offset(x: w * wipe - 1.5)
                VStack {
                    HStack {
                        tag("あなた", color: Theme.warm)
                        Spacer()
                        tag(otherName, color: Theme.accent)
                    }
                    Spacer()
                }
                .padding(10)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        wipe = max(0, min(1, value.location.x / max(w, 1)))
                    }
            )
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("あなたの写真と \(otherName) さんの写真を重ねて比べる")
        .accessibilityValue("あなたの写真が \(Int(wipe * 100)) パーセント")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: wipe = min(1, wipe + 0.1)
            case .decrement: wipe = max(0, wipe - 0.1)
            @unknown default: break
            }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color, in: Capsule())
    }
}

// MARK: - 「来たよ」カード

/// 友達のカードに、自分がこの GATE で残したカードを添えて「来たよ」を送る
struct CardLinkComposer: View {
    let friendCard: CardSnapshot
    let myCards: [CardSnapshot]
    let onSent: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: UUID?
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    private var friendName: String { friendCard.authorName.isEmpty ? "友達" : friendCard.authorName }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(friendName) さんのカードに、あなたのカードを添えて送ります。届いた人は、どこにいても 2 枚を並べて見られます。")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 10) {
                        mini(friendCard, label: friendName, color: Theme.accent)
                        Image(systemName: "arrow.left").font(.headline).foregroundStyle(Theme.textSecondary).padding(.top, 50)
                        if let card = myCards.first(where: { $0.id == chosen }) ?? myCards.first {
                            mini(card, label: "あなた", color: Theme.warm)
                        }
                    }
                    if myCards.count > 1 {
                        Text("添えるカード").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(myCards) { card in
                                    Button {
                                        chosen = card.id
                                    } label: {
                                        Text(card.dayText).font(.caption.weight(.semibold))
                                            .foregroundStyle((chosen ?? myCards.first?.id) == card.id ? .white : Theme.text)
                                            .padding(.horizontal, 10).padding(.vertical, 6)
                                            .background((chosen ?? myCards.first?.id) == card.id ? Theme.warm : Theme.surfaceElevated,
                                                        in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    TextField("ひとこと（例：俺も今日来たよ！）", text: $text, axis: .vertical)
                        .lineLimit(2...4)
                        .padding(12)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                    if let error { NoticeText(text: error) }
                    Button {
                        Task { await send() }
                    } label: {
                        if sending { ProgressView().tint(.white) } else { Label("来たよを送る", systemImage: "hand.wave") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(sending || text.count > 200)
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("来たよを送る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
            }
            .onAppear {
                if text.isEmpty { text = "俺も今日来たよ！" }
            }
        }
    }

    private func mini(_ card: CardSnapshot, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.bold)).foregroundStyle(color).lineLimit(1)
            if let path = card.photoPath {
                RemotePhoto(path: path)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(color, lineWidth: 2))
            } else {
                Text(card.body).font(.footnote).foregroundStyle(Theme.text).lineLimit(5)
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
            }
            Text(card.dayText).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func send() async {
        guard let api = session.api, let mine = myCards.first(where: { $0.id == chosen }) ?? myCards.first else { return }
        sending = true
        defer { sending = false }
        do {
            _ = try await api.sendCardLink(from: mine.id, to: friendCard.id,
                                           body: text.trimmingCharacters(in: .whitespacesAndNewlines))
            Haptics.success()
            Trace.log("来たよを送った")
            onSent()
            dismiss()
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}

/// 届いた・送った「来たよ」
struct CardLinksView: View {
    var highlight: UUID? = nil

    @EnvironmentObject private var session: SessionModel
    @State private var links: [CardLink] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var comparing: CardCompareRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error { NoticeText(text: error) }
                if loaded && links.isEmpty && error == nil {
                    EmptyNote(title: "まだありません",
                              message: "GATE の中で友達のカードに「来たよ」を送ると、ここに並びます。",
                              systemImage: "hand.wave")
                        .padding(.top, 40)
                }
                ForEach(links) { link in
                    Button {
                        comparing = request(for: link)
                    } label: {
                        row(link)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("来たよ")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $comparing) { request in
            CardCompareView(request: request).environmentObject(session)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ link: CardLink) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PersonBadge(name: link.other_name, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(link.incoming ? "\(link.other_name) さんから" : "\(link.other_name) さんへ")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text("\(link.gate_title)・\(ServerDate.relative(link.created_at))")
                        .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                if link.incoming && (!link.seen || link.id == highlight) {
                    Circle().fill(Theme.accent).frame(width: 8, height: 8)
                }
            }
            if !link.body.isEmpty {
                Text("「\(link.body)」").font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                thumb(link.from_photo, body: link.from_body, label: link.incoming ? link.other_name : "あなた",
                      color: link.incoming ? Theme.accent : Theme.warm)
                thumb(link.to_photo, body: link.to_body, label: link.incoming ? "あなた" : link.other_name,
                      color: link.incoming ? Theme.warm : Theme.accent)
            }
            Label("押すと 2 枚を並べて見られます", systemImage: "rectangle.split.2x1")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(link.id == highlight ? Theme.accent : Theme.line, lineWidth: link.id == highlight ? 2 : 1))
    }

    private func thumb(_ photo: String?, body: String, label: String, color: Color) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let photo {
                RemotePhoto(path: photo)
            } else {
                Theme.surfaceElevated
                Text(body).font(.caption).foregroundStyle(Theme.text).lineLimit(4).padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color, in: Capsule())
                .padding(6)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 自分のカードを上、相手のカードを下にして並べる
    private func request(for link: CardLink) -> CardCompareRequest {
        let fromCard = CardSnapshot(id: link.from_card, gateID: link.gate_id, gateTitle: link.gate_title,
                                    author: link.incoming ? link.other : (session.userID ?? link.other),
                                    authorName: link.incoming ? link.other_name : "",
                                    body: link.from_body, photoPath: link.from_photo, createdAt: link.from_created_at)
        let toCard = CardSnapshot(id: link.to_card, gateID: link.gate_id, gateTitle: link.gate_title,
                                  author: link.incoming ? (session.userID ?? link.other) : link.other,
                                  authorName: link.incoming ? "" : link.other_name,
                                  body: link.to_body, photoPath: link.to_photo, createdAt: link.to_created_at)
        return link.incoming ? CardCompareRequest(other: fromCard, mine: [toCard])
                             : CardCompareRequest(other: toCard, mine: [fromCard])
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            links = try await api.myCardLinks()
            error = nil
            try? await api.markCardLinksSeen()
        } catch {
            self.error = ErrorText.isMissingFunction(error) ? "サーバーの準備がまだです（SQL を貼り直すと使えます）。" : ErrorText.of(error)
        }
        loaded = true
    }
}
