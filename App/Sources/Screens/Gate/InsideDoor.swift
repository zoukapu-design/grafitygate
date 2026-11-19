import SwiftUI

// 扉の中の画面（2026-11-18 オーナー「入った感がなさすぎる」「ボードと同じではダメ」）。
// グラフィティボード（白い紙の掲示）に対して、扉の中は AR の扉の向こうと同じ夜空の世界にする。
// 上から：小さな見出し（どこにいるか・扉を出る）→ みんなのグラフィティカード（主役）→「カードを作る」→ 扉の中の切り替え。

/// 扉の中の背景：夕焼けから夜空へ。星と、ネオンの光がにじむ
struct InsideBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0B0F2A), Color(hex: 0x1D1240), Color(hex: 0x2E1546), Color(hex: 0x14102A)],
                           startPoint: .top, endPoint: .bottom)
            // 上のほうに、扉からもれる光
            RadialGradient(colors: [Color(hex: 0x8A4DF5).opacity(0.45), .clear], center: .top, startRadius: 10, endRadius: 420)
            RadialGradient(colors: [Color(hex: 0xFF7A59).opacity(0.18), .clear], center: UnitPoint(x: 0.15, y: 0.35),
                           startRadius: 10, endRadius: 300)
            StarDust(count: 60)
        }
    }
}

/// 散らばった星（場所は毎回同じ）。2 つの層をゆっくり交互に明るくして、またたいて見せる。
/// 毎コマ描き直さない（星を描くのは 1 回だけで、明るさの変化は重ねた層の透明度だけ）
struct StarDust: View {
    let count: Int
    @State private var twinkle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            StarLayer(count: count / 2, seed: 0x9E3779B97F4A7C15)
                .opacity(twinkle ? 0.35 : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: twinkle)
            StarLayer(count: count - count / 2, seed: 0x2545F4914F6CDD1D)
                .opacity(twinkle ? 1 : 0.4)
                .animation(reduceMotion ? nil : .easeInOut(duration: 3.4).repeatForever(autoreverses: true), value: twinkle)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { twinkle = true }
    }
}

private struct StarLayer: View {
    let count: Int
    let seed: UInt64

    var body: some View {
        Canvas { context, size in
            var state = seed
            func next() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 11) / Double(1 << 53)
            }
            for _ in 0..<count {
                let x = next() * size.width
                let y = next() * size.height * 0.75
                let r = 0.6 + next() * 1.6
                let a = 0.35 + next() * 0.5
                context.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(.white.opacity(a)))
            }
        }
    }
}

/// 扉の中のいちばん上（小さく）：光る輪の表紙・「WELCOME INSIDE」・GATE の名前・扉の様子と「扉を出る」。
/// 2026-11-18 オーナー「どこを見ればいいかわからない」→ 大きな表紙とタイルをやめ、主役はみんなのカードにした
struct InsideHeader: View {
    let title: String
    let coverPath: String?
    let ownerLine: String
    /// 離れて、まもなく閉じるときだけ出す一言（ふだんは何も出さない。GATE を出るのは右上の「…」から）
    var closingNote: String? = nil

    private let ring = AngularGradient(colors: Brand.neon + [Brand.neon.first ?? .orange], center: .center)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().strokeBorder(ring, lineWidth: 3).frame(width: 70, height: 70)
                    GateCoverImage(path: coverPath, markSize: 26)
                        .frame(width: 60, height: 60)
                        .clipShape(Circle())
                }
                .shadow(color: Color(hex: 0x8A4DF5).opacity(0.7), radius: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text("WELCOME INSIDE")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(LinearGradient(colors: Brand.neon, startPoint: .leading, endPoint: .trailing))
                    Text(title)
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    Text(ownerLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer(minLength: 0)
            }
            if let closingNote {
                Label(closingNote, systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(hex: 0xFFB36B))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.08), in: Capsule())
            }
        }
    }
}
