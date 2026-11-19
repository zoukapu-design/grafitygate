import ARKit
import Combine
import RealityKit
import SwiftUI

// AR カメラ（2026-11-19 オーナー「扉に入ったあとにもう一回写真を撮るところが要の機能。インスタのストーリーの投稿のように」）。
// 扉の中で、扉・みんなの AR の飾り（友達の人物の映像など）と一緒に、写真だけに入れる AR の効果（キラキラ・ハート・雪…）と
// AR の文字を重ねて撮り、グラフィティカードの写真にする。効果・文字は写真のためだけのもので、GATE には残らない
// （GATE に残すのは、いままでどおり「AR の飾りを置く」）。カメラの映像はサーバーに送らない。

/// 写真に一緒に写す AR の効果
enum StoryEffect: String, CaseIterable, Identifiable {
    case none, sparkle, hearts, confetti, snow, petals, stardust, fireflies, bubbles

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "なし"
        case .sparkle: return "キラキラ"
        case .hearts: return "ハート"
        case .confetti: return "紙ふぶき"
        case .snow: return "雪"
        case .petals: return "花びら"
        case .stardust: return "星くず"
        case .fireflies: return "ほたる"
        case .bubbles: return "シャボン玉"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "circle.slash"
        case .sparkle: return "sparkles"
        case .hearts: return "heart.fill"
        case .confetti: return "party.popper.fill"
        case .snow: return "snowflake"
        case .petals: return "camera.macro"
        case .stardust: return "moon.stars.fill"
        case .fireflies: return "light.max"
        case .bubbles: return "bubbles.and.sparkles.fill"
        }
    }

    /// 選ぶ丸の色（効果の雰囲気）
    var chipColors: [Color] {
        switch self {
        case .none: return [Color(hex: 0x3A3550), Color(hex: 0x24203A)]
        case .sparkle: return [Color(hex: 0xFFD27A), Color(hex: 0xB07BFF)]
        case .hearts: return [Color(hex: 0xFF7AA8), Color(hex: 0xFF3D6E)]
        case .confetti: return [Color(hex: 0xFFCF4A), Color(hex: 0x4AC8FF)]
        case .snow: return [Color(hex: 0xDDEBFF), Color(hex: 0x7FA8E8)]
        case .petals: return [Color(hex: 0xFFC2D6), Color(hex: 0xF27AA0)]
        case .stardust: return [Color(hex: 0x6B4CFF), Color(hex: 0x1B1450)]
        case .fireflies: return [Color(hex: 0xFFE38A), Color(hex: 0x3B5A2A)]
        case .bubbles: return [Color(hex: 0x9BE7FF), Color(hex: 0xC8A8FF)]
        }
    }
}

/// AR の文字の色
enum StoryInk: String, CaseIterable, Identifiable {
    case white, pink, orange, yellow, mint, sky, violet

    var id: String { rawValue }

    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .white: return (1, 1, 1)
        case .pink: return (1.0, 0.42, 0.66)
        case .orange: return (1.0, 0.62, 0.26)
        case .yellow: return (1.0, 0.88, 0.32)
        case .mint: return (0.42, 0.96, 0.78)
        case .sky: return (0.4, 0.82, 1.0)
        case .violet: return (0.7, 0.52, 1.0)
        }
    }

    var ui: UIColor { UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }
    var color: Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2) }
}

/// AR の文字の見た目
enum StoryTextStyle: String, CaseIterable, Identifiable {
    /// 光る文字（まわりに光）
    case neon
    /// 厚みのあるつやつやの文字
    case pop
    /// 白い札に色の文字
    case label

    var id: String { rawValue }

    var label: String {
        switch self {
        case .neon: return "ネオン"
        case .pop: return "ポップ"
        case .label: return "ラベル"
        }
    }
}

/// 写真だけに入れる AR の文字
struct StorySticker: Identifiable, Equatable {
    let id: UUID
    var text: String
    var ink: StoryInk
    var style: StoryTextStyle
}

/// 文字を書いているあいだの下書き
struct StoryTextDraft: Equatable {
    var editing: UUID?
    var text = ""
    var ink: StoryInk = .white
    var style: StoryTextStyle = .neon
}

@MainActor
final class StoryCamera: ObservableObject {
    @Published private(set) var isOn = false
    @Published private(set) var effect: StoryEffect = .none
    @Published private(set) var doorHidden = false
    @Published private(set) var stickers: [StorySticker] = []
    @Published var selected: UUID?
    /// セルフタイマー（0・3・10 秒）
    @Published private(set) var timerSeconds = 0
    @Published private(set) var countdown: Int?
    /// 撮った写真（確かめる画面）
    @Published var shot: UIImage?
    /// 文字を書いているあいだ
    @Published var textDraft: StoryTextDraft?
    @Published private(set) var flash = false
    @Published private(set) var capturing = false
    /// iPhone の持ち方に合わせて、ボタンの絵を回す（画面は縦のまま。横に持って撮る人が多い＝カードの写真は横長）
    @Published private(set) var iconTurn: Double = 0

    weak var arView: ARView?
    /// 効果を集める所（扉の足もと。扉が無ければ目の前）
    var doorBase: (() -> Entity?)?
    var doorScale: Float = 1
    var onDoorHidden: ((Bool) -> Void)?

    private var root: AnchorEntity?
    private var field: StoryEffectField?
    private var fieldHolder: Entity?
    private var entities: [UUID: Entity] = [:]
    private var rolls: [UUID: Float] = [:]
    private var scales: [UUID: Float] = [:]
    private var dragTarget: UUID?
    private var dragOffset: SIMD3<Float> = .zero
    private var pinchStart: Float?
    private var rotateStart: Float?
    private var turnTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    static let maxStickers = 6

    // MARK: 始める・やめる

    func begin(arView: ARView) {
        guard !isOn else { return }
        self.arView = arView
        let anchor = AnchorEntity(world: matrix_identity_float4x4)
        arView.scene.addAnchor(anchor)
        root = anchor
        isOn = true
        shot = nil
        Trace.log("AR カメラを開いた（扉 \(doorBase?() == nil ? "なし" : "あり")・大きさ \(String(format: "%.2f", doorScale))）")
        turnTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateIconTurn()
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    func end() {
        guard isOn else { return }
        turnTask?.cancel()
        countdownTask?.cancel()
        field?.remove()
        field = nil
        fieldHolder?.removeFromParent()
        fieldHolder = nil
        root?.removeFromParent()
        root = nil
        entities.removeAll()
        rolls.removeAll()
        scales.removeAll()
        stickers = []
        selected = nil
        effect = .none
        if doorHidden { onDoorHidden?(false) }
        doorHidden = false
        countdown = nil
        shot = nil
        textDraft = nil
        capturing = false
        isOn = false
        StorySprites.release()
        Trace.log("AR カメラを閉じた")
    }

    // MARK: 効果

    func setEffect(_ next: StoryEffect) {
        guard next != effect else { return }
        effect = next
        field?.remove()
        field = nil
        fieldHolder?.removeFromParent()
        fieldHolder = nil
        Haptics.tap()
        guard next != .none, let arView else { return }
        let parent: Entity
        if let base = doorBase?(), !doorHidden {
            parent = base
        } else if let root {
            // 扉が無い（隠した）ときは目の前（1.8m 先の足もと）に、こちらを向けて集める
            let holder = Entity()
            let cam = arView.cameraTransform
            var forward = -cam.matrix.columns.2.xyz
            forward.y = 0
            forward = simd_length(forward) > 0.01 ? simd_normalize(forward) : [0, 0, -1]
            let center = cam.translation + forward * 1.8 + SIMD3<Float>(0, -1.3, 0)
            holder.transform = Transform(scale: .one, rotation: simd_quatf(angle: atan2(-forward.x, -forward.z), axis: [0, 1, 0]),
                                         translation: center)
            root.addChild(holder)
            fieldHolder = holder
            parent = holder
        } else {
            return
        }
        let scale = doorHidden || doorBase?() == nil ? 1 : min(max(doorScale, 0.4), 1.5)
        field = StoryEffectField(effect: next, parent: parent, scale: scale, arView: arView)
        Trace.log("AR カメラ：効果「\(next.label)」")
    }

    func toggleDoor() {
        doorHidden.toggle()
        onDoorHidden?(doorHidden)
        Haptics.tap()
        // 効果は扉に付いているので、置き直す
        let current = effect
        effect = .none
        setEffect(current)
        Trace.log("AR カメラ：扉を\(doorHidden ? "隠した" : "出した")")
    }

    func cycleTimer() {
        timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
        Haptics.tap()
    }

    // MARK: 文字

    func startText(editing id: UUID? = nil) {
        if let id, let s = stickers.first(where: { $0.id == id }) {
            textDraft = StoryTextDraft(editing: id, text: s.text, ink: s.ink, style: s.style)
        } else {
            guard stickers.count < Self.maxStickers else { return }
            textDraft = StoryTextDraft(ink: stickers.last?.ink ?? .white, style: stickers.last?.style ?? .neon)
        }
    }

    func commitText() {
        guard let draft = textDraft else { return }
        textDraft = nil
        let text = String(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if let id = draft.editing {
            guard !text.isEmpty else {
                remove(id)
                return
            }
            guard let i = stickers.firstIndex(where: { $0.id == id }), let old = entities[id] else { return }
            stickers[i].text = text
            stickers[i].ink = draft.ink
            stickers[i].style = draft.style
            let fresh = Self.makeTextEntity(stickers[i])
            fresh.transform = old.transform
            old.parent?.addChild(fresh)
            old.removeFromParent()
            entities[id] = fresh
            selected = id
            return
        }
        guard !text.isEmpty, let arView, let root else { return }
        let sticker = StorySticker(id: UUID(), text: text, ink: draft.ink, style: draft.style)
        let entity = Self.makeTextEntity(sticker)
        // 目の前 1.2m・目の高さより少し下に、こちらを向けて置く
        let cam = arView.cameraTransform
        let forward = simd_normalize(-cam.matrix.columns.2.xyz)
        let position = cam.translation + forward * 1.2 + SIMD3<Float>(0, -0.08, 0)
        entities[sticker.id] = entity
        rolls[sticker.id] = 0
        scales[sticker.id] = 1
        root.addChild(entity)
        stickers.append(sticker)
        place(sticker.id, at: position)
        selected = sticker.id
        Haptics.soft()
        Trace.log("AR カメラ：文字を置いた（\(text.count) 文字・\(draft.style.rawValue)）")
    }

    func removeSelected() {
        guard let id = selected else { return }
        remove(id)
    }

    private func remove(_ id: UUID) {
        entities[id]?.removeFromParent()
        entities[id] = nil
        rolls[id] = nil
        scales[id] = nil
        stickers.removeAll { $0.id == id }
        if selected == id { selected = nil }
        Haptics.tap()
    }

    /// 押した所の文字
    func sticker(at point: CGPoint) -> UUID? {
        guard let arView, var e = arView.entity(at: point) else { return nil }
        while true {
            if let hit = entities.first(where: { $0.value === e })?.key { return hit }
            guard let parent = e.parent else { return nil }
            e = parent
        }
    }

    /// 押した：文字なら選ぶ（もう選んでいれば書き直す）。文字でなければ選ぶのをやめる
    func tap(at point: CGPoint) -> Bool {
        if let id = sticker(at: point) {
            if selected == id {
                startText(editing: id)
            } else {
                selected = id
                Haptics.tap()
            }
            return true
        }
        if selected != nil {
            selected = nil
            return true
        }
        return false
    }

    var canManipulate: Bool { isOn && shot == nil && textDraft == nil && !stickers.isEmpty }

    // MARK: 動かす（なぞる・つまむ・ひねる）

    func drag(from start: CGPoint, to point: CGPoint) {
        guard let arView else { return }
        if dragTarget == nil {
            guard let id = sticker(at: start) ?? selected, let entity = entities[id] else { return }
            dragTarget = id
            selected = id
            let pos = entity.position(relativeTo: nil)
            if let hit = planeHit(point: start, through: pos, arView: arView) {
                dragOffset = pos - hit
            } else {
                dragOffset = .zero
            }
        }
        guard let id = dragTarget, let entity = entities[id] else { return }
        let pos = entity.position(relativeTo: nil)
        guard let hit = planeHit(point: point, through: pos, arView: arView) else { return }
        place(id, at: hit + dragOffset)
    }

    func endDrag() {
        dragTarget = nil
        dragOffset = .zero
    }

    func pinch(by magnification: CGFloat) {
        guard let id = selected ?? stickers.last?.id else { return }
        let start = pinchStart ?? (scales[id] ?? 1)
        pinchStart = start
        scales[id] = min(max(start * Float(magnification), 0.3), 5)
        refresh(id)
    }

    func endPinch() { pinchStart = nil }

    func rotate(by radians: Double) {
        guard let id = selected ?? stickers.last?.id else { return }
        let start = rotateStart ?? (rolls[id] ?? 0)
        rotateStart = start
        rolls[id] = start - Float(radians)
        refresh(id)
    }

    func endRotate() { rotateStart = nil }

    /// カメラと同じ向きの面（文字の位置を通る）に、指の下の光線が当たる所
    private func planeHit(point: CGPoint, through position: SIMD3<Float>, arView: ARView) -> SIMD3<Float>? {
        guard let ray = arView.ray(through: point) else { return nil }
        let normal = simd_normalize(-arView.cameraTransform.matrix.columns.2.xyz)
        let denom = simd_dot(normal, ray.direction)
        guard abs(denom) > 0.0001 else { return nil }
        let t = simd_dot(position - ray.origin, normal) / denom
        guard t > 0.1, t < 30 else { return nil }
        return ray.origin + ray.direction * t
    }

    /// 文字を置く（いつもこちらを向き、ひねった分だけ傾く）
    private func place(_ id: UUID, at position: SIMD3<Float>) {
        guard let arView, let entity = entities[id] else { return }
        let cam = arView.cameraTransform.translation
        let dir = cam - position
        let yaw = atan2(dir.x, dir.z)
        let rotation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: rolls[id] ?? 0, axis: [0, 0, 1])
        entity.setTransformMatrix(Transform(scale: .one * (scales[id] ?? 1), rotation: rotation, translation: position).matrix,
                                  relativeTo: nil)
    }

    private func refresh(_ id: UUID) {
        guard let entity = entities[id] else { return }
        place(id, at: entity.position(relativeTo: nil))
    }

    static func makeTextEntity(_ sticker: StorySticker) -> Entity {
        let holder = Entity()
        let size: CGFloat = 0.09
        let font = UIFont(name: "HiraginoSans-W8", size: size) ?? UIFont(name: "HiraginoSans-W6", size: size)
            ?? .systemFont(ofSize: size, weight: .heavy)
        let depth: Float = sticker.style == .pop ? 0.035 : 0.012
        let mesh = MeshResource.generateText(sticker.text, extrusionDepth: depth, font: font,
                                             containerFrame: CGRect(x: 0, y: 0, width: 1.1, height: 0.8),
                                             alignment: .center, lineBreakMode: .byCharWrapping)
        let bounds = mesh.bounds
        let width = max(bounds.extents.x, 0.08)
        let height = max(bounds.extents.y, 0.06)
        let ink = sticker.ink.ui
        let letters: ModelEntity
        switch sticker.style {
        case .neon:
            letters = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: ink)])
            if let glow = StorySprites.texture(.glow) {
                var m = UnlitMaterial()
                m.color = .init(tint: ink.withAlphaComponent(0.85), texture: .init(glow))
                m.blending = .transparent(opacity: .init(floatLiteral: 1))
                let plane = ModelEntity(mesh: .generatePlane(width: width * 1.5 + 0.22, height: height * 2.2 + 0.18), materials: [m])
                plane.position = [0, 0, -0.02]
                holder.addChild(plane)
            }
        case .pop:
            letters = ModelEntity(mesh: mesh, materials: [DoorDecor.pbr(ink, rough: 0.25, coat: 1, emissive: ink, glow: 0.35)])
        case .label:
            let textColor: UIColor = sticker.ink == .white ? UIColor(red: 0.16, green: 0.1, blue: 0.32, alpha: 1) : ink
            letters = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: textColor)])
            let plate = ModelEntity(mesh: .generatePlane(width: width + 0.1, height: height + 0.07,
                                                         cornerRadius: min(0.05, (height + 0.07) / 2)),
                                    materials: [DoorDecor.unlit(.white, opacity: 0.94)])
            plate.position = [0, 0, -0.004]
            holder.addChild(plate)
        }
        letters.position = -bounds.center
        holder.addChild(letters)
        // 押して選べるように（当たり判定は文字の大きさの板）
        let hit = ModelEntity()
        hit.collision = CollisionComponent(shapes: [.generateBox(width: width + 0.12, height: height + 0.1, depth: 0.06)])
        holder.addChild(hit)
        return holder
    }

    // MARK: 撮る

    func shutter() {
        guard !capturing, shot == nil else { return }
        selected = nil
        if timerSeconds > 0 {
            capturing = true
            countdownTask = Task { [weak self] in
                guard let self else { return }
                for left in stride(from: self.timerSeconds, through: 1, by: -1) {
                    self.countdown = left
                    Haptics.soft()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                }
                self.countdown = nil
                self.snap()
            }
        } else {
            capturing = true
            snap()
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdown = nil
        capturing = false
    }

    private func snap() {
        guard let arView else {
            capturing = false
            return
        }
        let holding = arView.session.currentFrame.map { FrameGrab.orientation(of: $0.camera.transform) } ?? .right
        arView.snapshot(saveToHDR: false) { [weak self] image in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.capturing = false
                    guard let image else {
                        Trace.log("AR カメラ：撮れなかった")
                        return
                    }
                    // 画面は縦のままなので、横に持って撮ったときは、景色がまっすぐ立つように回す
                    // （2026-11-19：横に持って AR ごと撮ると、カードの写真が横倒しになっていた）
                    let upright = Self.upright(image, holding: holding).downscaled(maxSide: 1600)
                    withAnimation(.easeOut(duration: 0.08)) { self.flash = true }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 140_000_000)
                        withAnimation(.easeIn(duration: 0.3)) { self.flash = false }
                    }
                    self.shot = upright
                    Haptics.success()
                    Trace.log("AR カメラ：撮った（持ち方 \(holding.rawValue)・効果 \(self.effect.rawValue)・文字 \(self.stickers.count)・"
                              + "GATE \(self.doorHidden ? "なし" : "あり")・\(Int(upright.size.width))×\(Int(upright.size.height))）")
                }
            }
        }
    }

    /// 画面の絵（縦）を、iPhone の持ち方に合わせてまっすぐ立てる
    static func upright(_ image: UIImage, holding: CGImagePropertyOrientation) -> UIImage {
        switch holding {
        case .up: return image.rotatedLeft()
        case .down: return image.rotatedRight()
        case .left: return image.rotatedRight().rotatedRight()
        default: return image
        }
    }

    private func updateIconTurn() {
        guard let frame = arView?.session.currentFrame else { return }
        let next: Double
        switch FrameGrab.orientation(of: frame.camera.transform) {
        case .up: next = 90
        case .down: next = -90
        case .left: next = 180
        default: next = 0
        }
        if next != iconTurn {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { iconTurn = next }
        }
    }
}

extension UIImage {
    /// 左に 90° 回した絵
    func rotatedLeft() -> UIImage {
        let source = size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: source.height, height: source.width), format: format).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: 0, y: source.width)
            c.rotate(by: -.pi / 2)
            draw(in: CGRect(origin: .zero, size: source))
        }
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

// MARK: - 効果の粒

/// 効果の粒を、扉のまわり（扉の座標：+Z が手前、y は足もとから上）に舞わせる
@MainActor
final class StoryEffectField {
    private struct Particle {
        let entity: Entity
        var p: SIMD3<Float>
        var speed: Float
        let phase: Float
        let size: Float
        let spin: SIMD3<Float>
        let spinSpeed: Float
        let billboard: Bool
        var orbit: Float = 0
        let radius: Float
    }

    private let holder = Entity()
    private var particles: [Particle] = []
    private var subscription: Cancellable?
    private var time: Float = 0
    private weak var arView: ARView?
    private let effect: StoryEffect
    /// 舞う範囲（扉の座標の m）
    private let halfWidth: Float
    private let top: Float
    private let near: Float
    private let far: Float

    init(effect: StoryEffect, parent: Entity, scale: Float, arView: ARView) {
        self.effect = effect
        self.arView = arView
        halfWidth = 1.5 * scale
        top = 2.8 * scale
        near = -0.6 * scale
        far = 1.8 * scale
        let low = Perf.isLowMemoryDevice
        let count: Int
        switch effect {
        case .stardust: count = low ? 40 : 64
        case .confetti: count = low ? 34 : 52
        case .snow: count = low ? 36 : 56
        case .none: count = 0
        default: count = low ? 24 : 36
        }
        MainWatch.run("AR カメラの効果を作る") {
            build(count: count, scale: scale)
        }
        parent.addChild(holder)
        subscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.tick(Float(event.deltaTime))
            }
        }
    }

    func remove() {
        subscription?.cancel()
        subscription = nil
        holder.removeFromParent()
        particles.removeAll()
    }

    private func random(_ r: ClosedRange<Float>) -> Float { Float.random(in: r) }

    private func build(count: Int, scale: Float) {
        guard count > 0 else { return }
        let materials: [RealityKit.Material]
        let mesh: MeshResource
        var billboard = true
        let baseSize: Float
        switch effect {
        case .sparkle:
            mesh = .generatePlane(width: 1, height: 1)
            materials = [UIColor(red: 1, green: 0.92, blue: 0.7, alpha: 1), .white, UIColor(red: 0.85, green: 0.75, blue: 1, alpha: 1)]
                .compactMap { StorySprites.material(.star, tint: $0) }
            baseSize = 0.09
        case .hearts:
            mesh = .generatePlane(width: 1, height: 1)
            materials = [UIColor(red: 1, green: 0.4, blue: 0.62, alpha: 1), UIColor(red: 1, green: 0.62, blue: 0.75, alpha: 1),
                         UIColor(red: 0.95, green: 0.25, blue: 0.4, alpha: 1)]
                .compactMap { StorySprites.material(.heart, tint: $0) }
            baseSize = 0.1
        case .confetti:
            mesh = .generateBox(width: 1, height: 0.5, depth: 0.04)
            billboard = false
            materials = [UIColor(red: 1, green: 0.4, blue: 0.5, alpha: 1), UIColor(red: 1, green: 0.8, blue: 0.3, alpha: 1),
                         UIColor(red: 0.4, green: 0.8, blue: 1, alpha: 1), UIColor(red: 0.6, green: 0.95, blue: 0.6, alpha: 1),
                         UIColor(red: 0.8, green: 0.6, blue: 1, alpha: 1)]
                .map { DoorDecor.pbr($0, rough: 0.4, emissive: $0, glow: 0.4) }
            baseSize = 0.045
        case .snow:
            mesh = .generatePlane(width: 1, height: 1)
            materials = [StorySprites.material(.dot, tint: .white)].compactMap { $0 }
            baseSize = 0.05
        case .petals:
            mesh = .generateBox(width: 1, height: 0.7, depth: 0.03, cornerRadius: 0.3)
            billboard = false
            materials = [UIColor(red: 1, green: 0.76, blue: 0.84, alpha: 1), UIColor(red: 1, green: 0.66, blue: 0.78, alpha: 1),
                         UIColor(red: 1, green: 0.88, blue: 0.92, alpha: 1)]
                .map { DoorDecor.pbr($0, rough: 0.6, emissive: $0, glow: 0.25) }
            baseSize = 0.05
        case .stardust:
            mesh = .generatePlane(width: 1, height: 1)
            materials = [UIColor(red: 0.75, green: 0.6, blue: 1, alpha: 1), UIColor(red: 0.5, green: 0.85, blue: 1, alpha: 1), .white]
                .compactMap { StorySprites.material(.dot, tint: $0) }
            baseSize = 0.035
        case .fireflies:
            mesh = .generatePlane(width: 1, height: 1)
            materials = [UIColor(red: 1, green: 0.9, blue: 0.45, alpha: 1), UIColor(red: 0.85, green: 1, blue: 0.5, alpha: 1)]
                .compactMap { StorySprites.material(.dot, tint: $0) }
            baseSize = 0.07
        case .bubbles:
            mesh = .generatePlane(width: 1, height: 1)
            materials = [StorySprites.material(.bubble, tint: .white)].compactMap { $0 }
            baseSize = 0.13
        case .none:
            return
        }
        guard !materials.isEmpty else { return }
        for i in 0..<count {
            let entity = ModelEntity(mesh: mesh, materials: [materials[i % materials.count]])
            holder.addChild(entity)
            let size = baseSize * scale * random(0.6...1.4)
            let start = SIMD3<Float>(random(-halfWidth...halfWidth), random(0...top), random(near...far))
            let axis = simd_normalize(SIMD3<Float>(random(-1...1), random(-1...1), random(-1...1)) + [0, 0.001, 0])
            particles.append(Particle(entity: entity, p: start, speed: random(0.6...1.4), phase: random(0...6.28), size: size,
                                      spin: axis, spinSpeed: random(1.5...4), billboard: billboard,
                                      orbit: random(0...6.28), radius: random(0.3...1.0) * halfWidth))
        }
    }

    private func tick(_ dt: Float) {
        guard !particles.isEmpty, let arView else { return }
        let step = min(dt, 0.05)
        time += step
        let cam = holder.convert(position: arView.cameraTransform.translation, from: nil)
        let height = top
        for i in particles.indices {
            var q = particles[i]
            var scaleFactor: Float = 1
            switch effect {
            case .sparkle:
                q.p.y += 0.12 * q.speed * step
                q.p.x += sin(time * 0.8 + q.phase) * 0.04 * step
                scaleFactor = 0.45 + 0.55 * abs(sin(time * 2.4 * q.speed + q.phase))
            case .hearts:
                q.p.y += 0.22 * q.speed * step
                q.p.x += sin(time * 1.6 + q.phase) * 0.12 * step
                scaleFactor = 0.9 + 0.1 * sin(time * 5 + q.phase)
            case .bubbles:
                q.p.y += 0.14 * q.speed * step
                q.p.x += sin(time * 1.1 + q.phase) * 0.1 * step
                q.p.z += cos(time * 0.9 + q.phase) * 0.06 * step
                scaleFactor = 0.92 + 0.08 * sin(time * 3 + q.phase)
            case .confetti:
                q.p.y -= 0.32 * q.speed * step
                q.p.x += sin(time * 1.3 + q.phase) * 0.15 * step
            case .snow:
                q.p.y -= 0.2 * q.speed * step
                q.p.x += sin(time * 0.7 + q.phase) * 0.08 * step
            case .petals:
                q.p.y -= 0.17 * q.speed * step
                q.p.x += sin(time * 0.9 + q.phase) * 0.22 * step
                q.p.z += cos(time * 0.6 + q.phase) * 0.08 * step
            case .stardust:
                // 扉のまわりを、ゆっくりめぐる
                q.orbit += 0.25 * q.speed * step
                q.p.x = cos(q.orbit) * q.radius
                q.p.z = 0.5 * (far + near) + sin(q.orbit) * q.radius * 0.6
                q.p.y += sin(time * 0.5 + q.phase) * 0.05 * step
                scaleFactor = 0.5 + 0.5 * abs(sin(time * 1.8 + q.phase))
            case .fireflies:
                q.p.x += sin(time * 0.5 * q.speed + q.phase) * 0.12 * step
                q.p.y += cos(time * 0.4 * q.speed + q.phase * 1.3) * 0.08 * step
                q.p.z += sin(time * 0.35 * q.speed + q.phase * 0.7) * 0.1 * step
                scaleFactor = 0.25 + 0.75 * max(0, sin(time * 1.2 * q.speed + q.phase))
            case .none:
                break
            }
            // 範囲の外へ出たら、反対の端から入り直す
            if q.p.y > height { q.p.y = 0; q.p.x = random(-halfWidth...halfWidth) }
            if q.p.y < 0 { q.p.y = height; q.p.x = random(-halfWidth...halfWidth) }
            if q.p.x > halfWidth { q.p.x = -halfWidth }
            if q.p.x < -halfWidth { q.p.x = halfWidth }
            if q.p.z > far { q.p.z = near }
            if q.p.z < near { q.p.z = far }
            let rotation: simd_quatf
            if q.billboard {
                let d = cam - q.p
                let yaw = atan2(d.x, d.z)
                let pitch = atan2(d.y, max(simd_length(SIMD2<Float>(d.x, d.z)), 0.001))
                rotation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -pitch, axis: [1, 0, 0])
            } else {
                rotation = simd_quatf(angle: time * q.spinSpeed + q.phase, axis: q.spin)
            }
            q.entity.transform = Transform(scale: .one * (q.size * scaleFactor), rotation: rotation, translation: q.p)
            particles[i] = q
        }
    }
}

// MARK: - 粒の絵

@MainActor
enum StorySprites {
    enum Kind: String {
        case star, dot, heart, bubble, glow
    }

    private static var cache: [Kind: TextureResource] = [:]
    private static var materials: [String: UnlitMaterial] = [:]

    static func release() {
        cache.removeAll()
        materials.removeAll()
    }

    static func material(_ kind: Kind, tint: UIColor) -> UnlitMaterial? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        let key = "\(kind.rawValue)-\(Int(r * 255))-\(Int(g * 255))-\(Int(b * 255))"
        if let m = materials[key] { return m }
        guard let texture = texture(kind) else { return nil }
        var m = UnlitMaterial()
        m.color = .init(tint: tint, texture: .init(texture))
        m.blending = .transparent(opacity: .init(floatLiteral: 1))
        materials[key] = m
        return m
    }

    static func texture(_ kind: Kind) -> TextureResource? {
        if let t = cache[kind] { return t }
        let w = kind == .glow ? 256 : 128
        let h = kind == .glow ? 128 : 128
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let W = CGFloat(w), H = CGFloat(h)
        let c = CGPoint(x: W / 2, y: H / 2)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        switch kind {
        case .dot:
            if let g = CGGradient(colorsSpace: space, colors: [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.55).cgColor,
                                                               UIColor.white.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 0.25, 1]) {
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: W / 2, options: [])
            }
        case .star:
            if let g = CGGradient(colorsSpace: space, colors: [UIColor.white.withAlphaComponent(0.7).cgColor,
                                                               UIColor.white.withAlphaComponent(0).cgColor] as CFArray,
                                  locations: [0, 1]) {
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: W * 0.32, options: [])
            }
            let r = W * 0.48
            let p = CGMutablePath()
            p.move(to: CGPoint(x: c.x, y: c.y - r))
            p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
            p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
            ctx.addPath(p)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillPath()
        case .heart:
            let path = CGMutablePath()
            for i in 0...60 {
                let t = CGFloat(i) / 60 * 2 * .pi
                let x = 16 * pow(sin(t), 3)
                let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                let q = CGPoint(x: c.x + x * 3.4, y: c.y + 4 + y * 3.4)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            ctx.setShadow(offset: .zero, blur: 10, color: UIColor.white.withAlphaComponent(0.8).cgColor)
            ctx.addPath(path)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillPath()
        case .bubble:
            let rect = CGRect(x: 8, y: 8, width: W - 16, height: H - 16)
            if let g = CGGradient(colorsSpace: space, colors: [UIColor.white.withAlphaComponent(0.05).cgColor,
                                                               UIColor.white.withAlphaComponent(0.25).cgColor] as CFArray,
                                  locations: [0.6, 1]) {
                ctx.saveGState()
                ctx.addEllipse(in: rect)
                ctx.clip()
                ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: rect.width / 2, options: [])
                ctx.restoreGState()
            }
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: rect)
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
            ctx.fillEllipse(in: CGRect(x: W * 0.62, y: H * 0.22, width: W * 0.14, height: H * 0.1))
        case .glow:
            let rect = CGRect(x: W * 0.2, y: H * 0.3, width: W * 0.6, height: H * 0.4)
            ctx.setShadow(offset: .zero, blur: 28, color: UIColor.white.cgColor)
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.5).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).cgPath)
            ctx.fillPath()
        }
        guard let image = ctx.makeImage(),
              let texture = try? TextureResource.generate(from: image, options: TextureResource.CreateOptions(semantic: .color))
        else { return nil }
        cache[kind] = texture
        return texture
    }
}
