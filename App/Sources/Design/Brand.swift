import SwiftUI

/// Grafity Gate のしるし：アプリのアイコンと同じ絵（G の形の扉のネオン。下の夕焼けから上の夜空へ、扉の中と足もとに光がもれる）。
/// 絵は `tools/icon/make_icon.py` で作り、`BrandMark` に入れてある。ホーム画面のアイコンと同じ角の丸め方で見せる。
struct GateMark: View {
    var size: CGFloat = 120
    var glowing = true

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            .background {
                if glowing {
                    // ネオンの色のやわらかい光を後ろに
                    RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                        .fill(LinearGradient(colors: Brand.neon, startPoint: .bottom, endPoint: .top))
                        .blur(radius: size * 0.16)
                        .opacity(0.45)
                        .offset(y: size * 0.06)
                }
            }
            .shadow(color: Color.black.opacity(0.18), radius: size * 0.05, y: size * 0.03)
            .accessibilityHidden(true)
    }
}

/// しるしの色（アイコンのネオンと同じ。下＝夕焼け、上＝夜空）
enum Brand {
    static let neon: [Color] = [Color(hex: 0xFF9A3C), Color(hex: 0xFF3D7F), Color(hex: 0x9B5CFF), Color(hex: 0x3FD0FF)]
    /// 白い地に置く文字用（いちばん明るい水色だと読みにくいので、最後を濃い青にする）
    static let neonOnLight: [Color] = [Color(hex: 0xFF8A2A), Color(hex: 0xF0306F), Color(hex: 0x8A4DF5), Color(hex: 0x2F7DFF)]
}

/// 上が半円の四角（扉の形）
struct ArchShapeView: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width / 2
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.midX, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 文字のしるし：「Grafity Gate」を、アイコンのネオンと同じ夕焼けから夜空への色で
struct Wordmark: View {
    var size: CGFloat = 22

    var body: some View {
        Text("Grafity Gate")
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .tracking(size * 0.02)
            .foregroundStyle(LinearGradient(colors: Brand.neonOnLight, startPoint: .leading, endPoint: .trailing))
            .accessibilityLabel("Grafity Gate")
    }
}
