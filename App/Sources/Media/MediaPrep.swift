import AVFoundation
import CoreTransferable
import UIKit
import UniformTypeIdentifiers

/// 写真アプリから選んだ動画を受け取る（一時フォルダに写してから使う）
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Self(url: dest)
        }
    }
}

/// 送る前の動画・声の下ごしらえ（iPhone の中だけで行う）
enum MediaPrep {
    /// 思い出の動画の長さ（秒）
    static let videoLimit: Double = 15
    /// 思い出の声の長さ（秒）
    static let voiceLimit: Double = 60

    struct PreparedVideo {
        let file: URL
        let thumbnail: UIImage
        let duration: Double
        /// 15 秒より長かったので、はじめの 15 秒にした
        let trimmed: Bool
    }

    enum Failure: LocalizedError {
        case unreadable
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: return "動画を読み込めませんでした。"
            case .exportFailed(let reason): return "動画を作り直せませんでした（\(reason)）。"
            }
        }
    }

    /// 動画を 720p・はじめの 15 秒まで・付加情報（位置など）なしの MP4 に作り直し、表紙の絵を作る
    static func prepareVideo(_ source: URL) async throws -> PreparedVideo {
        let asset = AVURLAsset(url: source)
        let total = try await asset.load(.duration).seconds
        guard total.isFinite, total > 0.3 else { throw Failure.unreadable }
        let length = min(total, videoLimit)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw Failure.exportFailed("この動画は作り直せません")
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: length, preferredTimescale: 600))
        session.metadata = []
        session.metadataItemFilter = .forSharing()
        await session.export()
        guard session.status == .completed else {
            throw Failure.exportFailed(session.error?.localizedDescription ?? "不明")
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let at = CMTime(seconds: min(0.5, length / 2), preferredTimescale: 600)
        let cgImage = try await generator.image(at: at).image
        try? FileManager.default.removeItem(at: source)
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        Trace.log(String(format: "動画を作り直しました（%.1f 秒→%.1f 秒・%dKB）", total, length, size / 1024))
        return PreparedVideo(file: output, thumbnail: UIImage(cgImage: cgImage), duration: length,
                             trimmed: total > videoLimit + 0.2)
    }

    /// 長さ（秒）
    static func duration(of url: URL) async -> Double {
        (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
    }
}
