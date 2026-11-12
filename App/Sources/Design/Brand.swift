import SwiftUI

/// GRAFITYGATE のしるし：石のアーチの扉と、向こうの光（アプリのアイコンと同じ形）
struct GateMark: View {
    var size: CGFloat = 120
    var glowing = true

    var body: some View {
        ZStack {
            if glowing {
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: 0xFFD99A).opacity(0.55), .clear],
                                         center: .center, startRadius: 0, endRadius: size * 0.75))
                    .frame(width: size * 1.6, height: size * 1.6)
                    .offset(y: size * 0.08)
            }
            ArchShapeView()
                .fill(LinearGradient(colors: [Color(hex: 0xFAF7F0), Color(hex: 0xD8D2C4)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.72, height: size)
            ArchShapeView()
                .fill(LinearGradient(colors: [Color(hex: 0x2A7A6A), Color(hex: 0xFFE0A6)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    RadialGradient(colors: [Color.white.opacity(0.85), .clear], center: UnitPoint(x: 0.5, y: 0.62),
                                   startRadius: 0, endRadius: size * 0.35)
                        .clipShape(ArchShapeView())
                )
                .overlay(ArchShapeView().stroke(Color(hex: 0xFFE7B8), lineWidth: max(1, size * 0.012)))
                .frame(width: size * 0.5, height: size * 0.86)
                .offset(y: size * 0.07)
            RoundedRectangle(cornerRadius: size * 0.02)
                .fill(Color(hex: 0xE2DCCF))
                .frame(width: size * 0.82, height: size * 0.05)
                .offset(y: size * 0.5)
        }
        .frame(width: size, height: size * 1.1)
        .accessibilityHidden(true)
    }
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

/// 文字のしるし
struct Wordmark: View {
    var size: CGFloat = 22

    var body: some View {
        Text("GRAFITYGATE")
            .font(.system(size: size, weight: .semibold, design: .serif))
            .tracking(size * 0.18)
            .foregroundStyle(Theme.text)
            .accessibilityLabel("GRAFITYGATE")
    }
}
