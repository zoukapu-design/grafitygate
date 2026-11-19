import SwiftUI

/// 手紙・タイムカプセル（2026-11-20 オーナー「もっと手紙っぽく。残したら手紙だと分かる形で、開いたら封を開けて中からカードと便せんが出てくる」）：
/// 一覧は封筒の形（封ろう・切手・消印）。開けられるものは光って揺れ、押すと封を切って中身が出てくる。
struct LetterSection: View {
    let context: GateContext
    let refreshToken: Int

    @EnvironmentObject private var session: SessionModel
    @State private var letters: [LetterInfo] = []
    @State private var error: String?
    @State private var showComposer = false
    @State private var loaded = false

    init(context: GateContext, refreshToken: Int) {
        self.context = context
        self.refreshToken = refreshToken
    }

    private var received: [LetterInfo] { letters.filter { !$0.sent } }
    private var sent: [LetterInfo] { letters.filter(\.sent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if context.isInside {
                Button {
                    showComposer = true
                } label: {
                    Label("手紙を書く", systemImage: "pencil.and.scribble")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            if let error { NoticeText(text: error) }
            if loaded && letters.isEmpty {
                LetterEmptyArt(canWrite: context.isInside)
            }
            if !received.isEmpty {
                SectionHeader(title: "あなたあて", count: received.count)
                ForEach(received) { letter in
                    LetterRow(letter: letter, context: context) { Task { await load() } }
                }
            }
            if !sent.isEmpty {
                SectionHeader(title: "あなたが書いた手紙", count: sent.count)
                    .padding(.top, 6)
                ForEach(sent) { letter in
                    LetterRow(letter: letter, context: context) { Task { await load() } }
                }
            }
        }
        .task(id: "\(context.isInside)-\(refreshToken)") { await load() }
        .sheet(isPresented: $showComposer) {
            LetterComposer(context: context) { Task { await load() } }
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            letters = try await api.letters(at: context.gateID)
            error = nil
        } catch {
            self.error = ErrorText.of(error)
        }
        loaded = true
    }
}

/// まだ手紙が無いとき：封筒が 1 通、ふわっと浮いている
private struct LetterEmptyArt: View {
    let canWrite: Bool
    @State private var float = false

    var body: some View {
        VStack(spacing: 14) {
            EnvelopeArt(to: "未来の自分へ", from: nil, stampDate: "", place: "", sealed: true)
                .frame(width: 220)
                .rotationEffect(.degrees(float ? -3 : 3))
                .offset(y: float ? -6 : 6)
                .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: float)
                .onAppear { float = true }
            Text(canWrite ? "最初の 1 通を書いてみよう" : "GATE を開けると書けます")
                .font(.headline)
                .foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

/// 手紙の 1 通：封筒の形（開けられるなら押すと開く）
struct LetterRow: View {
    let letter: LetterInfo
    var context: GateContext?
    var showsGate = false
    let onChanged: () -> Void

    @EnvironmentObject private var session: SessionModel
    @State private var confirmDelete = false
    @State private var message: String?
    @State private var shake: CGFloat = 0
    @State private var glow = false

    init(letter: LetterInfo, context: GateContext?, showsGate: Bool = false, onChanged: @escaping () -> Void) {
        self.letter = letter
        self.context = context
        self.showsGate = showsGate
        self.onChanged = onChanged
    }

    private var title: String {
        if letter.isToSelf { return "未来の自分へ" }
        return letter.sent ? "\(letter.recipient_name) さんへ" : "\(letter.recipient_name) さんへ"
    }

    private var from: String? {
        if letter.isToSelf { return "あの日の自分より" }
        return letter.sent ? "あなたより" : "\(letter.author_name) より"
    }

    /// 封筒の下に出す一言
    private var status: (text: String, symbol: String, color: Color) {
        if letter.sent {
            return letter.isOpened ? ("読まれました", "envelope.open.fill", Theme.accent)
                                   : ("まだ開かれていません", "paperplane.fill", Theme.textSecondary)
        }
        if letter.isOpened { return ("開封済み・もう一度読めます", "envelope.open.fill", Theme.textSecondary) }
        if let lock = letter.lockReason { return (lock, "lock.fill", Theme.textSecondary) }
        return ("開けられます！", "sparkles", Theme.warm)
    }

    /// まだ開けていない・いま開けられる（光らせて揺らす）
    private var ready: Bool { !letter.sent && !letter.isOpened && letter.canOpenNow }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if canRead {
                NavigationLink {
                    LetterView(info: letter) { onChanged() }
                } label: {
                    envelope
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    // まだ開けない：封筒がぷるっとふるえて、理由を見せる
                    withAnimation(.linear(duration: 0.4)) { shake += 1 }
                    Haptics.tap()
                } label: {
                    envelope
                }
                .buttonStyle(.plain)
            }
            if let message { NoticeText(text: message) }
        }
        .contextMenu {
            if canDelete {
                Button("この手紙を消す", role: .destructive) { confirmDelete = true }
            }
        }
        .confirmationDialog("この手紙を消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("消す", role: .destructive) { Task { await delete() } }
        }
    }

    private var envelope: some View {
        VStack(alignment: .leading, spacing: 8) {
            EnvelopeArt(to: title, from: from,
                        stampDate: ServerDate.parse(letter.created_at).map { ServerDate.day($0) } ?? "",
                        place: letter.gate_title,
                        sealed: !letter.isOpened,
                        peeking: letter.isOpened)
                .modifier(ShakeEffect(amount: 8, shakes: shake))
                .shadow(color: ready ? Theme.warm.opacity(glow ? 0.55 : 0.15) : .black.opacity(0.08),
                        radius: ready ? (glow ? 18 : 8) : 8, y: 4)
                .rotationEffect(.degrees(ready ? (glow ? -1.2 : 1.2) : 0))
                .onAppear {
                    guard ready else { return }
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { glow = true }
                }
            HStack(spacing: 6) {
                Label(status.text, systemImage: status.symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(status.color)
                if showsGate {
                    Text("・\(letter.gate_title)")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
        }
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)の手紙。\(status.text)")
    }

    /// 書いた人はいつでも読める（自分あてのタイムカプセルは開く日まで）。宛先の人は開けるときだけ
    private var canRead: Bool {
        if letter.sent { return true }
        return letter.canOpenNow
    }

    private var canDelete: Bool {
        if letter.sent { return !letter.isOpened }
        return letter.isOpened
    }

    private func delete() async {
        guard let api = session.api else { return }
        do {
            try await api.deleteLetter(letter.id)
            onChanged()
        } catch {
            message = ErrorText.of(error)
        }
    }
}

/// 左右にぷるっとふるえる
struct ShakeEffect: GeometryEffect {
    var amount: CGFloat = 8
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: amount * sin(shakes * .pi * 4), y: 0))
    }
}

// MARK: - 封筒・便せんの絵

enum LetterPalette {
    static let envelope = Color(hex: 0xF7E8D0)
    static let envelopeDeep = Color(hex: 0xEED6B2)
    static let envelopeEdge = Color(hex: 0xD8B98C)
    static let paper = Color(hex: 0xFFFCF4)
    static let rule = Color(hex: 0xEADFCB)
    static let margin = Color(hex: 0xF3B7A8)
    static let ink = Color(hex: 0x2B2440)
    static let wax = [Color(hex: 0xE2435E), Color(hex: 0xA51F3D)]
}

/// 封筒（横長）：ふた・封ろう・切手・消印・宛名。flapOpen で、ふたが上へ開く
struct EnvelopeArt: View {
    let to: String
    let from: String?
    let stampDate: String
    let place: String
    var sealed = true
    /// 開封済み：ふたを開け、便せんの頭を少しのぞかせる
    var peeking = false
    /// 0＝閉じている 〜 1＝開いた（開ける動きのとき）
    var flapOpen: CGFloat? = nil

    private var openAmount: CGFloat { flapOpen ?? (peeking ? 1 : 0) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                // 便せんの頭（開封済み）
                if peeking {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LetterPalette.paper)
                        .overlay(alignment: .top) { RuledLines(spacing: h * 0.09).padding(.top, h * 0.08).opacity(0.8) }
                        .frame(width: w * 0.82, height: h * 0.5)
                        .offset(x: w * 0.09, y: -h * 0.22)
                        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                }
                // 封筒の本体
                RoundedRectangle(cornerRadius: h * 0.07, style: .continuous)
                    .fill(LinearGradient(colors: [LetterPalette.envelope, LetterPalette.envelopeDeep],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: h * 0.07, style: .continuous)
                        .strokeBorder(LetterPalette.envelopeEdge.opacity(0.7), lineWidth: 1))
                // 下のポケットの折り目
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.5))
                    p.addLine(to: CGPoint(x: w, y: h))
                }
                .stroke(LetterPalette.envelopeEdge.opacity(0.45), lineWidth: 1)
                // 宛名・差出人
                VStack(alignment: .leading, spacing: 4) {
                    Text(to)
                        .font(.system(size: max(15, h * 0.12), weight: .bold, design: .serif))
                        .foregroundStyle(LetterPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let from {
                        Text(from)
                            .font(.system(size: max(11, h * 0.072), weight: .medium, design: .serif))
                            .foregroundStyle(LetterPalette.ink.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                .padding(.leading, w * 0.07)
                .padding(.top, h * 0.66)
                .frame(width: w * 0.6, alignment: .leading)
                // 切手と消印
                if !stampDate.isEmpty || !place.isEmpty {
                    StampArt(date: stampDate, place: place)
                        .frame(width: h * 0.32, height: h * 0.38)
                        .offset(x: w - h * 0.32 - w * 0.06, y: h * 0.56)
                }
                // ふた（上の三角）：開くと上へ返る
                EnvelopeFlap()
                    .fill(LinearGradient(colors: [LetterPalette.envelopeDeep, LetterPalette.envelope],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(EnvelopeFlap().stroke(LetterPalette.envelopeEdge.opacity(0.6), lineWidth: 1))
                    .frame(width: w, height: h * 0.48)
                    .shadow(color: .black.opacity(openAmount > 0.5 ? 0 : 0.08), radius: 3, y: 2)
                    .rotation3DEffect(.degrees(Double(openAmount) * 178), axis: (x: 1, y: 0, z: 0),
                                      anchor: .top, perspective: 0.5)
                // 封ろう
                if sealed {
                    WaxSeal()
                        .frame(width: h * 0.24, height: h * 0.24)
                        .offset(x: w * 0.5 - h * 0.12, y: h * 0.48 - h * 0.12)
                        .opacity(Double(1 - min(1, openAmount * 2.5)))
                        .scaleEffect(1 + openAmount * 0.6, anchor: .center)
                }
            }
            .frame(width: w, height: h)
        }
        .aspectRatio(1.72, contentMode: .fit)
    }
}

/// 封筒のおもて側（開けるときだけ使う）：ふたの下のポケット。宛名・切手は封筒と同じ位置
struct EnvelopePocket: View {
    let to: String
    let from: String?
    let stampDate: String
    let place: String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                PocketShape()
                    .fill(LinearGradient(colors: [LetterPalette.envelope, LetterPalette.envelopeDeep],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(PocketShape().stroke(LetterPalette.envelopeEdge.opacity(0.6), lineWidth: 1))
                    .shadow(color: .black.opacity(0.08), radius: 3, y: -1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(to)
                        .font(.system(size: max(15, h * 0.12), weight: .bold, design: .serif))
                        .foregroundStyle(LetterPalette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let from {
                        Text(from)
                            .font(.system(size: max(11, h * 0.072), weight: .medium, design: .serif))
                            .foregroundStyle(LetterPalette.ink.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                .padding(.leading, w * 0.07)
                .padding(.top, h * 0.66)
                .frame(width: w * 0.6, alignment: .leading)
                if !stampDate.isEmpty {
                    StampArt(date: stampDate, place: place)
                        .frame(width: h * 0.32, height: h * 0.38)
                        .offset(x: w - h * 0.32 - w * 0.06, y: h * 0.56)
                }
            }
            .frame(width: w, height: h)
        }
        .aspectRatio(1.72, contentMode: .fit)
    }
}

/// ポケットの形：上の辺がまん中へ少し下がる
struct PocketShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let top = rect.minY + rect.height * 0.36
        let r = rect.height * 0.07
        p.move(to: CGPoint(x: rect.minX, y: top))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.5))
        p.addLine(to: CGPoint(x: rect.maxX, y: top))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// ふたの形（上の辺から、まん中へとがる三角）
struct EnvelopeFlap: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                       control: CGPoint(x: rect.maxX * 0.7, y: rect.maxY * 0.75))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                       control: CGPoint(x: rect.maxX * 0.3, y: rect.maxY * 0.75))
        p.closeSubpath()
        return p
    }
}

/// 封ろう（赤いろうに、GATE のしるし）
struct WaxSeal: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: LetterPalette.wax, center: .topLeading, startRadius: 2, endRadius: 40))
                .shadow(color: Color(hex: 0x7A1530).opacity(0.45), radius: 3, y: 2)
            Circle()
                .strokeBorder(.white.opacity(0.28), lineWidth: 1.5)
                .padding(4)
            Image(systemName: "door.left.hand.closed")
                .resizable()
                .scaledToFit()
                .padding(10)
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// 切手（ギザギザの縁・夜空の絵に GATE のしるし）と、消印
struct StampArt: View {
    let date: String
    let place: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [Color(hex: 0x2A1650), Color(hex: 0x8A4DF5), Color(hex: 0xFF8A3D)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(GateMark(size: 24, glowing: false).padding(6))
                        .padding(3)
                )
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [2, 2])))
                .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            // 消印（切手に少し重ねる）
            if !date.isEmpty {
                ZStack {
                    Circle().strokeBorder(Color(hex: 0x6B5E88).opacity(0.55), lineWidth: 1.2)
                    VStack(spacing: 0) {
                        Text(date).font(.system(size: 6, weight: .bold))
                        Text(place).font(.system(size: 5, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(Color(hex: 0x6B5E88).opacity(0.75))
                    .padding(4)
                }
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(-14))
                .offset(x: -28, y: 10)
            }
        }
    }
}

/// 便せんの罫線
struct RuledLines: View {
    var spacing: CGFloat = 32
    var body: some View {
        Canvas { ctx, size in
            var y = spacing
            while y < size.height {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(LetterPalette.rule), lineWidth: 1)
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// 便せん：罫線・左の赤い線・宛名・本文・差出人・日付と場所
struct LetterPaper<Content: View>: View {
    let to: String
    let from: String
    let footnote: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(to)
                .font(.system(.title3, design: .serif).weight(.bold))
                .foregroundStyle(LetterPalette.ink)
            content()
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(from)
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(LetterPalette.ink)
                    if !footnote.isEmpty {
                        Text(footnote)
                            .font(.caption)
                            .foregroundStyle(LetterPalette.ink.opacity(0.55))
                    }
                }
            }
        }
        .padding(.leading, 34)
        .padding(.trailing, 22)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .leading) {
                LetterPalette.paper
                RuledLines(spacing: 32).padding(.top, 50)
                Rectangle().fill(LetterPalette.margin.opacity(0.7)).frame(width: 1.5).padding(.leading, 22)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

/// 封を切ったときの光のつぶ
struct SparkleBurst: View {
    let trigger: Bool
    private let count = 14

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                let angle = Double(i) / Double(count) * 2 * .pi
                let dist: CGFloat = i.isMultiple(of: 2) ? 130 : 90
                Image(systemName: i.isMultiple(of: 3) ? "heart.fill" : "sparkle")
                    .font(.system(size: i.isMultiple(of: 2) ? 16 : 11, weight: .bold))
                    .foregroundStyle(i.isMultiple(of: 3) ? Color(hex: 0xFF5C8A) : Color(hex: 0xFFC34D))
                    .offset(x: trigger ? CGFloat(cos(angle)) * dist : 0, y: trigger ? CGFloat(sin(angle)) * dist : 0)
                    .scaleEffect(trigger ? 1 : 0.2)
                    .opacity(trigger ? 0 : 1)
            }
        }
        .animation(.easeOut(duration: 1.1), value: trigger)
        .allowsHitTesting(false)
        .opacity(trigger ? 1 : 0)
    }
}

// MARK: - 手紙を開く

/// 手紙を開く：封筒 →（封ろうを押す）→ ふたが開く → 中からカードと便せんが出てくる → 読む
struct LetterView: View {
    let info: LetterInfo
    let onOpened: () -> Void

    @EnvironmentObject private var session: SessionModel
    @State private var content: LetterContent?
    @State private var error: String?
    @State private var phase: Phase = .sealed
    @State private var report: ReportItem?
    @State private var bigCard: TradingCardContent?
    @State private var burst = false
    @State private var sealPulse = false

    enum Phase: Int, Comparable {
        case sealed, flapOpen, rising, reading
        static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
    }

    init(info: LetterInfo, onOpened: @escaping () -> Void) {
        self.info = info
        self.onOpened = onOpened
    }

    private var toText: String {
        info.isToSelf ? "未来の自分へ" : "\(content?.recipient_name ?? info.recipient_name) さんへ"
    }

    private var fromText: String {
        info.isToSelf ? "あの日の自分より" : "\(content?.author_name ?? info.author_name) より"
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0xFBF4E8), Color(hex: 0xF3E6D3)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if phase == .reading, let content {
                reading(content)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            } else if let error {
                NoticeText(text: error).padding(16)
            } else {
                openingStage
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .navigationTitle("手紙")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if content != nil, !info.sent, !info.isToSelf {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            report = ReportItem(id: info.id, target: .letter, userID: info.author,
                                                userName: info.author_name, label: "手紙")
                        } label: {
                            Label("通報する", systemImage: "exclamationmark.bubble")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .sheet(item: $report) { item in ReportSheet(item: item) }
        .fullScreenCover(item: $bigCard) { card in
            TradingCardViewer(content: card, isMine: info.sent || info.isToSelf)
        }
        .task { await load() }
    }

    // MARK: 封を切る

    private var openingStage: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                // ① 封筒のうら側とふた（ふたは開くと上へ返り、中身の後ろになる）
                EnvelopeArt(to: toText, from: fromText, stampDate: stampText, place: info.gate_title,
                            sealed: true, flapOpen: phase >= .flapOpen ? 1 : 0)
                    .frame(width: 320)
                // ② 中身（便せんとカード）：ふたが開くと、上へすっと出てくる
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LetterPalette.paper)
                        .overlay(RuledLines(spacing: 18).padding(.top, 20))
                        .frame(width: 280, height: 170)
                        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    if let cardContent = content.flatMap(letterCard) {
                        TradingCard(content: cardContent, animated: false)
                            .frame(width: 96)
                            .rotationEffect(.degrees(phase >= .rising ? -10 : 0))
                            .offset(x: 14, y: phase >= .rising ? -50 : 8)
                    }
                }
                .offset(y: phase >= .rising ? -120 : 12)
                .opacity(phase >= .flapOpen ? 1 : 0)
                // ③ 封筒のおもて側（ポケット）：中身の下のほうを隠す
                EnvelopePocket(to: toText, from: fromText, stampDate: stampText, place: info.gate_title)
                    .frame(width: 320)
                    .opacity(phase >= .flapOpen ? 1 : 0)
                SparkleBurst(trigger: burst)
                    .offset(y: -90)
            }
            .frame(height: 360)
            .contentShape(Rectangle())
            .onTapGesture { startOpening() }
            if phase == .sealed {
                Button {
                    startOpening()
                } label: {
                    Label(content == nil ? "手紙を受け取っています…" : "封を切る", systemImage: "hand.tap.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(content == nil)
                .padding(.horizontal, 40)
                .scaleEffect(sealPulse ? 1.03 : 1)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { sealPulse = true }
                }
            }
            Spacer()
        }
    }

    private var stampText: String {
        ServerDate.parse(info.created_at).map { ServerDate.day($0) } ?? ""
    }

    private func startOpening() {
        guard content != nil, phase == .sealed else { return }
        Haptics.open()
        Trace.log("手紙：封を切る")
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { phase = .flapOpen }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            burst = true
            Haptics.tap()
            withAnimation(.spring(response: 0.7, dampingFraction: 0.72)) { phase = .rising }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.35) {
            Haptics.success()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { phase = .reading }
        }
    }

    // MARK: 読む

    private func reading(_ content: LetterContent) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                if let cardContent = letterCard(content) {
                    // 添えたグラフィティカード（クリップで留めてある。押すと大きく見る）
                    Button {
                        bigCard = cardContent
                    } label: {
                        TradingCard(content: cardContent)
                            .frame(width: 200)
                            .overlay(alignment: .top) {
                                Image(systemName: "paperclip")
                                    .font(.system(size: 34, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0x9AA0AE))
                                    .rotationEffect(.degrees(20))
                                    .offset(x: 30, y: -20)
                            }
                            .rotationEffect(.degrees(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("添えてあるグラフィティカードを大きく見る")
                    .zIndex(1)
                    .padding(.bottom, -18)
                } else if content.card_gone == true {
                    Label("添えてあったカードは、書いた人が消しました", systemImage: "rectangle.slash")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.bottom, 12)
                }
                LetterPaper(to: toText, from: fromText,
                            footnote: ServerDate.parse(content.created_at).map { "\(ServerDate.day($0))・\(info.gate_title) で" } ?? "") {
                    if let path = content.photo_path {
                        RemotePhoto(path: path)
                            .frame(height: 220)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Text(content.body)
                        .font(.system(size: 17, design: .serif))
                        .foregroundStyle(LetterPalette.ink)
                        .lineSpacing(11)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 30)
            .padding(.bottom, 40)
        }
    }

    /// 手紙に添えたカード（書いた人のカード）
    private func letterCard(_ content: LetterContent) -> TradingCardContent? {
        guard let id = content.card_id else { return nil }
        return TradingCardContent(id: id, photoPath: content.card_photo, body: content.card_body ?? "",
                                  author: content.author_name, title: content.card_title,
                                  gateTitle: content.card_gate_title ?? info.gate_title,
                                  createdAt: content.card_created_at, finish: CardFinish(raw: content.card_finish),
                                  badge: info.sent || info.isToSelf ? .mine : .friend)
    }

    private func load() async {
        guard content == nil, let api = session.api else { return }
        let firstTime = !info.isOpened && !info.sent
        do {
            content = try await api.openLetterWithCard(info.id)
            if content == nil { error = "手紙が見つかりませんでした。" }
            if firstTime {
                Trace.log("手紙を開きました")
                onOpened()
            } else if content != nil {
                // 前に開けた手紙：封を切るところを、少し速く見せる
                try? await Task.sleep(nanoseconds: 350_000_000)
                startOpening()
            }
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}

/// 手紙を書く（2026-11-20 オーナー「手紙を書いている感じの画面に」）：
/// 机の上の便せんに、宛名・本文・差出人。右上にカードをクリップで留める。下に「いつ開ける？」の切手。
/// 「封をする」と、便せんが封筒に入り、封ろうが押される。
struct LetterComposer: View {
    let context: GateContext
    let onSent: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var toSelf = true
    @State private var friend: Set<UUID> = []
    @State private var friendName: String?
    @State private var text = ""
    /// 添えるグラフィティカード（2026-11-19 オーナー「手紙には写真ではなく、カードを添付」）
    @State private var card: MyCard?
    @State private var choosingCard = false
    @State private var choosingFriend = false
    @State private var onsite = true
    @State private var useDate = false
    @State private var openAt = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var sending = false
    @State private var sealed = false
    @State private var message: String?
    @FocusState private var writing: Bool

    init(context: GateContext, onSent: @escaping () -> Void) {
        self.context = context
        self.onSent = onSent
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (onsite || useDate) && (toSelf || !friend.isEmpty)
    }

    private var toText: String {
        toSelf ? "未来の自分へ" : (friendName.map { "\($0) さんへ" } ?? "だれかへ")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(hex: 0xFBF4E8), Color(hex: 0xF0E2CC)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 22) {
                        recipientPicker
                        paper
                        whenStamps
                        if let message { NoticeText(text: message) }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 120)
                }
                .scrollDismissesKeyboard(.interactively)
                if sealed {
                    SealingOverlay(to: toText)
                        .transition(.opacity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !sealed {
                    Button {
                        Task { await send() }
                    } label: {
                        if sending {
                            ProgressView().tint(.white)
                        } else {
                            Label("封をする", systemImage: "seal.fill")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSend || sending)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
            .navigationTitle("手紙を書く")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("書けた") { writing = false }.bold()
                    }
                }
            }
            .sheet(isPresented: $choosingCard) {
                MyCardPicker(preferGate: context.gateID) { picked in
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { card = picked }
                    Haptics.tap()
                }
                .environmentObject(session)
            }
            .navigationDestination(isPresented: $choosingFriend) {
                FriendPicker(title: "宛先の友達", multiple: false, selection: $friend)
            }
            .onChange(of: friend) { _, ids in Task { await loadFriendName(ids.first) } }
            .onChange(of: text) { _, value in
                if value.count > 2000 { text = String(value.prefix(2000)) }
            }
        }
    }

    // MARK: だれに書く？

    private var recipientPicker: some View {
        HStack(spacing: 10) {
            recipientChip("未来の自分", systemImage: "hourglass", on: toSelf) {
                toSelf = true
            }
            recipientChip(!toSelf && friendName != nil ? "\(friendName!) さん" : "友達",
                          systemImage: "person.2.fill", on: !toSelf) {
                toSelf = false
                if friend.isEmpty { choosingFriend = true }
            }
        }
    }

    private func recipientChip(_ title: String, systemImage: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { action() }
            Haptics.tap()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(on ? .white : LetterPalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    if on {
                        Capsule().fill(LinearGradient(colors: LetterPalette.wax, startPoint: .top, endPoint: .bottom))
                    } else {
                        Capsule().fill(.white.opacity(0.7))
                    }
                }
                .overlay(Capsule().strokeBorder(LetterPalette.envelopeEdge.opacity(on ? 0 : 0.6)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: 便せん

    private var paper: some View {
        LetterPaper(to: toText, from: "あなたより",
                    footnote: "\(ServerDate.day(Date()))・\(context.title) で") {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(toSelf ? "いまの気持ち、未来の自分に伝えたいこと…" : "伝えたいこと…")
                        .font(.system(size: 17, design: .serif))
                        .foregroundStyle(LetterPalette.ink.opacity(0.35))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(LetterPalette.ink)
                    .lineSpacing(11)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .frame(minHeight: 220)
                    .focused($writing)
            }
            HStack {
                Spacer()
                Text("\(text.count) / 2000")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(LetterPalette.ink.opacity(0.4))
            }
        }
        .padding(.top, 54)
        .overlay(alignment: .topTrailing) { cardClip }
    }

    /// 右上：カードをクリップで留める（無ければ点線の枠）
    @ViewBuilder private var cardClip: some View {
        if let card {
            Menu {
                Button { choosingCard = true } label: { Label("ほかのカードにする", systemImage: "arrow.triangle.2.circlepath") }
                Button(role: .destructive) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { self.card = nil }
                } label: {
                    Label("カードを外す", systemImage: "xmark")
                }
            } label: {
                TradingCard(content: MyCardPicker.content(card, author: session.profile?.display_name ?? "あなた"),
                            animated: false)
                    .frame(width: 96)
                    .overlay(alignment: .top) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x9AA0AE))
                            .rotationEffect(.degrees(20))
                            .offset(x: 14, y: -14)
                    }
                    .rotationEffect(.degrees(6))
            }
            .padding(.trailing, 10)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
            .accessibilityLabel("添えたグラフィティカード（押すと替える・外す）")
        } else {
            Button {
                choosingCard = true
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .bold))
                    Text("カードを\n添える")
                        .font(.caption.weight(.bold))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(LetterPalette.wax[1])
                .frame(width: 86, height: 120)
                .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LetterPalette.wax[1].opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .rotationEffect(.degrees(6))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
            .accessibilityLabel("グラフィティカードを添える")
        }
    }

    // MARK: いつ開ける？

    private var whenStamps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("いつ開ける？")
                .font(.headline)
                .foregroundStyle(LetterPalette.ink)
            HStack(spacing: 12) {
                stampToggle("ここに来たとき", systemImage: "mappin.and.ellipse", on: $onsite)
                stampToggle("日を決める", systemImage: "calendar", on: $useDate)
            }
            if useDate {
                DatePicker("開く日", selection: $openAt,
                           in: Date().addingTimeInterval(3600)...Date().addingTimeInterval(3600 * 24 * 365 * 10),
                           displayedComponents: [.date, .hourAndMinute])
                    .font(.subheadline.weight(.semibold))
                    .padding(12)
                    .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Label(conditionText, systemImage: onsite || useDate ? "envelope.badge" : "exclamationmark.circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(onsite || useDate ? LetterPalette.ink.opacity(0.75) : Theme.alert)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: useDate)
    }

    /// 切手の形のスイッチ（ギザギザの縁。押すと色がつく）
    private func stampToggle(_ title: String, systemImage: String, on: Binding<Bool>) -> some View {
        Button {
            on.wrappedValue.toggle()
            Haptics.tap()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .bold))
                Text(title)
                    .font(.footnote.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(on.wrappedValue ? .white : LetterPalette.ink.opacity(0.7))
            .frame(maxWidth: .infinity, minHeight: 86)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(on.wrappedValue
                          ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x8A4DF5), Color(hex: 0xFF8A3D)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color.white.opacity(0.75)))
                    .padding(4)
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(LetterPalette.envelopeEdge, style: StrokeStyle(lineWidth: 2, dash: [3, 3])))
            .rotationEffect(.degrees(on.wrappedValue ? -2 : 0))
            .scaleEffect(on.wrappedValue ? 1.02 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: on.wrappedValue)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on.wrappedValue ? .isSelected : [])
    }

    private var conditionText: String {
        switch (onsite, useDate) {
        case (true, true): return "\(ServerDate.day(openAt)) を過ぎて、ここで GATE を開けたときに開けられます"
        case (true, false): return "次にここで GATE を開けたときに開けられます"
        case (false, true): return "\(ServerDate.day(openAt)) を過ぎると、どこからでも開けられます"
        case (false, false): return "どちらか 1 つを選んでください"
        }
    }

    private func loadFriendName(_ id: UUID?) async {
        guard let id, let api = session.api else { friendName = nil; return }
        friendName = (try? await api.names(of: [id]))?[id]
    }

    private func send() async {
        guard let api = session.api, let visit = context.visit else {
            message = "GATE が閉じました（離れたため）。現地でもう一度 GATE を開けてください。"
            return
        }
        writing = false
        sending = true
        defer { sending = false }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            do {
                _ = try await api.writeLetter(visit: visit, to: toSelf ? nil : friend.first, body: body,
                                              card: card?.id, openAt: useDate ? openAt : nil, onsite: onsite)
            } catch let error where ErrorText.isMissingFunction(error) && card == nil {
                // 0030 の前のサーバー：カードなしなら前の書き方で送る
                _ = try await api.writeLetter(visit: visit, to: toSelf ? nil : friend.first, body: body,
                                              photoPath: nil, openAt: useDate ? openAt : nil, onsite: onsite)
            }
            Trace.log("手紙を書きました（\(toSelf ? "自分あて" : "友達あて")・現地：\(onsite)・日時：\(useDate)・カード\(card == nil ? "なし" : "あり")）")
            // 封をする：便せんが封筒に入り、封ろうが押される
            withAnimation(.easeInOut(duration: 0.25)) { sealed = true }
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            onSent()
            dismiss()
        } catch {
            message = ErrorText.isMissingFunction(error)
                ? "カードを添えるのは、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
    }
}

/// 封をするところ：便せんが封筒に入り、ふたが閉じ、封ろうがぽんと押される
private struct SealingOverlay: View {
    let to: String
    @State private var step = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 22) {
                ZStack {
                    EnvelopeArt(to: to, from: "あなたより", stampDate: ServerDate.day(Date()), place: "",
                                sealed: false, flapOpen: step >= 2 ? 0 : 1)
                        .frame(width: 300)
                    // 便せんが上から入っていく
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LetterPalette.paper)
                        .overlay(RuledLines(spacing: 16).padding(.top, 16))
                        .frame(width: 260, height: 150)
                        .offset(y: step >= 1 ? 30 : -200)
                        .opacity(step >= 2 ? 0 : 1)
                    EnvelopePocket(to: to, from: "あなたより", stampDate: ServerDate.day(Date()), place: "")
                        .frame(width: 300)
                        .opacity(step >= 2 ? 0 : 1)
                    if step >= 3 {
                        WaxSeal()
                            .frame(width: 60, height: 60)
                            .offset(y: 300 / 1.72 * (0.48 - 0.5))
                            .transition(.scale(scale: 2.4).combined(with: .opacity))
                    }
                }
                Text(step >= 3 ? "封をしました" : "封をしています…")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.white)
                    .shadow(radius: 6)
            }
        }
        .task {
            withAnimation(.easeInOut(duration: 0.55)) { step = 1 }
            try? await Task.sleep(nanoseconds: 600_000_000)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { step = 2 }
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { step = 3 }
            Haptics.success()
        }
    }
}
