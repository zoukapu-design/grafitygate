import RealityKit
import SwiftUI
import UIKit

// 扉の見た目（2026-11-18 オーナー「AR で見て面白い見た目のゲートをたくさん」「シンプル・かわいいものも」）。
// 作る人が選び、サーバーの gf_gates.door_style に残す（0028。入った人にも同じ見た目で出る）。
// 開口部の形（DoorShape）・枠の質感・ネオンの色・まわりの飾り（DoorDecor）が見た目ごとに違う。
// 扉の向こうの世界・見えない壁・くぐる仕組みは、どの見た目でも同じ。
// 足すときは：ここの case と情報・DoorDecor の飾り・サーバーの check と gf_set_door_style の一覧を一緒に直す。

enum DoorDesign: String, CaseIterable, Identifiable {
    // ワクワク
    case neon, magic, torii, timering, crystal, wooden, galaxy
    // かわいい
    case heart, cloud, flower, candy, cat
    // シンプル
    case white, black, round

    var id: String { rawValue }

    init(raw: String?) {
        self = DoorDesign(rawValue: raw ?? "") ?? .neon
    }

    enum Group: String, CaseIterable, Identifiable {
        case exciting = "ワクワク"
        case cute = "かわいい"
        case simple = "シンプル"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .neon, .magic, .torii, .timering, .crystal, .wooden, .galaxy: return .exciting
        case .heart, .cloud, .flower, .candy, .cat: return .cute
        case .white, .black, .round: return .simple
        }
    }

    var label: String {
        switch self {
        case .neon: return "ネオン"
        case .magic: return "魔法陣"
        case .torii: return "鳥居"
        case .timering: return "時空の輪"
        case .crystal: return "クリスタル"
        case .wooden: return "木の扉"
        case .galaxy: return "銀河"
        case .heart: return "ハート"
        case .cloud: return "くも"
        case .flower: return "花のアーチ"
        case .candy: return "キャンディ"
        case .cat: return "ねこ"
        case .white: return "しろ"
        case .black: return "くろ"
        case .round: return "まる"
        }
    }

    /// ひとことの説明（選ぶ画面に出す）
    var summary: String {
        switch self {
        case .neon: return "夕焼けから夜空へ光るネオンのアーチ"
        case .magic: return "光の文字の輪がまわる、円い魔法の扉"
        case .torii: return "朱い鳥居。くぐると向こうの世界へ"
        case .timering: return "開くと印が順に灯る、金属の大きな輪"
        case .crystal: return "氷の結晶に囲まれた、すきとおる扉"
        case .wooden: return "本物の扉のように、木の戸が開く"
        case .galaxy: return "星と惑星が、まわりをめぐる円い扉"
        case .heart: return "小さなハートが浮かぶ、ピンクのハート"
        case .cloud: return "ふわふわの雲と、うしろに虹"
        case .flower: return "花でいっぱいのアーチ"
        case .candy: return "しましまの飴と、ペロペロキャンディ"
        case .cat: return "ねこ耳とひげとしっぽのアーチ"
        case .white: return "白くて細い、静かなアーチ"
        case .black: return "黒い四角に、金の光"
        case .round: return "白い円がひとつ、浮かんでいる"
        }
    }

    /// 開口部の形と寸法（扉の大きさ 1 のとき）
    var shape: DoorShape {
        switch self {
        case .neon:
            return DoorShape()
        case .magic:
            return DoorShape(kind: .circle, openingWidth: 1.5, openingHeight: 1.5, lift: 0.3, frameWidth: 0.05, depth: 0.05)
        case .torii:
            return DoorShape(kind: .roundedRect, openingWidth: 1.1, openingHeight: 2.0, corner: 0.02, frameWidth: 0.025, depth: 0.04)
        case .timering:
            return DoorShape(kind: .circle, openingWidth: 1.7, openingHeight: 1.7, lift: 0.16, frameWidth: 0.2, depth: 0.22)
        case .crystal:
            return DoorShape(openingWidth: 0.9, openingHeight: 1.9, frameWidth: 0.08, depth: 0.1)
        case .wooden:
            return DoorShape(openingWidth: 0.95, openingHeight: 2.05, frameWidth: 0.14, depth: 0.18)
        case .galaxy:
            return DoorShape(kind: .circle, openingWidth: 1.6, openingHeight: 1.6, lift: 0.25, frameWidth: 0.06, depth: 0.06)
        case .heart:
            return DoorShape(kind: .heart, openingWidth: 1.35, openingHeight: 1.22, lift: 0.32, frameWidth: 0.07, depth: 0.08,
                             arcSegments: 40)
        case .cloud:
            return DoorShape(openingWidth: 0.9, openingHeight: 1.85, frameWidth: 0.06, depth: 0.08)
        case .flower:
            return DoorShape(openingWidth: 0.9, openingHeight: 1.9, frameWidth: 0.05, depth: 0.06)
        case .candy:
            return DoorShape(openingWidth: 0.9, openingHeight: 1.85, frameWidth: 0.12, depth: 0.12)
        case .cat:
            return DoorShape(openingWidth: 0.85, openingHeight: 1.8, frameWidth: 0.12, depth: 0.14)
        case .white:
            return DoorShape(openingWidth: 0.85, openingHeight: 1.85, frameWidth: 0.05, depth: 0.06)
        case .black:
            return DoorShape(kind: .roundedRect, openingWidth: 0.9, openingHeight: 2.0, corner: 0.04, frameWidth: 0.05, depth: 0.06)
        case .round:
            return DoorShape(kind: .circle, openingWidth: 1.4, openingHeight: 1.4, lift: 0.32, frameWidth: 0.05, depth: 0.06)
        }
    }

    /// ネオン（開口部のふちの光）の色。下 → 上の順
    var palette: [UIColor] {
        func c(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch self {
        case .neon: return [c(0xFF993D), c(0xFF3D7F), c(0x9B5CFF), c(0x3FD0FF)]
        case .magic: return [c(0x5EF2FF), c(0x8A7BFF), c(0xC86BFF)]
        case .torii: return [c(0xFFB347), c(0xFF6A3D)]
        case .timering: return [c(0x3FD0FF), c(0x5B8CFF), c(0xB28CFF)]
        case .crystal: return [c(0xB8F3FF), c(0x7FD7FF), c(0xE0D4FF)]
        case .wooden: return [c(0xFFD27A), c(0xFFB04A)]
        case .galaxy: return [c(0xFF5FD2), c(0x9B5CFF), c(0x3FD0FF)]
        case .heart: return [c(0xFF4F9A), c(0xFF8FB1), c(0xFFC0D9)]
        case .cloud: return [c(0xFFC4E1), c(0xA8E6FF), c(0xFFF1A8)]
        case .flower: return [c(0xFF9CC7), c(0xFFD1E8)]
        case .candy: return [c(0xFF6FA8), c(0xFFFFFF), c(0xFF6FA8)]
        case .cat: return [c(0xFFB36B), c(0xFF8FB1)]
        case .white: return [c(0xFFFFFF), c(0xE8E4FF)]
        case .black: return [c(0xFFD27A), c(0xFFE9B0)]
        case .round: return [c(0xFFFFFF), c(0xCFE8FF)]
        }
    }

    /// 高さの割合（0＝下・1＝上）でのネオンの色
    func neonColor(at t: Float) -> UIColor {
        let colors = palette
        guard colors.count > 1 else { return colors.first ?? .white }
        let x = min(max(t, 0), 1) * Float(colors.count - 1)
        let i = min(Int(x), colors.count - 2)
        let f = CGFloat(x - Float(i))
        var r0: CGFloat = 0, g0: CGFloat = 0, b0: CGFloat = 0, a0: CGFloat = 0
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        colors[i].getRed(&r0, green: &g0, blue: &b0, alpha: &a0)
        colors[i + 1].getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        return UIColor(red: r0 + (r1 - r0) * f, green: g0 + (g1 - g0) * f, blue: b0 + (b1 - b0) * f, alpha: 1)
    }

    /// 枠の質感
    func frameMaterial() -> RealityKit.Material {
        switch self {
        case .neon: return DoorDecor.pbr(UIColor(red: 0.15, green: 0.14, blue: 0.21, alpha: 1), rough: 0.34, metal: 0.08, coat: 0.65)
        case .magic: return DoorDecor.pbr(UIColor(red: 0.95, green: 0.76, blue: 0.36, alpha: 1), rough: 0.25, metal: 0.9)
        case .torii: return DoorDecor.pbr(UIColor(red: 0.86, green: 0.2, blue: 0.12, alpha: 1), rough: 0.35, coat: 0.5)
        case .timering: return DoorDecor.pbr(UIColor(red: 0.34, green: 0.36, blue: 0.42, alpha: 1), rough: 0.35, metal: 0.8)
        case .crystal: return DoorDecor.pbr(UIColor(red: 0.72, green: 0.9, blue: 1.0, alpha: 1), rough: 0.05, coat: 1, opacity: 0.7)
        case .wooden: return DoorDecor.pbr(UIColor(red: 0.36, green: 0.22, blue: 0.12, alpha: 1), rough: 0.72)
        case .galaxy: return DoorDecor.pbr(UIColor(red: 0.06, green: 0.05, blue: 0.1, alpha: 1), rough: 0.15, metal: 0.6, coat: 1)
        case .heart: return DoorDecor.pbr(UIColor(red: 1.0, green: 0.55, blue: 0.72, alpha: 1), rough: 0.3, coat: 0.8)
        case .cloud: return DoorDecor.pbr(UIColor(white: 0.97, alpha: 1), rough: 0.9)
        case .flower: return DoorDecor.pbr(UIColor(red: 0.3, green: 0.6, blue: 0.35, alpha: 1), rough: 0.7)
        case .candy: return DoorDecor.pbr(UIColor(red: 0.95, green: 0.25, blue: 0.4, alpha: 1), rough: 0.2, coat: 1)
        case .cat: return DoorDecor.pbr(UIColor(red: 1.0, green: 0.78, blue: 0.5, alpha: 1), rough: 0.6, coat: 0.3)
        case .white, .round: return DoorDecor.pbr(UIColor(white: 0.95, alpha: 1), rough: 0.55)
        case .black: return DoorDecor.pbr(UIColor(white: 0.06, alpha: 1), rough: 0.12, metal: 0.3, coat: 1)
        }
    }

    /// 開く前のガラスの色
    var glassTint: UIColor {
        switch self {
        case .neon: return UIColor(red: 0.30, green: 0.24, blue: 0.56, alpha: 1)
        case .wooden: return UIColor(red: 0.30, green: 0.2, blue: 0.12, alpha: 1)
        default: return neonColor(at: 0.5)
        }
    }

    /// 足もとの踏み石を置くか（地面に立つアーチ・四角だけ）
    var hasSlab: Bool { self == .neon || self == .crystal || self == .wooden || self == .cat || self == .candy }

    /// 飾りまで入れた、だいたいの横幅・高さ（押した所の当たり判定）
    var extent: SIMD2<Float> {
        let s = shape
        switch self {
        case .torii: return SIMD2(2.2, 2.55)
        case .cloud, .flower: return SIMD2(s.outerWidth + 0.5, s.outerHeight + 0.3)
        case .candy: return SIMD2(s.outerWidth + 0.9, s.outerHeight + 0.1)
        case .cat: return SIMD2(s.outerWidth + 0.5, s.outerHeight + 0.3)
        case .galaxy, .magic: return SIMD2(s.outerWidth + 0.6, s.outerHeight + 0.3)
        default: return SIMD2(s.outerWidth, s.outerHeight)
        }
    }

    /// 選ぶ画面の小さな絵の色（枠・中）
    var swatch: (frame: Color, glow: [Color]) {
        let frame: Color
        switch self {
        case .neon: frame = Color(hex: 0x262336)
        case .magic: frame = Color(hex: 0xF2C25C)
        case .torii: frame = Color(hex: 0xDB331F)
        case .timering: frame = Color(hex: 0x575C6B)
        case .crystal: frame = Color(hex: 0xB8E6FF)
        case .wooden: frame = Color(hex: 0x5C381F)
        case .galaxy: frame = Color(hex: 0x0F0D1A)
        case .heart: frame = Color(hex: 0xFF8CB8)
        case .cloud: frame = Color(hex: 0xF7F7F7)
        case .flower: frame = Color(hex: 0x4D9959)
        case .candy: frame = Color(hex: 0xF2406A)
        case .cat: frame = Color(hex: 0xFFC780)
        case .white, .round: frame = Color(hex: 0xF2F2F2)
        case .black: frame = Color(hex: 0x0F0F0F)
        }
        return (frame, palette.map { Color(uiColor: $0) })
    }
}

/// 扉のまわりの飾りと、その動き（扉が毎コマ tick を呼ぶ）
@MainActor
final class DoorDecor {
    let root = Entity()
    /// まわり続けるもの（向き・速さ rad/秒）
    private var spinners: [(entity: Entity, axis: SIMD3<Float>, speed: Float)] = []
    /// まわりをめぐるもの（扉の面の上の円）
    private var orbiters: [(entity: Entity, center: SIMD3<Float>, radius: Float, speed: Float, phase: Float)] = []
    /// 下から浮かんでいくもの（ハート）
    private var risers: [(entity: Entity, base: SIMD3<Float>, speed: Float, phase: Float, height: Float)] = []
    /// 開くと順に灯るもの（時空の輪の印）
    private(set) var lights: [Entity] = []
    /// 開く戸（木の扉。ちょうつがいの位置）
    private(set) var leaf: Entity?

    static func pbr(_ color: UIColor, rough: Float, metal: Float = 0, coat: Float = 0, opacity: Float = 1,
                    emissive: UIColor? = nil, glow: Float = 0) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color)
        m.roughness = .init(floatLiteral: rough)
        m.metallic = .init(floatLiteral: metal)
        if coat > 0 {
            m.clearcoat = .init(floatLiteral: coat)
            m.clearcoatRoughness = .init(floatLiteral: 0.15)
        }
        if let emissive {
            m.emissiveColor = .init(color: emissive)
            m.emissiveIntensity = glow
        }
        if opacity < 1 { m.blending = .transparent(opacity: .init(floatLiteral: opacity)) }
        return m
    }

    static func unlit(_ color: UIColor, opacity: Float = 1) -> UnlitMaterial {
        var m = UnlitMaterial(color: color)
        if opacity < 1 { m.blending = .transparent(opacity: .init(floatLiteral: opacity)) }
        return m
    }

    static func textured(_ texture: TextureResource?) -> UnlitMaterial? {
        guard let texture else { return nil }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(texture))
        m.blending = .transparent(opacity: .init(floatLiteral: 1))
        return m
    }

    init(design: DoorDesign, shape: DoorShape) throws {
        let low = Perf.isLowMemoryDevice
        switch design {
        case .neon, .white:
            break
        case .magic:
            buildMagic(shape)
        case .torii:
            buildTorii(shape)
        case .timering:
            buildTimeRing(shape)
        case .crystal:
            buildCrystal(shape, count: low ? 10 : 16)
        case .wooden:
            try buildWooden(shape)
        case .galaxy:
            buildGalaxy(shape, count: low ? 22 : 40)
        case .heart:
            buildHearts(shape, count: low ? 6 : 10)
        case .cloud:
            try buildCloud(shape, step: low ? 0.2 : 0.15)
        case .flower:
            try buildFlowers(shape, step: low ? 0.26 : 0.19)
        case .candy:
            buildCandy(shape)
        case .cat:
            try buildCat(shape)
        case .black:
            buildBlack(shape)
        case .round:
            buildRound(shape)
        }
    }

    /// 毎コマ（time は扉が現れてからの秒）
    func tick(time: Float) {
        for s in spinners {
            s.entity.orientation = simd_quatf(angle: s.speed * time, axis: s.axis)
        }
        for o in orbiters {
            let a = o.phase + o.speed * time
            o.entity.position = o.center + SIMD3(cos(a) * o.radius, sin(a) * o.radius * 0.96, 0)
        }
        for r in risers {
            let f = (r.phase + r.speed * time).truncatingRemainder(dividingBy: 1)
            r.entity.position = r.base + SIMD3(sin(time * 1.3 + r.phase * 6) * 0.05, f * r.height, 0)
            Fade.set(r.entity, sin(Float.pi * f) * 0.95)
        }
    }

    // MARK: 魔法陣：光の文字の輪が 2 つ、逆向きにまわる。足もとにも輪

    private func buildMagic(_ s: DoorShape) {
        let c = SIMD3<Float>(0, s.center.y, s.depth / 2 + 0.015)
        if let m = Self.textured(DoorTextures.runeRing(key: "rune-a", rgb: (0.45, 0.95, 1.0), glyphs: 28)) {
            let outer = ModelEntity(mesh: .generatePlane(width: s.openingWidth + 0.62, height: s.openingWidth + 0.62), materials: [m])
            let holder = Entity()
            holder.position = c
            holder.addChild(outer)
            root.addChild(holder)
            spinners.append((outer, [0, 0, 1], 0.22))
        }
        if let m = Self.textured(DoorTextures.runeRing(key: "rune-b", rgb: (0.78, 0.55, 1.0), glyphs: 18)) {
            let inner = ModelEntity(mesh: .generatePlane(width: s.openingWidth + 0.28, height: s.openingWidth + 0.28), materials: [m])
            let holder = Entity()
            holder.position = c + [0, 0, 0.01]
            holder.addChild(inner)
            root.addChild(holder)
            spinners.append((inner, [0, 0, 1], -0.35))
        }
        if let m = Self.textured(DoorTextures.runeRing(key: "rune-ground", rgb: (0.55, 0.85, 1.0), glyphs: 36)) {
            let ground = ModelEntity(mesh: .generatePlane(width: 2.2, depth: 2.2), materials: [m])
            let holder = Entity()
            holder.position = [0, 0.006, 0.7]
            holder.addChild(ground)
            root.addChild(holder)
            spinners.append((ground, [0, 1, 0], 0.12))
        }
    }

    // MARK: 鳥居：朱の柱 2 本・貫・笠木（両はしが反る）・額

    private func buildTorii(_ s: DoorShape) {
        let red = DoorDecor.pbr(UIColor(red: 0.86, green: 0.2, blue: 0.12, alpha: 1), rough: 0.35, coat: 0.5)
        let black = DoorDecor.pbr(UIColor(red: 0.1, green: 0.08, blue: 0.08, alpha: 1), rough: 0.4, coat: 0.3)
        let px = s.radius + 0.1
        for side: Float in [-1, 1] {
            let pillar = ModelEntity(mesh: .generateBox(size: [0.16, 2.36, 0.16], cornerRadius: 0.075), materials: [red])
            pillar.position = [side * px, 1.18, 0]
            root.addChild(pillar)
            let foot = ModelEntity(mesh: .generateBox(size: [0.22, 0.16, 0.22], cornerRadius: 0.03), materials: [black])
            foot.position = [side * px, 0.08, 0]
            root.addChild(foot)
            // 笠木の反った端
            let tip = ModelEntity(mesh: .generateBox(size: [0.34, 0.12, 0.2], cornerRadius: 0.02), materials: [black])
            tip.position = [side * (px + 0.42), 2.46, 0]
            tip.orientation = simd_quatf(angle: side * 0.2, axis: [0, 0, 1])
            root.addChild(tip)
        }
        let nuki = ModelEntity(mesh: .generateBox(size: [px * 2 + 0.5, 0.1, 0.1], cornerRadius: 0.01), materials: [red])
        nuki.position = [0, 2.07, 0]
        root.addChild(nuki)
        let shimaki = ModelEntity(mesh: .generateBox(size: [px * 2 + 0.6, 0.08, 0.16], cornerRadius: 0.01), materials: [red])
        shimaki.position = [0, 2.33, 0]
        root.addChild(shimaki)
        let kasagi = ModelEntity(mesh: .generateBox(size: [px * 2 + 0.5, 0.12, 0.2], cornerRadius: 0.02), materials: [black])
        kasagi.position = [0, 2.43, 0]
        root.addChild(kasagi)
        let post = ModelEntity(mesh: .generateBox(size: [0.08, 0.22, 0.08]), materials: [red])
        post.position = [0, 2.2, 0]
        root.addChild(post)
        let plaque = ModelEntity(mesh: .generateBox(size: [0.2, 0.24, 0.035], cornerRadius: 0.01), materials: [black])
        plaque.position = [0, 2.2, 0.06]
        root.addChild(plaque)
        let gold = DoorDecor.unlit(UIColor(red: 1.0, green: 0.82, blue: 0.4, alpha: 1))
        let mark = ModelEntity(mesh: .generatePlane(width: 0.08, height: 0.14, cornerRadius: 0.02), materials: [gold])
        mark.position = [0, 2.2, 0.079]
        root.addChild(mark)
    }

    // MARK: 時空の輪：太い金属の輪に、印が 9 つ（開くと順に灯る）。足が 2 本

    private func buildTimeRing(_ s: DoorShape) {
        let metal = DoorDecor.pbr(UIColor(red: 0.28, green: 0.3, blue: 0.36, alpha: 1), rough: 0.3, metal: 0.85)
        let c = s.center
        let r = s.radius + s.frameWidth * 0.55
        for i in 0..<9 {
            let a = Float.pi / 2 - 2 * Float.pi * Float(i) / 9
            let chevron = ModelEntity(mesh: .generateBox(size: [0.14, 0.09, 0.06], cornerRadius: 0.015),
                                      materials: [DoorDecor.unlit(UIColor(red: 1.0, green: 0.55, blue: 0.2, alpha: 1))])
            chevron.position = [c.x + cos(a) * r, c.y + sin(a) * r, s.depth / 2 + 0.03]
            chevron.orientation = simd_quatf(angle: a - Float.pi / 2, axis: [0, 0, 1])
            Fade.set(chevron, 0.25)
            root.addChild(chevron)
            lights.append(chevron)
        }
        for side: Float in [-1, 1] {
            let foot = ModelEntity(mesh: .generateBox(size: [0.28, 0.2, 0.5], cornerRadius: 0.04), materials: [metal])
            foot.position = [side * s.radius * 0.55, 0.1, 0]
            root.addChild(foot)
        }
    }

    // MARK: クリスタル：すきとおる結晶が、枠のまわりと足もとに

    private func buildCrystal(_ s: DoorShape, count: Int) {
        let ice = DoorDecor.pbr(UIColor(red: 0.7, green: 0.9, blue: 1.0, alpha: 1), rough: 0.04, coat: 1, opacity: 0.6,
                                emissive: UIColor(red: 0.5, green: 0.85, blue: 1.0, alpha: 1), glow: 0.4)
        let glowIce = DoorDecor.unlit(UIColor(red: 0.75, green: 0.95, blue: 1.0, alpha: 1), opacity: 0.55)
        let path = s.finePath(maxStep: 0.2)
        var rng = SeededRandom(seed: 7)
        for i in 0..<count {
            let item = path[(i * path.count / max(count, 1)) % path.count]
            let outward = -item.n
            let h = 0.22 + Float(rng.next()) * 0.4
            let w = 0.05 + Float(rng.next()) * 0.06
            let shard = ModelEntity(mesh: .generateBox(size: [w, h, w * 0.9], cornerRadius: w * 0.2),
                                    materials: [i % 3 == 0 ? glowIce : ice])
            let p = item.p + outward * (s.frameWidth + h * 0.25)
            shard.position = [p.x, p.y, (Float(rng.next()) - 0.5) * 0.08]
            let tilt = atan2(outward.y, outward.x) - Float.pi / 2 + (Float(rng.next()) - 0.5) * 0.6
            shard.orientation = simd_quatf(angle: tilt, axis: [0, 0, 1])
            root.addChild(shard)
        }
        // 足もとの結晶のかたまり
        for side: Float in [-1, 1] {
            for k in 0..<3 {
                let h = 0.25 + Float(k) * 0.12
                let shard = ModelEntity(mesh: .generateBox(size: [0.08, h, 0.07], cornerRadius: 0.015), materials: [ice])
                shard.position = [side * (s.radius + 0.18 + Float(k) * 0.07), h / 2 - 0.02, 0.05 - Float(k) * 0.05]
                shard.orientation = simd_quatf(angle: side * (0.25 + Float(k) * 0.15), axis: [0, 0, 1])
                root.addChild(shard)
            }
        }
    }

    // MARK: 木の扉：戸（板・鉄の帯・取っ手）が、開くと手前に開く。上にランプ

    private func buildWooden(_ s: DoorShape) throws {
        let wood = DoorDecor.pbr(UIColor(red: 0.55, green: 0.34, blue: 0.18, alpha: 1), rough: 0.75)
        let iron = DoorDecor.pbr(UIColor(white: 0.12, alpha: 1), rough: 0.4, metal: 0.8)
        let brass = DoorDecor.pbr(UIColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1), rough: 0.25, metal: 0.95)
        let hinge = Entity()
        hinge.position = [-s.radius, 0, s.depth / 2 + 0.012]
        // 戸の形は開口部と同じ（ちょうつがいを原点に）
        let shifted = s.openingPath().map { (p: $0.p + SIMD2<Float>(s.radius, 0), n: $0.n) }
        let front = ModelEntity(mesh: try ArchMesh.opening(path: shifted, z: 0.012,
                                                           center: s.center + SIMD2<Float>(s.radius, 0), name: "leaf-front"),
                                materials: [wood])
        let back = ModelEntity(mesh: try ArchMesh.opening(path: shifted, z: 0.012,
                                                          center: s.center + SIMD2<Float>(s.radius, 0), name: "leaf-back"),
                               materials: [wood])
        back.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        back.position = [s.openingWidth, 0, 0]
        hinge.addChild(front)
        hinge.addChild(back)
        // 板の継ぎ目と鉄の帯
        for y: Float in [0.45, 1.35] {
            let band = ModelEntity(mesh: .generateBox(size: [s.openingWidth * 0.96, 0.06, 0.02]), materials: [iron])
            band.position = [s.radius, y, 0.022]
            hinge.addChild(band)
        }
        for k in 1..<4 {
            let seam = ModelEntity(mesh: .generateBox(size: [0.008, s.legHeight * 0.95, 0.004]),
                                   materials: [DoorDecor.pbr(UIColor(red: 0.3, green: 0.18, blue: 0.09, alpha: 1), rough: 0.8)])
            seam.position = [s.openingWidth * Float(k) / 4, s.legHeight * 0.5, 0.015]
            hinge.addChild(seam)
        }
        let knob = ModelEntity(mesh: .generateSphere(radius: 0.035), materials: [brass])
        knob.position = [s.openingWidth * 0.84, 1.0, 0.045]
        hinge.addChild(knob)
        root.addChild(hinge)
        leaf = hinge
        // 上のランプ（あたたかい光）
        let lamp = ModelEntity(mesh: .generateSphere(radius: 0.06),
                               materials: [DoorDecor.unlit(UIColor(red: 1.0, green: 0.85, blue: 0.5, alpha: 1))])
        lamp.position = [0, s.outerHeight + 0.12, s.depth / 2 + 0.05]
        root.addChild(lamp)
        let arm = ModelEntity(mesh: .generateBox(size: [0.02, 0.02, 0.1]), materials: [iron])
        arm.position = [0, s.outerHeight + 0.12, s.depth / 2]
        root.addChild(arm)
    }

    // MARK: 銀河：星と惑星が、扉のまわりをめぐる

    private func buildGalaxy(_ s: DoorShape, count: Int) {
        let c = SIMD3<Float>(0, s.center.y, s.depth / 2 + 0.02)
        let colors: [UIColor] = [.white, UIColor(red: 1.0, green: 0.6, blue: 0.9, alpha: 1),
                                 UIColor(red: 0.6, green: 0.8, blue: 1.0, alpha: 1), UIColor(red: 0.8, green: 0.65, blue: 1.0, alpha: 1)]
        var rng = SeededRandom(seed: 41)
        for i in 0..<count {
            let star = ModelEntity(mesh: .generateSphere(radius: 0.008 + Float(rng.next()) * 0.016),
                                   materials: [DoorDecor.unlit(colors[i % colors.count])])
            root.addChild(star)
            let radius = s.radius + s.frameWidth + 0.04 + Float(rng.next()) * 0.32
            orbiters.append((star, c + [0, 0, (Float(rng.next()) - 0.5) * 0.06], radius,
                             (0.12 + Float(rng.next()) * 0.25) * (radius < s.radius + 0.2 ? 1.4 : 1), Float(rng.next()) * 6.28))
        }
        let planetA = ModelEntity(mesh: .generateSphere(radius: 0.07),
                                  materials: [DoorDecor.pbr(UIColor(red: 1.0, green: 0.6, blue: 0.3, alpha: 1), rough: 0.5,
                                                            emissive: UIColor(red: 1.0, green: 0.5, blue: 0.2, alpha: 1), glow: 0.5)])
        root.addChild(planetA)
        orbiters.append((planetA, c + [0, 0, 0.05], s.radius + 0.38, 0.18, 0.5))
        let planetB = ModelEntity(mesh: .generateSphere(radius: 0.045),
                                  materials: [DoorDecor.pbr(UIColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1), rough: 0.4,
                                                            emissive: UIColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 1), glow: 0.5)])
        root.addChild(planetB)
        orbiters.append((planetB, c + [0, 0, 0.04], s.radius + 0.24, -0.27, 3.5))
    }

    // MARK: ハート：小さなハートが、ゆらゆら浮かんでいく

    private func buildHearts(_ s: DoorShape, count: Int) {
        guard let m = Self.textured(DoorTextures.heartSprite()) else { return }
        for i in 0..<count {
            let size: Float = 0.09 + Float(i % 3) * 0.035
            let heart = ModelEntity(mesh: .generatePlane(width: size, height: size), materials: [m])
            root.addChild(heart)
            let side: Float = i % 2 == 0 ? -1 : 1
            let x = side * (s.radius + 0.12 + Float(i % 4) * 0.08)
            risers.append((heart, [x, 0.15, s.depth / 2 + 0.05 + Float(i % 3) * 0.04], 0.09 + Float(i % 5) * 0.02,
                           Float(i) / Float(count), s.innerHeight + 0.3))
        }
    }

    // MARK: くも：枠のまわりにふわふわの雲。うしろに虹

    private func buildCloud(_ s: DoorShape, step: Float) throws {
        let puff = DoorDecor.pbr(UIColor(white: 0.98, alpha: 1), rough: 0.95)
        let path = s.finePath(maxStep: step)
        var rng = SeededRandom(seed: 13)
        for (i, item) in path.enumerated() where i % 1 == 0 {
            let outward = -item.n
            let r: Float = 0.07 + Float(rng.next()) * 0.08
            let p = item.p + outward * (s.frameWidth + r * 0.4)
            let ball = ModelEntity(mesh: .generateSphere(radius: r), materials: [puff])
            ball.position = [p.x, max(r * 0.7, p.y), (Float(rng.next()) - 0.5) * 0.06]
            root.addChild(ball)
        }
        // 虹（5 色の弧を、扉のうしろに）
        let colors: [UIColor] = [UIColor(red: 1.0, green: 0.45, blue: 0.5, alpha: 1), UIColor(red: 1.0, green: 0.7, blue: 0.4, alpha: 1),
                                 UIColor(red: 1.0, green: 0.92, blue: 0.5, alpha: 1), UIColor(red: 0.55, green: 0.9, blue: 0.6, alpha: 1),
                                 UIColor(red: 0.5, green: 0.75, blue: 1.0, alpha: 1)]
        for (k, color) in colors.enumerated() {
            let radius = s.radius + 0.42 - Float(k) * 0.055
            var arc: [(p: SIMD2<Float>, n: SIMD2<Float>)] = []
            for j in 0...24 {
                let a = Float.pi - Float.pi * Float(j) / 24
                let dir = SIMD2<Float>(cos(a), sin(a))
                arc.append((p: SIMD2(0, s.legHeight) + dir * radius, n: -dir))
            }
            let band = ModelEntity(mesh: try ArchMesh.frame(path: arc, width: 0.055, depth: 0.01, zCenter: -s.depth / 2 - 0.02,
                                                            name: "rainbow-\(k)"),
                                   materials: [DoorDecor.unlit(color, opacity: 0.85)])
            root.addChild(band)
        }
    }

    // MARK: 花のアーチ：枠に沿って花と葉

    private func buildFlowers(_ s: DoorShape, step: Float) throws {
        let petals: [UIColor] = [UIColor(red: 1.0, green: 0.6, blue: 0.78, alpha: 1), .white,
                                 UIColor(red: 0.8, green: 0.7, blue: 1.0, alpha: 1), UIColor(red: 1.0, green: 0.8, blue: 0.5, alpha: 1)]
        let flowerMesh = try DoorDecor.flowerMesh(radius: 0.07)
        let leafMesh = MeshResource.generateBox(size: [0.09, 0.03, 0.006], cornerRadius: 0.003)
        let leafMaterial = DoorDecor.pbr(UIColor(red: 0.35, green: 0.68, blue: 0.38, alpha: 1), rough: 0.6)
        let centerMaterial = DoorDecor.pbr(UIColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 1), rough: 0.5)
        let centerMesh = MeshResource.generateSphere(radius: 0.022)
        let path = s.finePath(maxStep: step)
        let z = s.depth / 2 + 0.012
        for (i, item) in path.enumerated() {
            let outward = -item.n
            let p = item.p + outward * (s.frameWidth * 0.5)
            guard p.y > 0.12 else { continue }
            let flower = ModelEntity(mesh: flowerMesh,
                                     materials: [DoorDecor.pbr(petals[i % petals.count], rough: 0.55)])
            flower.position = [p.x, p.y, z]
            flower.orientation = simd_quatf(angle: Float(i) * 0.7, axis: [0, 0, 1])
            flower.scale = .one * (0.8 + Float(i % 3) * 0.18)
            root.addChild(flower)
            let center = ModelEntity(mesh: centerMesh, materials: [centerMaterial])
            center.position = [p.x, p.y, z + 0.008]
            root.addChild(center)
            if i % 2 == 0 {
                let leaf = ModelEntity(mesh: leafMesh, materials: [leafMaterial])
                let q = p + outward * 0.07
                leaf.position = [q.x, q.y, z - 0.01]
                leaf.orientation = simd_quatf(angle: atan2(outward.y, outward.x), axis: [0, 0, 1])
                root.addChild(leaf)
            }
        }
    }

    /// 平たい花びら 5 枚の形（正面向き）
    static func flowerMesh(radius: Float) throws -> MeshResource {
        var b = MeshBuilder()
        for k in 0..<5 {
            let a = Float(k) * 2 * Float.pi / 5
            let c = SIMD2<Float>(cos(a), sin(a)) * radius * 0.55
            let rx = radius * 0.5, ry = radius * 0.32
            let steps = 10
            for j in 0..<steps {
                let t0 = Float(j) / Float(steps) * 2 * Float.pi, t1 = Float(j + 1) / Float(steps) * 2 * Float.pi
                func pt(_ t: Float) -> SIMD3<Float> {
                    // 花びらの楕円を、外向きに回す
                    let e = SIMD2<Float>(cos(t) * rx, sin(t) * ry)
                    let r = SIMD2<Float>(e.x * cos(a) - e.y * sin(a), e.x * sin(a) + e.y * cos(a))
                    return SIMD3(c.x + r.x, c.y + r.y, 0)
                }
                b.triangle(SIMD3(c.x, c.y, 0.002), pt(t0), pt(t1), normal: [0, 0, 1]) { SIMD2($0.x, $0.y) }
            }
        }
        return try b.mesh(name: "flower")
    }

    // MARK: キャンディ：しましまの枠の上に飴玉、両わきにペロペロキャンディ

    private func buildCandy(_ s: DoorShape) {
        let colors: [UIColor] = [UIColor(red: 1.0, green: 0.4, blue: 0.6, alpha: 1), UIColor(red: 0.5, green: 0.85, blue: 1.0, alpha: 1),
                                 UIColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 1), UIColor(red: 0.6, green: 0.95, blue: 0.6, alpha: 1),
                                 UIColor(red: 0.8, green: 0.6, blue: 1.0, alpha: 1)]
        let path = s.finePath(maxStep: 0.24)
        for (i, item) in path.enumerated() where item.p.y > s.legHeight * 0.6 {
            let outward = -item.n
            let p = item.p + outward * (s.frameWidth + 0.035)
            let drop = ModelEntity(mesh: .generateSphere(radius: 0.045),
                                   materials: [DoorDecor.pbr(colors[i % colors.count], rough: 0.15, coat: 1)])
            drop.position = [p.x, p.y, 0.02]
            root.addChild(drop)
        }
        let stick = DoorDecor.pbr(.white, rough: 0.4)
        for (k, side) in [Float(-1), 1].enumerated() {
            let x = side * (s.radius + s.frameWidth + 0.32)
            let pole = ModelEntity(mesh: .generateBox(size: [0.03, 0.95, 0.03], cornerRadius: 0.012), materials: [stick])
            pole.position = [x, 0.475, 0.05]
            root.addChild(pole)
            guard let m = Self.textured(DoorTextures.swirl(key: "swirl-\(k)",
                                                           rgb: k == 0 ? (1.0, 0.35, 0.55) : (0.4, 0.75, 1.0))) else { continue }
            let candy = ModelEntity(mesh: .generatePlane(width: 0.42, height: 0.42), materials: [m])
            candy.position = [x, 1.08, 0.06]
            let holder = Entity()
            holder.addChild(candy)
            root.addChild(holder)
            candy.position = .zero
            holder.position = [x, 1.08, 0.06]
            spinners.append((candy, [0, 0, 1], side * 0.6))
        }
    }

    // MARK: ねこ：耳 2 つ・ひげ・しっぽ

    private func buildCat(_ s: DoorShape) throws {
        let fur = DoorDecor.pbr(UIColor(red: 1.0, green: 0.74, blue: 0.45, alpha: 1), rough: 0.6, coat: 0.3)
        let pink = DoorDecor.pbr(UIColor(red: 1.0, green: 0.62, blue: 0.72, alpha: 1), rough: 0.5)
        let outer = try DoorDecor.prism(width: 0.34, height: 0.36, depth: s.depth)
        let inner = try DoorDecor.prism(width: 0.2, height: 0.22, depth: 0.01)
        for side: Float in [-1, 1] {
            let ear = Entity()
            ear.position = [side * s.radius * 0.72, s.innerHeight + s.frameWidth * 0.3, 0]
            ear.orientation = simd_quatf(angle: -side * 0.38, axis: [0, 0, 1])
            ear.addChild(ModelEntity(mesh: outer, materials: [fur]))
            let innerEar = ModelEntity(mesh: inner, materials: [pink])
            innerEar.position = [0, 0.04, s.depth / 2 + 0.006]
            ear.addChild(innerEar)
            root.addChild(ear)
            // ひげ 3 本
            for k in 0..<3 {
                let whisker = ModelEntity(mesh: .generateBox(size: [0.32, 0.012, 0.012], cornerRadius: 0.005),
                                          materials: [DoorDecor.pbr(UIColor(white: 0.25, alpha: 1), rough: 0.5)])
                let y = s.legHeight * 0.62 + Float(k - 1) * 0.07
                whisker.position = [side * (s.radius + s.frameWidth + 0.13), y, s.depth / 2]
                whisker.orientation = simd_quatf(angle: side * Float(k - 1) * 0.18, axis: [0, 0, 1])
                root.addChild(whisker)
            }
        }
        // しっぽ（右下から、くるんと上へ）
        let tailBase = SIMD2<Float>(s.radius + s.frameWidth + 0.05, 0.12)
        for k in 0..<10 {
            let t = Float(k) / 9
            let p = tailBase + SIMD2(0.18 * sin(t * 2.6), 0.75 * t)
            let ball = ModelEntity(mesh: .generateSphere(radius: 0.05 - 0.012 * t), materials: [fur])
            ball.position = [p.x, p.y, -0.04]
            root.addChild(ball)
        }
    }

    /// 三角の柱（ねこ耳）。底の中心が原点
    static func prism(width: Float, height: Float, depth: Float) throws -> MeshResource {
        var b = MeshBuilder()
        let zf = depth / 2, zb = -depth / 2
        let l = SIMD2<Float>(-width / 2, 0), r = SIMD2<Float>(width / 2, 0), t = SIMD2<Float>(0, height)
        func v(_ p: SIMD2<Float>, _ z: Float) -> SIMD3<Float> { SIMD3(p.x, p.y, z) }
        b.triangle(v(l, zf), v(r, zf), v(t, zf), normal: [0, 0, 1]) { SIMD2($0.x, $0.y) }
        b.triangle(v(l, zb), v(t, zb), v(r, zb), normal: [0, 0, -1]) { SIMD2($0.x, $0.y) }
        for (a, c) in [(l, t), (t, r), (r, l)] {
            let e = c - a
            let n = simd_normalize(SIMD3<Float>(e.y, -e.x, 0))
            b.quad(v(a, zf), v(a, zb), v(c, zb), v(c, zf), normal: -n)
        }
        return try b.mesh(name: "prism")
    }

    // MARK: シンプル

    private func buildBlack(_ s: DoorShape) {
        // 枠の内側に、細い金の線
        let gold = DoorDecor.pbr(UIColor(red: 0.95, green: 0.78, blue: 0.4, alpha: 1), rough: 0.2, metal: 0.95)
        let line = ModelEntity(mesh: .generateBox(size: [s.openingWidth + s.frameWidth * 2 + 0.02, 0.012, 0.02]), materials: [gold])
        line.position = [0, 0.006, s.depth / 2]
        root.addChild(line)
    }

    private func buildRound(_ s: DoorShape) {
        // 浮かぶ円を支える細い柱と台
        let white = DoorDecor.pbr(UIColor(white: 0.95, alpha: 1), rough: 0.55)
        let pole = ModelEntity(mesh: .generateBox(size: [0.035, s.lift, 0.035], cornerRadius: 0.012), materials: [white])
        pole.position = [0, s.lift / 2, 0]
        root.addChild(pole)
        let foot = ModelEntity(mesh: .generateBox(size: [0.42, 0.04, 0.22], cornerRadius: 0.015), materials: [white])
        foot.position = [0, 0.02, 0]
        root.addChild(foot)
    }
}

/// 選ぶ画面に出す、扉の小さな絵（開口部の形・枠の色・光の色）
struct DoorDesignThumb: View {
    let design: DoorDesign

    var body: some View {
        Canvas { context, size in
            let shape = design.shape
            let path = shape.openingPath()
            let w = max(design.extent.x, shape.outerWidth) + 0.25
            let h = max(design.extent.y, shape.outerHeight) + 0.15
            let scale = min(size.width / CGFloat(w), size.height / CGFloat(h))
            func pt(_ p: SIMD2<Float>) -> CGPoint {
                CGPoint(x: size.width / 2 + CGFloat(p.x) * scale, y: size.height - 4 - CGFloat(p.y) * scale)
            }
            var outline = Path()
            if let first = path.first {
                outline.move(to: pt(first.p))
                for item in path.dropFirst() { outline.addLine(to: pt(item.p)) }
                if shape.isClosed { outline.closeSubpath() }
            }
            let colors = design.swatch.glow
            // 中（扉の向こうの夜空）
            var fill = outline
            if !shape.isClosed { fill.closeSubpath() }
            context.fill(fill, with: .linearGradient(Gradient(colors: [Color(hex: 0x1D1240), Color(hex: 0x4A2A8A)]),
                                                     startPoint: CGPoint(x: 0, y: size.height), endPoint: .zero))
            // 枠
            context.stroke(outline, with: .color(design.swatch.frame),
                           style: StrokeStyle(lineWidth: max(2, CGFloat(shape.frameWidth) * scale * 1.6), lineCap: .round, lineJoin: .round))
            // ネオン
            context.stroke(outline, with: .linearGradient(Gradient(colors: colors),
                                                          startPoint: CGPoint(x: 0, y: size.height), endPoint: CGPoint(x: 0, y: 0)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: design.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(Color.black.opacity(0.35), in: Circle())
                .padding(2)
        }
        .accessibilityHidden(true)
    }
}

extension DoorDesign {
    /// 選ぶ画面の小さな印
    var symbol: String {
        switch self {
        case .neon: return "bolt.fill"
        case .magic: return "sparkles"
        case .torii: return "building.columns.fill"
        case .timering: return "circle.dashed"
        case .crystal: return "snowflake"
        case .wooden: return "door.left.hand.closed"
        case .galaxy: return "moon.stars.fill"
        case .heart: return "heart.fill"
        case .cloud: return "cloud.fill"
        case .flower: return "camera.macro"
        case .candy: return "birthday.cake.fill"
        case .cat: return "cat.fill"
        case .white: return "circle"
        case .black: return "square.fill"
        case .round: return "circle.circle"
        }
    }
}

/// 扉の見た目を選ぶ（横にめくる。ワクワク・かわいい・シンプルの順）
struct DoorDesignPicker: View {
    let selection: DoorDesign
    let onSelect: (DoorDesign) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("扉の見た目").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                Text(selection.label).font(.caption.weight(.heavy)).foregroundStyle(Theme.accent)
                Text(selection.summary).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(DoorDesign.Group.allCases) { group in
                            Text(group.rawValue)
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize()
                                .rotationEffect(.degrees(-90))
                                .frame(width: 14, height: 70)
                            ForEach(DoorDesign.allCases.filter { $0.group == group }) { design in
                                DoorDesignChip(design: design, selected: design == selection) { onSelect(design) }
                                    .id(design)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear { scroller.scrollTo(selection, anchor: .center) }
            }
        }
    }
}

/// 扉の見た目の 1 つ（小さな絵と名前）
struct DoorDesignChip: View {
    let design: DoorDesign
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                DoorDesignThumb(design: design)
                    .padding(6)
                    .frame(width: 58, height: 64)
                    .background(LinearGradient(colors: [Color(hex: 0x2A1650), Color(hex: 0x120B24)],
                                               startPoint: .top, endPoint: .bottom),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? AnyShapeStyle(Theme.neonBand) : AnyShapeStyle(Color.clear), lineWidth: 2.5))
                Text(design.label)
                    .font(.system(size: 10, weight: selected ? .heavy : .semibold))
                    .foregroundStyle(selected ? Theme.accent : Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 60)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("扉の見た目：\(design.label)。\(design.summary)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 扉の見た目をまとめて見せる（GATE を直す画面・見本）
struct DoorDesignGrid: View {
    let selection: DoorDesign
    let onSelect: (DoorDesign) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(DoorDesign.Group.allCases) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.rawValue).font(.caption.weight(.heavy)).foregroundStyle(Theme.textSecondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 10) {
                        ForEach(DoorDesign.allCases.filter { $0.group == group }) { design in
                            DoorDesignChip(design: design, selected: design == selection) { onSelect(design) }
                        }
                    }
                }
            }
            Text(selection.label + "：" + selection.summary)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
