import ARKit
import Combine
import RealityKit
import UIKit

/// GATE の扉。厚みのある石のアーチ、内側の光の縁、ガラスの面、接地の影。
/// 開くとガラスが消え、扉の向こうの世界（空・思い出の写真・光の粒）が見える。
/// 向こうの世界は、扉の後ろに置いた「見えない壁」で囲み、扉の開口部からだけ見えるようにしている。
@MainActor
final class GateDoor {
    let anchorEntity: AnchorEntity
    let shape = ArchShape()
    private(set) var isOpen = false

    private let root = Entity()
    private let hitBox = ModelEntity()
    private var glass = ModelEntity()
    private var trim = ModelEntity()
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
        anchorEntity.addChild(root)
        root.components.set(OpacityComponent(opacity: 0))
        arView.scene.addAnchor(anchorEntity)
        subscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.update(dt: event.deltaTime)
            }
        }
    }

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

        // 枠：あたたかい白の石。わずかにつやを出し、角の陰影で厚みが分かるように
        var stone = PhysicallyBasedMaterial()
        stone.baseColor = .init(tint: UIColor(red: 0.93, green: 0.92, blue: 0.89, alpha: 1))
        stone.roughness = .init(floatLiteral: 0.58)
        stone.metallic = .init(floatLiteral: 0)
        stone.clearcoat = .init(floatLiteral: 0.18)
        stone.clearcoatRoughness = .init(floatLiteral: 0.35)
        let frame = ModelEntity(mesh: try ArchMesh.frame(path: path, width: shape.frameWidth, depth: shape.depth,
                                                         name: "frame"),
                                materials: [stone])
        root.addChild(frame)

        // 足もとの踏み石
        var step = PhysicallyBasedMaterial()
        step.baseColor = .init(tint: UIColor(red: 0.84, green: 0.83, blue: 0.80, alpha: 1))
        step.roughness = .init(floatLiteral: 0.7)
        let slab = ModelEntity(mesh: .generateBox(size: [shape.outerWidth + 0.12, 0.035, shape.depth + 0.24],
                                                  cornerRadius: 0.012),
                               materials: [step])
        slab.position = [0, 0.0175, 0]
        root.addChild(slab)

        // 内側の光の縁（開口部のふちに沿う細い線）
        let inset = path.map { (p: $0.p + $0.n * 0.012, n: $0.n) }
        var light = UnlitMaterial(color: UIColor(red: 1.0, green: 0.86, blue: 0.58, alpha: 1))
        light.blending = .transparent(opacity: .init(floatLiteral: 1))
        trim = ModelEntity(mesh: try ArchMesh.frame(path: inset, width: 0.012, depth: shape.depth + 0.006, name: "trim"),
                           materials: [light])
        trim.components.set(OpacityComponent(opacity: 0.55))
        root.addChild(trim)

        // ガラスの面（開く前）
        var glassMaterial = PhysicallyBasedMaterial()
        glassMaterial.baseColor = .init(tint: UIColor(red: 0.84, green: 0.95, blue: 0.92, alpha: 1))
        glassMaterial.roughness = .init(floatLiteral: 0.06)
        glassMaterial.metallic = .init(floatLiteral: 0.0)
        glassMaterial.emissiveColor = .init(color: UIColor(red: 0.62, green: 0.86, blue: 0.78, alpha: 1))
        glassMaterial.emissiveIntensity = 0.25
        glassMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.32))
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

        // 開いたときに手前の地面に広がる光
        if let spillTexture = DoorTextures.radial(key: "spill", rgb: (1.0, 0.85, 0.58), alpha: 0.55) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(spillTexture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            spill = ModelEntity(mesh: .generatePlane(width: 1.6, depth: 1.8), materials: [m])
            spill.position = [0, 0.004, 0.75]
            spill.components.set(OpacityComponent(opacity: 0))
            root.addChild(spill)
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

        // 光の粒（ゆっくり立ちのぼる）
        let mote = MeshResource.generateSphere(radius: 0.007)
        var moteMaterial = UnlitMaterial(color: UIColor(red: 1.0, green: 0.95, blue: 0.82, alpha: 1))
        moteMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.85))
        let count = Perf.isLowMemoryDevice ? 14 : 22
        for i in 0..<count {
            let e = ModelEntity(mesh: mote, materials: [moteMaterial])
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
            photoSlots[i].model?.materials = [m]
            photoSlots[i].parent?.parent?.isEnabled = true
        }
        Trace.log("扉の向こうに写真を \(min(images.count, photoSlots.count)) 枚置きました")
    }

    // MARK: 動き

    /// 足もとから光が満ちるように現れる
    func appear() {
        root.position = [0, -0.05, 0]
        animate(0.9) { [weak self] t in
            guard let self else { return }
            let e = Self.easeOut(t)
            self.root.components.set(OpacityComponent(opacity: e))
            self.root.position = [0, -0.05 * (1 - e), 0]
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
            self.glass.components.set(OpacityComponent(opacity: 1 - e))
            self.glass.position = [0, 0, -0.12 * e]
            self.spill.components.set(OpacityComponent(opacity: e))
        }
        // 光の縁が一度強く光ってから落ち着く
        animate(1.4) { [weak self] t in
            let pulse = sin(Float.pi * min(t * 1.4, 1))
            self?.trim.components.set(OpacityComponent(opacity: 0.6 + 0.4 * pulse))
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
            // 閉じているあいだは、光の縁がゆっくり息をする
            if tweens.isEmpty {
                let breathe = 0.5 + 0.12 * sin(Float(clock) * 1.6)
                trim.components.set(OpacityComponent(opacity: breathe))
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
