import ARKit
import Combine
import RealityKit
import UIKit

/// GATE の扉。夜の色の石のアーチに、アイコンと同じネオン（足もとの夕焼け → てっぺんの夜空）が灯る。
/// 現れるときはネオンがまたたいて灯り、開くとガラスが消えて、扉の向こうの世界（夕焼けから夜空・思い出の写真・光の粒）と、
/// 足もとへもれる光が広がる。
/// 向こうの世界は、扉の後ろに置いた「見えない壁」で囲み、扉の開口部からだけ見えるようにしている。
@MainActor
final class GateDoor {
    /// 扉の向こうの見え方
    enum Style {
        /// 開くと、向こうに思い出の夜空の世界（見えない壁で囲み、開口部からだけ見せる）
        case portal
        /// 景色の GATE：向こうに本物の景色がそのまま見える額縁。思い出の写真と光の粒だけが、景色の手前に浮かぶ
        case window
    }

    let style: Style
    /// 扉の見た目（ネオン・魔法陣・鳥居…。作った人が選ぶ）
    let design: DoorDesign
    let anchorEntity: AnchorEntity
    let shape: DoorShape
    /// 見た目ごとのまわりの飾り（動くものは毎コマ tick）
    private var decor: DoorDecor?
    private(set) var isOpen = false
    /// 扉と AR の飾りを載せる台。見る人が指で少し動かした分（自分の画面だけ）は、この台の位置・向きで持つ
    let base = Entity()
    private(set) var nudgePosition: SIMD3<Float> = .zero
    private(set) var nudgeYaw: Float = 0

    private let root = Entity()
    private let hitBox = ModelEntity()
    private var glass = ModelEntity()
    private var trim = ModelEntity()
    /// ネオンの管（高さで色が変わるので、いくつかに分けて色を付ける）と、そのにじむ光
    private let neon = Entity()
    private var neonGlow = ModelEntity()
    private var groundGlow = ModelEntity()
    private var ring = ModelEntity()
    /// ネオンの明るさ（0〜1。またたき・息づかい・開いたときの強まり）
    private var neonLevel: Float = 0
    private let interior = Entity()
    private var spill = ModelEntity()
    private var photoSlots: [ModelEntity] = []

    private struct Floater {
        let entity: Entity
        let base: SIMD3<Float>
        let amplitude: Float
        let speed: Float
        let phase: Float
        let rises: Bool
        /// 立ちのぼる高さ（ここまで来たら足もとへ戻る）
        var wrap: Float = 2.1
    }
    private var floaters: [Floater] = []

    private struct Tween {
        let start: TimeInterval
        let duration: TimeInterval
        let apply: (Float) -> Void
    }
    private var tweens: [Tween] = []
    private var clock: TimeInterval = 0
    private var subscription: Cancellable?

    /// 扉の向こうの回廊の大きさ（扉の大きさ 1 のときの m）
    private static let worldHalfWidth: Float = 1.8
    private static let worldHeight: Float = 3.0
    private static let worldDeep: Float = 5.5
    /// 回廊を奥へ流れていく光の輪（中へ誘う）と、いちばん奥の光
    private var beckonRings: [ModelEntity] = []
    private var farLight = ModelEntity()

    /// 扉をくぐった（歩いて通った・iPhone を開口部の中へ入れた）ときに呼ぶ
    var onPassThrough: (() -> Void)?
    private weak var arView: ARView?
    /// 前のコマのカメラの位置（扉の座標。くぐったかを見る）
    private var lastCamLocal: SIMD3<Float>?
    private var passQuietUntil: TimeInterval = 0

    init(anchor: ARAnchor, in arView: ARView, style: Style = .portal, design: DoorDesign = .neon) throws {
        self.style = style
        self.design = design
        self.shape = design.shape
        self.arView = arView
        anchorEntity = AnchorEntity(anchor: anchor)
        try MainWatch.run("扉を組み立てる") {
            try build()
        }
        anchorEntity.addChild(base)
        base.addChild(root)
        Fade.set(root, 0)
        arView.scene.addAnchor(anchorEntity)
        subscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.update(dt: event.deltaTime)
            }
        }
    }

    /// 指で動かした分（印からの位置・向き）。扉と AR の飾りが一緒に動く
    func setNudge(position: SIMD3<Float>, yaw: Float) {
        nudgePosition = position
        nudgeYaw = yaw
        base.transform = Transform(scale: .one, rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]), translation: position)
        lastCamLocal = nil
    }

    /// 台（扉の足もとの中心）の、世界の中での位置・向き
    var baseWorldTransform: simd_float4x4 { base.transformMatrix(relativeTo: nil) }

    /// 扉に触れたか（押した所の entity が扉の当たり判定か）
    func isHit(_ entity: Entity?) -> Bool {
        var e = entity
        while let current = e {
            if current === hitBox || current === root { return true }
            e = current.parent
        }
        return false
    }

    // MARK: 組み立て

    private func build() throws {
        let path = shape.openingPath()

        // 枠：見た目ごとの質感（ネオンは夜の色の石。つやを出して、ネオンの光と景色が映るように）
        if design == .candy {
            // キャンディ：赤と白のしましま（ふちを細かく分けて、交互に色を付ける）
            let fine = shape.finePath(maxStep: 0.07)
            let red = design.frameMaterial()
            let white = DoorDecor.pbr(.white, rough: 0.2, coat: 1)
            var i = 0
            while i < fine.count - 1 {
                let band = Array(fine[i...min(i + 1, fine.count - 1)])
                let piece = ModelEntity(mesh: try ArchMesh.frame(path: band, width: shape.frameWidth, depth: shape.depth,
                                                                 name: "candy-\(i)"),
                                        materials: [i % 2 == 0 ? red : white])
                root.addChild(piece)
                i += 1
            }
        } else {
            let frame = ModelEntity(mesh: try ArchMesh.frame(path: path, width: shape.frameWidth, depth: shape.depth,
                                                             name: "frame"),
                                    materials: [design.frameMaterial()])
            root.addChild(frame)
        }

        // 足もとの踏み石（地面に立つアーチ・四角だけ）
        var step = PhysicallyBasedMaterial()
        step.baseColor = .init(tint: UIColor(red: 0.22, green: 0.21, blue: 0.28, alpha: 1))
        step.roughness = .init(floatLiteral: 0.5)
        step.clearcoat = .init(floatLiteral: 0.3)
        let slab = ModelEntity(mesh: .generateBox(size: [shape.outerWidth + 0.12, 0.035, shape.depth + 0.24],
                                                  cornerRadius: 0.012),
                               materials: [step])
        slab.position = [0, 0.0175, 0]
        if design.hasSlab { root.addChild(slab) }

        // 内側のうすい光の縁（開口部のふちに沿う細い線。ネオンの奥）
        let inset = path.map { (p: $0.p + $0.n * 0.012, n: $0.n) }
        var light = UnlitMaterial(color: UIColor(red: 1.0, green: 0.86, blue: 0.70, alpha: 1))
        light.blending = .transparent(opacity: .init(floatLiteral: 1))
        trim = ModelEntity(mesh: try ArchMesh.frame(path: inset, width: 0.008, depth: shape.depth + 0.004, name: "trim"),
                           materials: [light])
        Fade.set(trim, 0.35)
        root.addChild(trim)

        // ネオンの管：開口部のふちの少し内側、正面に沿って。高さで夕焼け → 夜空の色
        try buildNeon()

        // ガラスの面（開く前）：夜空のむらさき
        var glassMaterial = PhysicallyBasedMaterial()
        glassMaterial.baseColor = .init(tint: design.glassTint)
        glassMaterial.roughness = .init(floatLiteral: 0.05)
        glassMaterial.metallic = .init(floatLiteral: 0.0)
        glassMaterial.emissiveColor = .init(color: design == .neon ? UIColor(red: 0.42, green: 0.30, blue: 0.86, alpha: 1)
                                                                   : design.neonColor(at: 0.6))
        glassMaterial.emissiveIntensity = 0.3
        glassMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.38))
        glass = ModelEntity(mesh: try ArchMesh.opening(path: inset, z: 0.004, center: shape.center, name: "glass"),
                            materials: [glassMaterial])
        root.addChild(glass)

        // 扉の向こうの世界（開くまで隠す）
        try buildInterior(path: inset)
        interior.isEnabled = false
        root.addChild(interior)

        // 接地の影
        if let shadowTexture = DoorTextures.radial(key: "shadow", rgb: (0, 0, 0), alpha: 0.42) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(shadowTexture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            let shadow = ModelEntity(mesh: .generatePlane(width: shape.outerWidth + 0.7, depth: shape.depth + 0.9),
                                     materials: [m])
            shadow.position = [0, 0.002, 0]
            root.addChild(shadow)
        }

        // ネオンが足もとの地面を照らす、うすい色の光（閉じているあいだも）
        var gr: CGFloat = 1, gg: CGFloat = 0.36, gb: CGFloat = 0.55, ga: CGFloat = 1
        if design != .neon { design.neonColor(at: 0).getRed(&gr, green: &gg, blue: &gb, alpha: &ga) }
        if let texture = DoorTextures.radial(key: "neon-ground-\(design.rawValue)", rgb: (gr, gg, gb), alpha: 0.32) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(texture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            groundGlow = ModelEntity(mesh: .generatePlane(width: shape.outerWidth + 0.9, depth: 1.0), materials: [m])
            groundGlow.position = [0, 0.003, 0.32]
            Fade.set(groundGlow, 0)
            root.addChild(groundGlow)
        }

        // 開いたときに手前の地面に広がる光（アイコンの足もとの光と同じ、あたたかい金色）
        if let spillTexture = DoorTextures.radial(key: "spill", rgb: (1.0, 0.80, 0.50), alpha: 0.62) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(spillTexture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            spill = ModelEntity(mesh: .generatePlane(width: 1.8, depth: 2.2), materials: [m])
            spill.position = [0, 0.004, 0.9]
            Fade.set(spill, 0)
            root.addChild(spill)
        }

        // 開いたときに扉から広がる光の輪
        if let ringTexture = DoorTextures.neonRing() {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(ringTexture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            ring = ModelEntity(mesh: .generatePlane(width: 1.2, height: 1.2), materials: [m])
            ring.position = [0, shape.center.y, shape.depth / 2 + 0.05]
            ring.isEnabled = false
            root.addChild(ring)
        }

        // 陰影をはっきりさせる、やわらかい光（影は作らない＝軽く）
        let sun = DirectionalLight()
        sun.light.intensity = 1400
        sun.light.color = UIColor(red: 1.0, green: 0.97, blue: 0.92, alpha: 1)
        sun.orientation = simd_quatf(angle: -.pi / 3.2, axis: [1, 0, 0]) * simd_quatf(angle: .pi / 6, axis: [0, 1, 0])
        root.addChild(sun)

        // 見た目ごとの飾り（鳥居の柱・魔法陣の輪・木の戸…）
        let parts = try DoorDecor(design: design, shape: shape)
        root.addChild(parts.root)
        decor = parts

        // 押した所が扉かを見分ける当たり判定（飾りまで入れた大きさ）
        let hitW = max(shape.outerWidth, design.extent.x), hitH = max(shape.outerHeight, design.extent.y)
        hitBox.components.set(CollisionComponent(shapes: [
            .generateBox(size: [hitW, hitH, 0.4])
        ]))
        hitBox.position = [0, hitH / 2, 0]
        root.addChild(hitBox)
        Trace.log("扉の見た目：\(design.label)")
    }

    /// ネオンの管を、高さの帯ごとに色を変えて作る（足を細かく分けて、色が少しずつ変わるように）
    private func buildNeon() throws {
        let inward: Float = 0.03, tube: Float = design == .neon ? 0.024 : 0.018
        // 開口部のふち（長い辺は細かく分けて、高さで色が少しずつ変わるように）
        let inside = shape.finePath(maxStep: 0.12).map { (p: $0.p + $0.n * inward, n: $0.n) }
        let top = shape.innerHeight
        // 3 点ずつの帯（となりと 1 点重ねて、すき間を作らない）
        var start = 0
        while start < inside.count - 1 {
            let end = min(start + 3, inside.count - 1)
            let band = Array(inside[start...end])
            let midY = band.map(\.p.y).reduce(0, +) / Float(band.count)
            var m = UnlitMaterial(color: design.neonColor(at: midY / top))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            let piece = ModelEntity(mesh: try ArchMesh.frame(path: band, width: tube, depth: tube,
                                                             zCenter: shape.depth / 2 + tube / 2 + 0.004,
                                                             name: "neon-\(start)"),
                                    materials: [m])
            neon.addChild(piece)
            start = end
        }
        root.addChild(neon)
        Fade.set(neon, 0)

        // にじむ光（ネオンの前にうすく重ねる）
        let margin: Float = 0.3
        if let texture = DoorTextures.neonGlow(shape: shape, colors: design.palette, margin: margin,
                                               key: "neon-glow-\(design.rawValue)") {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(texture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            let w = shape.outerWidth + margin * 2, h = shape.outerHeight + margin * 2
            neonGlow = ModelEntity(mesh: .generatePlane(width: w, height: h), materials: [m])
            neonGlow.position = [0, h / 2 - margin, shape.depth / 2 + 0.03]
            Fade.set(neonGlow, 0)
            root.addChild(neonGlow)
        }
    }

    /// ネオンの明るさをまとめて変える（管・にじむ光・地面の照り返し）
    private func setNeon(_ level: Float) {
        // 少しの違いでは変えない（iOS 17 では質感の置き換えになるため、毎コマ変えると重い）
        if abs(level - neonLevel) < 0.012 && level > 0 && level < 1 { return }
        neonLevel = level
        Fade.set(neon, min(1, 0.25 + 0.75 * level))
        Fade.set(neonGlow, min(1, 0.9 * level))
        Fade.set(groundGlow, min(1, 0.85 * level))
    }

    private func buildInterior(path: [(p: SIMD2<Float>, n: SIMD2<Float>)]) throws {
        if style == .portal {
            try buildPortalWorld(halfWidth: Self.worldHalfWidth, height: Self.worldHeight, deep: Self.worldDeep)
        }
        try buildFloatingMemories()
    }

    /// 向こうの世界（見えない壁で囲んだ夜空と光の床）。景色の額縁では作らない＝本物の景色がそのまま見える
    private func buildPortalWorld(halfWidth: Float, height: Float, deep: Float) throws {
        let occlusion = OcclusionMaterial()

        // 扉の面の見えない壁（開口部の形の穴あき）と、まわりを囲む見えない壁
        let wall = ModelEntity(mesh: try ArchMesh.wallWithOpening(shape: shape, halfWidth: halfWidth, height: height,
                                                                  z: -0.01),
                               materials: [occlusion])
        interior.addChild(wall)
        let side = MeshResource.generatePlane(width: deep, height: height)
        let left = ModelEntity(mesh: side, materials: [occlusion])
        left.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
        left.position = [-halfWidth, height / 2, -deep / 2]
        let right = ModelEntity(mesh: side, materials: [occlusion])
        right.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        right.position = [halfWidth, height / 2, -deep / 2]
        let top = ModelEntity(mesh: .generatePlane(width: halfWidth * 2, depth: deep), materials: [occlusion])
        top.position = [0, height, -deep / 2]
        let back = ModelEntity(mesh: .generatePlane(width: halfWidth * 2, height: height), materials: [occlusion])
        back.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        back.position = [0, height / 2, -deep]
        [left, right, top, back].forEach { interior.addChild($0) }

        // 見えない壁のすぐ内側に、回廊の壁・天井・床を張る（扉越しに本物の景色が透けず、奥まで続く世界に見える）
        let inset: Float = 0.015
        func unlit(_ texture: TextureResource?, fallback: UIColor) -> UnlitMaterial {
            var m = UnlitMaterial(color: fallback)
            if let texture { m.color = .init(tint: .white, texture: .init(texture)) }
            return m
        }
        let wallMaterial = unlit(DoorTextures.innerWall(), fallback: UIColor(red: 0.12, green: 0.09, blue: 0.3, alpha: 1))
        let innerSide = MeshResource.generatePlane(width: deep, height: height)
        let leftIn = ModelEntity(mesh: innerSide, materials: [wallMaterial])
        leftIn.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        leftIn.position = [-halfWidth + inset, height / 2, -deep / 2]
        let rightIn = ModelEntity(mesh: innerSide, materials: [wallMaterial])
        rightIn.orientation = simd_quatf(angle: -.pi / 2, axis: [0, 1, 0])
        rightIn.position = [halfWidth - inset, height / 2, -deep / 2]
        let ceiling = ModelEntity(mesh: .generatePlane(width: halfWidth * 2, depth: deep),
                                  materials: [unlit(DoorTextures.innerCeiling(),
                                                    fallback: UIColor(red: 0.04, green: 0.05, blue: 0.15, alpha: 1))])
        ceiling.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])
        ceiling.position = [0, height - inset, -deep / 2]
        let floor = ModelEntity(mesh: .generatePlane(width: halfWidth * 2, depth: deep),
                                materials: [unlit(DoorTextures.innerFloor(),
                                                  fallback: UIColor(red: 0.08, green: 0.06, blue: 0.18, alpha: 1))])
        floor.position = [0, 0.004, -deep / 2]
        // いちばん奥：夕焼けから夜空へ、まん中に光
        let backdrop = ModelEntity(mesh: .generatePlane(width: halfWidth * 2, height: height),
                                   materials: [unlit(DoorTextures.memorySky(),
                                                     fallback: UIColor(red: 0.45, green: 0.29, blue: 0.74, alpha: 1))])
        backdrop.position = [0, height / 2, -deep + inset]
        // 扉の裏（中から振り返ったときの壁。開口部から本物の世界が見える）
        let frontIn = ModelEntity(mesh: try ArchMesh.wallWithOpening(shape: shape, halfWidth: halfWidth, height: height,
                                                                     z: -0.02),
                                  materials: [UnlitMaterial(color: UIColor(red: 0.10, green: 0.07, blue: 0.24, alpha: 1))])
        frontIn.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        frontIn.position = [0, 0, -0.04]
        [leftIn, rightIn, ceiling, floor, backdrop, frontIn].forEach { interior.addChild($0) }

        // 奥へ続くネオンのアーチ（手前は夕焼け、奥ほど夜空の色）
        let arch = DoorShape(openingWidth: 1.7, openingHeight: 2.6)
        let archPath = arch.openingPath()
        let archMesh = try ArchMesh.frame(path: archPath, width: 0.04, depth: 0.04, name: "tunnel-arch")
        let archZ: [Float] = [-1.0, -2.1, -3.2, -4.3]
        for (i, z) in archZ.enumerated() {
            let a = ModelEntity(mesh: archMesh,
                                materials: [UnlitMaterial(color: DoorTextures.neonColor(at: 0.1 + 0.85 * Float(i) / Float(archZ.count - 1)))])
            a.position = [0, 0, z]
            interior.addChild(a)
        }

        // 奥の光（息をするように明るさが変わる）と、そのにじみ
        farLight = ModelEntity(mesh: .generateSphere(radius: 0.22),
                               materials: [UnlitMaterial(color: UIColor(red: 1.0, green: 0.93, blue: 0.82, alpha: 1))])
        farLight.position = [0, 1.45, -deep + 0.7]
        interior.addChild(farLight)
        if let haloTexture = DoorTextures.radial(key: "far-halo", rgb: (1.0, 0.78, 0.6), alpha: 0.85) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(haloTexture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            let halo = ModelEntity(mesh: .generatePlane(width: 1.8, height: 1.8), materials: [m])
            halo.position = [0, 1.45, -deep + 0.5]
            interior.addChild(halo)
        }

        // 奥へ流れていく光の輪（扉の前の人を、中へ誘う）
        if let ringTexture = DoorTextures.neonRing() {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(ringTexture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            for _ in 0..<2 {
                let r = ModelEntity(mesh: .generatePlane(width: 1.6, height: 1.6), materials: [m])
                r.position = [0, 1.1, -0.3]
                interior.addChild(r)
                beckonRings.append(r)
            }
        }
        Trace.log("扉の向こうの回廊を作りました（奥行き \(deep)m・アーチ \(archZ.count)）")
    }

    /// 浮かぶ思い出の写真と、立ちのぼる光の粒（どちらの見え方でも）
    private func buildFloatingMemories() throws {
        // 思い出の写真を浮かべる場所（写真が届いたら入れる）
        // 回廊（portal）では奥へ並べ、少し大きく。額縁（window）では扉のすぐ向こう
        let deepWorld = style == .portal
        let slots: [(SIMD3<Float>, Float)] = deepWorld
            ? [([-0.75, 1.35, -1.5], 0.32), ([0.8, 1.15, -2.6], -0.28), ([0.0, 1.8, -3.7], 0.0)]
            : [([-0.42, 1.25, -1.15], 0.18), ([0.38, 1.05, -1.55], -0.14), ([0.02, 1.55, -2.05], 0.04)]
        for (i, slot) in slots.enumerated() {
            let holder = Entity()
            holder.position = slot.0
            holder.orientation = simd_quatf(angle: slot.1, axis: [0, 1, 0])
            if deepWorld { holder.scale = .one * 1.35 }
            var backing = PhysicallyBasedMaterial()
            backing.baseColor = .init(tint: .white)
            backing.roughness = .init(floatLiteral: 0.4)
            let card = ModelEntity(mesh: .generateBox(size: [0.5, 0.375, 0.012], cornerRadius: 0.006), materials: [backing])
            let picture = ModelEntity(mesh: .generatePlane(width: 0.47, height: 0.345), materials: [UnlitMaterial(color: .white)])
            picture.position = [0, 0, 0.0065]
            card.addChild(picture)
            holder.addChild(card)
            holder.isEnabled = false
            interior.addChild(holder)
            photoSlots.append(picture)
            floaters.append(Floater(entity: holder, base: slot.0, amplitude: 0.025, speed: 0.55 + Float(i) * 0.12,
                                    phase: Float(i) * 1.7, rises: false))
        }

        // 光の粒（ゆっくり立ちのぼる。金色と、ネオンの色）
        let mote = MeshResource.generateSphere(radius: 0.007)
        let moteColors = [UIColor(red: 1.0, green: 0.93, blue: 0.78, alpha: 1), DoorTextures.neonColor(at: 0.15),
                          DoorTextures.neonColor(at: 0.45), DoorTextures.neonColor(at: 0.9)]
        let moteMaterials: [UnlitMaterial] = moteColors.map {
            var m = UnlitMaterial(color: $0)
            m.blending = .transparent(opacity: .init(floatLiteral: 0.85))
            return m
        }
        let count = deepWorld ? (Perf.isLowMemoryDevice ? 22 : 36) : (Perf.isLowMemoryDevice ? 14 : 22)
        let spanX: Float = deepWorld ? 1.5 : 0.9
        let farZ: Float = deepWorld ? -(Self.worldDeep - 0.4) : -2.2
        let top: Float = deepWorld ? 2.8 : 2.2
        for i in 0..<count {
            let e = ModelEntity(mesh: mote, materials: [moteMaterials[i % moteMaterials.count]])
            let base = SIMD3<Float>(Float.random(in: -spanX...spanX), Float.random(in: 0.1...top), Float.random(in: farZ ... -0.3))
            e.position = base
            e.scale = .one * Float.random(in: 0.6...1.4) * (deepWorld ? 1.3 : 1)
            interior.addChild(e)
            floaters.append(Floater(entity: e, base: base, amplitude: 0.05, speed: Float.random(in: 0.08...0.18),
                                    phase: Float(i) * 0.9, rises: true, wrap: top - 0.1))
        }
    }

    // MARK: 思い出の写真

    func setPhotos(_ images: [UIImage]) {
        for (i, image) in images.prefix(photoSlots.count).enumerated() {
            guard let texture = DoorTextures.photo(image) else { continue }
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(texture))
            photoSlots[i].components.remove(FadeOriginal.self)   // iOS 17 の透明度の控えを、新しい写真で取り直す
            photoSlots[i].model?.materials = [m]
            photoSlots[i].parent?.parent?.isEnabled = true
        }
        Trace.log("扉の向こうに写真を \(min(images.count, photoSlots.count)) 枚置きました")
    }

    // MARK: 動き

    /// 扉の大きさ（1 = 人が通る大きさ）。AR の飾りは base に付くので、扉の大きさを変えても AR の飾りはそのまま
    private(set) var size: Float = 1

    func setSize(_ value: Float) {
        let v = min(max(value, 0.2), 1.5)
        size = v
        root.scale = .one * v
        lastCamLocal = nil
    }

    /// 足もとから現れ、ネオンがまたたいて灯る
    func appear() {
        root.position = [0, -0.05, 0]
        setNeon(0)
        animate(0.9) { [weak self] t in
            guard let self else { return }
            let e = Self.easeOut(t)
            Fade.set(self.root, e)
            self.root.position = [0, -0.05 * (1 - e), 0]
        }
        // 本物のネオン管のように、何度かまたたいてから灯る
        let flicker: [(Float, Float)] = [(0.0, 0), (0.35, 0), (0.42, 0.9), (0.5, 0.15), (0.6, 1), (0.66, 0.35),
                                         (0.78, 1), (1.0, 1)]
        animate(1.3) { [weak self] t in
            guard let self else { return }
            var level: Float = 1
            for i in 0..<(flicker.count - 1) where t >= flicker[i].0 && t <= flicker[i + 1].0 {
                level = t - flicker[i].0 < 0.02 ? flicker[i].1 : flicker[i + 1].1
            }
            self.setNeon(level)
        }
        Trace.log("扉が現れました")
    }

    /// ガラスが溶けて、向こうの世界が見える
    func open() {
        guard !isOpen else { return }
        isOpen = true
        interior.isEnabled = true
        animate(1.1) { [weak self] t in
            guard let self else { return }
            let e = Self.easeInOut(t)
            Fade.set(self.glass, 1 - e)
            self.glass.position = [0, 0, -0.12 * e]
            Fade.set(self.spill, e)
        }
        // 光の縁とネオンが一度強く光ってから落ち着く
        animate(1.4) { [weak self] t in
            let pulse = sin(Float.pi * min(t * 1.4, 1))
            guard let self else { return }
            Fade.set(self.trim, 0.35 + 0.65 * pulse)
            self.setNeon(1)
            self.neonGlow.scale = .one * (1 + 0.12 * pulse)
        }
        // 扉から光の輪が広がる
        burstRing()
        // 木の扉：戸が手前に開く
        if let leaf = decor?.leaf {
            animate(1.2) { t in
                let e = Self.easeInOut(t)
                leaf.orientation = simd_quatf(angle: -1.75 * e, axis: [0, 1, 0])
            }
        }
        // 時空の輪：印が上から順に灯る
        if let lights = decor?.lights, !lights.isEmpty {
            for (i, light) in lights.enumerated() {
                let delay = 0.09 * Double(i)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    Fade.set(light, 1)
                    if i % 3 == 0 { ChimePlayer.shared.play(.sky) }
                }
            }
        }
        // 開く音（夕焼けから夜空へ、下から上へ 3 つの音）
        ChimePlayer.shared.play(.warm)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            ChimePlayer.shared.play(.sakura)
            try? await Task.sleep(nanoseconds: 140_000_000)
            ChimePlayer.shared.play(.sky)
        }
        Trace.log("扉が開きました")
    }

    private func burstRing() {
        ring.isEnabled = true
        animate(1.0) { [weak self] t in
            guard let self else { return }
            let e = Self.easeOut(t)
            self.ring.scale = .one * (0.4 + 2.6 * e)
            Fade.set(self.ring, 0.95 * (1 - t))
            if t >= 1 { self.ring.isEnabled = false }
        }
    }

    /// 扉をくぐったときの光：光の輪が広がり、ネオンが強く光り、鐘が上へ鳴る
    func passFlash() {
        burstRing()
        animate(1.2) { [weak self] t in
            guard let self else { return }
            let pulse = sin(Float.pi * t)
            self.setNeon(1)
            self.neonGlow.scale = .one * (1 + 0.25 * pulse)
        }
        let notes: [ArtworkColor] = [.warm, .sakura, .mint, .sky]
        Task { @MainActor in
            for (i, note) in notes.enumerated() {
                if i > 0 { try? await Task.sleep(nanoseconds: 110_000_000) }
                ChimePlayer.shared.play(note)
            }
        }
        Trace.log("扉をくぐった光を出した")
    }

    /// カメラ（iPhone）が開口部を手前から奥へ通ったか（扉の座標で見る）
    private func checkPassThrough() {
        guard let arView, onPassThrough != nil else { return }
        let camera = root.convert(position: arView.cameraTransform.translation, from: nil)
        defer { lastCamLocal = camera }
        guard let last = lastCamLocal, clock >= passQuietUntil else { return }
        // AR の座標が直されて 1 コマで大きく飛んだときは、くぐったとしない
        guard simd_distance(last, camera) * size < 0.6 else { return }
        guard last.z > 0, camera.z <= 0 else { return }
        let t = last.z / max(last.z - camera.z, 0.0001)
        let p = last + (camera - last) * t
        // 開口部の形（少しゆるめに）の中を通ったか
        guard p.y > -0.15, shape.contains(SIMD2<Float>(p.x, p.y), margin: 0.08) else { return }
        passQuietUntil = clock + 4
        Trace.log(String(format: "扉をくぐった（扉の大きさ %.2f・通った所 x %.2f y %.2f）", size, p.x, p.y))
        onPassThrough?()
    }

    /// TRAIL の地点に着いたときの光：扉の足もとから、夕焼けと夜空の色の光の粒が舞い上がる（big＝歩き終えた）
    func celebrate(big: Bool) {
        let colors: [UIColor] = [UIColor(red: 1.0, green: 0.55, blue: 0.2, alpha: 1),
                                 UIColor(red: 1.0, green: 0.35, blue: 0.6, alpha: 1),
                                 UIColor(red: 0.62, green: 0.4, blue: 1.0, alpha: 1),
                                 UIColor(red: 0.4, green: 0.85, blue: 1.0, alpha: 1)]
        let count = big ? (Perf.isLowMemoryDevice ? 36 : 54) : 20
        let holder = Entity()
        base.addChild(holder)
        let mesh = MeshResource.generateSphere(radius: big ? 0.024 : 0.018)
        var dots: [(Entity, SIMD3<Float>, SIMD3<Float>)] = []
        for i in 0..<count {
            let dot = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: colors[i % colors.count])])
            let angle = Float(i) / Float(count) * 2 * .pi + Float.random(in: -0.25...0.25)
            let spread: Float = big ? Float.random(in: 0.25...1.0) : Float.random(in: 0.3...0.7)
            let start = SIMD3<Float>(cos(angle) * 0.3, 0.04, sin(angle) * 0.3 + 0.25)
            let end = SIMD3<Float>(cos(angle) * spread, big ? Float.random(in: 1.4...2.8) : Float.random(in: 0.8...1.7),
                                   sin(angle) * spread + 0.25)
            dot.position = start
            holder.addChild(dot)
            dots.append((dot, start, end))
        }
        animate(big ? 2.6 : 1.8) { t in
            let e = Self.easeOut(t)
            for (dot, start, end) in dots {
                dot.position = start + (end - start) * e
                dot.scale = SIMD3(repeating: max(0.01, 1 - t * t))
            }
            if t >= 1 { holder.removeFromParent() }
        }
        Trace.log(big ? "TRAIL：歩き終えた光を出した" : "TRAIL：地点に着いた光を出した")
    }

    func remove() {
        subscription?.cancel()
        subscription = nil
        anchorEntity.removeFromParent()
        tweens.removeAll()
        floaters.removeAll()
        beckonRings.removeAll()
        decor = nil
        onPassThrough = nil
    }

    private func animate(_ duration: TimeInterval, _ apply: @escaping (Float) -> Void) {
        tweens.append(Tween(start: clock, duration: duration, apply: apply))
    }

    private func update(dt: TimeInterval) {
        clock += dt
        checkPassThrough()
        decor?.tick(time: Float(clock))
        // 進行中の動き
        tweens.removeAll { tween in
            let t = Float(min(max((clock - tween.start) / tween.duration, 0), 1))
            tween.apply(t)
            return t >= 1
        }
        // 浮かぶ写真と光の粒（開いているあいだだけ動かす）
        guard isOpen else {
            // 閉じているあいだは、ネオンがゆっくり息をする
            if tweens.isEmpty {
                setNeon(0.86 + 0.14 * sin(Float(clock) * 1.6))
            }
            return
        }
        let time = Float(clock)
        // 奥へ流れていく光の輪（2 つが交互に。奥ほど小さく、うすく）と、奥の光の息づかい
        if !beckonRings.isEmpty {
            let travel = Self.worldDeep - 1.0
            for (i, r) in beckonRings.enumerated() {
                let f = (time * 0.32 + Float(i) * 0.5).truncatingRemainder(dividingBy: 1)
                r.position = [0, 1.1 + 0.3 * f, -0.3 - travel * f]
                r.scale = .one * (1.0 - 0.45 * f)
                Fade.set(r, sin(Float.pi * f) * 0.85)
            }
            farLight.scale = .one * (1 + 0.12 * sin(time * 1.4))
        }
        for f in floaters {
            if f.rises {
                var y = f.base.y + f.speed * time
                y = 0.1 + (y - 0.1).truncatingRemainder(dividingBy: f.wrap)
                f.entity.position = [f.base.x + sin(time * 0.7 + f.phase) * f.amplitude, y, f.base.z]
            } else {
                f.entity.position = f.base + [0, sin(time * f.speed + f.phase) * f.amplitude, 0]
            }
        }
    }

    private static func easeOut(_ t: Float) -> Float { 1 - pow(1 - t, 3) }
    private static func easeInOut(_ t: Float) -> Float { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
}
