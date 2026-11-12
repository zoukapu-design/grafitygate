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

    /// 写真の質感（扉の向こうに浮かべる思い出の写真）
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
