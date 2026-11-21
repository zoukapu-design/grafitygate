import RealityKit
import UIKit

/// GATE のまわりのエフェクト（2026-11-21 オーナー「ゲートのエフェクト出ないよ。ここの AR の機能はかなり大事」）。
/// 前は、見た目がネオン（いちばん多い）の GATE には、まわりに動くものが何もなかった。開いたときの光の粒も 1〜2cm で、
/// 物の GATE（大きさ 0.35 ほど）では扉の中の粒が数 mm になり、ほとんど見えなかった。
///
/// どの見た目の GATE にも、見える大きさの光の粒と星を舞わせる：
/// ・現れたとき：ふちに星が順に灯り、足もとから光の粒が立ちのぼる
/// ・閉じているあいだ：ふちをめぐってまたたく星と、足もとから立ちのぼる光の粒
/// ・開いたとき：開口部から星がはじけ飛び、そのあとは中から光の粒がこちらへあふれ続ける
/// 粒は台（base）に付け、GATE の大きさで小さくしすぎない（`visual` の下限）。白い壁の部屋でも見えるよう、
/// 色の濃い光の輪に白い芯の絵にする（白一色の粒は、白い壁の前で消えてしまう）。
/// 薄くするときは不透明度ではなく大きさで消す（iOS 17 では不透明度を変えるたびに質感を作り直すので重い）。
@MainActor
final class GateAura {
    let root = Entity()

    private enum Kind {
        /// ふちをめぐる星
        case orbit
        /// 足もとから立ちのぼる光の粒
        case rise
        /// 開いた GATE の中から、こちらへあふれる光の粒
        case spill
        /// 開いた瞬間にはじけ飛ぶ星
        case burst
    }

    private struct Sprite {
        let entity: ModelEntity
        let kind: Kind
        /// 0〜1 の進み具合（めぐる位置・のぼる高さ・あふれる距離）
        var u: Float
        let speed: Float
        let phase: Float
        let size: Float
        /// 立ちのぼる・あふれる粒の、横と奥の位置（GATE の大きさ 1 のときの m）
        var lane: SIMD3<Float> = .zero
        /// はじけ飛ぶ星の向き
        var velocity: SIMD3<Float> = .zero
        var position: SIMD3<Float> = .zero
        /// 現れるまでの待ち（秒）
        var delay: Float = 0
    }

    private let shape: DoorShape
    private let colors: [UIColor]
    private var sprites: [Sprite] = []
    /// ふちに沿った点（GATE の大きさ 1 のときの m。外側へ少しずらした所）と、その長さの割合
    private var outline: [SIMD2<Float>] = []
    private var outlineT: [Float] = []
    private var size: Float = 1
    private var isOpen = false
    private var shownAt: Float?
    private var openedAt: Float?
    private var lastTime: Float = 0
    private let low = Perf.isLowMemoryDevice

    /// 粒の見た目の大きさの倍率（小さな GATE でも、粒は小さくしすぎない）
    private var visual: Float { max(size, 0.7) }

    init(design: DoorDesign, shape: DoorShape) {
        self.shape = shape
        // 光の色：見た目のネオンの色と、金色。白に近い色は濃くする（白い壁でも見えるように）
        var list = design.palette.map(Self.deepened)
        list.append(UIColor(red: 1.0, green: 0.78, blue: 0.32, alpha: 1))
        colors = list
        buildOutline()
        build()
        root.isEnabled = false
    }

    // MARK: 組み立て

    private func buildOutline() {
        // 開口部のふちより、枠の外側へ少し出した線（星は枠のまわりをめぐる）
        let path = shape.finePath(maxStep: 0.05)
        let out = shape.frameWidth + 0.05
        outline = path.map { $0.p - $0.n * out }
        var lengths: [Float] = [0]
        for i in 1..<max(outline.count, 1) {
            lengths.append(lengths[i - 1] + simd_distance(outline[i - 1], outline[i]))
        }
        let total = max(lengths.last ?? 1, 0.001)
        outlineT = lengths.map { $0 / total }
    }

    private func build() {
        let star = MeshResource.generatePlane(width: 1, height: 1)
        func material(_ kind: AuraSprites.Kind, _ i: Int) -> UnlitMaterial? {
            AuraSprites.material(kind, color: colors[i % colors.count])
        }
        let orbitCount = low ? 10 : 14
        let riseCount = low ? 12 : 18
        let spillCount = low ? 14 : 22
        let burstCount = low ? 22 : 32
        for i in 0..<orbitCount {
            guard let m = material(.star, i) else { continue }
            let e = ModelEntity(mesh: star, materials: [m])
            sprites.append(Sprite(entity: e, kind: .orbit, u: Float(i) / Float(orbitCount), speed: Float.random(in: 0.035...0.06),
                                  phase: Float.random(in: 0...6.28), size: Float.random(in: 0.065...0.095),
                                  delay: 0.25 + 0.06 * Float(i)))
        }
        let halfW = shape.outerWidth / 2 + 0.25
        for i in 0..<riseCount {
            guard let m = material(.glow, i + 1) else { continue }
            let e = ModelEntity(mesh: star, materials: [m])
            sprites.append(Sprite(entity: e, kind: .rise, u: Float.random(in: 0...1), speed: Float.random(in: 0.12...0.24),
                                  phase: Float.random(in: 0...6.28), size: Float.random(in: 0.04...0.06),
                                  lane: SIMD3(Float.random(in: -halfW...halfW), 0, Float.random(in: 0.08...0.55)),
                                  delay: Float.random(in: 0...0.8)))
        }
        for i in 0..<spillCount {
            guard let m = material(i % 3 == 0 ? .star : .glow, i + 2) else { continue }
            let e = ModelEntity(mesh: star, materials: [m])
            sprites.append(Sprite(entity: e, kind: .spill, u: Float.random(in: 0...1), speed: Float.random(in: 0.18...0.34),
                                  phase: Float.random(in: 0...6.28), size: Float.random(in: 0.045...0.07),
                                  lane: randomInOpening()))
        }
        for i in 0..<burstCount {
            guard let m = material(.star, i + 3) else { continue }
            let e = ModelEntity(mesh: star, materials: [m])
            // 開口部のまん中から、まわりとこちらへ
            let a = Float(i) / Float(burstCount) * 2 * .pi + Float.random(in: -0.2...0.2)
            let spread = Float.random(in: 0.7...1.5)
            let v = SIMD3<Float>(cos(a) * spread, sin(a) * spread * 0.9 + 0.25, Float.random(in: 0.5...1.3))
            sprites.append(Sprite(entity: e, kind: .burst, u: 0, speed: 1, phase: Float.random(in: 0...6.28),
                                  size: Float.random(in: 0.08...0.12), velocity: v))
        }
        for s in sprites {
            s.entity.scale = .zero
            root.addChild(s.entity)
        }
        Trace.log("GATE のエフェクト：粒 \(sprites.count) 個（色 \(colors.count)）")
    }

    /// 開口部の中のどこか（GATE の大きさ 1 のときの m。z は奥）
    private func randomInOpening() -> SIMD3<Float> {
        for _ in 0..<12 {
            let q = SIMD2<Float>(Float.random(in: -shape.openingWidth / 2...shape.openingWidth / 2),
                                 Float.random(in: shape.lift + 0.1...shape.innerHeight - 0.05))
            if shape.contains(q) { return SIMD3(q.x, q.y, 0) }
        }
        return SIMD3(0, shape.center.y, 0)
    }

    // MARK: 動き

    func setSize(_ value: Float) {
        size = value
    }

    /// 現れる（ふちに星が順に灯り、足もとから光の粒が立ちのぼる）
    func appear(at time: Float) {
        root.isEnabled = true
        shownAt = time
    }

    /// 開く（星がはじけ飛び、そのあとは中から光の粒があふれ続ける）
    func open(at time: Float) {
        guard !isOpen else { return }
        isOpen = true
        openedAt = time
        root.isEnabled = true
        if shownAt == nil { shownAt = time }
        Trace.log("GATE のエフェクト：開いた光")
    }

    /// 毎コマ。camera は台（base）の座標でのカメラの位置
    func tick(time: Float, camera: SIMD3<Float>) {
        guard root.isEnabled, let shownAt else { return }
        let dt = min(max(time - lastTime, 0), 0.05)
        lastTime = time
        let since = time - shownAt
        let s = size
        let vis = visual
        let top = shape.outerHeight + 0.35
        let front = shape.depth / 2 + 0.06
        for i in sprites.indices {
            var p = sprites[i]
            var scale: Float = 0
            var pos = p.position
            switch p.kind {
            case .orbit:
                p.u = (p.u + p.speed * dt * (isOpen ? 1.6 : 1)).truncatingRemainder(dividingBy: 1)
                let q = outlinePoint(p.u)
                pos = SIMD3(q.x * s, q.y * s, front * s)
                // ふちの端（地面の近く）では小さく（アーチは下で切れているので、急に消えないように）
                let ends = shape.isClosed ? 1 : min(1, min(p.u, 1 - p.u) * 8)
                let twinkle = 0.55 + 0.45 * abs(sin(time * 2.6 + p.phase))
                scale = p.size * twinkle * ends * (isOpen ? 1.25 : 1) * grow(since - p.delay)
            case .rise:
                p.u += p.speed * dt / max(top, 0.5)
                if p.u > 1 {
                    p.u -= 1
                    let halfW = shape.outerWidth / 2 + 0.25
                    p.lane = SIMD3(Float.random(in: -halfW...halfW), 0, Float.random(in: 0.08...0.55))
                }
                let sway = sin(time * 0.9 + p.phase) * 0.05
                pos = SIMD3((p.lane.x + sway) * s, p.u * top * s, p.lane.z * s)
                scale = p.size * sin(.pi * p.u) * grow(since - p.delay)
            case .spill:
                guard isOpen, let openedAt else { break }
                let started = time - openedAt - 0.5
                guard started > 0 else { break }
                p.u += p.speed * dt
                if p.u > 1 {
                    p.u -= 1
                    p.lane = randomInOpening()
                }
                // 開口部の少し奥から、こちらへ。少しずつ外へ広がって、ゆっくり上へ
                let z = (-0.25 + 1.35 * p.u) * s
                let widen = 1 + 0.6 * p.u
                pos = SIMD3(p.lane.x * widen * s + sin(time + p.phase) * 0.03 * s,
                            (p.lane.y + 0.18 * p.u) * s, z)
                scale = p.size * sin(.pi * p.u) * grow(started * 1.5)
            case .burst:
                guard let openedAt else { break }
                let t = time - openedAt
                guard t < 1.6 else { break }
                // 速く飛び出して、ゆるやかに止まる
                let k = 1 - pow(1 - min(t / 1.6, 1), 3)
                let center = SIMD3<Float>(0, shape.center.y, front)
                pos = (center + p.velocity * 0.9 * k) * s
                scale = p.size * (1 - k * k) * min(1, t * 8)
            }
            p.position = pos
            sprites[i] = p
            guard scale > 0.002 else {
                if p.entity.scale.x != 0 { p.entity.scale = .zero }
                continue
            }
            // こちらを向ける（板の絵なので）
            let d = camera - pos
            let yaw = atan2(d.x, d.z)
            let pitch = atan2(d.y, max(simd_length(SIMD2<Float>(d.x, d.z)), 0.001))
            p.entity.transform = Transform(scale: .one * (scale * vis),
                                           rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -pitch, axis: [1, 0, 0]),
                                           translation: pos)
        }
    }

    /// 0 → 1 にふくらむ（現れるとき）
    private func grow(_ t: Float) -> Float {
        guard t > 0 else { return 0 }
        let x = min(t / 0.5, 1)
        return 1 - pow(1 - x, 3)
    }

    private func outlinePoint(_ u: Float) -> SIMD2<Float> {
        guard outline.count > 1 else { return SIMD2(0, shape.center.y) }
        var lo = 0, hi = outlineT.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if outlineT[mid] <= u { lo = mid } else { hi = mid }
        }
        let span = max(outlineT[hi] - outlineT[lo], 0.0001)
        let f = (u - outlineT[lo]) / span
        return outline[lo] + (outline[hi] - outline[lo]) * f
    }

    /// 白に近い色は少し濃くする（白い壁の前でも見えるように）
    private static func deepened(_ color: UIColor) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return color }
        return UIColor(hue: h, saturation: max(s, 0.55), brightness: max(b, 0.85), alpha: 1)
    }
}

/// エフェクトの粒の絵：色の濃い光の輪に、白い芯（白い壁でも、暗い所でも見える）
@MainActor
enum AuraSprites {
    enum Kind: String {
        /// 4 つの光の筋の星
        case star
        /// 丸い光
        case glow
    }

    private static var materials: [String: UnlitMaterial] = [:]

    static func material(_ kind: Kind, color: UIColor) -> UnlitMaterial? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let key = "\(kind.rawValue)-\(Int(r * 255))-\(Int(g * 255))-\(Int(b * 255))"
        if let m = materials[key] { return m }
        guard let texture = texture(kind, color: color) else { return nil }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(texture))
        m.blending = .transparent(opacity: .init(floatLiteral: 1))
        materials[key] = m
        return m
    }

    private static func texture(_ kind: Kind, color: UIColor) -> TextureResource? {
        let n = 128
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let W = CGFloat(n)
        let c = CGPoint(x: W / 2, y: W / 2)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        // 色の光の輪（ふちで消える）
        if let g = CGGradient(colorsSpace: space, colors: [color.withAlphaComponent(0.95).cgColor,
                                                           color.withAlphaComponent(0.55).cgColor,
                                                           color.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 0.35, 1]) {
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c,
                                   endRadius: kind == .star ? W * 0.36 : W * 0.5, options: [])
        }
        switch kind {
        case .star:
            // 4 つの光の筋（色）と、白い芯
            let r = W * 0.49
            let p = CGMutablePath()
            p.move(to: CGPoint(x: c.x, y: c.y - r))
            p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
            p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
            ctx.addPath(p)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
            let inner = CGMutablePath()
            let ri = W * 0.3
            inner.move(to: CGPoint(x: c.x, y: c.y - ri))
            inner.addQuadCurve(to: CGPoint(x: c.x + ri, y: c.y), control: c)
            inner.addQuadCurve(to: CGPoint(x: c.x, y: c.y + ri), control: c)
            inner.addQuadCurve(to: CGPoint(x: c.x - ri, y: c.y), control: c)
            inner.addQuadCurve(to: CGPoint(x: c.x, y: c.y - ri), control: c)
            ctx.addPath(inner)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillPath()
        case .glow:
            // 白い芯
            if let g = CGGradient(colorsSpace: space, colors: [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: W * 0.2, options: [])
            }
        }
        guard let image = ctx.makeImage() else { return nil }
        return try? TextureResource.generate(from: image, options: TextureResource.CreateOptions(semantic: .color))
    }
}
