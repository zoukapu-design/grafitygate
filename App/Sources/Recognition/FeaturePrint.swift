import UIKit
import Vision

/// 写真の「特徴」（Apple の Vision が作る数の並び）。サーバーは参照写真の特徴との距離で、同じ場所・物かを判断する。
/// 写真そのものは送らず、この数の並びだけを送る。
enum FeaturePrint {
    /// 使う Vision の版。サーバーの gf_gate_refs.print_rev と同じ値で比べる（版が違うと比べない）
    static let revision = VNGenerateImageFeaturePrintRequestRevision2

    enum Failure: LocalizedError {
        case noImage
        case noResult

        var errorDescription: String? {
            switch self {
            case .noImage: return "写真を読み込めませんでした。撮り直してください。"
            case .noResult: return "写真の特徴を作れませんでした。明るい所で撮り直してください。"
            }
        }
    }

    /// 写真から特徴を作る（時間がかかるので、メインの列では呼ばない）
    static func make(from image: UIImage) throws -> [Float] {
        let small = image.downscaled(maxSide: 1024)
        guard let cg = small.cgImage else { throw Failure.noImage }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = revision
        let handler = VNImageRequestHandler(cgImage: cg, orientation: small.cgOrientation, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { throw Failure.noResult }
        let values = observation.floatValues
        guard !values.isEmpty else { throw Failure.noResult }
        return values
    }

    /// 2 つの特徴の距離（サーバーの gf_print_distance と同じ計算。調べもの用）
    static func distance(_ a: [Float], _ b: [Float]) -> Float? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var sum: Float = 0
        for i in 0..<a.count {
            let d = a[i] - b[i]
            sum += d * d
        }
        return sum.squareRoot()
    }
}

extension VNFeaturePrintObservation {
    var floatValues: [Float] {
        switch elementType {
        case .float:
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        case .double:
            return data.withUnsafeBytes { $0.bindMemory(to: Double.self).map { Float($0) } }
        default:
            return []
        }
    }
}

extension UIImage {
    /// 長い辺を maxSide 以下にした写真（向きは正しく直す）
    func downscaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }

    var cgOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
