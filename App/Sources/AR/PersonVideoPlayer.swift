import AVFoundation
import Metal
import RealityKit
import UIKit

/// 透けるところのある動画（HEVC のアルファ付き）を流して、毎コマ RealityKit の質感に写す。
/// AVPlayer の絵（BGRA・アルファ付き）を、Metal で質感（DrawableQueue）に写すだけ（形を描くプログラムは持たない）。
@MainActor
final class PersonVideoPlayer {
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private var feeder: VideoTextureFeeder?
    private var endObserver: NSObjectProtocol?
    private(set) var texture: TextureResource?
    /// 流し終えたとき
    var onEnd: (() -> Void)?

    init(url: URL) {
        item = AVPlayerItem(url: url)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnd?() }
        }
    }

    func play() {
        player.play()
    }

    /// 毎コマ呼ぶ。新しい絵があれば質感に写す。はじめて写せたとき（質感ができたとき）true。
    @discardableResult
    func pump() -> Bool {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return false }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var created = false
        if feeder == nil || feeder?.width != width || feeder?.height != height {
            feeder = VideoTextureFeeder(width: width, height: height)
            texture = feeder?.texture
            created = feeder != nil
            if feeder == nil { Trace.log("人物の映像：質感を作れませんでした（\(width)×\(height)）") }
        }
        feeder?.push(buffer)
        return created
    }

    /// 映像の縦横の比（幅 ÷ 高さ。まだ分からなければ nil）
    var aspect: Float? {
        guard let feeder, feeder.height > 0 else { return nil }
        return Float(feeder.width) / Float(feeder.height)
    }

    func stop() {
        player.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        onEnd = nil
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
}

/// CVPixelBuffer（BGRA）を、RealityKit の質感へ毎コマ写す入れ物
@MainActor
final class VideoTextureFeeder {
    let width: Int
    let height: Int
    let texture: TextureResource
    private let queue: TextureResource.DrawableQueue
    private let device: MTLDevice
    private let commands: MTLCommandQueue
    private var cache: CVMetalTextureCache?

    init?(width: Int, height: Int) {
        guard width > 0, height > 0, let device = MTLCreateSystemDefaultDevice(),
              let commands = device.makeCommandQueue() else { return nil }
        self.width = width
        self.height = height
        self.device = device
        self.commands = commands
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        do {
            let descriptor = TextureResource.DrawableQueue.Descriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                      usage: [.shaderRead, .renderTarget],
                                                                      mipmapsMode: .none)
            queue = try TextureResource.DrawableQueue(descriptor)
            queue.allowsNextDrawableTimeout = true
            // 初めは透明な 1 点の絵。すぐに動画の絵に置き換わる
            guard let blank = Self.blankImage() else { return nil }
            texture = try TextureResource.generate(from: blank, options: .init(semantic: .color))
            texture.replace(withDrawables: queue)
        } catch {
            Trace.log("人物の映像：質感の入れ物を作れませんでした（\(error.localizedDescription)）")
            return nil
        }
    }

    func push(_ buffer: CVPixelBuffer) {
        guard let cache, let drawable = try? queue.nextDrawable() else { return }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm, width, height, 0,
                                                  &cvTexture)
        guard let cvTexture, let source = CVMetalTextureGetTexture(cvTexture),
              let commandBuffer = commands.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        let size = MTLSize(width: min(width, drawable.texture.width), height: min(height, drawable.texture.height), depth: 1)
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: size,
                  to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        drawable.present()
    }

    private static func blankImage() -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
        return ctx.makeImage()
    }
}
