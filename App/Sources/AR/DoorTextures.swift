import CoreGraphics
import RealityKit
import UIKit

/// 扉まわりの絵（グラデーション・影・光だまり）をその場で描いて、RealityKit の質感にする。
@MainActor
enum DoorTextures {
    private static var cache: [String: TextureResource] = [:]

    /// 中心が濃く、ふちで消える丸い影や光（色は rgb、中心の濃さは alpha）
    static func radial(key: String, rgb: (CGFloat, CGFloat, CGFloat), alpha: CGFloat, size: Int = 256) -> TextureResource? {
        if let t = cache[key] { return t }
        guard let ctx = context(size: size) else { return nil }
        let colors = [UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha).cgColor,
                      UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: alpha * 0.45).cgColor,
                      UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                        locations: [0, 0.45, 1]) else { return nil }
        let c = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2,
                               options: [])
        return make(key: key, ctx: ctx)
    }

    /// 扉の向こうの空（上から下へのグラデーションに、中央の光をのせる）
    static func memorySky(key: String = "sky") -> TextureResource? {
        if let t = cache[key] { return t }
        let size = 512
        guard let ctx = context(size: size) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        // アイコンと同じ、下の夕焼けから上の夜空へ
        let sky = [UIColor(red: 1.00, green: 0.78, blue: 0.52, alpha: 1).cgColor,   // 下：夕焼けの光
                   UIColor(red: 0.96, green: 0.42, blue: 0.52, alpha: 1).cgColor,
                   UIColor(red: 0.45, green: 0.29, blue: 0.74, alpha: 1).cgColor,
                   UIColor(red: 0.07, green: 0.08, blue: 0.24, alpha: 1).cgColor] as CFArray   // 上：夜空
        if let g = CGGradient(colorsSpace: space, colors: sky, locations: [0, 0.3, 0.6, 1]) {
            // CGContext は下が y=0
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size), options: [])
        }
        // 上のほうに小さな星
        var generator = SeededRandom(seed: 7)
        for _ in 0..<70 {
            let x = CGFloat(generator.next()) * CGFloat(size)
            let y = CGFloat(size) * (0.55 + 0.45 * CGFloat(generator.next()))
            let r = 0.6 + 1.6 * CGFloat(generator.next())
            ctx.setFillColor(UIColor(white: 1, alpha: 0.35 + 0.55 * CGFloat(generator.next())).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        let glow = [UIColor(white: 1, alpha: 0.75).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: glow, locations: [0, 1]) {
            let c = CGPoint(x: size / 2, y: Int(Double(size) * 0.35))
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) * 0.42,
                                   options: [])
        }
        return make(key: key, ctx: ctx)
    }

    /// 扉のネオンの色（アイコンと同じ。t は 0＝足もと〜1＝てっぺん）
    static func neonColor(at t: Float) -> UIColor {
        let stops: [(Float, (CGFloat, CGFloat, CGFloat))] = [
            (0, (1.00, 0.60, 0.24)), (0.28, (1.00, 0.24, 0.50)), (0.62, (0.61, 0.36, 1.00)), (1, (0.25, 0.82, 1.00)),
        ]
        let x = min(max(t, 0), 1)
        for i in 0..<(stops.count - 1) where x <= stops[i + 1].0 {
            let (t0, c0) = stops[i], (t1, c1) = stops[i + 1]
            let f = CGFloat((x - t0) / max(t1 - t0, 0.0001))
            return UIColor(red: c0.0 + (c1.0 - c0.0) * f, green: c0.1 + (c1.1 - c0.1) * f, blue: c0.2 + (c1.2 - c0.2) * f,
                           alpha: 1)
        }
        return UIColor(red: 0.25, green: 0.82, blue: 1.0, alpha: 1)
    }

    /// 扉のネオンのまわりのにじむ光（扉の形の絵。幅 width・高さ height の m を、余白 margin こみで描く）
    static func neonGlow(shape: ArchShape, margin: Float) -> TextureResource? {
        let key = "neon-glow"
        if let t = cache[key] { return t }
        let w = shape.outerWidth + margin * 2
        let h = shape.outerHeight + margin * 2
        let px: Float = 280   // 1m あたりの点の数
        let width = Int(w * px), height = Int(h * px)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 扉の座標（足もとの中心が原点・m）→ 絵の点
        func point(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: CGFloat((p.x + w / 2) * px), y: CGFloat((p.y + margin) * px))
        }
        let path = CGMutablePath()
        let outline = shape.openingPath()
        path.move(to: point(outline[0].p))
        for item in outline.dropFirst() { path.addLine(to: point(item.p)) }
        let colors = [neonColor(at: 0).cgColor, neonColor(at: 0.28).cgColor, neonColor(at: 0.62).cgColor,
                      neonColor(at: 1).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                        locations: [0, 0.28, 0.62, 1]) else { return nil }
        let bottom = point(SIMD2(0, 0)), top = point(SIMD2(0, shape.innerHeight))
        // 太い線をうすく何度も重ねて、にじむ光にする（外ほどうすい）
        let passes = 9
        for i in 0..<passes {
            let f = CGFloat(i) / CGFloat(passes - 1)
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setLineWidth(CGFloat(px) * (0.02 + 0.30 * (1 - f)))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.setAlpha(0.06 + 0.14 * f)
            ctx.drawLinearGradient(gradient, start: bottom, end: top, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        return make(key: key, ctx: ctx)
    }

    /// 開いたときに広がる光の輪（ネオンの色）
    static func neonRing() -> TextureResource? {
        let key = "neon-ring"
        if let t = cache[key] { return t }
        let size = 512
        guard let ctx = context(size: size) else { return nil }
        let s = CGFloat(size)
        let colors = [neonColor(at: 0).cgColor, neonColor(at: 0.35).cgColor, neonColor(at: 0.7).cgColor,
                      neonColor(at: 1).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                        locations: [0, 0.35, 0.7, 1]) else { return nil }
        for i in 0..<6 {
            let f = CGFloat(i) / 5
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8))
            ctx.setLineWidth(s * (0.012 + 0.07 * (1 - f)))
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.setAlpha(0.12 + 0.25 * f)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: s), options: [])
            ctx.restoreGState()
        }
        return make(key: key, ctx: ctx)
    }

    /// 作品のまわりのやわらかい光（色ごとに 1 枚）
    static func halo(_ color: ArtworkColor) -> TextureResource? {
        radial(key: "halo-\(color.rawValue)", rgb: color.rgb, alpha: 0.85)
    }

    /// 波紋の輪（中は透明、ふちが光る）
    static func ring(_ color: ArtworkColor) -> TextureResource? {
        let key = "ring-\(color.rawValue)"
        if let t = cache[key] { return t }
        let size = 256
        guard let ctx = context(size: size) else { return nil }
        let (r, g, b) = color.rgb
        let colors = [UIColor(red: r, green: g, blue: b, alpha: 0).cgColor,
                      UIColor(red: r, green: g, blue: b, alpha: 0).cgColor,
                      UIColor(red: min(r + 0.1, 1), green: min(g + 0.1, 1), blue: min(b + 0.1, 1), alpha: 0.95).cgColor,
                      UIColor(red: r, green: g, blue: b, alpha: 0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                        locations: [0, 0.72, 0.86, 1]) else { return nil }
        let c = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2,
                               options: [])
        return make(key: key, ctx: ctx)
    }

    /// 花びら 1 枚（先が少し割れた、ふちの淡い形）
    static func petal(_ color: ArtworkColor) -> TextureResource? {
        let key = "petal-\(color.rawValue)"
        if let t = cache[key] { return t }
        let size = 128
        guard let ctx = context(size: size) else { return nil }
        let s = CGFloat(size)
        let path = CGMutablePath()
        // 下（根もと）から上（先）へ。CGContext は下が y=0
        path.move(to: CGPoint(x: s * 0.5, y: s * 0.04))
        path.addCurve(to: CGPoint(x: s * 0.42, y: s * 0.92), control1: CGPoint(x: s * 0.06, y: s * 0.30),
                      control2: CGPoint(x: s * 0.10, y: s * 0.86))
        path.addLine(to: CGPoint(x: s * 0.5, y: s * 0.82))
        path.addLine(to: CGPoint(x: s * 0.58, y: s * 0.92))
        path.addCurve(to: CGPoint(x: s * 0.5, y: s * 0.04), control1: CGPoint(x: s * 0.90, y: s * 0.86),
                      control2: CGPoint(x: s * 0.94, y: s * 0.30))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.clip()
        let (r, g, b) = color.rgb
        let colors = [UIColor(red: r * 0.92, green: g * 0.78, blue: b * 0.82, alpha: 1).cgColor,
                      UIColor(red: r, green: g, blue: b, alpha: 1).cgColor,
                      UIColor(red: min(r + 0.08, 1), green: min(g + 0.16, 1), blue: min(b + 0.14, 1), alpha: 0.92).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                     locations: [0, 0.35, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: s / 2, y: 0), end: CGPoint(x: s / 2, y: s), options: [])
        }
        return make(key: key, ctx: ctx)
    }

    /// 写真の質感（扉の向こうに浮かべる思い出の写真）
    /// 映像パネルの「▶」の印（白い丸に三角）
    static func playBadge() -> TextureResource? {
        let key = "play-badge"
        if let t = cache[key] { return t }
        let size = 128
        guard let ctx = context(size: size) else { return nil }
        let s = CGFloat(size)
        ctx.setFillColor(UIColor(white: 1, alpha: 0.88).cgColor)
        ctx.fillEllipse(in: CGRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88))
        ctx.setFillColor(UIColor(red: 0.13, green: 0.49, blue: 0.41, alpha: 1).cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: s * 0.40, y: s * 0.30))
        ctx.addLine(to: CGPoint(x: s * 0.72, y: s * 0.50))
        ctx.addLine(to: CGPoint(x: s * 0.40, y: s * 0.70))
        ctx.closePath()
        ctx.fillPath()
        return make(key: key, ctx: ctx)
    }

    static func photo(_ image: UIImage) -> TextureResource? {
        let small = image.downscaled(maxSide: 1024)
        guard let cg = small.cgImage else { return nil }
        return MainWatch.run("写真の質感を作る") {
            try? TextureResource.generate(from: cg, options: TextureResource.CreateOptions(semantic: .color))
        }
    }

    static func releaseAll() {
        cache.removeAll()
    }

    private static func context(size: Int) -> CGContext? {
        CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func make(key: String, ctx: CGContext) -> TextureResource? {
        guard let image = ctx.makeImage(),
              let texture = try? TextureResource.generate(from: image,
                                                          options: TextureResource.CreateOptions(semantic: .color))
        else { return nil }
        cache[key] = texture
        return texture
    }
}

/// 決まった並びの乱数（星の位置を毎回同じにする）
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    /// 0〜1
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}
