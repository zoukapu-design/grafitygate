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
        let sky = [UIColor(red: 0.98, green: 0.86, blue: 0.62, alpha: 1).cgColor,   // 下：あたたかい光
                   UIColor(red: 0.42, green: 0.70, blue: 0.62, alpha: 1).cgColor,
                   UIColor(red: 0.09, green: 0.27, blue: 0.25, alpha: 1).cgColor] as CFArray   // 上：深い緑
        if let g = CGGradient(colorsSpace: space, colors: sky, locations: [0, 0.45, 1]) {
            // CGContext は下が y=0
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size), options: [])
        }
        let glow = [UIColor(white: 1, alpha: 0.75).cgColor, UIColor(white: 1, alpha: 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: glow, locations: [0, 1]) {
            let c = CGPoint(x: size / 2, y: Int(Double(size) * 0.35))
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) * 0.42,
                                   options: [])
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
