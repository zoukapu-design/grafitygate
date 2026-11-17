import ARKit
import AVFoundation
import VideoToolbox

/// AR のカメラに映った人を、その場で 10 秒まで記録する（人物の映像の元。切り抜くのは `PersonCutout`）。
///
/// - 絵：ARKit のカメラの絵（1920×1440 など）を 960×720 に縮めた写しを作って記録し、ARKit の絵はすぐ返す
///   （ARKit の絵を長く持つと、AR の絵が止まる）。30 コマ/秒。縦持ちで見えるように、動画に向きを付ける。
/// - 声：ARKit のマイク（`providesAudioData`）。記録しているあいだだけ音の種類を録音もできる形にし、終わったら
///   `ARAudio.prepare()` に戻す。マイクが許可されていなければ、声なしで撮る。
/// - 映像・声はサーバーに送らない。切り抜いたあとの人物の映像だけを、置いたときに送る。
@MainActor
final class ARPersonRecorder: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case finishing
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var withAudio = false

    static let limit: Double = 10
    static let minimum: Double = 1

    /// 10 秒になったとき
    var onLimit: (() -> Void)?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var transfer: VTPixelTransferSession?
    private var startTime: CMTime?
    private var lastVideoSeconds: Double = -1
    private var frames = 0
    private var limitFired = false
    /// 声の時刻を絵の時刻にそろえるずれ（ふつうは 0。ARKit は同じ時計で渡すが、違ったときのため）
    private var audioShift: CMTime?
    private var url: URL?
    private weak var stage: ARStage?

    private static let size = (width: 960, height: 720)

    enum Failure: LocalizedError {
        case cannotStart
        case tooShort
        case failed

        var errorDescription: String? {
            switch self {
            case .cannotStart: return "記録を始められませんでした。もう一度お試しください。"
            case .tooShort: return "短すぎます。1 秒以上撮ってください。"
            case .failed: return "記録を保存できませんでした。もう一度お試しください。"
            }
        }
    }

    func start(stage: ARStage) async throws {
        guard state == .idle else { return }
        let micAllowed = await Self.askMicrophone()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("person-\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: file, fileType: .mov) else { throw Failure.cannotStart }

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.size.width,
            AVVideoHeightKey: Self.size.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000],
        ])
        video.expectsMediaDataInRealTime = true
        // ARKit の絵は横向き。縦持ちで見えるように 90° 回して見せる（iPhone のカメラで縦に撮った動画と同じ値。
        // rotationAngle で作ると 0 がわずかにずれ、切り抜きの向きの判定 `PersonCutout.orientation` が外れる）
        // 撮り始めたときの持ち方で、動画の向きを決める（横に持って撮っても、人がまっすぐ立つように）
        let w = CGFloat(Self.size.width), h = CGFloat(Self.size.height)
        let holding = stage.arView.session.currentFrame.map { FrameGrab.orientation(of: $0.camera.transform) } ?? .right
        switch holding {
        case .up: video.transform = .identity
        case .down: video.transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .left: video.transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: video.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        }
        Trace.log("人物の映像：持ち方 \(holding.rawValue)（1＝横・6＝縦）で撮る")
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: Self.size.width,
            kCVPixelBufferHeightKey as String: Self.size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        guard writer.canAdd(video) else { throw Failure.cannotStart }
        writer.add(video)

        var audio: AVAssetWriterInput?
        if micAllowed {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 96_000,
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            }
        }
        guard writer.startWriting() else { throw Failure.cannotStart }

        var session: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
        guard let session else { throw Failure.cannotStart }

        self.writer = writer
        self.videoInput = video
        self.audioInput = audio
        self.adaptor = adaptor
        self.transfer = session
        self.url = file
        self.stage = stage
        startTime = nil
        lastVideoSeconds = -1
        frames = 0
        limitFired = false
        audioShift = nil
        elapsed = 0
        withAudio = audio != nil
        state = .recording

        if audio != nil {
            Self.useRecordingAudio(true)
            stage.setAudioCapture(true)
            stage.audioTap = { [weak self] buffer in self?.append(audio: buffer) }
        }
        stage.frameTap = { [weak self] frame in self?.append(frame: frame) }
        Trace.log("人物の映像：その場で記録を始めました（声：\(audio != nil ? "あり" : "なし（マイクが許可されていない）")）")
    }

    /// 止めて、記録したファイルを返す
    func stop() async throws -> URL {
        guard state == .recording, let writer, let url else { throw Failure.failed }
        state = .finishing
        detach()
        let length = elapsed
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        if startTime != nil {
            await writer.finishWriting()
        } else {
            writer.cancelWriting()
        }
        defer { reset() }
        Trace.log(String(format: "人物の映像：記録を止めました（%.1f 秒・%d コマ・状態 %d）", length, frames, writer.status.rawValue))
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw Failure.failed
        }
        guard length >= Self.minimum else {
            try? FileManager.default.removeItem(at: url)
            throw Failure.tooShort
        }
        return url
    }

    func cancel() {
        guard state != .idle else { return }
        detach()
        writer?.cancelWriting()
        if let url { try? FileManager.default.removeItem(at: url) }
        reset()
        Trace.log("人物の映像：記録をやめました")
    }

    // MARK: 中身

    private func append(frame: ARFrame) {
        guard state == .recording, let writer, writer.status == .writing, let videoInput, let adaptor, let transfer else { return }
        let seconds = frame.timestamp
        // 30 コマ/秒にそろえる
        if lastVideoSeconds >= 0, seconds - lastVideoSeconds < 1.0 / 31.0 { return }
        let time = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
        if startTime == nil {
            writer.startSession(atSourceTime: time)
            startTime = time
        }
        guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return }
        // 縮めた写しを作る（ARKit の絵は、この関数を出たら返す）
        guard VTPixelTransferSessionTransferImage(transfer, from: frame.capturedImage, to: out) == noErr else { return }
        if adaptor.append(out, withPresentationTime: time) {
            lastVideoSeconds = seconds
            frames += 1
        }
        if let start = startTime {
            let now = CMTimeGetSeconds(CMTimeSubtract(time, start))
            // 画面の数字は 0.1 秒ごとに変える（毎コマ変えると画面を描き直しすぎる）
            if now - elapsed >= 0.1 || now >= Self.limit { elapsed = now }
            if now >= Self.limit, !limitFired {
                limitFired = true
                onLimit?()
            }
        }
    }

    private func append(audio buffer: CMSampleBuffer) {
        guard state == .recording, let startTime, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if audioShift == nil {
            let gap = CMTimeGetSeconds(pts) - lastVideoSeconds
            audioShift = abs(gap) > 1 ? CMTime(seconds: -gap, preferredTimescale: 1_000_000) : .zero
            Trace.log(String(format: "人物の映像：声と絵の時刻の差 %.3f 秒%@", gap, abs(gap) > 1 ? "（そろえます）" : ""))
        }
        var sample = buffer
        if let shift = audioShift, shift != .zero {
            guard let moved = Self.shifted(buffer, by: shift) else { return }
            sample = moved
        }
        // 絵より前の声は入れない
        guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), startTime) >= 0 else { return }
        audioInput.append(sample)
    }

    private static func shifted(_ buffer: CMSampleBuffer, by shift: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for index in timings.indices {
            timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, shift)
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, shift)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timings, sampleBufferOut: &out)
        return out
    }

    private func detach() {
        stage?.frameTap = nil
        stage?.audioTap = nil
        if withAudio {
            stage?.setAudioCapture(false)
            Self.useRecordingAudio(false)
        }
    }

    private func reset() {
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        transfer = nil
        url = nil
        startTime = nil
        state = .idle
    }

    private static func askMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// 記録しているあいだだけ、録音もできる音の種類にする（終わったら AR の音の決まりに戻す）
    private static func useRecordingAudio(_ on: Bool) {
        if on {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoRecording,
                                                                options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                Trace.log("人物の映像：録音の準備ができませんでした：\(error.localizedDescription)")
            }
        } else {
            ARAudio.prepare()
        }
    }
}
