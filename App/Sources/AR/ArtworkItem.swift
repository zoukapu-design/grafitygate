import AVFoundation
import RealityKit
import UIKit

/// GATE に置かれた作品 1 つ。種類ごとの見た目と、触れたときの動き（光る・ゆれる・波紋・はじける・はねる・流す）。
/// 位置・向き・大きさは扉が基準（`root` を扉の印の下に置く）。毎コマ `update` で動かす。
@MainActor
final class ArtworkItem {
    private(set) var artwork: Artwork
    let root = Entity()
    let isPreview: Bool
    /// 触れる判定の半径（root の中の長さ。大きさを掛ける前）
    private(set) var radius: Float = 0.3

    /// ゆれる・はねるで動かす部分
    private let body = Entity()
    /// 写真パネルの面（写真が届いたら作り直す）
    private let panel = Entity()

    /// 映像パネルの面（流すあいだは映像、ふだんは表紙の絵）と「▶」の印
    private var screen: ModelEntity?
    private var posterMaterial: UnlitMaterial?
    private var badge: ModelEntity?
    /// 声の玉のまわりの音の輪
    private var soundRings: [ModelEntity] = []

    // 流す
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var audio: AudioPlaybackController?
    private var fallbackAudio: AVAudioPlayer?
    private var playToken = UUID()
    private var pulseClock: Float = 0
    private(set) var isPlaying = false
    /// 「流す」の動きが起きたとき（ファイルを受け取って流すのは ArtworkScene・ARExperienceModel）
    var onPlay: (() -> Void)?
    /// 流し終えた・止めたとき
    var onPlaybackEnd: (() -> Void)?

    private var halo: ModelEntity?
    private var haloFacesCamera = false
    private var haloBaseOpacity: Float = 0.8
    private var outerHalo: ModelEntity?
    private var core: ModelEntity?

    private struct Petal {
        let entity: Entity
        var angle: Float
        let radius: Float
        let height: Float
        let speed: Float
        let spinAxis: SIMD3<Float>
        let spinSpeed: Float
        let phase: Float
    }
    private var petals: [Petal] = []

    private struct Mote {
        let entity: ModelEntity
        let radius: Float
        let tilt: simd_quatf
        let speed: Float
        var angle: Float
    }
    private var motes: [Mote] = []

    private struct Ripple {
        let entity: ModelEntity
        var age: Float
    }
    private var ripples: [Ripple] = []

    private struct Spark {
        let entity: ModelEntity
        var velocity: SIMD3<Float>
        var age: Float
    }
    private var sparks: [Spark] = []

    // 動きの状態
    private var time = Float.random(in: 0...10)
    private var glow: Float = 0
    private var near: Float = 0
    private var hover: Float = 0
    private var hoverTarget: Float = 0
    private(set) var isNear = false
    private var swayAngle: Float = 0
    private var swayVelocity: Float = 0
    private var bounce: Float = 0
    private var bounceVelocity: Float = 0
    private var spread: Float = 1
    private var spreadVelocity: Float = 0
    private var swirlBoost: Float = 0
    private var reveal: Float = 1
    private var lastFired: [Int: TimeInterval] = [:]

    private var color: ArtworkColor { artwork.artColor }

    init(_ artwork: Artwork, image: UIImage?, preview: Bool = false) {
        self.artwork = artwork
        isPreview = preview
        root.name = "artwork"
        root.addChild(body)
        MainWatch.run("作品を組み立てる（\(artwork.artKind.label)）") {
            switch artwork.artKind {
            case .photo, .video: buildPhoto(image)
            case .text: buildText()
            case .voice: buildVoice()
            case .petals: buildPetals()
            case .light: buildLight()
            }
        }
        applyPose()
        if !preview {
            root.components.set(CollisionComponent(shapes: [.generateSphere(radius: radius)]))
        }
        Fade.set(root, preview ? 0.75 : 1)
    }

    // MARK: 置き場所

    func applyPose() {
        root.position = artwork.position
        root.orientation = simd_quatf(angle: artwork.yaw, axis: [0, 1, 0])
        root.scale = .one * artwork.scale
    }

    func setPose(position: SIMD3<Float>, yaw: Float, scale: Float, revision: Int? = nil) {
        artwork.px = position.x
        artwork.py = position.y
        artwork.pz = position.z
        artwork.yaw = yaw
        artwork.scale = scale
        if let revision { artwork.revision = revision }
        applyPose()
    }

    /// 押した所がこの作品か
    func contains(_ entity: Entity?) -> Bool {
        var e = entity
        while let current = e {
            if current === root { return true }
            e = current.parent
        }
        return false
    }

    /// 作品の中心（世界の座標）と、触れる判定の半径（m）
    var worldCenter: SIMD3<Float> { root.position(relativeTo: nil) }
    var worldRadius: Float { radius * artwork.scale }

    // MARK: 種類ごとの見た目

    private func buildPhoto(_ image: UIImage?) {
        body.addChild(panel)
        setPhoto(image)
    }

    /// 写真パネル：白い額（つやのある厚み）に写真、後ろにやわらかい光。
    /// 映像パネルも同じ形で、ふだんは表紙の絵と「▶」の印を見せる。
    func setPhoto(_ image: UIImage?) {
        let kind = artwork.artKind
        guard kind == .photo || kind == .video, !isPlaying else { return }
        panel.children.removeAll()
        let longest: Float = 0.55
        var aspect: Float = 4 / 3
        if let image, image.size.height > 0 { aspect = Float(image.size.width / image.size.height) }
        aspect = min(max(aspect, 0.5), 2.0)
        let w = aspect >= 1 ? longest : longest * aspect
        let h = aspect >= 1 ? longest / aspect : longest
        let border: Float = 0.026

        var frameMaterial = PhysicallyBasedMaterial()
        frameMaterial.baseColor = .init(tint: UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1))
        frameMaterial.roughness = .init(floatLiteral: 0.42)
        frameMaterial.clearcoat = .init(floatLiteral: 0.35)
        frameMaterial.clearcoatRoughness = .init(floatLiteral: 0.2)
        let frame = ModelEntity(mesh: .generateBox(size: [w + border * 2, h + border * 2, 0.014], cornerRadius: 0.008),
                                materials: [frameMaterial])
        panel.addChild(frame)

        var pictureMaterial = UnlitMaterial(color: UIColor(white: 0.92, alpha: 1))
        if let image, let texture = DoorTextures.photo(image) {
            pictureMaterial.color = .init(tint: .white, texture: .init(texture))
        }
        let picture = ModelEntity(mesh: .generatePlane(width: w, height: h, cornerRadius: 0.004),
                                  materials: [pictureMaterial])
        picture.position = [0, 0, 0.0075]
        panel.addChild(picture)
        if kind == .video {
            screen = picture
            posterMaterial = pictureMaterial
            if let texture = DoorTextures.playBadge() {
                var m = UnlitMaterial()
                m.color = .init(tint: .white, texture: .init(texture))
                m.blending = .transparent(opacity: .init(floatLiteral: 1))
                let mark = ModelEntity(mesh: .generatePlane(width: 0.11, height: 0.11), materials: [m])
                mark.position = [0, 0, 0.0095]
                panel.addChild(mark)
                badge = mark
            }
        }

        if let texture = DoorTextures.halo(color) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(texture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            let glowPlane = ModelEntity(mesh: .generatePlane(width: (w + border * 2) * 2.0, height: (h + border * 2) * 2.0),
                                        materials: [m])
            glowPlane.position = [0, 0, -0.03]
            panel.addChild(glowPlane)
            halo = glowPlane
            haloBaseOpacity = 0.75
        }
        radius = max(w, h) / 2 + 0.08
        if !isPreview {
            root.components.set(CollisionComponent(shapes: [.generateSphere(radius: radius)]))
        }
    }

    /// 光る文字：ひらがな・漢字も読める太めの字を、厚みのある光の文字にする
    private func buildText() {
        let text = String(artwork.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let size: CGFloat = 0.07
        let font = UIFont(name: "HiraginoSans-W6", size: size) ?? .systemFont(ofSize: size, weight: .bold)
        let mesh = MeshResource.generateText(text, extrusionDepth: 0.012, font: font,
                                             containerFrame: CGRect(x: 0, y: 0, width: 0.84, height: 0.6),
                                             alignment: .center, lineBreakMode: .byCharWrapping)
        let (r, g, b) = color.rgb
        let letters = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: UIColor(red: r, green: g, blue: b, alpha: 1))])
        let bounds = mesh.bounds
        letters.position = -bounds.center
        body.addChild(letters)

        let width = max(bounds.extents.x, 0.1)
        let height = max(bounds.extents.y, 0.07)
        if let texture = DoorTextures.halo(color) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(texture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            let glowPlane = ModelEntity(mesh: .generatePlane(width: width * 1.5 + 0.24, height: height * 2.4 + 0.2),
                                        materials: [m])
            glowPlane.position = [0, 0, -0.03]
            body.addChild(glowPlane)
            halo = glowPlane
            haloBaseOpacity = 0.55
        }
        radius = max(width, height) / 2 + 0.08
    }

    /// 花びら：柱のまわりをくるくる舞う。はじけると外へ広がって、またもどる
    private func buildPetals() {
        let count = Perf.isLowMemoryDevice ? 12 : 18
        if let texture = DoorTextures.petal(color) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(texture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            let mesh = MeshResource.generatePlane(width: 0.036, height: 0.046)
            for i in 0..<count {
                // 片面の板を背中合わせに 2 枚＝どちらから見ても見える
                let holder = Entity()
                let front = ModelEntity(mesh: mesh, materials: [m])
                let back = ModelEntity(mesh: mesh, materials: [m])
                back.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
                holder.addChild(front)
                holder.addChild(back)
                holder.scale = .one * Float.random(in: 0.8...1.25)
                body.addChild(holder)
                let axis = simd_normalize(SIMD3<Float>(Float.random(in: -1...1), Float.random(in: -1...1), Float.random(in: -1...1)) + [0, 0.001, 0])
                petals.append(Petal(entity: holder, angle: Float(i) / Float(count) * 2 * .pi + Float.random(in: -0.3...0.3),
                                    radius: Float.random(in: 0.12...0.3), height: Float.random(in: -0.26...0.26),
                                    speed: Float.random(in: 0.35...0.7), spinAxis: axis,
                                    spinSpeed: Float.random(in: 0.8...2.2), phase: Float.random(in: 0...6)))
            }
        }
        if let texture = DoorTextures.halo(color) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(texture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            let glowPlane = ModelEntity(mesh: .generatePlane(width: 0.7, height: 0.7), materials: [m])
            root.addChild(glowPlane)
            halo = glowPlane
            haloFacesCamera = true
            haloBaseOpacity = 0.35
        }
        radius = 0.36
    }

    /// 声の玉：小さな光の芯と、まわりの音の輪。流すあいだは輪がふるえ、波紋が広がる
    private func buildVoice() {
        let (r, g, b) = color.rgb
        let coreEntity = ModelEntity(mesh: .generateSphere(radius: 0.05),
                                     materials: [UnlitMaterial(color: UIColor(red: min(r + 0.2, 1), green: min(g + 0.2, 1),
                                                                              blue: min(b + 0.2, 1), alpha: 1))])
        body.addChild(coreEntity)
        core = coreEntity
        if let texture = DoorTextures.halo(color) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(texture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            let inner = ModelEntity(mesh: .generatePlane(width: 0.36, height: 0.36), materials: [m])
            root.addChild(inner)
            halo = inner
            haloFacesCamera = true
            haloBaseOpacity = 0.85
        }
        if let texture = DoorTextures.ring(color) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(texture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            for size: Float in [0.2, 0.3] {
                let ring = ModelEntity(mesh: .generatePlane(width: size, height: size), materials: [m])
                Fade.set(ring, 0.3)
                body.addChild(ring)
                soundRings.append(ring)
            }
        }
        radius = 0.24
    }

    /// 光の玉：芯・内と外の光・まわりをめぐる小さな光
    private func buildLight() {
        let (r, g, b) = color.rgb
        let coreEntity = ModelEntity(mesh: .generateSphere(radius: 0.045),
                                     materials: [UnlitMaterial(color: UIColor(red: min(r + 0.15, 1), green: min(g + 0.15, 1),
                                                                              blue: min(b + 0.15, 1), alpha: 1))])
        body.addChild(coreEntity)
        core = coreEntity
        if let texture = DoorTextures.halo(color) {
            var m = UnlitMaterial()
            m.color = .init(tint: .white, texture: .init(texture))
            m.blending = .transparent(opacity: .init(floatLiteral: 1))
            let inner = ModelEntity(mesh: .generatePlane(width: 0.34, height: 0.34), materials: [m])
            root.addChild(inner)
            halo = inner
            haloFacesCamera = true
            haloBaseOpacity = 0.95
            let outer = ModelEntity(mesh: .generatePlane(width: 0.95, height: 0.95), materials: [m])
            Fade.set(outer, 0.22)
            root.addChild(outer)
            outerHalo = outer
        }
        let moteMesh = MeshResource.generateSphere(radius: 0.008)
        let moteMaterial = UnlitMaterial(color: UIColor(red: r, green: g, blue: b, alpha: 1))
        for i in 0..<6 {
            let e = ModelEntity(mesh: moteMesh, materials: [moteMaterial])
            body.addChild(e)
            let tilt = simd_quatf(angle: Float.random(in: -0.9...0.9), axis: [1, 0, 0]) *
                simd_quatf(angle: Float(i) * 1.05, axis: [0, 1, 0])
            motes.append(Mote(entity: e, radius: Float.random(in: 0.11...0.2), tilt: tilt,
                              speed: Float.random(in: 0.9...1.6) * (i % 2 == 0 ? 1 : -1), angle: Float(i)))
        }
        radius = 0.26
    }

    // MARK: 反応

    /// きっかけ（近づいた・触れた・押した・扉が開いた）に合うルールを動かす。何か動いたら true。
    @discardableResult
    func fire(_ trigger: ArtworkTrigger, now: TimeInterval) -> Bool {
        var matched = false
        var did = false
        for (i, rule) in artwork.rules.enumerated() where rule.trigger == trigger.rawValue {
            guard let action = ArtworkAction(rawValue: rule.action) else { continue }
            matched = true
            let cooldown = Double(rule.cooldown_ms ?? Self.defaultCooldownMS(trigger)) / 1000
            if let last = lastFired[i], now - last < cooldown { continue }
            lastFired[i] = now
            perform(action)
            did = true
        }
        // ルールが無い作品も、押す・触れると少し光る
        if !matched, trigger == .tap || trigger == .touch {
            if let last = lastFired[-1], now - last < 0.4 { return false }
            lastFired[-1] = now
            perform(.glow)
            did = true
        }
        return did
    }

    private static func defaultCooldownMS(_ trigger: ArtworkTrigger) -> Int {
        switch trigger {
        case .approach: return 5000
        case .touch: return 1000
        case .tap: return 500
        case .open: return 0
        }
    }

    /// 「視差効果を減らす」の設定のときは、点滅・飛び散る光をやめ、やわらかく光るだけにする
    static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    func perform(_ action: ArtworkAction) {
        if action == .play {
            glow = max(glow, 0.6)
            if !isPreview { onPlay?() }
            return
        }
        if Self.reduceMotion, action != .chime {
            glow = max(glow, 0.6)
            return
        }
        switch action {
        case .glow:
            glow = 1
        case .sway:
            swayVelocity += (swayAngle >= 0 ? 1 : -1) * 2.6
            glow = max(glow, 0.35)
        case .ripple:
            spawnRipple()
            glow = max(glow, 0.5)
        case .burst:
            if artwork.artKind == .petals {
                spreadVelocity += 7
                swirlBoost = 3
            } else {
                spawnSparks()
            }
            glow = max(glow, 0.6)
        case .bounce:
            bounceVelocity += 1.5
            glow = max(glow, 0.35)
        case .chime:
            ChimePlayer.shared.play(color)
            glow = max(glow, 0.7)
        case .play:
            break
        }
    }

    // MARK: 流す（映像パネル・声の玉）

    /// 手もとのファイルを流す（映像はパネルの面に、声は玉の位置から聞こえる音で）
    func startPlayback(_ file: URL) {
        stopPlayback(notify: false)
        ARAudio.prepare()
        let token = UUID()
        playToken = token
        switch artwork.artKind {
        case .video:
            guard let screen else { return }
            let item = AVPlayerItem(url: file)
            let p = AVPlayer(playerItem: item)
            screen.model?.materials = [VideoMaterial(avPlayer: p)]
            badge?.isEnabled = false
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                                 queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.playToken == token else { return }
                    self.stopPlayback(notify: true)
                }
            }
            player = p
            p.play()
        case .voice:
            do {
                let resource = try AudioFileResource.load(contentsOf: file, inputMode: .spatial,
                                                          loadingStrategy: .stream, shouldLoop: false)
                let controller = body.playAudio(resource)
                controller.completionHandler = { [weak self] in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.playToken == token else { return }
                            self.stopPlayback(notify: true)
                        }
                    }
                }
                audio = controller
            } catch {
                // 位置から聞こえる音にできないときは、ふつうに流す（遠いと小さく）
                Trace.log("声の玉：位置から聞こえる音にできませんでした（\(error.localizedDescription)）。ふつうに流します")
                guard let p = try? AVAudioPlayer(contentsOf: file) else {
                    Trace.log("声の玉：声のファイルを開けませんでした")
                    return
                }
                p.play()
                fallbackAudio = p
            }
        default:
            return
        }
        isPlaying = true
        pulseClock = 0
        glow = max(glow, 0.8)
        Trace.log("作品を流します（\(artwork.artKind.label)・\(String(format: "%.1f", artwork.duration ?? 0)) 秒）")
    }

    /// 止める（notify が true なら、流し終えたことを知らせる）
    func stopPlayback(notify: Bool = true) {
        playToken = UUID()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        if let screen, let posterMaterial { screen.model?.materials = [posterMaterial] }
        badge?.isEnabled = true
        audio?.completionHandler = nil
        audio?.stop()
        audio = nil
        fallbackAudio?.stop()
        fallbackAudio = nil
        let was = isPlaying
        isPlaying = false
        if was, notify { onPlaybackEnd?() }
    }

    /// 近づいたか（1.4m 以内で近い、1.9m より離れたら離れた）。近づいた瞬間だけ true。
    func updateNear(distance: Float) -> Bool {
        if !isNear, distance < 1.4 {
            isNear = true
            return true
        }
        if isNear, distance > 1.9 { isNear = false }
        return false
    }

    /// 手が近くにあるあいだ、少し明るくする
    func setHover(_ on: Bool) {
        hoverTarget = on ? 1 : 0
    }

    /// 現れる（足もとから光が満ちるように）
    func appear() {
        reveal = 0
        Fade.set(root, 0)
    }

    // MARK: 波紋・光の粒

    private func spawnRipple() {
        guard let texture = DoorTextures.ring(color) else { return }
        if ripples.count >= 3, let oldest = ripples.first {
            oldest.entity.removeFromParent()
            ripples.removeFirst()
        }
        var m = UnlitMaterial()
        m.color = .init(tint: .white, texture: .init(texture))
        m.blending = .transparent(opacity: .init(floatLiteral: 1))
        let size = radius * 1.6
        let ring = ModelEntity(mesh: .generatePlane(width: size, height: size), materials: [m])
        Fade.set(ring, 0.9)
        root.addChild(ring)
        ripples.append(Ripple(entity: ring, age: 0))
    }

    private func spawnSparks() {
        let (r, g, b) = color.rgb
        let material = UnlitMaterial(color: UIColor(red: min(r + 0.1, 1), green: min(g + 0.1, 1), blue: min(b + 0.1, 1), alpha: 1))
        let mesh = MeshResource.generateSphere(radius: 0.009)
        let count = Perf.isLowMemoryDevice ? 10 : 16
        for spark in sparks { spark.entity.removeFromParent() }
        sparks.removeAll()
        for _ in 0..<count {
            let e = ModelEntity(mesh: mesh, materials: [material])
            var dir = SIMD3<Float>(Float.random(in: -1...1), Float.random(in: -0.6...1), Float.random(in: -1...1))
            if simd_length(dir) < 0.01 { dir = [0, 1, 0] }
            dir = simd_normalize(dir)
            e.position = dir * 0.04
            e.scale = .one * Float.random(in: 0.7...1.4)
            root.addChild(e)
            sparks.append(Spark(entity: e, velocity: dir * Float.random(in: 0.55...1.15), age: 0))
        }
    }

    // MARK: 毎コマ

    func update(dt rawDT: Float, cameraWorld: SIMD3<Float>) {
        let dt = min(rawDT, 0.05)
        time += dt

        // ばねの動き（ゆれる・はねる・広がる）
        swayVelocity += (-28 * swayAngle - 3.2 * swayVelocity) * dt
        swayAngle += swayVelocity * dt
        bounceVelocity += (-70 * bounce - 7 * bounceVelocity) * dt
        bounce += bounceVelocity * dt
        spreadVelocity += (-20 * (spread - 1) - 4 * spreadVelocity) * dt
        spread += spreadVelocity * dt
        glow = max(0, glow - dt * 0.9)
        swirlBoost = max(0, swirlBoost - dt * 1.8)
        near += ((isNear ? 1 : 0) - near) * min(1, dt * 3)
        hover += (hoverTarget - hover) * min(1, dt * 6)

        let kind = artwork.artKind
        let bob: Float = (kind == .photo || kind == .text || kind == .video) ? sin(time * 0.9) * 0.012 : sin(time * 0.7) * 0.02
        if reveal < 1 {
            reveal = min(1, reveal + dt / 0.8)
            let e = 1 - pow(1 - reveal, 3)
            Fade.set(root, e)
            body.position = [0, bob + bounce - 0.06 * (1 - e), 0]
        } else {
            body.position = [0, bob + bounce, 0]
        }
        if isPreview {
            Fade.set(root, 0.62 + 0.18 * sin(time * 4))
        }
        body.orientation = simd_quatf(angle: swayAngle, axis: [0, 1, 0]) * simd_quatf(angle: swayAngle * 0.3, axis: [0, 0, 1])

        // カメラの位置（作品の中の座標）。光と波紋をカメラに向ける
        let camera = root.convert(position: cameraWorld, from: nil)

        // 光の強さ：近づく・手が近い・反応で明るく
        let intensity = min(1, 0.42 + 0.22 * near + 0.25 * hover + 0.7 * glow)
        if let halo {
            Fade.set(halo, haloBaseOpacity * intensity)
            halo.scale = .one * (1 + 0.22 * glow + 0.06 * near)
            if haloFacesCamera { face(halo, toward: camera) }
        }
        if let outerHalo {
            Fade.set(outerHalo, 0.16 + 0.22 * glow + 0.06 * near)
            face(outerHalo, toward: camera)
        }
        if let core {
            core.scale = .one * (1 + 0.06 * sin(time * 2.1) + 0.3 * glow)
        }

        // 流しているあいだ：声は波紋を少しずつ広げ、映像は遠いと小さく聞こえる
        if isPlaying {
            let distance = simd_length(camera) * artwork.scale
            glow = max(glow, 0.35)
            if kind == .voice, !Self.reduceMotion {
                pulseClock += dt
                if pulseClock > 0.85 {
                    pulseClock = 0
                    spawnRipple()
                }
            }
            if let player { player.volume = min(1, 1.6 / (distance + 0.6)) }
            if let fallbackAudio {
                fallbackAudio.volume = min(1, 1.6 / (distance + 0.6))
                if !fallbackAudio.isPlaying { stopPlayback(notify: true) }
            }
        }

        // 声の玉の音の輪
        for (i, ring) in soundRings.enumerated() {
            let phase = Float(i) * 1.7
            let wave = isPlaying ? 0.12 * sin(time * 7 + phase) : 0.04 * sin(time * 1.6 + phase)
            ring.scale = .one * (1 + wave)
            Fade.set(ring, isPlaying ? 0.55 : 0.28 + 0.1 * near)
            face(ring, toward: body.convert(position: camera, from: root))
        }

        // 花びら
        for i in petals.indices {
            petals[i].angle += petals[i].speed * (1 + swirlBoost) * dt
            let p = petals[i]
            let r = p.radius * spread
            let y = p.height * (0.65 + 0.35 * spread) + sin(time * 0.8 + p.phase) * 0.03
            p.entity.position = [cos(p.angle) * r, y, sin(p.angle) * r]
            p.entity.orientation = simd_quatf(angle: time * p.spinSpeed * (1 + swirlBoost * 0.5) + p.phase, axis: p.spinAxis)
        }

        // めぐる光
        for i in motes.indices {
            motes[i].angle += motes[i].speed * (1 + glow * 2) * dt
            let m = motes[i]
            m.entity.position = m.tilt.act([cos(m.angle) * m.radius, 0, sin(m.angle) * m.radius])
        }

        // 波紋：広がりながら消える
        for i in ripples.indices { ripples[i].age += dt }
        ripples.removeAll { ripple in
            let t = ripple.age / 1.3
            if t >= 1 {
                ripple.entity.removeFromParent()
                return true
            }
            ripple.entity.scale = .one * (1 + t * 2.6)
            Fade.set(ripple.entity, 0.9 * pow(1 - t, 1.5))
            face(ripple.entity, toward: camera)
            return false
        }

        // 光の粒：飛び散って、ゆっくり落ちながら消える
        for i in sparks.indices {
            sparks[i].age += dt
            sparks[i].velocity *= exp(-2.2 * dt)
            sparks[i].velocity.y -= 0.35 * dt
            sparks[i].entity.position += sparks[i].velocity * dt
        }
        sparks.removeAll { spark in
            let t = spark.age / 1.0
            if t >= 1 {
                spark.entity.removeFromParent()
                return true
            }
            Fade.set(spark.entity, 1 - t * t)
            return false
        }
    }

    /// 板（+Z が表）をカメラに向ける
    private func face(_ entity: Entity, toward camera: SIMD3<Float>) {
        let d = camera - entity.position
        guard simd_length(d) > 0.001 else { return }
        let dir = simd_normalize(d)
        if simd_dot(dir, [0, 0, -1]) > 0.9999 {
            entity.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        } else {
            entity.orientation = simd_quatf(from: [0, 0, 1], to: dir)
        }
    }

    func remove() {
        stopPlayback(notify: false)
        root.removeFromParent()
        ripples.removeAll()
        sparks.removeAll()
    }
}
