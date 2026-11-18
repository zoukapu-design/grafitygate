import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// カードの写真を整える（2026-11-19 オーナー「写真は加工できるように。エフェクト・向き・拡大縮小」）。
// カードの写真の窓（横長 0.91:0.62）に、指で広げる・動かして入れる所を決め、回す・左右反転・色（PhotoLook）・
// エフェクト（PhotoSparkle）を付けて、1 枚の絵（長い辺 1600）にする。写真は iPhone の中だけで作り直す。

/// 色の加工
enum PhotoLook: String, CaseIterable, Identifiable {
    case normal, vivid, sunset, night, mono, retro, soft, neon

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: return "そのまま"
        case .vivid: return "あざやか"
        case .sunset: return "夕焼け"
        case .night: return "夜"
        case .mono: return "モノクロ"
        case .retro: return "レトロ"
        case .soft: return "ふんわり"
        case .neon: return "ネオン"
        }
    }

    func apply(_ input: CIImage) -> CIImage {
        let extent = input.extent
        func vignette(_ image: CIImage, _ intensity: Float) -> CIImage {
            let f = CIFilter.vignette()
            f.inputImage = image
            f.intensity = intensity
            f.radius = Float(max(extent.width, extent.height)) * 0.9
            return f.outputImage ?? image
        }
        func controls(_ image: CIImage, sat: Float, con: Float, bri: Float) -> CIImage {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.saturation = sat
            f.contrast = con
            f.brightness = bri
            return f.outputImage ?? image
        }
        func matrix(_ image: CIImage, r: CGFloat, g: CGFloat, b: CGFloat, bias: (CGFloat, CGFloat, CGFloat)) -> CIImage {
            let f = CIFilter.colorMatrix()
            f.inputImage = image
            f.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
            f.biasVector = CIVector(x: bias.0, y: bias.1, z: bias.2, w: 0)
            return f.outputImage ?? image
        }
        var out: CIImage
        switch self {
        case .normal:
            return input
        case .vivid:
            let v = CIFilter.vibrance()
            v.inputImage = controls(input, sat: 1.3, con: 1.08, bri: 0.01)
            v.amount = 0.5
            out = v.outputImage ?? input
        case .sunset:
            out = vignette(matrix(controls(input, sat: 1.15, con: 1.05, bri: 0.02), r: 1.1, g: 0.98, b: 0.82,
                                  bias: (0.05, 0.015, 0.02)), 0.6)
        case .night:
            out = vignette(matrix(controls(input, sat: 0.85, con: 1.12, bri: -0.07), r: 0.86, g: 0.92, b: 1.12,
                                  bias: (0.0, 0.0, 0.04)), 1.0)
        case .mono:
            let f = CIFilter.photoEffectNoir()
            f.inputImage = input
            out = f.outputImage ?? input
        case .retro:
            let f = CIFilter.photoEffectTransfer()
            f.inputImage = input
            out = vignette(matrix(f.outputImage ?? input, r: 1.02, g: 1.0, b: 0.9, bias: (0.04, 0.03, 0.0)), 0.8)
        case .soft:
            let f = CIFilter.photoEffectFade()
            f.inputImage = input
            let bloom = CIFilter.bloom()
            bloom.inputImage = f.outputImage ?? input
            bloom.radius = Float(max(extent.width, extent.height)) * 0.012
            bloom.intensity = 0.5
            out = controls(bloom.outputImage ?? input, sat: 1.0, con: 0.95, bri: 0.04)
        case .neon:
            let bloom = CIFilter.bloom()
            bloom.inputImage = controls(input, sat: 1.6, con: 1.15, bri: -0.02)
            bloom.radius = Float(max(extent.width, extent.height)) * 0.015
            bloom.intensity = 0.9
            out = matrix(bloom.outputImage ?? input, r: 1.05, g: 0.92, b: 1.12, bias: (0.02, 0.0, 0.04))
        }
        return out.cropped(to: extent)
    }
}

/// 写真に重ねるエフェクト（描くのは iPhone の中で、決まった場所に）
enum PhotoSparkle: String, CaseIterable, Identifiable {
    case none, sparkle, lightLeak, hearts, confetti, stars, neonFrame

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "なし"
        case .sparkle: return "キラキラ"
        case .lightLeak: return "光もれ"
        case .hearts: return "ハート"
        case .confetti: return "紙ふぶき"
        case .stars: return "星空"
        case .neonFrame: return "ネオンの枠"
        }
    }

    var symbol: String {
        switch self {
        case .none: return "circle.slash"
        case .sparkle: return "sparkles"
        case .lightLeak: return "sun.max.fill"
        case .hearts: return "heart.fill"
        case .confetti: return "party.popper.fill"
        case .stars: return "moon.stars.fill"
        case .neonFrame: return "rectangle.dashed"
        }
    }

    /// 重ねる絵を描く（size はできあがりの大きさ）
    func draw(in ctx: CGContext, size: CGSize) {
        let w = size.width, h = size.height, unit = min(w, h)
        var rng = SeededRandom(seed: rawValue.unicodeScalars.reduce(UInt64(99)) { $0 &* 31 &+ UInt64($1.value) })
        func star(_ c: CGPoint, _ r: CGFloat, _ color: UIColor) {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: c.x, y: c.y - r))
            p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: c)
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: c)
            p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: c)
            p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: c)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: r * 0.9, color: color.withAlphaComponent(0.9).cgColor)
            ctx.addPath(p)
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        func heart(_ c: CGPoint, _ s: CGFloat, _ color: UIColor) {
            let p = CGMutablePath()
            for i in 0...40 {
                let t = CGFloat(i) / 40 * 2 * .pi
                let x = 16 * pow(sin(t), 3)
                let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                let q = CGPoint(x: c.x + x * s / 32, y: c.y - y * s / 32)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: s * 0.3, color: color.withAlphaComponent(0.6).cgColor)
            ctx.addPath(p)
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        switch self {
        case .none:
            return
        case .sparkle:
            let tints: [UIColor] = [.white, UIColor(red: 1, green: 0.85, blue: 0.5, alpha: 1), UIColor(red: 0.8, green: 0.7, blue: 1, alpha: 1)]
            for i in 0..<16 {
                let x = CGFloat(rng.next()) * w, y = CGFloat(rng.next()) * h
                // まん中は少なめに（写真の主役をかくさない）
                let dx = abs(x - w / 2) / w, dy = abs(y - h / 2) / h
                if dx < 0.18 && dy < 0.2 && i % 3 != 0 { continue }
                star(CGPoint(x: x, y: y), unit * (0.02 + CGFloat(rng.next()) * 0.045), tints[i % tints.count])
            }
        case .lightLeak:
            let space = CGColorSpace(name: CGColorSpace.sRGB)
            let corners: [(CGPoint, UIColor)] = [
                (CGPoint(x: 0, y: 0), UIColor(red: 1.0, green: 0.55, blue: 0.25, alpha: 0.55)),
                (CGPoint(x: w, y: h * 0.15), UIColor(red: 1.0, green: 0.3, blue: 0.55, alpha: 0.4)),
                (CGPoint(x: w * 0.2, y: h), UIColor(red: 0.6, green: 0.4, blue: 1.0, alpha: 0.35)),
            ]
            ctx.saveGState()
            ctx.setBlendMode(.screen)
            for (point, color) in corners {
                if let g = CGGradient(colorsSpace: space, colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                                      locations: [0, 1]) {
                    ctx.drawRadialGradient(g, startCenter: point, startRadius: 0, endCenter: point, endRadius: unit * 0.75, options: [])
                }
            }
            ctx.restoreGState()
        case .hearts:
            let pinks: [UIColor] = [UIColor(red: 1.0, green: 0.42, blue: 0.62, alpha: 0.95), UIColor(red: 1.0, green: 0.7, blue: 0.8, alpha: 0.95),
                                    UIColor(red: 0.95, green: 0.3, blue: 0.45, alpha: 0.95)]
            for i in 0..<12 {
                let edge = i % 2 == 0
                let x = edge ? CGFloat(rng.next()) * w * 0.25 + (i % 4 == 0 ? 0 : w * 0.75) : CGFloat(rng.next()) * w
                let y = edge ? CGFloat(rng.next()) * h : (i % 3 == 0 ? CGFloat(rng.next()) * h * 0.2 : h - CGFloat(rng.next()) * h * 0.2)
                heart(CGPoint(x: x, y: y), unit * (0.06 + CGFloat(rng.next()) * 0.07), pinks[i % pinks.count])
            }
        case .confetti:
            let colors: [UIColor] = [UIColor(red: 1.0, green: 0.4, blue: 0.5, alpha: 1), UIColor(red: 1.0, green: 0.8, blue: 0.3, alpha: 1),
                                     UIColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1), UIColor(red: 0.6, green: 0.95, blue: 0.6, alpha: 1),
                                     UIColor(red: 0.8, green: 0.6, blue: 1.0, alpha: 1)]
            for i in 0..<46 {
                let x = CGFloat(rng.next()) * w, y = CGFloat(rng.next()) * h * 0.55
                ctx.saveGState()
                ctx.translateBy(x: x, y: y)
                ctx.rotate(by: CGFloat(rng.next()) * .pi)
                ctx.setFillColor(colors[i % colors.count].cgColor)
                let s = unit * (0.012 + CGFloat(rng.next()) * 0.014)
                ctx.fill(CGRect(x: -s, y: -s * 0.45, width: s * 2, height: s * 0.9))
                ctx.restoreGState()
            }
        case .stars:
            let space = CGColorSpace(name: CGColorSpace.sRGB)
            if let g = CGGradient(colorsSpace: space,
                                  colors: [UIColor(red: 0.1, green: 0.06, blue: 0.3, alpha: 0.55).cgColor,
                                           UIColor(red: 0.1, green: 0.06, blue: 0.3, alpha: 0).cgColor] as CFArray,
                                  locations: [0, 1]) {
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h * 0.6), options: [])
            }
            for _ in 0..<90 {
                let x = CGFloat(rng.next()) * w, y = CGFloat(rng.next()) * h * 0.55
                let r = unit * (0.002 + CGFloat(rng.next()) * 0.005)
                ctx.setFillColor(UIColor(white: 1, alpha: 0.5 + CGFloat(rng.next()) * 0.5).cgColor)
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            for _ in 0..<4 {
                star(CGPoint(x: CGFloat(rng.next()) * w, y: CGFloat(rng.next()) * h * 0.45), unit * 0.03, .white)
            }
        case .neonFrame:
            let inset = unit * 0.035, lineW = unit * 0.014
            let rect = CGRect(x: inset, y: inset, width: w - inset * 2, height: h - inset * 2)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: unit * 0.05).cgPath
            let colors: [UIColor] = [UIColor(red: 1.0, green: 0.6, blue: 0.24, alpha: 1), UIColor(red: 1.0, green: 0.24, blue: 0.5, alpha: 1),
                                     UIColor(red: 0.6, green: 0.36, blue: 1.0, alpha: 1), UIColor(red: 0.25, green: 0.82, blue: 1.0, alpha: 1)]
            let space = CGColorSpace(name: CGColorSpace.sRGB)
            guard let g = CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray,
                                     locations: [0, 0.35, 0.7, 1]) else { return }
            for (width, alpha) in [(lineW * 4, 0.18), (lineW * 2, 0.35), (lineW, 1.0)] {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setLineWidth(width)
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                ctx.setAlpha(CGFloat(alpha))
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
                ctx.restoreGState()
            }
        }
    }

    /// 重ねる絵（透明な地に描いたもの）
    func overlay(size: CGSize) -> UIImage? {
        guard self != .none else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { draw(in: $0.cgContext, size: size) }
    }
}

/// 写真を作り直す道具（画面とは別にして、裏の処理からも使えるように）
enum PhotoRender {
    static let context = CIContext(options: [.cacheIntermediates: false])

    static func filtered(_ image: UIImage, _ look: PhotoLook) -> UIImage {
        guard look != .normal, let ci = CIImage(image: image) else { return image }
        let out = look.apply(ci)
        guard let cg = context.createCGImage(out, from: ci.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
    }
}

/// カードの写真を整える画面
struct CardPhotoEditor: View {
    let original: UIImage
    let onUse: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 回す・反転したあとの写真（長い辺 1600 まで）
    @State private var base: UIImage
    @State private var preview: UIImage?
    @State private var look: PhotoLook = .normal
    @State private var sparkle: PhotoSparkle = .none
    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var thumbs: [PhotoLook: UIImage] = [:]
    @State private var tab = 0
    @State private var working = false
    @State private var frameSize: CGSize = .zero
    /// 重ねるエフェクトの絵（選んだときに 1 回だけ作る。指で動かすたびに作り直さない）
    @State private var overlay: UIImage?

    /// カードの写真の窓の縦横の比（横 0.91・縦 0.62）
    static let aspect: CGFloat = 0.91 / 0.62

    init(original: UIImage, onUse: @escaping (UIImage) -> Void) {
        self.original = original
        self.onUse = onUse
        _base = State(initialValue: original.downscaled(maxSide: 1600))
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button("やめる") { dismiss() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("写真を整える").font(.headline).foregroundStyle(.white)
                Spacer()
                Button {
                    Task { await finish() }
                } label: {
                    if working { ProgressView().tint(.white) } else { Text("使う").font(.body.weight(.heavy)) }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16).frame(minHeight: 36)
                .background(Theme.neonBand, in: Capsule())
                .disabled(working)
            }
            .padding(.horizontal, 16)

            // カードの写真の窓（指で広げる・動かす）
            GeometryReader { geo in
                let fw = geo.size.width
                let fh = geo.size.height
                ZStack {
                    Image(uiImage: preview ?? base)
                        .resizable()
                        .scaledToFill()
                        .frame(width: fw, height: fh)
                        .scaleEffect(zoom)
                        .offset(offset)
                    if let overlay {
                        Image(uiImage: overlay).resizable().frame(width: fw, height: fh).allowsHitTesting(false)
                    }
                }
                .frame(width: fw, height: fh)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 2))
                .contentShape(Rectangle())
                .gesture(SimultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            zoom = min(max(lastZoom * value.magnification, 1), 5)
                            offset = clamp(offset, frame: CGSize(width: fw, height: fh))
                        }
                        .onEnded { _ in lastZoom = zoom },
                    DragGesture()
                        .onChanged { value in
                            offset = clamp(CGSize(width: lastOffset.width + value.translation.width,
                                                  height: lastOffset.height + value.translation.height),
                                           frame: CGSize(width: fw, height: fh))
                        }
                        .onEnded { _ in lastOffset = offset }))
                .onAppear {
                    frameSize = geo.size
                    refreshOverlay()
                }
                .onChange(of: geo.size) { _, size in
                    frameSize = size
                    refreshOverlay()
                }
            }
            .aspectRatio(Self.aspect, contentMode: .fit)
            .padding(.horizontal, 16)

            Text("2 本の指で広げる・1 本の指で動かすと、カードに入る所を決められます")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                tool("rotate.left", "左に回す") { turn(right: false) }
                tool("rotate.right", "右に回す") { turn(right: true) }
                tool("arrow.left.and.right.righttriangle.left.righttriangle.right", "左右反転") { flip() }
                tool("arrow.uturn.backward", "元に戻す") { reset() }
            }

            Picker("加工", selection: $tab) {
                Text("色").tag(0)
                Text("エフェクト").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    if tab == 0 {
                        ForEach(PhotoLook.allCases) { item in
                            choice(label: item.label, selected: look == item) {
                                look = item
                                Task { await refreshPreview() }
                            } content: {
                                if let thumb = thumbs[item] {
                                    Image(uiImage: thumb).resizable().scaledToFill()
                                } else {
                                    Color.white.opacity(0.1)
                                }
                            }
                        }
                    } else {
                        ForEach(PhotoSparkle.allCases) { item in
                            choice(label: item.label, selected: sparkle == item) {
                                sparkle = item
                                refreshOverlay()
                            } content: {
                                ZStack {
                                    LinearGradient(colors: [Color(hex: 0x2A1650), Color(hex: 0x4A2A8A)],
                                                   startPoint: .top, endPoint: .bottom)
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .background(Color(hex: 0x0E0A1F).ignoresSafeArea())
        .task {
            await refreshPreview()
            await makeThumbs()
        }
    }

    private func refreshOverlay() {
        let size = frameSize == .zero ? CGSize(width: 340, height: 340 / Self.aspect) : frameSize
        overlay = sparkle.overlay(size: CGSize(width: size.width * 2, height: size.height * 2))
    }

    private func tool(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                Text(label).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 74, height: 54)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func choice<C: View>(label: String, selected: Bool, action: @escaping () -> Void,
                                 @ViewBuilder content: () -> C) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                content()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? AnyShapeStyle(Theme.neonBand) : AnyShapeStyle(Color.clear), lineWidth: 3))
                Text(label)
                    .font(.caption2.weight(selected ? .heavy : .semibold))
                    .foregroundStyle(selected ? .white : .white.opacity(0.7))
            }
        }
        .buttonStyle(.plain)
    }

    /// 写真が窓からはみ出さないように（すき間ができない範囲で）動かす
    private func clamp(_ value: CGSize, frame: CGSize) -> CGSize {
        let s0 = max(frame.width / base.size.width, frame.height / base.size.height)
        let shownW = base.size.width * s0 * zoom, shownH = base.size.height * s0 * zoom
        let mx = max(0, (shownW - frame.width) / 2), my = max(0, (shownH - frame.height) / 2)
        return CGSize(width: min(max(value.width, -mx), mx), height: min(max(value.height, -my), my))
    }

    private func turn(right: Bool) {
        base = right ? base.rotatedRight() : base.rotatedRight().rotatedRight().rotatedRight()
        reset(keepImage: true)
        Task { await refreshPreview(); await makeThumbs() }
        Haptics.tap()
    }

    private func flip() {
        let size = base.size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = base.scale
        base = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: size.width, y: 0)
            ctx.cgContext.scaleBy(x: -1, y: 1)
            base.draw(in: CGRect(origin: .zero, size: size))
        }
        Task { await refreshPreview(); await makeThumbs() }
        Haptics.tap()
    }

    private func reset(keepImage: Bool = false) {
        if !keepImage {
            base = original.downscaled(maxSide: 1600)
            look = .normal
            sparkle = .none
            overlay = nil
            Task { await refreshPreview(); await makeThumbs() }
        }
        zoom = 1
        lastZoom = 1
        offset = .zero
        lastOffset = .zero
    }

    private func refreshPreview() async {
        let source = base.downscaled(maxSide: 1000)
        let look = self.look
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage in
            PhotoRender.filtered(source, look)
        }.value
        preview = image
    }

    private func makeThumbs() async {
        let small = base.downscaled(maxSide: 180)
        var result: [PhotoLook: UIImage] = [:]
        for item in PhotoLook.allCases {
            result[item] = PhotoRender.filtered(small, item)
        }
        thumbs = result
    }

    /// できあがり：窓に見えている所を切り出し、色とエフェクトを付けた 1 枚（横 1600）
    private func finish() async {
        working = true
        defer { working = false }
        let frame = frameSize == .zero ? CGSize(width: 340, height: 340 / Self.aspect) : frameSize
        let source = base, look = self.look
        let image = await Task.detached(priority: .userInitiated) { PhotoRender.filtered(source, look) }.value
        let W = image.size.width, H = image.size.height
        let s0 = max(frame.width / W, frame.height / H)
        let scale = s0 * zoom
        let cropW = frame.width / scale, cropH = frame.height / scale
        let cx = W / 2 - offset.width / scale, cy = H / 2 - offset.height / scale
        let crop = CGRect(x: cx - cropW / 2, y: cy - cropH / 2, width: cropW, height: cropH)
        let outSize = CGSize(width: 1600, height: (1600 / Self.aspect).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let sparkle = self.sparkle
        let result = UIGraphicsImageRenderer(size: outSize, format: format).image { ctx in
            let k = outSize.width / crop.width
            image.draw(in: CGRect(x: -crop.minX * k, y: -crop.minY * k, width: W * k, height: H * k))
            sparkle.draw(in: ctx.cgContext, size: outSize)
        }
        Trace.log("カードの写真を整えた（色 \(look.rawValue)・エフェクト \(sparkle.rawValue)・拡大 \(String(format: "%.1f", zoom))）")
        Haptics.success()
        onUse(result)
        dismiss()
    }
}

/// 整える写真（fullScreenCover(item:) 用）
struct PhotoToEdit: Identifiable {
    let id = UUID()
    let image: UIImage
}
