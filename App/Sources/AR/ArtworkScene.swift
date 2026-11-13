import Combine
import RealityKit
import UIKit

/// 扉のまわりの作品をまとめて扱う。扉と同じ印（ARAnchor）の下に置くので、扉が動いても一緒に動く。
/// - 扉が開くまでは見せない（開いたら、少しずつ順に現れる）
/// - 近づく・押す・手で触れると、作品ごとのルールで動く
/// - 置くときは、見本がカメラの前についてくる（扉から 4m・地面から 3.5m の内側だけに置ける）
@MainActor
final class ArtworkScene {
    struct Target {
        let id: UUID
        let center: SIMD3<Float>
        let radius: Float
    }

    /// 置ける範囲（扉の足もとの中心から。サーバーの決まりより少し内側）
    static let horizontalLimit: Float = 3.9
    static let heightRange: ClosedRange<Float> = -0.4...3.4

    let container = Entity()
    private(set) var items: [UUID: ArtworkItem] = [:]
    private var order: [UUID] = []
    private(set) var isRevealed = false

    private var preview: ArtworkItem?
    private var previewHides: UUID?
    private var previewPosition: SIMD3<Float>?
    private(set) var previewInRange = true
    var previewDistance: Float = 1.0
    var previewScale: Float = 1 {
        didSet { preview?.root.scale = .one * previewScale }
    }
    /// 見本が置ける範囲の外に出た・戻ったとき
    var onPreviewRangeChange: ((Bool) -> Void)?
    /// 近づいて作品が動いたとき（手ざわりの合図などに使う）
    var onApproach: ((UUID) -> Void)?

    private weak var arView: ARView?
    private var subscription: Cancellable?
    private var clock: TimeInterval = 0
    private var revealQueue: [(id: UUID, at: TimeInterval)] = []

    /// parent は扉の台（GateDoor.base）。見る人が扉を指で動かすと、作品も一緒に動く
    init(parent: Entity, arView: ARView) {
        self.arView = arView
        container.name = "artworks"
        parent.addChild(container)
        subscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated {
                self?.update(dt: event.deltaTime)
            }
        }
    }

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    // MARK: 作品を出す・消す

    @discardableResult
    func add(_ artwork: Artwork, image: UIImage?, animated: Bool) -> ArtworkItem {
        if let old = items[artwork.id] { old.remove() }
        let item = ArtworkItem(artwork, image: image)
        items[artwork.id] = item
        if !order.contains(artwork.id) { order.append(artwork.id) }
        container.addChild(item.root)
        if isRevealed {
            if animated { item.appear() }
            item.root.isEnabled = true
        } else {
            item.root.isEnabled = false
        }
        return item
    }

    func setPhoto(_ image: UIImage, for id: UUID) {
        items[id]?.setPhoto(image)
    }

    func remove(_ id: UUID) {
        items[id]?.remove()
        items[id] = nil
        order.removeAll { $0 == id }
    }

    func removeAll() {
        endPreview()
        for item in items.values { item.remove() }
        items.removeAll()
        order.removeAll()
        subscription?.cancel()
        subscription = nil
        container.removeFromParent()
    }

    func artwork(_ id: UUID) -> Artwork? { items[id]?.artwork }

    /// 扉が開いたとき：作品が順に現れ、「扉が開いたとき」のルールが動く
    func reveal() {
        guard !isRevealed else { return }
        isRevealed = true
        for (i, id) in order.enumerated() {
            revealQueue.append((id, clock + 0.35 + Double(i) * 0.18))
        }
        Trace.log("扉の前の作品を見せます（\(order.count) 個）")
    }

    // MARK: 反応

    @discardableResult
    func fire(_ trigger: ArtworkTrigger, on id: UUID) -> Bool {
        guard let item = items[id], item.root.isEnabled else { return false }
        return item.fire(trigger, now: clock)
    }

    /// 押した所の作品（なければ nil）
    func artworkID(at entity: Entity?) -> UUID? {
        guard let entity else { return nil }
        return items.first(where: { $0.value.contains(entity) })?.key
    }

    /// 手で触れられる作品（カメラから maxDistance m 以内）
    func targets(within maxDistance: Float) -> [Target] {
        guard isRevealed, let camera = arView?.cameraTransform.translation else { return [] }
        return items.values.compactMap { item in
            guard item.root.isEnabled else { return nil }
            let center = item.worldCenter
            guard simd_distance(center, camera) <= maxDistance else { return nil }
            return Target(id: item.artwork.id, center: center, radius: item.worldRadius)
        }
    }

    func setHover(_ id: UUID?) {
        for (key, item) in items { item.setHover(key == id) }
    }

    // MARK: 置く（見本がカメラの前についてくる）

    func beginPreview(_ draft: Artwork, image: UIImage?, hiding: UUID? = nil) {
        endPreview()
        let item = ArtworkItem(draft, image: image, preview: true)
        preview = item
        previewHides = hiding
        if let hiding { items[hiding]?.root.isEnabled = false }
        previewScale = draft.scale
        previewPosition = nil
        container.addChild(item.root)
        Trace.log("作品の見本を出しました（\(draft.artKind.label)\(hiding != nil ? "・置き直し" : "")）")
    }

    /// いまの見本の位置（扉が基準）・向き・大きさ
    func previewPose() -> (position: SIMD3<Float>, yaw: Float, scale: Float)? {
        guard let preview else { return nil }
        return (preview.root.position, preview.artwork.yaw, previewScale)
    }

    func endPreview() {
        preview?.remove()
        preview = nil
        if let hidden = previewHides, isRevealed { items[hidden]?.root.isEnabled = true }
        previewHides = nil
        previewPosition = nil
    }

    private func updatePreview(dt: Float, camera: Transform) {
        guard let preview else { return }
        let camPos = camera.translation
        let m = camera.matrix
        var forward = -SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        if simd_length(forward) < 0.001 { forward = [0, 0, -1] }
        forward = simd_normalize(forward)
        let worldTarget = camPos + forward * previewDistance
        let local = container.convert(position: worldTarget, from: nil)
        let limit = Self.horizontalLimit
        let clamped = SIMD3<Float>(min(max(local.x, -limit), limit),
                                   min(max(local.y, Self.heightRange.lowerBound), Self.heightRange.upperBound),
                                   min(max(local.z, -limit), limit))
        let inRange = simd_distance(clamped, local) < 0.01
        if inRange != previewInRange {
            previewInRange = inRange
            onPreviewRangeChange?(inRange)
        }
        // なめらかについてくる
        let current = previewPosition ?? clamped
        let next = current + (clamped - current) * min(1, dt * 10)
        previewPosition = next
        let camLocal = container.convert(position: camPos, from: nil)
        let toCamera = SIMD2<Float>(camLocal.x - next.x, camLocal.z - next.z)
        let yaw = simd_length(toCamera) > 0.01 ? atan2(toCamera.x, toCamera.y) : preview.artwork.yaw
        preview.setPose(position: next, yaw: yaw, scale: previewScale)
    }

    // MARK: 毎コマ

    private func update(dt: TimeInterval) {
        clock += dt
        guard let arView else { return }
        let camera = arView.cameraTransform
        let camPos = camera.translation

        // 順に現れる
        if !revealQueue.isEmpty {
            revealQueue.removeAll { entry in
                guard entry.at <= clock else { return false }
                if let item = items[entry.id], entry.id != previewHides {
                    item.root.isEnabled = true
                    item.appear()
                    item.fire(.open, now: clock)
                }
                return true
            }
        }

        updatePreview(dt: Float(dt), camera: camera)
        preview?.update(dt: Float(dt), cameraWorld: camPos)

        for (id, item) in items where item.root.isEnabled {
            if isRevealed, item.updateNear(distance: simd_distance(item.worldCenter, camPos)) {
                if item.fire(.approach, now: clock) { onApproach?(id) }
            }
            item.update(dt: Float(dt), cameraWorld: camPos)
        }
    }
}
