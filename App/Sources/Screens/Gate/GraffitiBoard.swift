import SwiftUI

// グラフィティボード（2026-11-17 オーナーが名前を決めた）：GATE の扉を開けずに見られる「GATE の顔」。
// 表紙の写真・名前・作った人・紹介・数・場所と、「扉を開ける」。扉を開けると、中のグラフィティカード・掲示板・
// アルバム・手紙が使える。GATE の画面の上（GraffitiBoardHero）と、地図の「近くのグラフィティボード」
// （GraffitiBoardCard）で同じ見た目にそろえる。

/// ネオンの帯（夕焼け → 夜空）。白い地の上ではなく、写真や夜空の上に置く
private let neonLine = LinearGradient(colors: Brand.neon, startPoint: .leading, endPoint: .trailing)

/// 「GRAFFITI BOARD」の札（写真の上に置く。ネオンの縁）
struct BoardTag: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait.fill")
            Text("GRAFFITI BOARD")
        }
        .font(.system(size: compact ? 9 : 11, weight: .heavy, design: .rounded))
        .tracking(compact ? 0.8 : 1.4)
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 5)
        .background(.black.opacity(0.38), in: Capsule())
        .overlay(Capsule().strokeBorder(neonLine, lineWidth: 1.2))
        .accessibilityLabel("グラフィティボード")
    }
}

/// 写真の上の小さな札（種類・距離など）
struct BoardPill: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.38), in: Capsule())
    }
}

/// GATE の画面のいちばん上：表紙の写真いっぱいに、名前と作った人。下の縁にネオンの帯
struct GraffitiBoardHero<Footer: View>: View {
    let title: String
    let coverPath: String?
    let kind: GateKind
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GateCoverImage(path: coverPath, markSize: 92)
            // 上は札が読めるように少し暗く、下は名前が読めるように濃く
            LinearGradient(stops: [.init(color: .black.opacity(0.32), location: 0),
                                   .init(color: .clear, location: 0.22),
                                   .init(color: .clear, location: 0.45),
                                   .init(color: .black.opacity(0.78), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                footer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .frame(height: 330)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) { BoardTag().padding(14) }
        .overlay(alignment: .topTrailing) { BoardPill(text: kind.label, symbol: kind.symbol).padding(14) }
        .overlay(alignment: .bottom) { Rectangle().fill(neonLine).frame(height: 4) }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: Color(hex: 0x8A4DF5).opacity(0.22), radius: 18, y: 8)
    }
}

/// グラフィティボードの数（大きな数字と、その下に何の数か）
struct BoardStat: View {
    let value: String
    let label: String
    var warm = false

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .heavy, design: .rounded))
                .foregroundStyle(warm ? Theme.warm : Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 扉の札：閉じているときは「扉の向こうでできること」と「扉を開ける」、開いているときは「扉が開いています」。
/// 白い画面の中で、ここだけ夜空の色にして目立たせる
struct BoardDoorPanel<Actions: View>: View {
    let isOpen: Bool
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                GateMark(size: 52, glowing: isOpen)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: isOpen ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(isOpen ? Theme.accent : Color.black.opacity(0.55), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                            .offset(x: 4, y: 4)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if !isOpen {
                // 扉の向こうでできること
                HStack(spacing: 0) {
                    insideItem("square.stack.fill", "グラフィティ\nカード")
                    insideItem("text.bubble.fill", "掲示板")
                    insideItem("photo.on.rectangle.angled", "アルバム")
                    insideItem("envelope.fill", "手紙")
                }
                .padding(.vertical, 10)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            actions()
        }
        .padding(18)
        .background(GateCoverImage.nightSky, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(neonLine.opacity(isOpen ? 1 : 0.7), lineWidth: 1.5))
        .shadow(color: Color(hex: 0x8A4DF5).opacity(isOpen ? 0.35 : 0.18), radius: isOpen ? 16 : 10, y: 6)
    }

    private func insideItem(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 夜空の札の上の、二番目のボタン（白い文字・うすい白の地）
struct NightSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.white.opacity(configuration.isPressed ? 0.2 : 0.12),
                        in: RoundedRectangle(cornerRadius: Theme.radiusButton))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusButton).stroke(.white.opacity(0.3)))
    }
}

/// 地図の「近くのグラフィティボード」の 1 枚（表紙いっぱいに名前・作った人・距離）
struct GraffitiBoardCard: View {
    let gate: NearbyGate
    var selected = false
    /// 小さい iPhone では低くして、上の地図を広く見せる
    var compact = false

    static func size(compact: Bool) -> CGSize { compact ? CGSize(width: 224, height: 124) : CGSize(width: 260, height: 156) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GateCoverImage(path: gate.cover_path, markSize: 46)
            LinearGradient(stops: [.init(color: .black.opacity(0.3), location: 0),
                                   .init(color: .clear, location: 0.3),
                                   .init(color: .black.opacity(0.8), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 5) {
                Text(gate.title)
                    .font(.system(size: compact ? 17 : 19, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(spacing: 6) {
                    if gate.mine {
                        Image(systemName: "person.fill").font(.caption2.weight(.bold))
                        Text("あなたの GATE")
                    } else {
                        NeonAvatar(name: gate.owner_name, size: 18)
                        Text(gate.owner_name)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: Self.size(compact: compact).width, height: Self.size(compact: compact).height)
        .overlay(alignment: .topLeading) { BoardTag(compact: true).padding(10) }
        .overlay(alignment: .topTrailing) {
            BoardPill(text: "約 \(Int(gate.distance_m.rounded()))m", symbol: "location.fill").padding(10)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(neonLine).frame(height: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(selected ? AnyShapeStyle(neonLine) : AnyShapeStyle(Color.white.opacity(0.7)),
                          lineWidth: selected ? 2.5 : 1))
        .shadow(color: .black.opacity(selected ? 0.3 : 0.2), radius: selected ? 12 : 8, y: 5)
        .scaleEffect(selected ? 1 : 0.97)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("グラフィティボード「\(gate.title)」\(gate.mine ? "あなたの GATE" : gate.owner_name + " さん")・約 \(Int(gate.distance_m.rounded()))m")
    }
}
