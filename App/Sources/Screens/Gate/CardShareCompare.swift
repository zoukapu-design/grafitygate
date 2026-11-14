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
        "Grafity Gate の「\(card.gateTitle)」に記憶を残しました。\n\(AppNavigator.gateURL(card.gateID).absoluteString)"
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

                Text("この絵と GATE へのリンクを送ります。リンクを開いた人に見えるのは GATE の名前と表紙だけで、記憶の中身は現地で扉を開けた人だけが見られます。")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let image {
                    ShareLink(item: Image(uiImage: image),
                              message: Text(shareText),
                              preview: SharePreview("「\(card.gateTitle)」の記憶", image: Image(uiImage: image))) {
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

// MARK: - 同じ GATE で、自分のカードと友達のカードを並べる

/// 比べる組み合わせ（友達のカード 1 枚と、同じ GATE の自分のカード）
struct CardCompareRequest: Identifiable {
    let other: CardSnapshot
    let mine: [CardSnapshot]
    var id: UUID { other.id }
}

/// 同じ場所の、ふたりの記憶。「並べる」と、どちらも写真があるときは「重ねる」（指でなぞって入れ替える）。
struct CardCompareView: View {
    let request: CardCompareRequest

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var mineID: UUID
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
        // はじめは、友達のカードにいちばん近い日の自分のカード
        let target = request.other.date ?? Date()
        let nearest = request.mine.min {
            abs(($0.date ?? .distantPast).timeIntervalSince(target)) < abs(($1.date ?? .distantPast).timeIntervalSince(target))
        }
        _mineID = State(initialValue: nearest?.id ?? request.mine.first?.id ?? UUID())
    }

    private var other: CardSnapshot { request.other }
    private var mine: CardSnapshot? { request.mine.first { $0.id == mineID } ?? request.mine.first }
    private var canOverlay: Bool { other.photoPath != nil && mine?.photoPath != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if request.mine.count > 1 { minePicker }
                    if canOverlay {
                        Picker("見せ方", selection: $mode) {
                            ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if let mine {
                        if mode == .overlay && canOverlay, let a = mine.photoPath, let b = other.photoPath {
                            overlay(minePath: a, otherPath: b)
                            HStack(alignment: .top, spacing: 12) {
                                caption(mine, isMine: true)
                                caption(other, isMine: false)
                            }
                        } else {
                            HStack(alignment: .top, spacing: 10) {
                                column(mine, isMine: true)
                                column(other, isMine: false)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("ふたりの記憶")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .fullScreenCover(item: $viewer) { item in
                PhotoViewer(path: item.path, caption: item.caption)
                    .environmentObject(session)
            }
        }
        .onAppear {
            Trace.log("カードを並べる：自分 \(request.mine.count) 枚・写真 \(canOverlay ? "どちらもあり" : "片方か無し")")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(other.gateTitle, systemImage: "door.left.hand.open")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.accentLight, in: Capsule())
            Text("同じ場所の、ふたりの記憶")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.text)
            if let a = mine?.date, let b = other.date {
                Text(gapText(mine: a, other: b))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func gapText(mine a: Date, other b: Date) -> String {
        let name = other.authorName.isEmpty ? "友達" : "\(other.authorName) さん"
        let gap = CardDates.gap(a, b)
        if gap == "同じ日" { return "あなたと \(name) は、同じ日にここで記憶を残しました。" }
        return a < b
            ? "あなたが残してから \(gap) あとに、\(name) がここに来ました。"
            : "\(name) が残してから \(gap) あとに、あなたがここに来ました。"
    }

    /// 自分のカードが何枚もあるときに選ぶ
    private var minePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("あなたのカード").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(request.mine) { card in
                        Button {
                            withAnimation(.snappy) { mineID = card.id }
                        } label: {
                            HStack(spacing: 6) {
                                if let path = card.photoPath {
                                    RemotePhoto(path: path)
                                        .frame(width: 24, height: 24)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                Text(card.dayText).font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(card.id == mineID ? .white : Theme.text)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(card.id == mineID ? Theme.warm : Theme.surfaceElevated, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// 並べる：左が自分、右が友達
    private func column(_ card: CardSnapshot, isMine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            who(card, isMine: isMine)
            if let path = card.photoPath {
                Button {
                    viewer = PhotoViewerItem(path: path, caption: card.body)
                } label: {
                    RemotePhoto(path: path)
                        .aspectRatio(3 / 4, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isMine ? Theme.warm : Theme.accent, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("写真を大きく見る")
            }
            if !card.body.isEmpty {
                Text(card.body)
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
    }

    private func who(_ card: CardSnapshot, isMine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isMine ? "あなた" : (card.authorName.isEmpty ? "友達" : card.authorName))
                .font(.caption.weight(.bold))
                .foregroundStyle(isMine ? Theme.warm : Theme.accent)
                .lineLimit(1)
            Text(card.dayText).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }

    private func caption(_ card: CardSnapshot, isMine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            who(card, isMine: isMine)
            if !card.body.isEmpty {
                Text(card.body).font(.footnote).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// 重ねる：下に友達の写真、上に自分の写真。白い線を左右になぞって入れ替える
    private func overlay(minePath: String, otherPath: String) -> some View {
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
                // なぞる線
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
                        tag(other.authorName.isEmpty ? "友達" : other.authorName, color: Theme.accent)
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
        .accessibilityLabel("あなたの写真と友達の写真を重ねて比べる")
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
