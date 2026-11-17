import SwiftUI

// 扉の中の画面（2026-11-18 オーナー「入った感がなさすぎる」「ボードと同じではダメ」）。
// グラフィティボード（白い紙の掲示）に対して、扉の中は AR の扉の向こうと同じ夜空の世界にする。
// いちばん上に「ようこそ」と GATE の名前、その下に「扉の中でできること」を大きなタイルで並べる。

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

/// 散らばった星（場所は毎回同じ。ゆっくりまたたく）
struct StarDust: View {
    let count: Int

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                var seed: UInt64 = 0x9E3779B97F4A7C15
                func next() -> Double {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    return Double(seed >> 11) / Double(1 << 53)
                }
                for i in 0..<count {
                    let x = next() * size.width
                    let y = next() * size.height * 0.75
                    let r = 0.6 + next() * 1.6
                    let twinkle = 0.35 + 0.65 * (0.5 + 0.5 * sin(t * (0.6 + next() * 1.4) + Double(i)))
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(twinkle * 0.8)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 「ようこそ、扉の中へ」：光る輪の中に表紙、GATE の名前、扉の様子
struct InsideWelcome: View {
    let title: String
    let coverPath: String?
    let ownerLine: String
    let status: String
    var warning = false

    @State private var spin = false

    private let neon = AngularGradient(colors: Brand.neon + [Brand.neon.first ?? .orange], center: .center)

    var body: some View {
        VStack(spacing: 14) {
            Text("WELCOME INSIDE")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(2.4)
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .overlay(Capsule().strokeBorder(LinearGradient(colors: Brand.neon, startPoint: .leading, endPoint: .trailing),
                                                lineWidth: 1.2))
            ZStack {
                // にじむ光
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: 0x8A4DF5).opacity(0.55), .clear], center: .center,
                                         startRadius: 40, endRadius: 120))
                    .frame(width: 240, height: 240)
                // まわるネオンの輪
                Circle()
                    .strokeBorder(neon, lineWidth: 5)
                    .frame(width: 150, height: 150)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .shadow(color: Color(hex: 0xFF4F9A).opacity(0.7), radius: 12)
                GateCoverImage(path: coverPath, markSize: 48)
                    .frame(width: 132, height: 132)
                    .clipShape(Circle())
            }
            .frame(height: 200)
            .onAppear {
                withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { spin = true }
            }
            VStack(spacing: 6) {
                Text("扉の中へ、ようこそ")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.75))
                Text(title)
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .shadow(color: Color(hex: 0x8A4DF5).opacity(0.8), radius: 14)
                Text(ownerLine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
            Label(status, systemImage: warning ? "exclamationmark.circle.fill" : "lock.open.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(warning ? Color(hex: 0xFFB36B) : .white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.white.opacity(0.1), in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}

/// 扉の中でできること（押すと、その場所へ）
struct InsideActionTile: View {
    let symbol: String
    let title: String
    let detail: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: primary ? 22 : 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: primary ? 44 : 36, height: primary ? 44 : 36)
                    .background(primary ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(Theme.neonBand),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(primary ? .headline.weight(.heavy) : .subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if primary {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.top, 12)
                }
            }
            .padding(primary ? 16 : 12)
            .frame(maxWidth: .infinity, minHeight: primary ? 0 : 92, alignment: .topLeading)
            .background {
                if primary {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.neonBand)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white.opacity(0.08))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: primary ? 20 : 18, style: .continuous)
                .strokeBorder(.white.opacity(primary ? 0.35 : 0.14), lineWidth: 1))
            .shadow(color: primary ? Color(hex: 0xFF4F9A).opacity(0.4) : .clear, radius: 14, y: 6)
        }
        .buttonStyle(.plain)
    }
}
