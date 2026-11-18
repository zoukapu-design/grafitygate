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

    // MARK: 扉の向こうの回廊（2026-11-18 オーナー「写真が貼り付けてあるだけ」→ 中に入りたくなる奥行きのある世界）

    /// 回廊の横の壁：足もとに夕焼けの光、上は星の夜空（横長）
    static func innerWall() -> TextureResource? {
        let key = "inner-wall"
        if let t = cache[key] { return t }
        let w = 1024, h = 512
        guard let ctx = context(width: w, height: h) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let colors = [UIColor(red: 1.00, green: 0.62, blue: 0.42, alpha: 1).cgColor,
                      UIColor(red: 0.78, green: 0.28, blue: 0.52, alpha: 1).cgColor,
                      UIColor(red: 0.28, green: 0.17, blue: 0.52, alpha: 1).cgColor,
                      UIColor(red: 0.07, green: 0.08, blue: 0.24, alpha: 1).cgColor,
                      UIColor(red: 0.03, green: 0.04, blue: 0.13, alpha: 1).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.1, 0.32, 0.7, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        }
        stars(ctx, width: w, height: h, count: 170, from: 0.35, seed: 11)
        return make(key: key, ctx: ctx)
    }

    /// 回廊の天井：深い夜空に、たくさんの星と天の川
    static func innerCeiling() -> TextureResource? {
        let key = "inner-ceiling"
        if let t = cache[key] { return t }
        let size = 512
        guard let ctx = context(size: size) else { return nil }
        ctx.setFillColor(UIColor(red: 0.04, green: 0.05, blue: 0.15, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        // 天の川（うすい光の帯）
        var r = SeededRandom(seed: 23)
        for i in 0..<26 {
            let f = CGFloat(i) / 25
            let x = CGFloat(size) * (0.15 + 0.7 * f) + CGFloat(r.next() - 0.5) * 40
            let y = CGFloat(size) * (0.2 + 0.6 * f) + CGFloat(r.next() - 0.5) * 40
            let rad = 40 + 50 * CGFloat(r.next())
            ctx.setFillColor(UIColor(red: 0.62, green: 0.48, blue: 1.0, alpha: 0.05).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
        }
        stars(ctx, width: size, height: size, count: 220, from: 0, seed: 29)
        return make(key: key, ctx: ctx)
    }

    /// 回廊の床：暗い夜の色に細い格子、まん中に奥へ続く光の道と、光る踏み石
    static func innerFloor() -> TextureResource? {
        let key = "inner-floor"
        if let t = cache[key] { return t }
        let w = 512, h = 1024
        guard let ctx = context(width: w, height: h) else { return nil }
        let W = CGFloat(w), H = CGFloat(h)
        ctx.setFillColor(UIColor(red: 0.08, green: 0.06, blue: 0.18, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // 細い格子
        ctx.setStrokeColor(UIColor(red: 0.62, green: 0.40, blue: 1.0, alpha: 0.18).cgColor)
        ctx.setLineWidth(2)
        for i in 1..<8 {
            let x = W * CGFloat(i) / 8
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H))
        }
        for i in 1..<16 {
            let y = H * CGFloat(i) / 16
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y))
        }
        ctx.strokePath()
        // まん中の光の道（中は夕焼けの色、ふちは夜空の紫）
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let path = [UIColor(red: 0.62, green: 0.36, blue: 1.0, alpha: 0).cgColor,
                    UIColor(red: 0.85, green: 0.35, blue: 0.75, alpha: 0.55).cgColor,
                    UIColor(red: 1.0, green: 0.72, blue: 0.48, alpha: 0.95).cgColor,
                    UIColor(red: 0.85, green: 0.35, blue: 0.75, alpha: 0.55).cgColor,
                    UIColor(red: 0.62, green: 0.36, blue: 1.0, alpha: 0).cgColor] as CFArray
        if let g = CGGradient(colorsSpace: space, colors: path, locations: [0, 0.3, 0.5, 0.7, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: W * 0.36, y: 0), end: CGPoint(x: W * 0.64, y: 0), options: [])
        }
        // 光る踏み石
        for i in 0..<9 {
            let y = H * (CGFloat(i) + 0.5) / 9
            let r: CGFloat = 16
            ctx.setFillColor(UIColor(white: 1, alpha: 0.9).cgColor)
            ctx.fillEllipse(in: CGRect(x: W / 2 - r, y: y - r, width: r * 2, height: r * 2))
        }
        return make(key: key, ctx: ctx)
    }

    /// 星をちりばめる（from より上だけ。0＝下〜1＝上）
    private static func stars(_ ctx: CGContext, width: Int, height: Int, count: Int, from: CGFloat, seed: UInt64) {
        var r = SeededRandom(seed: seed)
        for _ in 0..<count {
            let x = CGFloat(r.next()) * CGFloat(width)
            let y = CGFloat(height) * (from + (1 - from) * CGFloat(r.next()))
            let rad = 0.7 + 1.9 * CGFloat(r.next())
            ctx.setFillColor(UIColor(white: 1, alpha: 0.3 + 0.65 * CGFloat(r.next())).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2))
        }
    }

    // MARK: 扉の見た目（DoorDesign）の飾り

    /// 開口部のふちに沿ってにじむ光（どの形・色でも）。key は見た目ごとに分ける
    static func neonGlow(shape: DoorShape, colors: [UIColor], margin: Float, key: String) -> TextureResource? {
        if let t = cache[key] { return t }
        let w = shape.outerWidth + margin * 2
        let h = shape.outerHeight + margin * 2
        let px: Float = 240
        let width = Int(w * px), height = Int(h * px)
        guard let ctx = context(width: width, height: height) else { return nil }
        func point(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: CGFloat((p.x + w / 2) * px), y: CGFloat((p.y + margin) * px))
        }
        let path = CGMutablePath()
        let outline = shape.openingPath()
        path.move(to: point(outline[0].p))
        for item in outline.dropFirst() { path.addLine(to: point(item.p)) }
        if shape.isClosed { path.closeSubpath() }
        let list = colors.isEmpty ? [UIColor.white] : colors
        let stops = list.count == 1 ? [list[0], list[0]] : list
        let locations = (0..<stops.count).map { CGFloat($0) / CGFloat(stops.count - 1) }
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: stops.map(\.cgColor) as CFArray, locations: locations) else { return nil }
        let bottom = point(SIMD2(0, 0)), top = point(SIMD2(0, shape.innerHeight))
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

    /// 魔法陣の輪：二重の円・目盛り・光る文字のような印
    static func runeRing(key: String, rgb: (CGFloat, CGFloat, CGFloat), glyphs: Int) -> TextureResource? {
        if let t = cache[key] { return t }
        let size = 512
        guard let ctx = context(size: size) else { return nil }
        let c = CGPoint(x: 256, y: 256)
        let color = UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        ctx.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(5)
        ctx.strokeEllipse(in: CGRect(x: 14, y: 14, width: 484, height: 484))
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(x: 52, y: 52, width: 408, height: 408))
        // 目盛り
        ctx.setLineWidth(2)
        for i in 0..<72 {
            let a = CGFloat(i) / 72 * 2 * .pi
            let r0: CGFloat = 212, r1: CGFloat = i % 6 == 0 ? 236 : 226
            ctx.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
        }
        ctx.strokePath()
        // 文字のような印（短い線と小さな円を組み合わせる）
        var r = SeededRandom(seed: UInt64(glyphs) * 31 + 5)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        for i in 0..<glyphs {
            let a = CGFloat(i) / CGFloat(glyphs) * 2 * .pi
            let p = CGPoint(x: c.x + cos(a) * 240, y: c.y + sin(a) * 240)
            ctx.saveGState()
            ctx.translateBy(x: p.x, y: p.y)
            ctx.rotate(by: a + .pi / 2)
            for _ in 0..<3 {
                let x0 = CGFloat(r.next() - 0.5) * 14, y0 = CGFloat(r.next() - 0.5) * 12
                if r.next() < 0.3 {
                    ctx.strokeEllipse(in: CGRect(x: x0 - 3, y: y0 - 3, width: 6, height: 6))
                } else {
                    ctx.move(to: CGPoint(x: x0, y: y0))
                    ctx.addLine(to: CGPoint(x: x0 + CGFloat(r.next() - 0.5) * 14, y: y0 + CGFloat(r.next() - 0.5) * 14))
                    ctx.strokePath()
                }
            }
            ctx.restoreGState()
        }
        // 内側の星形（2 つの三角）
        ctx.setLineWidth(2.5)
        ctx.setStrokeColor(color.withAlphaComponent(0.55).cgColor)
        for k in 0..<2 {
            let off = CGFloat(k) * .pi / 3
            ctx.move(to: CGPoint(x: c.x + cos(off) * 200, y: c.y + sin(off) * 200))
            for j in 1...3 {
                let a = off + CGFloat(j) * 2 * .pi / 3
                ctx.addLine(to: CGPoint(x: c.x + cos(a) * 200, y: c.y + sin(a) * 200))
            }
            ctx.strokePath()
        }
        // まん中は抜く（扉の向こうが見えるように）
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: 92, y: 92, width: 328, height: 328))
        return make(key: key, ctx: ctx)
    }

    /// 浮かぶ小さなハート
    static func heartSprite() -> TextureResource? {
        let key = "heart-sprite"
        if let t = cache[key] { return t }
        let size = 128
        guard let ctx = context(size: size) else { return nil }
        let path = CGMutablePath()
        let count = 60
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count) * 2 * .pi
            let x = 16 * pow(sin(t), 3)
            let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
            let p = CGPoint(x: 64 + x * 3.4, y: 70 + y * 3.4)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.addPath(path)
        ctx.setFillColor(UIColor(red: 1.0, green: 0.42, blue: 0.62, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.setFillColor(UIColor(white: 1, alpha: 0.7).cgColor)
        ctx.fillEllipse(in: CGRect(x: 36, y: 74, width: 16, height: 12))
        return make(key: key, ctx: ctx)
    }

    /// ペロペロキャンディのうずまき
    static func swirl(key: String, rgb: (CGFloat, CGFloat, CGFloat)) -> TextureResource? {
        if let t = cache[key] { return t }
        let size = 256
        guard let ctx = context(size: size) else { return nil }
        let c = CGPoint(x: 128, y: 128)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: 4, y: 4, width: 248, height: 248))
        ctx.setStrokeColor(UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).cgColor)
        ctx.setLineWidth(18)
        ctx.setLineCap(.round)
        let turns: CGFloat = 3.2
        let steps = 160
        for i in 0...steps {
            let f = CGFloat(i) / CGFloat(steps)
            let a = f * turns * 2 * .pi
            let r = 8 + f * 108
            let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
        }
        ctx.strokePath()
        ctx.setStrokeColor(UIColor(white: 1, alpha: 0.9).cgColor)
        ctx.setLineWidth(5)
        ctx.strokeEllipse(in: CGRect(x: 6, y: 6, width: 244, height: 244))
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

    /// AR の飾りのまわりのやわらかい光（色ごとに 1 枚）
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
        context(width: size, height: size)
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
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
