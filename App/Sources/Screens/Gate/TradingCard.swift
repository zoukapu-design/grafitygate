import SwiftUI

// グラフィティカードを「トレーディングカード」の形に（2026-11-18 オーナー「もっとカードっぽい見た目に」「キラキラの加工」）。
// 縦長（63:88）の枠に、上に書いた人、まん中にその場の写真、GATE の名前の帯、ひとことの欄、下に日付と星。
// 仕上げ（CardFinish）で枠の色と光り方が変わる：ノーマル・キラ（虹色）・ゴールド・ネオン。

/// カードの仕上げ（サーバーの gf_graffiti.finish と同じ。足すときはサーバーの check と gf_set_card_finish も直す）
enum CardFinish: String, CaseIterable, Identifiable {
    case normal, holo, gold, neon

    var id: String { rawValue }

    init(raw: String?) {
        self = CardFinish(rawValue: raw ?? "") ?? .normal
    }

    var label: String {
        switch self {
        case .normal: return "ノーマル"
        case .holo: return "キラ"
        case .gold: return "ゴールド"
        case .neon: return "ネオン"
        }
    }

    var symbol: String {
        switch self {
        case .normal: return "rectangle.portrait"
        case .holo: return "sparkles"
        case .gold: return "crown.fill"
        case .neon: return "bolt.fill"
        }
    }

    /// 枠の色
    var frame: LinearGradient {
        switch self {
        case .normal:
            return LinearGradient(colors: [Color(hex: 0xF4F1FB), Color(hex: 0xD9D3EA), Color(hex: 0xF4F1FB)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .holo:
            return LinearGradient(colors: [Color(hex: 0xBFE9FF), Color(hex: 0xF7C6FF), Color(hex: 0xFFF1B8),
                                           Color(hex: 0xB8FFD9), Color(hex: 0xC9C2FF)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .gold:
            return LinearGradient(colors: [Color(hex: 0xFFF3B0), Color(hex: 0xE2A93B), Color(hex: 0xFFE38A),
                                           Color(hex: 0xB9781E)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .neon:
            return LinearGradient(colors: [Color(hex: 0x1A1033), Color(hex: 0x2A1650)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }

    /// 枠の上の文字の色（日付・星）
    var ink: Color { self == .neon ? .white : Color(hex: 0x2A2340) }

    /// ひとことの欄の色
    var textBox: Color {
        switch self {
        case .normal: return .white
        case .holo: return Color.white.opacity(0.9)
        case .gold: return Color(hex: 0xFFF9E6)
        case .neon: return Color(hex: 0x120B24).opacity(0.92)
        }
    }

    var textInk: Color { self == .neon ? .white : Color(hex: 0x17181F) }

    /// めずらしさの星
    var stars: String {
        switch self {
        case .normal: return "★"
        case .neon: return "★★"
        case .holo, .gold: return "★★★"
        }
    }
}

/// カードに出す中身
struct TradingCardContent: Identifiable {
    let id: UUID
    var photoPath: String?
    /// まだ送っていない写真（作っている途中の見本）
    var image: UIImage?
    var body: String
    var author: String
    /// カードの名前（書いた本人が付けたもの。無ければ書いた人の名前を出す）
    var title: String? = nil
    var gateTitle: String
    var createdAt: String?
    var likes: Int = 0
    var finish: CardFinish = .normal
    /// 左上の札（友達・あなた・訪れた人）
    var badge: Badge? = nil

    enum Badge {
        case friend, mine, visitor

        var label: String {
            switch self {
            case .friend: return "友達"
            case .mine: return "あなた"
            case .visitor: return "訪れた人"
            }
        }

        var color: Color {
            switch self {
            case .friend: return Theme.accent
            case .mine: return Theme.warm
            case .visitor: return Color(hex: 0x3A8DDE)
            }
        }
    }

    var dateText: String {
        guard let s = createdAt, let date = ServerDate.parse(s) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy.MM.dd"
        return f.string(from: date)
    }
}

/// 飾りの動き（光が流れる・星がまたたく）をするか。「視差効果を減らす」のときと、画面の見本では止める
enum CardMotion {
    static var enabled: Bool {
        #if DEBUG
        if DemoMode.screen != nil { return false }
        #endif
        return !UIAccessibility.isReduceMotionEnabled
    }
}

/// トレーディングカードの形のグラフィティカード（幅に合わせて文字も大きさが変わる）
struct TradingCard: View {
    let content: TradingCardContent
    /// 傾き（-1〜1。指で傾けたとき、光の帯が動く）
    var tilt: CGSize = .zero
    /// 光を流すか（一覧で並べるときは控えめに）
    var animated = true

    static let aspect: CGFloat = 63.0 / 88.0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let finish = content.finish
            ZStack {
                RoundedRectangle(cornerRadius: w * 0.055, style: .continuous)
                    .fill(finish.frame)
                if finish == .neon {
                    RoundedRectangle(cornerRadius: w * 0.055, style: .continuous)
                        .strokeBorder(Theme.neonBand, lineWidth: w * 0.022)
                }
                VStack(spacing: w * 0.022) {
                    header(w)
                    art(w)
                    typeLine(w)
                    textBox(w)
                    footer(w)
                }
                .padding(w * 0.045)
                // 光の帯（どの仕上げでも。キラ・ゴールドは強く）
                CardShine(finish: finish, tilt: tilt, animated: animated && CardMotion.enabled)
                    .clipShape(RoundedRectangle(cornerRadius: w * 0.055, style: .continuous))
                    .allowsHitTesting(false)
                if finish == .holo || finish == .gold {
                    CardSparkles(width: w, gold: finish == .gold, animated: animated && CardMotion.enabled)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: finish == .neon ? Color(hex: 0xFF3D7F).opacity(0.45) : .black.opacity(0.22),
                    radius: finish == .neon ? w * 0.06 : w * 0.035, y: w * 0.02)
        }
        .aspectRatio(Self.aspect, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("グラフィティカード「\(headline)」。\(content.author.isEmpty ? "" : content.author + " さん。")\(content.body)")
    }

    /// 上の帯に出す名前（カードの名前。無ければ書いた人の名前）
    private var headline: String {
        if let t = content.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return content.author.isEmpty ? "だれか" : content.author
    }

    private var hasTitle: Bool {
        !(content.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    // 上：カードの名前（無ければ書いた人）と、いいねの数
    private func header(_ w: CGFloat) -> some View {
        HStack(spacing: w * 0.025) {
            NeonAvatar(name: content.author.isEmpty ? "?" : content.author, size: w * 0.085)
            Text(headline)
                .font(.system(size: w * 0.062, weight: .heavy))
                .foregroundStyle(Color(hex: 0x17181F))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            HStack(spacing: w * 0.012) {
                Image(systemName: "heart.fill")
                Text("\(content.likes)")
            }
            .font(.system(size: w * 0.05, weight: .heavy, design: .rounded))
            .foregroundStyle(Color(hex: 0xE0457B))
        }
        .padding(.horizontal, w * 0.03)
        .frame(height: w * 0.115)
        .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: w * 0.03, style: .continuous))
    }

    // まん中：その場の写真（無ければ夜空に扉のしるし）
    private func art(_ w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let image = content.image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if let path = content.photoPath {
                    RemotePhoto(path: path)
                } else {
                    ZStack {
                        GateCoverImage.nightSky
                        GateMark(size: w * 0.26, glowing: true)
                    }
                }
            }
            .frame(width: w * 0.91, height: w * 0.62)
            .clipped()
            if let badge = content.badge {
                Text(badge.label)
                    .font(.system(size: w * 0.042, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, w * 0.025).padding(.vertical, w * 0.008)
                    .background(badge.color, in: Capsule())
                    .overlay(Capsule().stroke(.white, lineWidth: 1.2))
                    .padding(w * 0.025)
            }
        }
        .frame(width: w * 0.91, height: w * 0.62)
        .clipShape(RoundedRectangle(cornerRadius: w * 0.02, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: w * 0.02, style: .continuous)
            .strokeBorder(Color.white.opacity(0.9), lineWidth: max(1.5, w * 0.008)))
    }

    // GATE の名前の帯
    private func typeLine(_ w: CGFloat) -> some View {
        HStack(spacing: w * 0.02) {
            Image(systemName: "door.left.hand.open")
            Text("GRAFFITI CARD")
                .tracking(w * 0.004)
            Text("・\(content.gateTitle)")
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .font(.system(size: w * 0.038, weight: .heavy))
        .foregroundStyle(.white)
        .padding(.horizontal, w * 0.03)
        .frame(height: w * 0.075)
        .background(LinearGradient(colors: [Color(hex: 0x2A1650), Color(hex: 0x4A2A8A)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: w * 0.02, style: .continuous))
    }

    // ひとこと
    private func textBox(_ w: CGFloat) -> some View {
        Text(content.body.isEmpty ? "（ひとことなし）" : content.body)
            .font(.system(size: w * 0.055, weight: .semibold))
            .foregroundStyle(content.body.isEmpty ? content.finish.textInk.opacity(0.4) : content.finish.textInk)
            .lineLimit(4)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(w * 0.035)
            .background(content.finish.textBox, in: RoundedRectangle(cornerRadius: w * 0.025, style: .continuous))
    }

    // 下：日付（名前を付けたカードは、書いた人も）と星
    private func footer(_ w: CGFloat) -> some View {
        HStack(spacing: w * 0.02) {
            Text(content.dateText)
            if hasTitle, !content.author.isEmpty {
                Text("by \(content.author)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            Text(content.finish.stars)
        }
        .font(.system(size: w * 0.038, weight: .bold, design: .rounded))
        .foregroundStyle(content.finish.ink.opacity(0.85))
        .frame(height: w * 0.05)
    }
}

/// カードの上を流れる光の帯（傾けると動く）。キラは虹色、ゴールドは金色に光る
struct CardShine: View {
    let finish: CardFinish
    var tilt: CGSize = .zero
    var animated = true
    @State private var sweep: CGFloat = -1.2

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let position = animated ? sweep : CGFloat(tilt.width) * 0.9
            ZStack {
                if finish == .holo {
                    // 虹色のうすい膜（傾けると色がずれる）
                    AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red],
                                    center: UnitPoint(x: 0.5 + tilt.width * 0.4, y: 0.5 + tilt.height * 0.4))
                        .opacity(0.22)
                        .blendMode(.colorDodge)
                }
                LinearGradient(colors: [.clear, .white.opacity(strength), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: w * 0.45, height: h * 1.6)
                    .rotationEffect(.degrees(22))
                    .offset(x: position * w)
                    .blendMode(.plusLighter)
            }
            .frame(width: w, height: h)
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.linear(duration: finish == .normal ? 5.5 : 3.2).repeatForever(autoreverses: false)) {
                sweep = 1.4
            }
        }
    }

    private var strength: Double {
        switch finish {
        case .normal: return 0.22
        case .neon: return 0.28
        case .holo: return 0.45
        case .gold: return 0.5
        }
    }
}

/// キラ・ゴールドのカードの、またたく星
struct CardSparkles: View {
    let width: CGFloat
    var gold = false
    var animated = true
    @State private var on = false

    private static let spots: [(x: CGFloat, y: CGFloat, s: CGFloat, layer: Int)] = [
        (0.12, 0.2, 0.07, 0), (0.86, 0.14, 0.05, 1), (0.78, 0.46, 0.08, 0), (0.18, 0.55, 0.05, 1),
        (0.5, 0.08, 0.045, 0), (0.9, 0.82, 0.06, 1), (0.08, 0.86, 0.05, 0),
    ]

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(Self.spots.enumerated()), id: \.offset) { _, spot in
                Image(systemName: "sparkle")
                    .font(.system(size: width * spot.s, weight: .bold))
                    .foregroundStyle(gold ? Color(hex: 0xFFF3B0) : .white)
                    .shadow(color: gold ? Color(hex: 0xFFC94A) : Color(hex: 0xB28CFF), radius: width * 0.02)
                    .position(x: geo.size.width * spot.x, y: geo.size.height * spot.y)
                    .opacity(animated ? ((on ? spot.layer == 0 : spot.layer == 1) ? 1 : 0.25) : 0.9)
                    .scaleEffect(animated ? ((on ? spot.layer == 0 : spot.layer == 1) ? 1 : 0.6) : 1)
            }
        }
        .onAppear {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { on = true }
        }
    }
}

/// 1 枚を大きく見る（指で傾けると光が動く）。ひとことは全部、下に出す
struct TradingCardViewer: View {
    let content: TradingCardContent
    var isMine = false
    var onReport: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var tilt: CGSize = .zero

    var body: some View {
        ZStack {
            InsideBackground().ignoresSafeArea()
            VStack(spacing: 18) {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                    .accessibilityLabel("閉じる")
                }
                Spacer(minLength: 0)
                TradingCard(content: content, tilt: tilt, animated: tilt == .zero)
                    .frame(maxWidth: 330)
                    .rotation3DEffect(.degrees(Double(tilt.width) * 16), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                    .rotation3DEffect(.degrees(Double(-tilt.height) * 14), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                    .gesture(DragGesture()
                        .onChanged { value in
                            tilt = CGSize(width: max(-1, min(1, value.translation.width / 140)),
                                          height: max(-1, min(1, value.translation.height / 180)))
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { tilt = .zero }
                        })
                Text("指でカードを傾けると、光が動きます")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                if content.body.count > 40 {
                    ScrollView {
                        Text(content.body)
                            .font(.body)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(.horizontal, 8)
                }
                Spacer(minLength: 0)
                if !isMine, let onReport {
                    Button {
                        dismiss()
                        onReport()
                    } label: {
                        Label("通報する", systemImage: "exclamationmark.bubble")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .padding(20)
        }
    }
}

/// 仕上げを選ぶ（小さな見本の札を横に並べる）
struct CardFinishPicker: View {
    @Binding var selection: CardFinish

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CardFinish.allCases) { finish in
                Button {
                    Haptics.tap()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = finish }
                } label: {
                    VStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(finish.frame)
                            .overlay {
                                if finish == .neon {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.neonBand, lineWidth: 2)
                                }
                            }
                            .overlay(Image(systemName: finish.symbol)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(finish == .neon ? .white : Color(hex: 0x4A2A8A)))
                            .frame(width: 34, height: 46)
                        Text(finish.label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(selection == finish ? Theme.accent : Theme.textSecondary)
                    }
                    .padding(6)
                    .background(selection == finish ? Theme.accentLight : .clear,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selection == finish ? Theme.accent : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("仕上げ：\(finish.label)")
                .accessibilityAddTraits(selection == finish ? .isSelected : [])
            }
        }
    }
}
