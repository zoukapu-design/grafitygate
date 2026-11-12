import Foundation
import RealityKit
import simd

/// 扉のアーチの寸法（m）。人の背丈に合わせ、道をふさぐほど大きくしない。
struct ArchShape {
    /// 開口部の幅
    var openingWidth: Float = 0.8
    /// 開口部のまっすぐな部分の高さ（この上に半円が乗る）
    var legHeight: Float = 1.35
    /// 枠の太さ
    var frameWidth: Float = 0.1
    /// 枠の厚み（奥行き）
    var depth: Float = 0.14
    /// 半円の分け方（多いほど丸い）
    var arcSegments = 32

    var radius: Float { openingWidth / 2 }
    var innerHeight: Float { legHeight + radius }
    var outerWidth: Float { openingWidth + frameWidth * 2 }
    var outerHeight: Float { innerHeight + frameWidth }

    /// 開口部のふちに沿った点（左下 → 左上 → 半円 → 右上 → 右下）と、開口部の中心へ向く向き
    func openingPath(extraAngles: [Float] = []) -> [(p: SIMD2<Float>, n: SIMD2<Float>)] {
        var angles = (0...arcSegments).map { Float.pi - Float.pi * Float($0) / Float(arcSegments) }
        angles.append(contentsOf: extraAngles)
        angles = Array(Set(angles)).sorted(by: >)
        var path: [(p: SIMD2<Float>, n: SIMD2<Float>)] = [(p: SIMD2<Float>(-radius, 0), n: SIMD2<Float>(1, 0))]
        for a in angles {
            let dir = SIMD2<Float>(cos(a), sin(a))
            path.append((p: SIMD2<Float>(0, legHeight) + dir * radius, n: -dir))
        }
        path.append((p: SIMD2<Float>(radius, 0), n: SIMD2<Float>(-1, 0)))
        return path
    }
}

/// 三角形を積み上げて、RealityKit の形を作る道具
struct MeshBuilder {
    private(set) var positions: [SIMD3<Float>] = []
    private(set) var normals: [SIMD3<Float>] = []
    private(set) var uvs: [SIMD2<Float>] = []
    private(set) var indices: [UInt32] = []

    /// 4 点の面。a→b→c→d が、法線の側から見て反時計回り
    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                       normals na: SIMD3<Float>, _ nb: SIMD3<Float>, _ nc: SIMD3<Float>, _ nd: SIMD3<Float>) {
        let base = UInt32(positions.count)
        positions += [a, b, c, d]
        normals += [na, nb, nc, nd]
        uvs += [SIMD2(a.x, a.y), SIMD2(b.x, b.y), SIMD2(c.x, c.y), SIMD2(d.x, d.y)]
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    mutating func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, normal: SIMD3<Float>) {
        quad(a, b, c, d, normals: normal, normal, normal, normal)
    }

    mutating func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, normal: SIMD3<Float>,
                           uv: (SIMD3<Float>) -> SIMD2<Float>) {
        let base = UInt32(positions.count)
        positions += [a, b, c]
        normals += [normal, normal, normal]
        uvs += [uv(a), uv(b), uv(c)]
        indices += [base, base + 1, base + 2]
    }

    func mesh(name: String) throws -> MeshResource {
        var d = MeshDescriptor(name: name)
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        d.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        d.primitives = .triangles(indices)
        return try MeshResource.generate(from: [d])
    }
}

enum ArchMesh {
    /// 枠（開口部のふち path を内側として、太さ width・厚み depth の立体）。z の中心は zCenter。
    static func frame(path: [(p: SIMD2<Float>, n: SIMD2<Float>)], width: Float, depth: Float,
                      zCenter: Float = 0, name: String) throws -> MeshResource {
        var b = MeshBuilder()
        let zf = zCenter + depth / 2
        let zb = zCenter - depth / 2
        func v(_ p: SIMD2<Float>, _ z: Float) -> SIMD3<Float> { SIMD3(p.x, p.y, z) }
        for i in 0..<(path.count - 1) {
            let p0 = path[i].p, p1 = path[i + 1].p
            let n0 = path[i].n, n1 = path[i + 1].n
            let q0 = p0 - n0 * width, q1 = p1 - n1 * width
            // 正面と裏
            b.quad(v(p0, zf), v(p1, zf), v(q1, zf), v(q0, zf), normal: [0, 0, 1])
            b.quad(v(p0, zb), v(q0, zb), v(q1, zb), v(p1, zb), normal: [0, 0, -1])
            // 開口部の側（なめらかに丸める）と、外側
            let in0 = SIMD3<Float>(n0.x, n0.y, 0), in1 = SIMD3<Float>(n1.x, n1.y, 0)
            b.quad(v(p0, zf), v(p0, zb), v(p1, zb), v(p1, zf), normals: in0, in0, in1, in1)
            b.quad(v(q0, zf), v(q1, zf), v(q1, zb), v(q0, zb), normals: -in0, -in1, -in1, -in0)
        }
        return try b.mesh(name: name)
    }

    /// 開口部をふさぐ面（ガラス・向こうの世界の入口）。z の位置は z。+Z 向き。
    static func opening(path: [(p: SIMD2<Float>, n: SIMD2<Float>)], z: Float, name: String) throws -> MeshResource {
        var b = MeshBuilder()
        let ys = path.map(\.p.y)
        let center = SIMD3<Float>(0, ((ys.max() ?? 1) + (ys.min() ?? 0)) * 0.45, z)
        let count = path.count
        for i in 0..<count {
            let a = path[i].p
            let c = path[(i + 1) % count].p
            // 下の辺（右下 → 左下）も含めて一周する
            b.triangle(center, SIMD3(c.x, c.y, z), SIMD3(a.x, a.y, z), normal: [0, 0, 1]) { SIMD2($0.x, $0.y) }
        }
        return try b.mesh(name: name)
    }

    /// 開口部の形の穴があいた壁（向こうの世界を、扉越しにだけ見せるための見えない壁）。+Z 向き。
    static func wallWithOpening(shape: ArchShape, halfWidth: Float, height: Float, z: Float) throws -> MeshResource {
        // 四隅に向かう角度も入れて、壁の角に隙間ができないようにする
        let cornerAngle = atan2(height - shape.legHeight, halfWidth)
        let path = shape.openingPath(extraAngles: [cornerAngle, Float.pi - cornerAngle])
        var b = MeshBuilder()
        func outer(_ p: SIMD2<Float>, _ n: SIMD2<Float>) -> SIMD2<Float> {
            if abs(n.y) < 0.0001 && p.y <= shape.legHeight + 0.0001 {
                return SIMD2(n.x > 0 ? -halfWidth : halfWidth, p.y)
            }
            let dir = -n
            var t = Float.greatestFiniteMagnitude
            if dir.x > 0.0001 { t = min(t, halfWidth / dir.x) }
            if dir.x < -0.0001 { t = min(t, -halfWidth / dir.x) }
            if dir.y > 0.0001 { t = min(t, (height - shape.legHeight) / dir.y) }
            return SIMD2(0, shape.legHeight) + dir * t
        }
        for i in 0..<(path.count - 1) {
            let p0 = path[i].p, p1 = path[i + 1].p
            let r0 = outer(p0, path[i].n), r1 = outer(p1, path[i + 1].n)
            b.quad(SIMD3(p0.x, p0.y, z), SIMD3(p1.x, p1.y, z), SIMD3(r1.x, r1.y, z), SIMD3(r0.x, r0.y, z),
                   normal: [0, 0, 1])
        }
        return try b.mesh(name: "wall")
    }
}
