import ARKit
import Foundation
import RealityKit
import UIKit
import Vision

/// AR の舞台。カメラと AR の状態を見張り、床を探し、場所の記憶（ARWorldMap）を保存・探索する。
/// - iPhone 12（メモリ 4GB）では、映像を 30 コマ/秒にし、周りの映り込みを作らない
/// - 人の奥行き（人が扉の手前を通ると人が前に見える・手の距離）は、端末が熱くないときだけ使う
/// - ARFrame は長く持たない（持つと AR が止まる）。必要なときに currentFrame から取り出してすぐ離す
@MainActor
final class ARStage: NSObject, ObservableObject {
    enum Guidance: Equatable {
        case starting, ready, lookAround, moveSlowly, tooDark, featureless, relocalizing, interrupted

        var text: String? {
            switch self {
            case .starting: return "カメラの準備をしています…"
            case .ready: return nil
            case .lookAround: return "iPhone をゆっくり動かして、周りを見回してください"
            case .moveSlowly: return "動きが速すぎます。ゆっくり動かしてください"
            case .tooDark: return "暗すぎて周りが見えません。明るい所でお試しください"
            case .featureless: return "模様の少ない所です。形や文字のある物の方に向けてください"
            case .relocalizing: return "扉の場所を探しています。作った人が扉を置いた辺りを見回してください"
            case .interrupted: return "カメラが止まりました。少し待つと戻ります"
            }
        }
    }

    enum StageError: LocalizedError {
        case noWorldMap
        case noFrame

        var errorDescription: String? {
            switch self {
            case .noWorldMap: return "場所の記憶を作れませんでした。扉のまわりを、もう少し見回してください。"
            case .noFrame: return "カメラの準備ができていません。少し待ってからお試しください。"
            }
        }
    }

    @Published private(set) var guidance: Guidance = .starting
    @Published private(set) var mapping: ARFrame.WorldMappingStatus = .notAvailable
    @Published private(set) var isRunning = false

    let arView: ARView
    /// カメラの動く速さ（m/秒。ならした値）。速いときは写さない
    private(set) var cameraSpeed: Float = 0
    private(set) var usesPeopleDepth = false
    private var lastPosition: SIMD3<Float>?
    private var lastTime: TimeInterval = 0
    private var relocalizing = false

    override init() {
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        super.init()
        arView.session.delegate = self
        arView.renderOptions.insert(.disableMotionBlur)
        arView.renderOptions.insert(.disableDepthOfField)
        if Perf.isLowMemoryDevice {
            arView.renderOptions.insert(.disableHDR)
        }
    }

    // MARK: 始める・止める

    func run(initialMap: ARWorldMap? = nil, reset: Bool = false) {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = Perf.isLowMemoryDevice ? .none : .automatic
        usesPeopleDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) && !Perf.isHot
        if usesPeopleDepth {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }
        if Perf.isLowMemoryDevice,
           let format = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: { $0.framesPerSecond == 30 }) {
            config.videoFormat = format
        }
        config.initialWorldMap = initialMap
        relocalizing = initialMap != nil
        let options: ARSession.RunOptions = (initialMap != nil || reset) ? [.resetTracking, .removeExistingAnchors] : []
        arView.session.run(config, options: options)
        isRunning = true
        lastPosition = nil
        Trace.log("AR を始める（場所の記憶：\(initialMap != nil ? "あり" : "なし")・人の奥行き：\(usesPeopleDepth ? "使う" : "使わない")・メモリの少ない端末：\(Perf.isLowMemoryDevice)・端末の温度：\(Perf.thermalText)）")
    }

    func pause() {
        guard isRunning else { return }
        arView.session.pause()
        isRunning = false
        Trace.log("AR を止める")
    }

    // MARK: 置く場所

    /// 画面の点の先の床（見つからなければ nil）
    func floorTransform(at point: CGPoint) -> simd_float4x4? {
        arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first?.worldTransform
    }

    var cameraTransform: simd_float4x4? { arView.session.currentFrame?.camera.transform }

    /// カメラの前 distance m の床に、こちらを向けて置く姿勢。床が見つからなければ、目の高さ − 1.4m に置く。
    func placementInFront(distance: Float) -> simd_float4x4? {
        guard let cam = cameraTransform else { return nil }
        let camPos = SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        var forward = -SIMD3<Float>(cam.columns.2.x, 0, cam.columns.2.z)
        if simd_length(forward) < 0.01 { forward = [0, 0, -1] }
        forward = simd_normalize(forward)
        var target = camPos + forward * distance
        let query = ARRaycastQuery(origin: target + SIMD3<Float>(0, 0.6, 0), direction: [0, -1, 0],
                                   allowing: .estimatedPlane, alignment: .horizontal)
        if let hit = arView.session.raycast(query).first {
            target.y = hit.worldTransform.columns.3.y
        } else {
            target.y = camPos.y - 1.4
        }
        return facing(position: target, toward: camPos)
    }

    /// position に置き、+Z の向きを toward に向けた姿勢（水平の回転だけ）
    func facing(position: SIMD3<Float>, toward: SIMD3<Float>) -> simd_float4x4 {
        var direction = SIMD3<Float>(toward.x - position.x, 0, toward.z - position.z)
        if simd_length(direction) < 0.001 { direction = [0, 0, 1] }
        direction = simd_normalize(direction)
        let yaw = atan2(direction.x, direction.z)
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: [0, 1, 0]))
        m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return m
    }

    /// 床の点 floor に、カメラの方を向けて置く姿勢
    func facingCamera(at floor: simd_float4x4) -> simd_float4x4 {
        let p = SIMD3<Float>(floor.columns.3.x, floor.columns.3.y, floor.columns.3.z)
        guard let cam = cameraTransform else { return floor }
        return facing(position: p, toward: SIMD3<Float>(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z))
    }

    func addAnchor(named name: String, transform: simd_float4x4) -> ARAnchor {
        let anchor = ARAnchor(name: name, transform: transform)
        arView.session.add(anchor: anchor)
        return anchor
    }

    func removeAnchor(_ anchor: ARAnchor) {
        arView.session.remove(anchor: anchor)
    }

    /// AR がふつうに動き出すまで待つ（最大 timeout 秒）
    func waitUntilTracking(timeout: TimeInterval) async -> Bool {
        let started = Date()
        while Date().timeIntervalSince(started) < timeout {
            if let state = arView.session.currentFrame?.camera.trackingState, case .normal = state { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    // MARK: 写す

    /// いま写してよいか（だめなら理由）
    func shotProblem() -> String? {
        guard let frame = arView.session.currentFrame else { return "カメラの準備をしています…" }
        let light = frame.lightEstimate?.ambientIntensity ?? 1000
        switch frame.camera.trackingState {
        case .normal:
            break
        case .limited(.insufficientFeatures):
            return light < 150 ? "暗すぎます。明るい所で写してください。" : "模様の少ない所です。形や文字のはっきりした物を写してください。"
        case .limited(.excessiveMotion):
            return "動きが速すぎます。少しのあいだ iPhone を止めてください。"
        default:
            return "周りを少し見回してから、もう一度写してください。"
        }
        if light < 120 { return "暗すぎます。明るい所で写してください。" }
        if (frame.rawFeaturePoints?.points.count ?? 0) < 40 {
            return "模様の少ない所です。形や文字のはっきりした物を写してください。"
        }
        if cameraSpeed > 0.5 { return "少しのあいだ iPhone を止めて写してください。" }
        return nil
    }

    /// いまのカメラの絵から、写真の特徴（と、頼まれれば写真）を作る
    func grabShot(withPhoto: Bool) async throws -> FrameGrab.Shot {
        guard let buffer = arView.session.currentFrame?.capturedImage else { throw StageError.noFrame }
        return try await Task.detached(priority: .userInitiated) {
            try FrameGrab.make(from: buffer, withPhoto: withPhoto)
        }.value
    }

    /// いまのカメラの景色を写真にする（AR の飾りは写らない。位置などの付加情報も入らない）
    func grabPhoto() async -> UIImage? {
        guard let buffer = arView.session.currentFrame?.capturedImage else { return nil }
        let data = await Task.detached(priority: .userInitiated) {
            FrameGrab.photo(from: buffer)
        }.value
        return data.flatMap(UIImage.init(data:))
    }

    // MARK: 場所の記憶

    func captureWorldMap() async throws -> ARWorldMap {
        try await withCheckedThrowingContinuation { continuation in
            arView.session.getCurrentWorldMap { map, error in
                if let map {
                    continuation.resume(returning: map)
                } else {
                    continuation.resume(throwing: error ?? StageError.noWorldMap)
                }
            }
        }
    }

    /// 場所の記憶で、作った人と同じ座標に合わせる。見つかれば、作った人が置いた印（ARAnchor）を返す。
    /// 見つからない・やめたときは nil を返し、ふつうの AR で始め直す。
    func relocalize(with map: ARWorldMap, anchorName: String, timeout: TimeInterval,
                    shouldStop: () -> Bool) async -> ARAnchor? {
        run(initialMap: map)
        let started = Date()
        var sawRelocalizing = false
        while Date().timeIntervalSince(started) < timeout, !Task.isCancelled, !shouldStop() {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let frame = arView.session.currentFrame else { continue }
            switch frame.camera.trackingState {
            case .limited(.relocalizing):
                sawRelocalizing = true
            case .normal:
                if let anchor = frame.anchors.first(where: { $0.name == anchorName }) {
                    relocalizing = false
                    Trace.log(String(format: "場所の記憶が見つかりました（%.1f 秒）", Date().timeIntervalSince(started)))
                    return anchor
                }
            default:
                break
            }
        }
        relocalizing = false
        Trace.log(String(format: "場所の記憶が見つかりませんでした（%.1f 秒・探索中の表示：%@・途中でやめた：%@）。ふつうの AR で始め直します",
                         Date().timeIntervalSince(started), sawRelocalizing ? "あり" : "なし",
                         (Task.isCancelled || shouldStop()) ? "はい" : "いいえ"))
        run(initialMap: nil, reset: true)
        return nil
    }

    // MARK: コマごと

    fileprivate func frameUpdated(position: SIMD3<Float>, time: TimeInterval, tracking: ARCamera.TrackingState,
                                  mapping newMapping: ARFrame.WorldMappingStatus, light: CGFloat) {
        if let last = lastPosition, time > lastTime {
            let dt = Float(time - lastTime)
            let moved = simd_distance(position, last)
            if case .normal = tracking, moved > 0.6, dt < 0.2, !relocalizing {
                Trace.log(String(format: "AR の座標が 1 コマで %.2fm 飛びました（暗さ %.0f）", moved, light))
            }
            cameraSpeed = cameraSpeed * 0.85 + min(moved / max(dt, 0.001), 5) * 0.15
        }
        lastPosition = position
        lastTime = time

        let next = Self.guidance(for: tracking, light: light)
        if next != guidance {
            guidance = next
            Trace.log("AR の状態：\(next.text ?? "ふつう")")
        }
        if newMapping != mapping {
            mapping = newMapping
        }
    }

    private static func guidance(for tracking: ARCamera.TrackingState, light: CGFloat) -> Guidance {
        switch tracking {
        case .notAvailable:
            return .starting
        case .limited(let reason):
            switch reason {
            case .initializing: return .lookAround
            case .excessiveMotion: return .moveSlowly
            case .insufficientFeatures: return light < 150 ? .tooDark : .featureless
            case .relocalizing: return .relocalizing
            @unknown default: return .lookAround
            }
        case .normal:
            return .ready
        }
    }

    fileprivate func setInterrupted(_ interrupted: Bool) {
        guidance = interrupted ? .interrupted : .lookAround
        Trace.log(interrupted ? "AR が中断されました" : "AR の中断が終わりました")
    }
}

extension ARStage: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t = frame.camera.transform.columns.3
        let position = SIMD3<Float>(t.x, t.y, t.z)
        let tracking = frame.camera.trackingState
        let mapping = frame.worldMappingStatus
        let light = frame.lightEstimate?.ambientIntensity ?? 1000
        let time = frame.timestamp
        MainActor.assumeIsolated {
            self.frameUpdated(position: position, time: time, tracking: tracking, mapping: mapping, light: light)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated { self.setInterrupted(true) }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        MainActor.assumeIsolated { self.setInterrupted(false) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            Trace.log("AR のエラー：\(message)")
        }
    }

    /// 中断のあと、前の座標に戻ろうとする（扉が元の場所に戻るように）
    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
}

/// AR のカメラの絵から、写真の特徴と写真を作る（メインの列の外で呼ぶ）
enum FrameGrab {
    struct Shot {
        let print: [Float]
        let jpeg: Data?
    }

    private static let context = CIContext()

    static func make(from buffer: CVPixelBuffer, withPhoto: Bool) throws -> Shot {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = FeaturePrint.revision
        // 縦に持ったときの背面カメラの絵は、右に 90° 回っている
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { throw FeaturePrint.Failure.noResult }
        let values = observation.floatValues
        guard !values.isEmpty else { throw FeaturePrint.Failure.noResult }
        return Shot(print: values, jpeg: withPhoto ? photo(from: buffer) : nil)
    }

    /// カメラの絵を JPEG にする（位置などの付加情報は入らない）
    static func photo(from buffer: CVPixelBuffer, maxSide: CGFloat = 1600) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer).oriented(.right)
        let longest = max(image.extent.width, image.extent.height)
        if longest > maxSide {
            let s = maxSide / longest
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.82)
    }
}
