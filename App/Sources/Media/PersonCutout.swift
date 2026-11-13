import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import VideoToolbox
import Vision

/// 「切り抜いた人物の映像」を作る：人が写った動画から、iPhone の中で人だけを切り抜き（Vision の人の形）、
/// 透けるところのある動画（HEVC のアルファ付き・.mov・10 秒まで・24 コマ/秒・長い辺 720）にする。
/// 声（音）はそのまま入れる。カメラの映像はどこにも送らず、できた動画だけを、置くと決めたときに送る。
enum PersonCutout {
    static let limit: Double = 10
    static let maxSide: CGFloat = 720
    static let fps: Double = 24

    struct Result {
        /// できた動画（.mov・アルファ付き）
        let file: URL
        /// 透けるところのある最初の絵（AR に置く見本・置いた直後の姿）
        let poster: UIImage
        /// 一覧に出す絵（夜空の色の上に人を重ねた、透けない絵）
        let thumbnail: UIImage
        let duration: Double
        /// 10 秒より長かったので、はじめの 10 秒にした
        let trimmed: Bool
    }

    enum Failure: LocalizedError {
        case unreadable
        case noPerson
        case unsupported
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "動画を読み込めませんでした。"
            case .noPerson: return "人が見つかりませんでした。人の全身か上半身が、はっきり写っている動画を選んでください。"
            case .unsupported: return "この iPhone では、切り抜いた映像を作れません。"
            case .failed(let reason): return "切り抜いた映像を作れませんでした（\(reason)）。"
            }
        }
    }

    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])

    /// 動画から人だけを切り抜く。progress は 0〜1（メインの列の外から呼ばれる）
    static func make(from source: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.unreadable }
        let total = try await asset.load(.duration).seconds
        guard total.isFinite, total > 0.5 else { throw Failure.unreadable }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let length = min(total, limit)
        let started = Date()
        let result = try await Task.detached(priority: .userInitiated) {
            try process(asset: asset, track: track, audioTrack: audioTrack, natural: natural, transform: transform,
                        length: length, trimmed: total > limit + 0.2, progress: progress)
        }.value
        try? FileManager.default.removeItem(at: source)
        let size = (try? FileManager.default.attributesOfItem(atPath: result.file.path)[.size] as? Int) ?? 0
        Trace.log(String(format: "人物の映像を作りました（%.1f 秒・%dKB・%.1f 秒かかった）", result.duration, size / 1024,
                         Date().timeIntervalSince(started)))
        return result
    }

    // MARK: 中身

    private static func process(asset: AVURLAsset, track: AVAssetTrack, audioTrack: AVAssetTrack?, natural: CGSize,
                                transform: CGAffineTransform, length: Double, trimmed: Bool,
                                progress: @Sendable (Double) -> Void) throws -> Result {
        let orientation = orientation(for: transform)
        let rotated = orientation == .left || orientation == .right
        let upright = rotated ? CGSize(width: natural.height, height: natural.width) : natural
        let scale = min(1, maxSide / max(upright.width, upright.height))
        let outW = max(2, Int((upright.width * scale / 2).rounded()) * 2)
        let outH = max(2, Int((upright.height * scale / 2).rounded()) * 2)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600))

        // 声は先に読んでおき、映像と交互に書く（書く側は両方が進むのを待つため）
        var audioSamples: [CMSampleBuffer] = []
        var audioFormat: CMFormatDescription?
        if let audioTrack, let reader = try? AVAssetReader(asset: asset) {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            reader.timeRange = range
            if reader.canAdd(output) {
                reader.add(output)
                if reader.startReading() {
                    while let sample = output.copyNextSampleBuffer() {
                        if audioFormat == nil { audioFormat = CMSampleBufferGetFormatDescription(sample) }
                        audioSamples.append(sample)
                    }
                }
            }
        }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw Failure.unreadable }
        reader.add(videoOutput)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("person-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_500_000,
                kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.8,
                kVTCompressionPropertyKey_AlphaChannelMode as String: kVTAlphaChannelMode_PremultipliedAlpha,
            ] as [String: Any],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw Failure.unsupported }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH,
        ])
        guard writer.canAdd(videoInput) else { throw Failure.unsupported }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if let audioFormat, !audioSamples.isEmpty {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else { throw Failure.failed(reader.error?.localizedDescription ?? "読み込み") }
        guard writer.startWriting() else { throw Failure.failed(writer.error?.localizedDescription ?? "書き出し") }
        writer.startSession(atSourceTime: .zero)

        var audioIndex = 0
        /// 声を 1 つ書く（書けたら true）
        func pushAudio(upTo limit: CMTime?) -> Bool {
            guard let audioInput, audioIndex < audioSamples.count, audioInput.isReadyForMoreMediaData else { return false }
            let sample = audioSamples[audioIndex]
            if let limit, CMSampleBufferGetPresentationTimeStamp(sample) > limit { return false }
            audioInput.append(sample)
            audioIndex += 1
            return true
        }
        /// 映像を書けるようになるまで待つ（そのあいだに声を進める＝書く側が詰まらないように）
        func waitVideoReady() {
            var waited = 0
            while !videoInput.isReadyForMoreMediaData && writer.status == .writing {
                if !pushAudio(upTo: nil) {
                    Thread.sleep(forTimeInterval: 0.003)
                    waited += 1
                    if waited > 4000 { break }   // 12 秒より待ったらあきらめる
                }
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        var lastPTS: CMTime?
        var poster: CGImage?
        var coverageSum = 0.0
        var coverageCount = 0
        var frameIndex = 0
        var lastTime = 0.0

        while let sample = videoOutput.copyNextSampleBuffer() {
            guard let source = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if let lastPTS, (pts - lastPTS).seconds < 1 / fps - 0.004 { continue }   // 24 コマ/秒に間引く
            lastPTS = pts
            try autoreleasepool {
                var image = CIImage(cvPixelBuffer: source).oriented(orientation)
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                let extent = CGRect(x: 0, y: 0, width: outW, height: outH)
                image = image.cropped(to: extent)

                // 人の形（白＝人）
                try VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
                guard let maskBuffer = request.results?.first?.pixelBuffer else { return }
                var mask = CIImage(cvPixelBuffer: maskBuffer)
                mask = mask.transformed(by: CGAffineTransform(scaleX: CGFloat(outW) / mask.extent.width,
                                                              y: CGFloat(outH) / mask.extent.height))
                mask = mask.clampedToExtent().applyingGaussianBlur(sigma: 1.4).cropped(to: extent)

                // 人がどれくらい写っているか（ときどき測る）
                if frameIndex % 8 == 0 { coverageSum += average(of: mask, in: extent); coverageCount += 1 }
                frameIndex += 1

                let cut = image.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: mask,
                ]).cropped(to: extent)
                if poster == nil { poster = context.createCGImage(cut, from: extent) }

                guard let pool = adaptor.pixelBufferPool else { throw Failure.failed("書き出しの準備") }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw Failure.failed("書き出しの準備") }
                context.render(cut, to: buffer, bounds: extent, colorSpace: colorSpace)

                // 声をこの時刻まで進めてから、映像を書く
                while pushAudio(upTo: pts) {}
                waitVideoReady()
                guard videoInput.isReadyForMoreMediaData else { throw Failure.failed("書き出しが進まない") }
                if !adaptor.append(buffer, withPresentationTime: pts) {
                    throw Failure.failed(writer.error?.localizedDescription ?? "書き出し")
                }
                lastTime = pts.seconds
            }
            progress(min(0.98, lastTime / max(length, 0.1)))
        }
        reader.cancelReading()
        videoInput.markAsFinished()
        // 残りの声
        while let audioInput, audioIndex < audioSamples.count {
            if audioInput.isReadyForMoreMediaData {
                audioInput.append(audioSamples[audioIndex])
                audioIndex += 1
            } else {
                Thread.sleep(forTimeInterval: 0.003)
            }
        }
        audioInput?.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw Failure.failed(writer.error?.localizedDescription ?? "書き出し")
        }
        let coverage = coverageCount > 0 ? coverageSum / Double(coverageCount) : 0
        Trace.log(String(format: "人物の映像：人の写っている割合 %.0f%%（%d コマ）", coverage * 100, frameIndex))
        guard coverage > 0.015, let poster else {
            try? FileManager.default.removeItem(at: out)
            throw Failure.noPerson
        }
        let posterImage = UIImage(cgImage: poster)
        return Result(file: out, poster: posterImage, thumbnail: thumbnail(of: posterImage),
                      duration: max(0.5, min(lastTime + 1 / fps, limit)), trimmed: trimmed)
    }

    /// 白黒の絵の平均の明るさ（0〜1＝人の写っている割合）
    private static func average(of mask: CIImage, in extent: CGRect) -> Double {
        let avg = mask.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: extent)])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(avg, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return Double(pixel[0]) / 255
    }

    /// 一覧用：夜空の色の上に人を重ねる
    private static func thumbnail(of poster: UIImage) -> UIImage {
        let size = poster.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let colors = [UIColor(red: 0.04, green: 0.06, blue: 0.16, alpha: 1).cgColor,
                          UIColor(red: 0.17, green: 0.08, blue: 0.27, alpha: 1).cgColor,
                          UIColor(red: 0.42, green: 0.16, blue: 0.24, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                         locations: [0, 0.65, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            poster.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 動画の向き（iPhone で縦に撮った動画は、横のまま入っていて向きの印で回す）
    private static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 { return .right }
        if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 { return .left }
        if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 { return .down }
        return .up
    }

    /// 受け取った人物の映像の、最初の絵（透けるところのある絵。AR に置いたまま見せる）
    static func poster(of file: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: image)
    }
}
