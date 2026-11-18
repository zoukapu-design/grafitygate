import Foundation
import RealityKit
import simd

/// 扉の開口部の形と寸法（m・扉の足もとの中心が原点）。人の背丈に合わせ、道をふさぐほど大きくしない。
/// 2026-11-18：扉の見た目（DoorDesign）を増やすため、アーチのほかに円・角の丸い四角・ハートも作れるようにした。
struct DoorShape {
    enum Kind {
        /// 上が半円の四角（いままでの扉）
        case arch
        /// 円（地面から浮かせる）
        case circle
        /// 角の丸い四角（鳥居・木の扉など）
        case roundedRect
        /// ハート（地面から浮かせる）
        case heart
    }

    var kind: Kind = .arch
    /// 開口部の幅
    var openingWidth: Float = 0.8
    /// 開口部の高さ（下のふちから上のふちまで）
    var openingHeight: Float = 1.75
    /// 開口部の下のふちの高さ（円・ハートは地面から浮かせる）
    var lift: Float = 0
    /// 角の丸み（角の丸い四角）
    var corner: Float = 0.1
    /// 枠の太さ
    var frameWidth: Float = 0.1
    /// 枠の厚み（奥行き）
    var depth: Float = 0.14
    /// 曲がった所の分け方（多いほどなめらか）
    var arcSegments = 32

    var radius: Float { openingWidth / 2 }
    /// 開口部のいちばん上の高さ
    var innerHeight: Float { lift + openingHeight }
    /// アーチの足の高さ（この上に半円）
    var legHeight: Float { kind == .arch ? max(0, innerHeight - radius) : innerHeight }
    var outerWidth: Float { openingWidth + frameWidth * 2 }
    var outerHeight: Float { innerHeight + frameWidth }
    /// 開口部がぐるりと閉じているか（円・ハート）。閉じていなければ、下は地面で開いている
    var isClosed: Bool { kind == .circle || kind == .heart }
    /// 開口部の「まん中」（ここから見て、ふちがひと回りする点）
    var center: SIMD2<Float> {
        switch kind {
        case .arch: return SIMD2(0, legHeight * 0.75)
        case .circle: return SIMD2(0, lift + radius)
        case .roundedRect: return SIMD2(0, innerHeight * 0.5)
        case .heart: return SIMD2(0, lift + openingHeight * (17.0 / 28.9))
        }
    }

    /// 開口部のふちに沿った点と、開口部の内側へ向く向き。
    /// 閉じていない形は左下 → 上 → 右下。閉じている形はひと回りして、最初の点で終わる
    func openingPath() -> [(p: SIMD2<Float>, n: SIMD2<Float>)] {
        switch kind {
        case .arch:
            var path: [(p: SIMD2<Float>, n: SIMD2<Float>)] = [(p: SIMD2<Float>(-radius, 0), n: SIMD2<Float>(1, 0))]
            for i in 0...arcSegments {
                let a = Float.pi - Float.pi * Float(i) / Float(arcSegments)
                let dir = SIMD2<Float>(cos(a), sin(a))
                path.append((p: SIMD2<Float>(0, legHeight) + dir * radius, n: -dir))
            }
            path.append((p: SIMD2<Float>(radius, 0), n: SIMD2<Float>(-1, 0)))
            return path
        case .circle:
            let c = center
            var path: [(p: SIMD2<Float>, n: SIMD2<Float>)] = []
            let count = arcSegments * 2
            for i in 0...count {
                // 左（180°）から時計回りにひと回り
                let a = Float.pi - 2 * Float.pi * Float(i) / Float(count)
                let dir = SIMD2<Float>(cos(a), sin(a))
                path.append((p: c + dir * radius, n: -dir))
            }
            return path
        case .roundedRect:
            let r = min(corner, radius * 0.9, innerHeight * 0.45)
            let left = -radius, right = radius, top = innerHeight
            var path: [(p: SIMD2<Float>, n: SIMD2<Float>)] = [(p: SIMD2(left, 0), n: SIMD2(1, 0))]
            let steps = max(4, arcSegments / 4)
            // 左上の角
            let c1 = SIMD2<Float>(left + r, top - r)
            for i in 0...steps {
                let a = Float.pi - (Float.pi / 2) * Float(i) / Float(steps)
                let dir = SIMD2<Float>(cos(a), sin(a))
                path.append((p: c1 + dir * r, n: -dir))
            }
            // 右上の角
            let c2 = SIMD2<Float>(right - r, top - r)
            for i in 0...steps {
                let a = Float.pi / 2 - (Float.pi / 2) * Float(i) / Float(steps)
                let dir = SIMD2<Float>(cos(a), sin(a))
                path.append((p: c2 + dir * r, n: -dir))
            }
            path.append((p: SIMD2(right, 0), n: SIMD2(-1, 0)))
            return path
        case .heart:
            // ハートの式（幅 32・高さ 28.9 の形）を、開口部の大きさに合わせる。上のくぼみから時計回り
            let sx = openingWidth / 32, sy = openingHeight / 28.9
            let base = SIMD2<Float>(0, lift + 17 * sy)
            let count = arcSegments * 3
            var points: [SIMD2<Float>] = []
            for i in 0..<count {
                let t = 2 * Float.pi * Float(i) / Float(count)
                let x = 16 * pow(sin(t), 3)
                let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                points.append(base + SIMD2(x * sx, y * sy))
            }
            var path: [(p: SIMD2<Float>, n: SIMD2<Float>)] = []
            for i in 0..<count {
                let prev = points[(i + count - 1) % count], next = points[(i + 1) % count]
                let t = simd_normalize(next - prev)
                // 時計回りなので、進む向きの右が内側
                var n = SIMD2<Float>(t.y, -t.x)
                // くぼみ・先の点は、まん中へ向ける
                if !n.x.isFinite || !n.y.isFinite { n = simd_normalize(center - points[i]) }
                path.append((p: points[i], n: n))
            }
            path.append(path[0])
            return path
        }
    }

    /// その点（扉の座標の x・y）が開口部の中か（margin だけゆるめる）
    func contains(_ q: SIMD2<Float>, margin: Float = 0) -> Bool {
        var polygon = openingPath().map(\.p)
        if !isClosed { polygon.append(SIMD2(polygon.last?.x ?? 0, -0.2)); polygon.insert(SIMD2(polygon.first?.x ?? 0, -0.2), at: 0) }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        if inside || margin <= 0 { return inside }
        // ふちのすぐ外も、margin までは中とみなす
        for i in 0..<(polygon.count - 1) {
            let a = polygon[i], b = polygon[i + 1]
            let ab = b - a
            let t = max(0, min(1, simd_dot(q - a, ab) / max(simd_dot(ab, ab), 1e-6)))
            if simd_distance(q, a + ab * t) <= margin { return true }
        }
        return false
    }

    /// 長い辺を細かく分けたふち（ネオンの色を高さで少しずつ変えるため）
    func finePath(maxStep: Float = 0.1) -> [(p: SIMD2<Float>, n: SIMD2<Float>)] {
        let path = openingPath()
        var out: [(p: SIMD2<Float>, n: SIMD2<Float>)] = []
        for i in 0..<path.count {
            out.append(path[i])
            guard i + 1 < path.count else { break }
            let a = path[i], b = path[i + 1]
            let steps = Int(simd_distance(a.p, b.p) / maxStep)
            if steps > 1 {
                for k in 1..<steps {
                    let f = Float(k) / Float(steps)
                    out.append((p: a.p + (b.p - a.p) * f, n: simd_normalize(a.n + (b.n - a.n) * f)))
                }
            }
        }
        return out
    }
}

/// 前の名前（アーチだけだったころ）
typealias ArchShape = DoorShape

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
    static func opening(path: [(p: SIMD2<Float>, n: SIMD2<Float>)], z: Float, center c: SIMD2<Float>? = nil,
                        name: String) throws -> MeshResource {
        var b = MeshBuilder()
        let ys = path.map(\.p.y)
        let center = SIMD3<Float>(c?.x ?? 0, c?.y ?? ((ys.max() ?? 1) + (ys.min() ?? 0)) * 0.45, z)
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
    /// どの形でも：開口部のまん中から見たふちの点を、開口部を囲む四角まで延ばして埋め、その外の四角い帯を足す
    static func wallWithOpening(shape: DoorShape, halfWidth: Float, height: Float, z: Float) throws -> MeshResource {
        var contour = shape.openingPath().map(\.p)
        if shape.isClosed, let first = contour.first, let last = contour.last, simd_distance(first, last) < 1e-5 {
            contour.removeLast()
        }
        let c = shape.center
        let xs = contour.map(\.x), ys = contour.map(\.y)
        let bx0 = xs.min() ?? -0.5, bx1 = xs.max() ?? 0.5
        let by0 = shape.isClosed ? (ys.min() ?? 0) : 0, by1 = ys.max() ?? 2
        let H = max(height, by1 + 0.01), W = max(halfWidth, max(-bx0, bx1) + 0.01)

        // 囲む四角の角へ向かう線が、ふちと交わる所に点を足す（角をまたぐすき間を作らない）
        let corners: [SIMD2<Float>] = [SIMD2(bx0, by0), SIMD2(bx1, by0), SIMD2(bx1, by1), SIMD2(bx0, by1)]
        func angle(_ p: SIMD2<Float>) -> Float { atan2(p.y - c.y, p.x - c.x) }
        var points: [SIMD2<Float>] = []
        let count = contour.count
        let segments = shape.isClosed ? count : count - 1
        for i in 0..<segments {
            let a = contour[i], b = contour[(i + 1) % count]
            points.append(a)
            var aa = angle(a), ab = angle(b)
            var d = ab - aa
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            ab = aa + d
            var hits: [(Float, SIMD2<Float>)] = []
            for corner in corners {
                var ac = angle(corner)
                while ac < min(aa, ab) { ac += 2 * .pi }
                while ac > max(aa, ab) { ac -= 2 * .pi }
                guard ac > min(aa, ab) + 1e-5, ac < max(aa, ab) - 1e-5 else { continue }
                // 角への線と、ふちの辺 a→b の交わる所
                let dir = SIMD2<Float>(cos(ac), sin(ac))
                let e = b - a
                let den = dir.x * (-e.y) - dir.y * (-e.x)
                guard abs(den) > 1e-7 else { continue }
                let w = a - c
                let t = (w.x * (-e.y) - w.y * (-e.x)) / den
                let u = (dir.x * w.y - dir.y * w.x) / den
                guard t > 0, u > 0, u < 1 else { continue }
                hits.append((u, a + e * u))
                _ = t
            }
            for hit in hits.sorted(by: { $0.0 < $1.0 }) { points.append(hit.1) }
            aa = ab
        }
        if !shape.isClosed, let last = contour.last { points.append(last) }

        // まん中からの線を、囲む四角のふちまで延ばす
        func project(_ p: SIMD2<Float>) -> SIMD2<Float> {
            let dir = p - c
            var t = Float.greatestFiniteMagnitude
            if dir.x > 1e-6 { t = min(t, (bx1 - c.x) / dir.x) }
            if dir.x < -1e-6 { t = min(t, (bx0 - c.x) / dir.x) }
            if dir.y > 1e-6 { t = min(t, (by1 - c.y) / dir.y) }
            if dir.y < -1e-6 { t = min(t, (by0 - c.y) / dir.y) }
            return t.isFinite ? c + dir * t : p
        }
        var b = MeshBuilder()
        func v(_ p: SIMD2<Float>) -> SIMD3<Float> { SIMD3(p.x, p.y, z) }
        /// 4 点の面を、+Z から見て反時計回りの順に並べて足す
        func face(_ p: [SIMD2<Float>]) {
            var area: Float = 0
            for i in 0..<p.count { let a = p[i], q = p[(i + 1) % p.count]; area += a.x * q.y - q.x * a.y }
            guard abs(area) > 1e-8 else { return }
            let o = area > 0 ? p : p.reversed()
            b.quad(v(o[0]), v(o[1]), v(o[2]), v(o[3]), normal: [0, 0, 1])
        }
        let ringCount = shape.isClosed ? points.count : points.count - 1
        for i in 0..<ringCount {
            let p0 = points[i], p1 = points[(i + 1) % points.count]
            face([p0, p1, project(p1), project(p0)])
        }
        // 囲む四角の外の帯（左・右・上・下）
        face([SIMD2(-W, 0), SIMD2(bx0, 0), SIMD2(bx0, H), SIMD2(-W, H)])
        face([SIMD2(bx1, 0), SIMD2(W, 0), SIMD2(W, H), SIMD2(bx1, H)])
        face([SIMD2(bx0, by1), SIMD2(bx1, by1), SIMD2(bx1, H), SIMD2(bx0, H)])
        if by0 > 0.0001 { face([SIMD2(bx0, 0), SIMD2(bx1, 0), SIMD2(bx1, by0), SIMD2(bx0, by0)]) }
        return try b.mesh(name: "wall")
    }
}
