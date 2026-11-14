import CoreVideo
import Foundation

/// 写す前に、カメラの絵そのものに「見分けられる模様」があるかを測る。
///
/// 前は AR の点（ARKit が立体の位置として拾えた点）の数で決めていたが、その点は少し動いて角度が変わらないと増えないので、
/// 「止めて写して」と言うほど減り、近くの物を写すと後ろの白い壁で足りなくなって、模様の多い物でも断っていた（2026-11-15）。
/// 写真の特徴（Vision）で見分けるのは絵なので、絵の明るさの変わり目（輪郭）の多さと、それが絵の何区画に散っているかで決める。
///
/// 160×120 に縮めた明るさの絵で測る（1 回 1 ミリ秒ほど）。しきい値は 2026-11-15 のオーナーの画面で測った値から決めた：
/// 模様の多い物の写真は 輪郭 22%・27 区画、白い壁だけは 0.2%・0 区画。
///
/// 景色（`GateKind.view`）は、空や海が広く、見分ける手がかりが稜線・水平線・夜の明かりのような細い線や点になるので、
/// やわらかい輪郭（差 16 以上・区画の 4% 以上）で数える（2026-11-15。景色らしい絵で測った値：稜線と街 9%・26 区画、
/// 凪の海と空 1.7%・16、夜景の明かり 30 個 1.2%・6、霞んだ山 1.6%・8、空だけ・真っ暗・白い壁は 0%・0）。
struct ShotQuality {
    /// 明るさの平均（0〜255）
    let meanLuma: Float
    /// 輪郭の点の割合（0〜1）
    let edgeFraction: Float
    /// 8×6 の区画のうち、模様のある区画の数
    let texturedCells: Int
    /// やわらかい輪郭の割合（景色用）
    let softEdgeFraction: Float
    /// やわらかい輪郭で数えた、模様のある区画の数（景色用）
    let softTexturedCells: Int

    static let cellColumns = 8
    static let cellRows = 6
    static var cellCount: Int { cellColumns * cellRows }

    /// 暗すぎる（景色は、夜の明かりが見えていれば暗くても写せる）
    func isDark(view: Bool) -> Bool {
        view ? (meanLuma < 40 && softEdgeFraction < 0.008) : meanLuma < 40
    }

    /// 見分けられるだけの模様がある
    func hasPattern(view: Bool) -> Bool {
        view ? (softEdgeFraction >= 0.012 && softTexturedCells >= 5)
             : (edgeFraction >= 0.04 && texturedCells >= 10)
    }

    /// ARKit のカメラの絵（420f／420v。1 枚めが明るさ）から測る。読めない形なら nil（そのときは止めない）。
    /// 絵は読むあいだだけ借りて、すぐ返す。
    static func measure(_ buffer: CVPixelBuffer) -> ShotQuality? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cols = 160, rows = 120
        guard width >= cols * 2, height >= rows * 2 else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        // 縮める：区画ごとに 4 点の平均（細かいざらつきで輪郭が増えないように）
        let sx = width / cols, sy = height / rows
        let hx = max(1, sx / 2), hy = max(1, sy / 2)
        var small = [Float](repeating: 0, count: cols * rows)
        var sum: Float = 0
        small.withUnsafeMutableBufferPointer { out in
            for r in 0..<rows {
                let y0 = r * sy, y1 = min(height - 1, y0 + hy)
                let row0 = pixels + y0 * rowBytes, row1 = pixels + y1 * rowBytes
                for c in 0..<cols {
                    let x0 = c * sx, x1 = min(width - 1, x0 + hx)
                    let v = Float(Int(row0[x0]) + Int(row0[x1]) + Int(row1[x0]) + Int(row1[x1])) / 4
                    out[r * cols + c] = v
                    sum += v
                }
            }
        }

        // 輪郭：左右と上下の明るさの差の合計が 28（やわらかい輪郭は 16）より大きい点
        let threshold: Float = 28, softThreshold: Float = 16
        var cellEdges = [Int](repeating: 0, count: cellCount)
        var cellSoftEdges = [Int](repeating: 0, count: cellCount)
        var cellTotals = [Int](repeating: 0, count: cellCount)
        var edges = 0, softEdges = 0, total = 0
        small.withUnsafeBufferPointer { l in
            for r in 1..<(rows - 1) {
                let cellRow = (r * cellRows / rows) * cellColumns
                for c in 1..<(cols - 1) {
                    let gx = abs(l[r * cols + c + 1] - l[r * cols + c - 1])
                    let gy = abs(l[(r + 1) * cols + c] - l[(r - 1) * cols + c])
                    let g = gx + gy
                    let cell = cellRow + c * cellColumns / cols
                    cellTotals[cell] += 1
                    total += 1
                    if g > softThreshold {
                        softEdges += 1
                        cellSoftEdges[cell] += 1
                        if g > threshold {
                            edges += 1
                            cellEdges[cell] += 1
                        }
                    }
                }
            }
        }
        var textured = 0, softTextured = 0
        for i in 0..<cellCount where cellTotals[i] > 0 {
            let n = Float(cellTotals[i])
            if Float(cellEdges[i]) / n >= 0.08 { textured += 1 }
            if Float(cellSoftEdges[i]) / n >= 0.04 { softTextured += 1 }
        }
        let count = Float(max(total, 1))
        return ShotQuality(meanLuma: sum / Float(cols * rows),
                           edgeFraction: Float(edges) / count,
                           texturedCells: textured,
                           softEdgeFraction: Float(softEdges) / count,
                           softTexturedCells: softTextured)
    }
}
