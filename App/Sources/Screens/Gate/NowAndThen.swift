import SwiftUI

// 今と昔（2026-11-20 オーナー「今とったカードと、昔の自分や友達が残したカードを、画面全体でアップで見比べたい。もっと楽しく」）：
// この GATE の写真（はじまりの表紙・みんなのグラフィティカード・今と昔で撮った写真）を時の順に並べ、
// 大きな舞台で「昔」と「今」を見比べる。くらべる（仕切りを動かす）／ならべる（上下）／パラパラ（古い順に流す）。
// 舞台を押すと画面いっぱい（2 本の指で広げると、2 枚が一緒に大きくなる）。説明の小さな文字は置かない。

/// 見比べる 1 枚
struct ThenNowFrame: Identifiable, Hashable {
    enum Kind: Hashable { case cover, card, photo }
    let id: String
    let path: String
    let kind: Kind
    let who: String
    let date: String
    /// カードの名前（カードのときだけ）
    var title: String? = nil
    /// 消す・通報するための元
    var snapshot: Snapshot? = nil
    var card: Graffiti? = nil

    var dayText: String { GateDates.day(date) }
    var kindLabel: String {
        switch kind {
        case .cover: return "はじまり"
        case .card: return "カード"
        case .photo: return "写真"
        }
    }
}

enum ThenNowMode: String, CaseIterable, Identifiable {
    case slider, stack, flip
    var id: String { rawValue }
    var label: String {
        switch self {
        case .slider: return "くらべる"
        case .stack: return "ならべる"
        case .flip: return "パラパラ"
        }
    }
    var symbol: String {
        switch self {
        case .slider: return "slider.horizontal.below.square.and.square.filled"
        case .stack: return "rectangle.split.1x2"
        case .flip: return "play.square.stack"
        }
    }
}

struct NowAndThenView: View {
    let context: GateContext
    let refreshToken: Int
    let onReport: (ReportItem) -> Void

    @EnvironmentObject private var session: SessionModel
    @State private var snapshots: [Snapshot] = []
    @State private var cards: [Graffiti] = []
    @State private var names: [UUID: String] = [:]
    @State private var images: [String: UIImage] = [:]
    @State private var thenID: String?
    @State private var nowID: String?
    /// 下の並びを押したとき、どちらに入れるか
    @State private var picking: Slot = .then
    @State private var mode: ThenNowMode = .slider
    @State private var split: CGFloat = 0.5
    @State private var fullScreen = false
    @State private var capturing = false
    @State private var error: String?
    @State private var loaded = false

    enum Slot { case then, now }

    /// 古い順：はじまり → カード・写真
    private var frames: [ThenNowFrame] {
        var list: [ThenNowFrame] = []
        if let cover = context.coverPath {
            list.append(ThenNowFrame(id: "cover", path: cover, kind: .cover, who: "はじまり", date: context.createdAt))
        }
        for c in cards {
            guard let path = c.photo_path else { continue }
            list.append(ThenNowFrame(id: "c-" + c.id.uuidString, path: path, kind: .card, who: who(c.author),
                                     date: c.created_at, title: c.title, card: c))
        }
        for s in snapshots {
            list.append(ThenNowFrame(id: "s-" + s.id.uuidString, path: s.photo_path, kind: .photo, who: who(s.author),
                                     date: s.created_at, snapshot: s))
        }
        return list.sorted { (ServerDate.parse($0.date) ?? .distantPast) < (ServerDate.parse($1.date) ?? .distantPast) }
    }

    /// 「今」を撮るときに、うすく重ねる写真：カメラでそのまま撮った写真（今と昔の写真・はじまりの表紙）。
    /// カードの写真は切り取り・飾りが入っていて形が合わないので、ほかに無いときだけ
    private var captureReference: String? {
        let picked = [thenFrame, nowFrame].compactMap { $0 }
        if let photo = picked.first(where: { $0.kind != .card }) { return photo.path }
        if let photo = frames.last(where: { $0.kind != .card }) { return photo.path }
        return (nowFrame ?? thenFrame)?.path
    }

    private func who(_ id: UUID) -> String {
        id == session.userID ? "あなた" : (names[id] ?? "だれか")
    }

    private var thenFrame: ThenNowFrame? {
        let list = frames
        return list.first { $0.id == thenID } ?? list.first
    }

    private var nowFrame: ThenNowFrame? {
        let list = frames
        return list.first { $0.id == nowID } ?? (list.count >= 2 ? list.last : nil)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let error { NoticeText(text: error) }
                if let then = thenFrame {
                    stage(then: then, now: nowFrame)
                    modeChips
                    filmstrip
                } else if loaded {
                    emptyStage
                } else {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 320)
                }
                if context.isInside {
                    Button {
                        capturing = true
                    } label: {
                        Label("同じ角度で「今」を撮る", systemImage: "camera.on.rectangle")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background { InsideBackground().ignoresSafeArea() }
        .navigationTitle("今と昔")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task(id: "\(context.isInside)-\(refreshToken)") { await load() }
        .fullScreenCover(isPresented: $capturing) {
            SnapshotCaptureView(context: context, reference: captureReference) {
                Task {
                    await load()
                    // 撮ったばかりの 1 枚を「今」に
                    nowID = frames.last?.id
                }
            }
        }
        .fullScreenCover(isPresented: $fullScreen) {
            if let then = thenFrame {
                ThenNowFullScreen(frames: frames, then: then, now: nowFrame, images: images,
                                  mode: $mode, split: $split)
            }
        }
        .onAppear { Trace.log("今と昔：開いた（写真 \(snapshots.count)・カード \(cards.count)）") }
    }

    // MARK: 舞台

    private func stage(then: ThenNowFrame, now: ThenNowFrame?) -> some View {
        ThenNowStage(frames: frames, then: then, now: now, images: images, mode: mode, split: $split)
            .aspectRatio(mode == .stack ? 2 / 3 : 3 / 4, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(LinearGradient(colors: Brand.neon, startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 2)
                .opacity(0.8))
            .shadow(color: Color(hex: 0x8A4DF5).opacity(0.45), radius: 22)
            .overlay(alignment: .topTrailing) {
                Button {
                    fullScreen = true
                    Trace.log("今と昔：画面いっぱいで見る（\(mode.label)）")
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .padding(12)
                .padding(.top, mode == .slider && now != nil ? 40 : 0)
                .accessibilityLabel("画面いっぱいで見る")
            }
    }

    private var emptyStage: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.2.circlepath")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(LinearGradient(colors: Brand.neon, startPoint: .top, endPoint: .bottom))
            Text(context.isInside ? "最初の「今」を撮ってみよう" : "GATE を開けると見られます")
                .font(.headline)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var modeChips: some View {
        HStack(spacing: 8) {
            ForEach(ThenNowMode.allCases) { m in
                let on = mode == m
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode = m }
                    Haptics.tap()
                } label: {
                    Label(m.label, systemImage: m.symbol)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(on ? Color(hex: 0x1B1235) : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(on ? Color.white : Color.white.opacity(0.1), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(on ? 0 : 0.22)))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .disabled(nowFrame == nil)
        .opacity(nowFrame == nil ? 0.5 : 1)
    }

    // MARK: 下の並び（押して「昔」「今」を選ぶ）

    private var filmstrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("えらぶ")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.white)
                slotChip("昔", .then)
                slotChip("今", .now)
                Spacer()
                Text("\(frames.count) 枚")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(frames) { frame in
                            thumb(frame).id(frame.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear {
                    if let id = nowFrame?.id { reader.scrollTo(id, anchor: .trailing) }
                }
            }
        }
    }

    private func slotChip(_ text: String, _ slot: Slot) -> some View {
        let on = picking == slot
        return Button {
            picking = slot
        } label: {
            Text(text)
                .font(.footnote.weight(.heavy))
                .foregroundStyle(on ? .white : .white.opacity(0.7))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background {
                    if on {
                        Capsule().fill(slot == .then ? Theme.accent : Theme.warm)
                    } else {
                        Capsule().fill(.white.opacity(0.1))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(slot == .then ? "押した写真を「昔」にする" : "押した写真を「今」にする")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func thumb(_ frame: ThenNowFrame) -> some View {
        let isThen = frame.id == thenFrame?.id
        let isNow = frame.id == nowFrame?.id
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                if picking == .then { thenID = frame.id } else { nowID = frame.id }
            }
            Haptics.tap()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ThenNowImage(image: images[frame.path])
                    .frame(width: 88, height: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isThen ? Theme.accent : (isNow ? Theme.warm : .white.opacity(0.18)),
                                      lineWidth: isThen || isNow ? 3 : 1))
                    .overlay(alignment: .topLeading) {
                        if isThen || isNow {
                            Text(isThen ? "昔" : "今")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(isThen ? Theme.accent : Theme.warm, in: Capsule())
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if frame.kind == .card {
                            Image(systemName: "rectangle.portrait.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.black.opacity(0.45), in: Circle())
                                .padding(5)
                        }
                    }
                Text(frame.dayText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(frame.who)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            .frame(width: 88)
        }
        .buttonStyle(.plain)
        .contextMenu { menu(for: frame) }
        .accessibilityLabel("\(frame.dayText)・\(frame.who)の\(frame.kindLabel)")
    }

    @ViewBuilder private func menu(for frame: ThenNowFrame) -> some View {
        Button {
            thenID = frame.id
        } label: {
            Label("「昔」にする", systemImage: "clock.arrow.circlepath")
        }
        Button {
            nowID = frame.id
        } label: {
            Label("「今」にする", systemImage: "sun.max")
        }
        if let s = frame.snapshot {
            if s.author == session.userID {
                Button(role: .destructive) { Task { await delete(s) } } label: { Label("この写真を消す", systemImage: "trash") }
            } else {
                Button {
                    onReport(ReportItem(id: s.id, target: .snapshot, userID: s.author,
                                        userName: names[s.author], label: "今と昔の写真"))
                } label: {
                    Label("通報する", systemImage: "exclamationmark.bubble")
                }
            }
        }
        if let c = frame.card, c.author != session.userID {
            Button {
                onReport(ReportItem(id: c.id, target: .graffiti, userID: c.author,
                                    userName: names[c.author], label: "グラフィティカード"))
            } label: {
                Label("通報する", systemImage: "exclamationmark.bubble")
            }
        }
    }

    // MARK: 読み込み

    private func load() async {
        guard let api = session.api else { return }
        do {
            async let snaps = api.snapshots(in: context.gateID)
            async let list = api.graffiti(in: context.gateID)
            snapshots = try await snaps
            cards = (try? await list) ?? []
            let authors = Set(snapshots.map(\.author)).union(cards.map(\.author))
            names = (try? await api.names(of: Array(authors))) ?? names
            error = nil
        } catch {
            self.error = ErrorText.of(error)
        }
        loaded = true
        if let id = thenID, !frames.contains(where: { $0.id == id }) { thenID = nil }
        if let id = nowID, !frames.contains(where: { $0.id == id }) { nowID = nil }
        await loadImages()
    }

    /// 写真は小さい順に受け取る（舞台の 2 枚を先に）
    private func loadImages() async {
        guard let media = session.media else { return }
        var order = [thenFrame, nowFrame].compactMap { $0 }
        order += frames.filter { f in !order.contains(where: { $0.id == f.id }) }
        for frame in order where images[frame.path] == nil {
            if let image = await media.photo(path: frame.path) {
                images[frame.path] = image
            }
        }
    }

    private func delete(_ s: Snapshot) async {
        guard let api = session.api else { return }
        do {
            if let path = try await api.deleteSnapshot(s.id) { await session.media?.removePhoto(path: path) }
            await load()
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}

// MARK: - 舞台（くらべる・ならべる・パラパラ）

struct ThenNowStage: View {
    let frames: [ThenNowFrame]
    let then: ThenNowFrame
    let now: ThenNowFrame?
    let images: [String: UIImage]
    let mode: ThenNowMode
    @Binding var split: CGFloat
    /// 画面いっぱいのとき：2 本の指で一緒に大きくする
    var zoom: CGFloat = 1
    var zoomAnchor: UnitPoint = .center

    var body: some View {
        GeometryReader { geo in
            Group {
                if let now {
                    switch mode {
                    case .slider: slider(then: then, now: now, size: geo.size)
                    case .stack: stack(then: then, now: now)
                    case .flip: ThenNowFlip(frames: frames, images: images, zoom: zoom, zoomAnchor: zoomAnchor)
                    }
                } else {
                    // まだ 1 枚だけ
                    zoomed(ThenNowImage(image: images[then.path]))
                        .overlay(alignment: .bottomLeading) { tag(then, slot: "はじまり", color: Theme.accent) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color(hex: 0x0B0F2A))
    }

    private func zoomed<V: View>(_ v: V) -> some View {
        v.scaleEffect(zoom, anchor: zoomAnchor)
    }

    private func slider(then: ThenNowFrame, now: ThenNowFrame, size: CGSize) -> some View {
        ZStack(alignment: .leading) {
            zoomed(ThenNowImage(image: images[now.path]))
            zoomed(ThenNowImage(image: images[then.path]))
                .mask(alignment: .leading) {
                    Rectangle().frame(width: size.width * split)
                }
            // 仕切り
            Rectangle()
                .fill(LinearGradient(colors: Brand.neon, startPoint: .top, endPoint: .bottom))
                .frame(width: 3)
                .shadow(color: .white.opacity(0.8), radius: 4)
                .offset(x: size.width * split - 1.5)
            Circle()
                .fill(.white)
                .frame(width: 42, height: 42)
                .overlay(Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(Theme.accent))
                .shadow(color: .black.opacity(0.35), radius: 6)
                .offset(x: size.width * split - 21)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) { tag(then, slot: "昔", color: Theme.accent).opacity(split > 0.12 ? 1 : 0) }
        .overlay(alignment: .topTrailing) { tag(now, slot: "今", color: Theme.warm).opacity(split < 0.88 ? 1 : 0) }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            split = min(max(value.location.x / max(size.width, 1), 0), 1)
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("昔 \(then.dayText) と 今 \(now.dayText) をくらべる")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: split = min(1, split + 0.1)
            case .decrement: split = max(0, split - 0.1)
            @unknown default: break
            }
        }
    }

    private func stack(then: ThenNowFrame, now: ThenNowFrame) -> some View {
        VStack(spacing: 3) {
            zoomed(ThenNowImage(image: images[then.path]))
                .clipped()
                .overlay(alignment: .topLeading) { tag(then, slot: "昔", color: Theme.accent) }
            zoomed(ThenNowImage(image: images[now.path]))
                .clipped()
                .overlay(alignment: .topLeading) { tag(now, slot: "今", color: Theme.warm) }
        }
        .background(.white)
    }

    private func tag(_ frame: ThenNowFrame, slot: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(slot)
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(color, in: Capsule())
            VStack(alignment: .leading, spacing: 0) {
                Text(frame.dayText).font(.caption.weight(.bold))
                Text(frame.title ?? frame.who).font(.caption2).lineLimit(1)
            }
            .foregroundStyle(.white)
        }
        .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 5)
        .background(.black.opacity(0.5), in: Capsule())
        .padding(12)
    }
}

/// パラパラ：古い順に 1 枚ずつ、ふわっと入れ替えて流す（日付を大きく）
struct ThenNowFlip: View {
    let frames: [ThenNowFrame]
    let images: [String: UIImage]
    var zoom: CGFloat = 1
    var zoomAnchor: UnitPoint = .center
    @State private var start = Date()

    private let step: TimeInterval = 1.4

    var body: some View {
        TimelineView(.periodic(from: start, by: step)) { timeline in
            let count = max(frames.count, 1)
            let index = frames.isEmpty ? 0 : Int(timeline.date.timeIntervalSince(start) / step) % count
            let frame = frames.isEmpty ? nil : frames[min(index, frames.count - 1)]
            if let frame {
            ZStack(alignment: .bottomLeading) {
                ThenNowImage(image: images[frame.path])
                    .scaleEffect(zoom, anchor: zoomAnchor)
                    .id(frame.id)
                    .transition(.opacity)
                VStack(alignment: .leading, spacing: 4) {
                    Text(frame.dayText)
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 6)
                    Text("\(frame.who)・\(frame.kindLabel)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.6), radius: 4)
                    // 進み具合
                    HStack(spacing: 4) {
                        ForEach(0..<count, id: \.self) { i in
                            Capsule()
                                .fill(i <= index ? Color.white : Color.white.opacity(0.3))
                                .frame(height: 3)
                        }
                    }
                    .frame(maxWidth: 220)
                    .padding(.top, 4)
                }
                .padding(18)
            }
            .animation(.easeInOut(duration: 0.55), value: frame.id)
            }
        }
        .onAppear { start = Date() }
    }
}

/// 写真 1 枚（届くまでは夜空の色）
struct ThenNowImage: View {
    let image: UIImage?

    var body: some View {
        GeometryReader { geo in
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                LinearGradient(colors: [Color(hex: 0x1D1240), Color(hex: 0x2E1546)], startPoint: .top, endPoint: .bottom)
                    .overlay(ProgressView().tint(.white))
            }
        }
    }
}

// MARK: - 画面いっぱい

struct ThenNowFullScreen: View {
    let frames: [ThenNowFrame]
    let then: ThenNowFrame
    let now: ThenNowFrame?
    let images: [String: UIImage]
    @Binding var mode: ThenNowMode
    @Binding var split: CGFloat

    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var anchor: UnitPoint = .center

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ThenNowStage(frames: frames, then: then, now: now, images: images, mode: mode, split: $split,
                         zoom: zoom, zoomAnchor: anchor)
                .ignoresSafeArea()
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            anchor = value.startAnchor
                            zoom = min(max(baseZoom * value.magnification, 1), 5)
                        }
                        .onEnded { _ in baseZoom = zoom }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        zoom = zoom > 1.05 ? 1 : 2.5
                        baseZoom = zoom
                    }
                }
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                    .accessibilityLabel("閉じる")
                    Spacer()
                    if zoom > 1.05 {
                        Button {
                            withAnimation { zoom = 1; baseZoom = 1 }
                        } label: {
                            Label("もとの大きさ", systemImage: "arrow.down.right.and.arrow.up.left")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .background(.black.opacity(0.5), in: Capsule())
                        }
                    }
                }
                Spacer()
                if now != nil {
                    HStack(spacing: 8) {
                        ForEach(ThenNowMode.allCases) { m in
                            let on = mode == m
                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode = m }
                            } label: {
                                Label(m.label, systemImage: m.symbol)
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(on ? Color(hex: 0x1B1235) : .white)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .background(on ? Color.white : Color.black.opacity(0.5), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .statusBarHidden()
        .onAppear { Trace.log("今と昔：画面いっぱい（\(mode.label)・\(frames.count) 枚）") }
    }
}
