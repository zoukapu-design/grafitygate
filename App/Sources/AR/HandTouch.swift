import ARKit
import Combine
import UIKit
import Vision

/// 手で作品に触れる。カメラの絵から人さし指の先を見つけ（Vision）、人の奥行き（ARKit）で指先までの距離を測って、
/// 指先の 3D の位置が作品に入ったら「触れた」とする。
/// - 奥行きが使えないとき（対応していない・端末が熱い・手が人として見分けられない）は、指先の先にある作品を
///   少し明るくするだけ（触れたことにはしない）。画面を押せば、いつでも同じ反応が起きる。
/// - 作品が近く（2.5m 以内）にあるときだけ、1 秒に 10 回ほど（4GB の端末は 8 回）調べる。熱いときは止める。
/// - カメラの絵・手の形はサーバーに送らない。調べ終わったらすぐ離す。
@MainActor
final class HandTouch: ObservableObject {
    struct Cursor: Equatable {
        /// 画面の上の指先の位置（pt）
        var point: CGPoint
        /// 作品に触れている
        var touching: Bool
        /// 作品の近くにある（触れる手前）
        var near: Bool
        /// 指先までの距離が測れている
        var hasDepth: Bool
    }

    @Published private(set) var cursor: Cursor?
    /// 手で触れる仕組みが動いているか（画面の案内に使う）
    @Published private(set) var isActive = false

    /// 触れた作品を知らせる
    var onTouch: ((UUID) -> Void)?
    /// 指先が近い作品（明るくする）
    var onHover: ((UUID?) -> Void)?
    /// 触れられる作品の一覧（毎回たずねる）
    var targets: (() -> [ArtworkScene.Target])?

    private weak var stage: ARStage?
    private var loop: Task<Void, Never>?
    private var busy = false
    private let worker = HandWorker()

    // 触れたかどうかの判定（ぶれで何度も触れないように）
    private var smoothed: SIMD3<Float>?
    private var touchCandidate: UUID?
    private var candidateCount = 0
    private var touchingID: UUID?
    private var hoverID: UUID?
    private var lastScreen: CGPoint?
    private var missCount = 0

    // 調べものの記録用
    private var samples = 0
    private var handSeen = 0
    private var depthOK = 0
    private var touches = 0
    private var startedAt = Date()

    func start(stage: ARStage) {
        guard loop == nil else { return }
        self.stage = stage
        startedAt = Date()
        samples = 0; handSeen = 0; depthOK = 0; touches = 0
        Trace.log("手で触れる：開始（人の奥行き：\(stage.usesPeopleDepth ? "使う" : "使えない")）")
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let interval: UInt64 = Perf.isLowMemoryDevice ? 125_000_000 : 100_000_000
                try? await Task.sleep(nanoseconds: interval)
                self?.tick()
            }
        }
    }

    func stop() {
        guard loop != nil else { return }
        loop?.cancel()
        loop = nil
        clear()
        isActive = false
        let seconds = Date().timeIntervalSince(startedAt)
        Trace.log(String(format: "手で触れる：終了（%.0f 秒・調べた %d 回・手が見えた %d 回・距離が測れた %d 回・触れた %d 回）",
                         seconds, samples, handSeen, depthOK, touches))
    }

    private func clear() {
        cursor = nil
        smoothed = nil
        touchCandidate = nil
        candidateCount = 0
        touchingID = nil
        if hoverID != nil { onHover?(nil) }
        hoverID = nil
        lastScreen = nil
    }

    private func tick() {
        guard let stage, !busy else { return }
        let list = targets?() ?? []
        // 熱いとき・近くに作品がないときは調べない
        guard !Perf.isHot, !list.isEmpty else {
            if isActive {
                isActive = false
                clear()
            }
            return
        }
        if !isActive { isActive = true }
        let viewport = stage.arView.bounds.size
        guard viewport.width > 0, let frame = stage.arView.session.currentFrame else { return }
        guard case .normal = frame.camera.trackingState else { return }
        // ARFrame から要る物だけを取り出して、すぐ離す
        let input = HandWorker.Input(image: frame.capturedImage,
                                     depth: stage.usesPeopleDepth ? frame.estimatedDepthData : nil,
                                     intrinsics: frame.camera.intrinsics,
                                     imageSize: frame.camera.imageResolution,
                                     cameraTransform: frame.camera.transform,
                                     display: frame.displayTransform(for: .portrait, viewportSize: viewport),
                                     viewport: viewport)
        busy = true
        worker.detect(input) { [weak self] sample in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = false
                    self.consume(sample, targets: list)
                }
            }
        }
    }

    private func consume(_ sample: HandWorker.Sample?, targets: [ArtworkScene.Target]) {
        guard loop != nil else { return }
        samples += 1
        guard let sample else {
            // 手が見えない：少し待ってから消す（1 回見失っただけでカーソルがちらつかないように）
            missCount += 1
            if missCount >= 3 { clear() }
            return
        }
        missCount = 0
        handSeen += 1

        let screen: CGPoint
        if let last = lastScreen {
            screen = CGPoint(x: last.x + (sample.screen.x - last.x) * 0.6, y: last.y + (sample.screen.y - last.y) * 0.6)
        } else {
            screen = sample.screen
        }
        lastScreen = screen

        var nearest: (id: UUID, gap: Float)?
        var touchingNow: UUID?
        if let world = sample.world {
            depthOK += 1
            let point: SIMD3<Float>
            if let s = smoothed, simd_distance(s, world) < 0.35 {
                point = s + (world - s) * 0.6
            } else {
                point = world
            }
            smoothed = point
            for t in targets {
                let gap = simd_distance(point, t.center) - t.radius
                if nearest == nil || gap < nearest!.gap { nearest = (t.id, gap) }
            }
            if let n = nearest {
                if n.gap < 0.02 {
                    touchingNow = n.id
                } else if touchingID == n.id, n.gap < 0.1 {
                    touchingNow = n.id   // 少し離れても、はっきり離れるまでは触れたまま
                }
            }
        } else {
            smoothed = nil
            // 距離が測れない：指先の先（カメラから指へのまっすぐな線）にある作品だけを明るくする
            for t in targets {
                if let gap = Self.rayGap(origin: sample.rayOrigin, direction: sample.rayDirection, center: t.center,
                                         radius: t.radius), nearest == nil || gap < nearest!.gap {
                    nearest = (t.id, gap)
                }
            }
        }

        // 2 回続けて触れていたら「触れた」（ぶれで 1 回だけ入ったものは数えない）
        if let id = touchingNow {
            if touchingID != id {
                if touchCandidate == id {
                    candidateCount += 1
                } else {
                    touchCandidate = id
                    candidateCount = 1
                }
                if candidateCount >= 2 {
                    touchingID = id
                    touches += 1
                    onTouch?(id)
                    Trace.log(String(format: "手で作品に触れました（指先から作品のふちまで %.2fm・奥行きの値 %.2fm）",
                                     nearest?.gap ?? -1, sample.depth ?? -1))
                }
            }
        } else {
            touchCandidate = nil
            candidateCount = 0
            touchingID = nil
        }

        let nearID: UUID? = (nearest.map { $0.gap < 0.25 } ?? false) ? nearest?.id : nil
        if nearID != hoverID {
            hoverID = nearID
            onHover?(nearID)
        }
        cursor = Cursor(point: screen, touching: touchingID != nil, near: nearID != nil, hasDepth: sample.world != nil)
    }

    /// まっすぐな線と球の、いちばん近いところの隙間（線が球を通れば 0 以下）。後ろ向きなら nil
    private static func rayGap(origin: SIMD3<Float>, direction: SIMD3<Float>, center: SIMD3<Float>,
                               radius: Float) -> Float? {
        let toCenter = center - origin
        let along = simd_dot(toCenter, direction)
        guard along > 0 else { return nil }
        let closest = origin + direction * along
        return simd_distance(closest, center) - radius
    }
}

/// メインの列の外で手を探す係。一度に 1 枚だけ調べる。
final class HandWorker: @unchecked Sendable {
    struct Input: @unchecked Sendable {
        let image: CVPixelBuffer
        let depth: CVPixelBuffer?
        let intrinsics: simd_float3x3
        let imageSize: CGSize
        let cameraTransform: simd_float4x4
        let display: CGAffineTransform
        let viewport: CGSize
    }

    struct Sample: @unchecked Sendable {
        /// 画面の上の指先（pt）
        let screen: CGPoint
        /// 指先の 3D の位置（世界の座標。距離が測れたときだけ）
        let world: SIMD3<Float>?
        /// 距離（m）
        let depth: Float?
        /// カメラから指先へのまっすぐな線
        let rayOrigin: SIMD3<Float>
        let rayDirection: SIMD3<Float>
    }

    private let queue = DispatchQueue(label: "gg.hand", qos: .userInitiated)
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()

    func detect(_ input: Input, completion: @escaping @Sendable (Sample?) -> Void) {
        queue.async { [self] in
            completion(self.run(input))
        }
    }

    private func run(_ input: Input) -> Sample? {
        // 縦に持ったときの背面カメラの絵は、右に 90° 回っている
        let handler = VNImageRequestHandler(cvPixelBuffer: input.image, orientation: .right, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let hand = request.results?.first,
              let tip = try? hand.recognizedPoint(.indexTip), tip.confidence > 0.35 else { return nil }

        // Vision の点（縦の絵・左下が原点）→ カメラの絵（横の絵・左上が原点）の 0〜1
        let u = Float(tip.location.x)
        let v = Float(tip.location.y)
        let xb = 1 - v
        let yb = 1 - u

        // 画面の上の位置
        let normalizedView = CGPoint(x: CGFloat(xb), y: CGFloat(yb)).applying(input.display)
        let screen = CGPoint(x: normalizedView.x * input.viewport.width, y: normalizedView.y * input.viewport.height)

        // カメラから指先への線
        let K = input.intrinsics
        let fx = K.columns.0.x, fy = K.columns.1.y, cx = K.columns.2.x, cy = K.columns.2.y
        let px = xb * Float(input.imageSize.width)
        let py = yb * Float(input.imageSize.height)
        let rayCamera = simd_normalize(SIMD3<Float>((px - cx) / fx, -(py - cy) / fy, -1))
        let T = input.cameraTransform
        let rotation = simd_float3x3(SIMD3(T.columns.0.x, T.columns.0.y, T.columns.0.z),
                                     SIMD3(T.columns.1.x, T.columns.1.y, T.columns.1.z),
                                     SIMD3(T.columns.2.x, T.columns.2.y, T.columns.2.z))
        let origin = SIMD3<Float>(T.columns.3.x, T.columns.3.y, T.columns.3.z)
        let direction = simd_normalize(rotation * rayCamera)

        // 指先までの距離（人の奥行き。手のあたりの値の真ん中を使う）
        var world: SIMD3<Float>?
        var depthValue: Float?
        if let depthBuffer = input.depth, let d = Self.sampleDepth(depthBuffer, x: xb, y: yb) {
            depthValue = d
            let local = SIMD4<Float>((px - cx) / fx * d, -(py - cy) / fy * d, -d, 1)
            let w = T * local
            world = SIMD3<Float>(w.x, w.y, w.z)
        }
        return Sample(screen: screen, world: world, depth: depthValue, rayOrigin: origin, rayDirection: direction)
    }

    /// 人の奥行きの絵の (x, y)（0〜1）のまわりの値の真ん中。人でない所は 0 なので除く。
    private static func sampleDepth(_ buffer: CVPixelBuffer, x: Float, y: Float) -> Float? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let cxp = Int(x * Float(width))
        let cyp = Int(y * Float(height))
        var values: [Float] = []
        values.reserveCapacity(25)
        for dy in -2...2 {
            let row = cyp + dy
            guard row >= 0, row < height else { continue }
            let pointer = base.advanced(by: row * rowBytes).assumingMemoryBound(to: Float32.self)
            for dx in -2...2 {
                let col = cxp + dx
                guard col >= 0, col < width else { continue }
                let value = pointer[col]
                if value.isFinite, value > 0.08, value < 3.0 { values.append(value) }
            }
        }
        guard values.count >= 4 else { return nil }
        values.sort()
        return values[values.count / 2]
    }
}
