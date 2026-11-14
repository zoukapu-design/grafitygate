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
    let anchorEntity: AnchorEntity
    let shape = ArchShape()
    private(set) var isOpen = false
    /// 扉と作品を載せる台。見る人が指で少し動かした分（自分の画面だけ）は、この台の位置・向きで持つ
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

    init(anchor: ARAnchor, in arView: ARView) throws {
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

    /// 指で動かした分（印からの位置・向き）。扉と作品が一緒に動く
    func setNudge(position: SIMD3<Float>, yaw: Float) {
        nudgePosition = position
        nudgeYaw = yaw
        base.transform = Transform(scale: .one, rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]), translation: position)
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

        // 枠：夜の色の石。つやを出して、ネオンの光と景色が映るように
        var stone = PhysicallyBasedMaterial()
        stone.baseColor = .init(tint: UIColor(red: 0.15, green: 0.14, blue: 0.21, alpha: 1))
        stone.roughness = .init(floatLiteral: 0.34)
        stone.metallic = .init(floatLiteral: 0.08)
        stone.clearcoat = .init(floatLiteral: 0.65)
        stone.clearcoatRoughness = .init(floatLiteral: 0.18)
        let frame = ModelEntity(mesh: try ArchMesh.frame(path: path, width: shape.frameWidth, depth: shape.depth,
                                                         name: "frame"),
                                materials: [stone])
        root.addChild(frame)

        // 足もとの踏み石
        var step = PhysicallyBasedMaterial()
        step.baseColor = .init(tint: UIColor(red: 0.22, green: 0.21, blue: 0.28, alpha: 1))
        step.roughness = .init(floatLiteral: 0.5)
        step.clearcoat = .init(floatLiteral: 0.3)
        let slab = ModelEntity(mesh: .generateBox(size: [shape.outerWidth + 0.12, 0.035, shape.depth + 0.24],
                                                  cornerRadius: 0.012),
                               materials: [step])
        slab.position = [0, 0.0175, 0]
        root.addChild(slab)

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
        glassMaterial.baseColor = .init(tint: UIColor(red: 0.30, green: 0.24, blue: 0.56, alpha: 1))
        glassMaterial.roughness = .init(floatLiteral: 0.05)
        glassMaterial.metallic = .init(floatLiteral: 0.0)
        glassMaterial.emissiveColor = .init(color: UIColor(red: 0.42, green: 0.30, blue: 0.86, alpha: 1))
        glassMaterial.emissiveIntensity = 0.3
        glassMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.38))
        glass = ModelEntity(mesh: try ArchMesh.opening(path: inset, z: 0.004, name: "glass"), materials: [glassMaterial])
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
        if let texture = DoorTextures.radial(key: "neon-ground", rgb: (1.0, 0.36, 0.55), alpha: 0.32) {
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
            ring.position = [0, shape.innerHeight * 0.55, shape.depth / 2 + 0.05]
            ring.isEnabled = false
            root.addChild(ring)
        }

        // 陰影をはっきりさせる、やわらかい光（影は作らない＝軽く）
        let sun = DirectionalLight()
        sun.light.intensity = 1400
        sun.light.color = UIColor(red: 1.0, green: 0.97, blue: 0.92, alpha: 1)
        sun.orientation = simd_quatf(angle: -.pi / 3.2, axis: [1, 0, 0]) * simd_quatf(angle: .pi / 6, axis: [0, 1, 0])
        root.addChild(sun)

        // 押した所が扉かを見分ける当たり判定
        hitBox.components.set(CollisionComponent(shapes: [
            .generateBox(size: [shape.outerWidth, shape.outerHeight, 0.4])
        ]))
        hitBox.position = [0, shape.outerHeight / 2, 0]
        root.addChild(hitBox)
    }

    /// ネオンの管を、高さの帯ごとに色を変えて作る（足を細かく分けて、色が少しずつ変わるように）
    private func buildNeon() throws {
        let inward: Float = 0.03, tube: Float = 0.024
        // 開口部のふち（足の部分も細かく分ける）
        var outline: [(p: SIMD2<Float>, n: SIMD2<Float>)] = []
        let legSteps = 12
        for i in 0...legSteps {
            outline.append((p: SIMD2(-shape.radius, shape.legHeight * Float(i) / Float(legSteps)), n: SIMD2(1, 0)))
        }
        for item in shape.openingPath().dropFirst().dropLast() { outline.append(item) }
        for i in (0...legSteps).reversed() {
            outline.append((p: SIMD2(shape.radius, shape.legHeight * Float(i) / Float(legSteps)), n: SIMD2(-1, 0)))
        }
        let inside = outline.map { (p: $0.p + $0.n * inward, n: $0.n) }
        let top = shape.innerHeight
        // 3 点ずつの帯（となりと 1 点重ねて、すき間を作らない）
        var start = 0
        while start < inside.count - 1 {
            let end = min(start + 3, inside.count - 1)
            let band = Array(inside[start...end])
            let midY = band.map(\.p.y).reduce(0, +) / Float(band.count)
            var m = UnlitMaterial(color: DoorTextures.neonColor(at: midY / top))
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
        if let texture = DoorTextures.neonGlow(shape: shape, margin: margin) {
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
        let halfWidth: Float = 1.5
        let height: Float = 2.7
        let deep: Float = 2.6
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

        // 向こうの空
        if let sky = DoorTextures.memorySky() {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(sky))
            let backdrop = ModelEntity(mesh: .generatePlane(width: halfWidth * 2 - 0.02, height: height - 0.02),
                                       materials: [m])
            backdrop.position = [0, height / 2, -deep + 0.03]
            interior.addChild(backdrop)
        }
        // 光の床
        if let floorTexture = DoorTextures.radial(key: "floor", rgb: (1.0, 0.93, 0.78), alpha: 0.9) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(floorTexture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            let floor = ModelEntity(mesh: .generatePlane(width: halfWidth * 2 - 0.1, depth: deep - 0.1), materials: [m])
            floor.position = [0, 0.006, -deep / 2]
            interior.addChild(floor)
        }

        // 思い出の写真を浮かべる場所（写真が届いたら入れる）
        let slots: [(SIMD3<Float>, Float)] = [([-0.42, 1.25, -1.15], 0.18), ([0.38, 1.05, -1.55], -0.14),
                                              ([0.02, 1.55, -2.05], 0.04)]
        for (i, slot) in slots.enumerated() {
            let holder = Entity()
            holder.position = slot.0
            holder.orientation = simd_quatf(angle: slot.1, axis: [0, 1, 0])
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
        let count = Perf.isLowMemoryDevice ? 14 : 22
        for i in 0..<count {
            let e = ModelEntity(mesh: mote, materials: [moteMaterials[i % moteMaterials.count]])
            let base = SIMD3<Float>(Float.random(in: -0.9...0.9), Float.random(in: 0.1...2.2), Float.random(in: -2.2 ... -0.3))
            e.position = base
            e.scale = .one * Float.random(in: 0.6...1.4)
            interior.addChild(e)
            floaters.append(Floater(entity: e, base: base, amplitude: 0.05, speed: Float.random(in: 0.08...0.18),
                                    phase: Float(i) * 0.9, rises: true))
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
        ring.isEnabled = true
        animate(1.0) { [weak self] t in
            guard let self else { return }
            let e = Self.easeOut(t)
            self.ring.scale = .one * (0.4 + 2.6 * e)
            Fade.set(self.ring, 0.95 * (1 - t))
            if t >= 1 { self.ring.isEnabled = false }
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

    func remove() {
        subscription?.cancel()
        subscription = nil
        anchorEntity.removeFromParent()
        tweens.removeAll()
        floaters.removeAll()
    }

    private func animate(_ duration: TimeInterval, _ apply: @escaping (Float) -> Void) {
        tweens.append(Tween(start: clock, duration: duration, apply: apply))
    }

    private func update(dt: TimeInterval) {
        clock += dt
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
        for f in floaters {
            if f.rises {
                var y = f.base.y + f.speed * time
                y = 0.1 + (y - 0.1).truncatingRemainder(dividingBy: 2.1)
                f.entity.position = [f.base.x + sin(time * 0.7 + f.phase) * f.amplitude, y, f.base.z]
            } else {
                f.entity.position = f.base + [0, sin(time * f.speed + f.phase) * f.amplitude, 0]
            }
        }
    }

    private static func easeOut(_ t: Float) -> Float { 1 - pow(1 - t, 3) }
    private static func easeInOut(_ t: Float) -> Float { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
}
