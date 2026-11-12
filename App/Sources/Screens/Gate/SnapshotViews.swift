import ARKit
import RealityKit
import SwiftUI

/// 今と昔：同じ場所の写真を時の順に並べ、2 枚を重ねて比べる。入場中は、前の写真をうすく重ねて同じ角度で「今」を撮れる。
struct SnapshotSection: View {
    let context: GateContext
    let refreshToken: Int
    let onReport: (ReportItem) -> Void

    @EnvironmentObject private var session: SessionModel
    @State private var snapshots: [Snapshot] = []
    @State private var names: [UUID: String] = [:]
    @State private var error: String?
    @State private var capturing = false
    @State private var comparing: ComparePair?
    @State private var selected: Set<String> = []

    init(context: GateContext, refreshToken: Int, onReport: @escaping (ReportItem) -> Void) {
        self.context = context
        self.refreshToken = refreshToken
        self.onReport = onReport
    }

    /// 並べる写真：はじまり（表紙）→ みんなが撮った今の写真
    private var frames: [SnapshotFrame] {
        var list: [SnapshotFrame] = []
        if let cover = context.coverPath {
            list.append(SnapshotFrame(id: "cover", path: cover, label: "はじまり", date: context.createdAt, snapshot: nil))
        }
        for s in snapshots {
            list.append(SnapshotFrame(id: s.id.uuidString, path: s.photo_path,
                                      label: s.author == session.userID ? "あなた" : (names[s.author] ?? "だれか"),
                                      date: s.created_at, snapshot: s))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if context.isInside {
                Button {
                    capturing = true
                } label: {
                    Label("同じ角度で「今」を撮る", systemImage: "camera.on.rectangle")
                }
                .buttonStyle(SecondaryButtonStyle())
                Text("前の写真がうすく重なるので、形を合わせて撮ると、同じ場所の移り変わりが分かります。1 回の入場で 1 枚。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } else if snapshots.isEmpty {
                Text("今と昔は、現地で扉を開けると見られます。同じ場所の写真が時の順に並び、2 枚を重ねて比べられます。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            if let error { NoticeText(text: error) }
            let list = frames
            if list.count >= 2 {
                HStack {
                    Text(selected.count == 2 ? "この 2 枚を比べます" : "比べる 2 枚を選ぶ（はじめは最初と最後）")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("比べる") { openCompare(list) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(list) { frame in
                        Button {
                            toggle(frame.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                RemotePhoto(path: frame.path)
                                    .frame(width: 120, height: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12)
                                        .stroke(selected.contains(frame.id) ? Theme.accent : Theme.line,
                                                lineWidth: selected.contains(frame.id) ? 3 : 1))
                                Text(ServerDate.parse(frame.date).map { ServerDate.day($0) } ?? "")
                                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.text)
                                Text(frame.label).font(.caption2).foregroundStyle(Theme.textSecondary)
                            }
                            .frame(width: 120)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let s = frame.snapshot {
                                if s.author == session.userID {
                                    Button("消す", role: .destructive) { Task { await delete(s) } }
                                } else {
                                    Button {
                                        onReport(ReportItem(id: s.id, target: .snapshot, userID: s.author,
                                                            userName: names[s.author], label: "今と昔の写真"))
                                    } label: {
                                        Label("通報する", systemImage: "exclamationmark.bubble")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .task(id: "\(context.isInside)-\(refreshToken)") { await load() }
        .fullScreenCover(isPresented: $capturing) {
            SnapshotCaptureView(context: context, reference: frames.last?.path) {
                Task { await load() }
            }
        }
        .sheet(item: $comparing) { pair in
            CompareView(pair: pair)
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            if selected.count >= 2 { selected.removeAll() }
            selected.insert(id)
        }
    }

    private func openCompare(_ list: [SnapshotFrame]) {
        let chosen = list.filter { selected.contains($0.id) }
        let pair = chosen.count == 2 ? chosen : [list.first, list.last].compactMap { $0 }
        guard pair.count == 2 else { return }
        comparing = ComparePair(before: pair[0], after: pair[1])
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            snapshots = try await api.snapshots(in: context.gateID)
            names = try await api.names(of: Array(Set(snapshots.map(\.author))))
            error = nil
        } catch {
            self.error = ErrorText.of(error)
        }
    }

    private func delete(_ s: Snapshot) async {
        guard let api = session.api else { return }
        do {
            if let path = try await api.deleteSnapshot(s.id) { await session.media?.removePhoto(path: path) }
            selected.remove(s.id.uuidString)
            await load()
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}

struct SnapshotFrame: Identifiable, Hashable {
    let id: String
    let path: String
    let label: String
    let date: String
    let snapshot: Snapshot?
}

struct ComparePair: Identifiable {
    let before: SnapshotFrame
    let after: SnapshotFrame
    var id: String { before.id + "-" + after.id }
}

/// 2 枚を重ねて、仕切りを左右に動かして比べる
struct CompareView: View {
    let pair: ComparePair

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var split: CGFloat = 0.5
    @State private var before: UIImage?
    @State private var after: UIImage?

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        image(after)
                        image(before)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geo.size.width * split)
                            }
                        Rectangle()
                            .fill(.white)
                            .frame(width: 3)
                            .shadow(radius: 3)
                            .offset(x: geo.size.width * split - 1.5)
                        Circle()
                            .fill(.white)
                            .frame(width: 34, height: 34)
                            .overlay(Image(systemName: "arrow.left.and.right").font(.caption.weight(.bold))
                                .foregroundStyle(Theme.accent))
                            .shadow(radius: 4)
                            .offset(x: geo.size.width * split - 17)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        split = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                    })
                }
                .aspectRatio(3 / 4, contentMode: .fit)
                HStack {
                    label(pair.before, alignment: .leading)
                    Spacer()
                    label(pair.after, alignment: .trailing)
                }
                Text("写真の上を左右になぞると、仕切りが動きます。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(16)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("今と昔をくらべる")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
            .task {
                before = await session.media?.photo(path: pair.before.path)
                after = await session.media?.photo(path: pair.after.path)
            }
        }
    }

    @ViewBuilder private func image(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
        } else {
            Theme.surfaceElevated.overlay(ProgressView())
        }
    }

    private func label(_ frame: SnapshotFrame, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(ServerDate.parse(frame.date).map { ServerDate.day($0) } ?? "")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
            Text(frame.label).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }
}

/// 同じ角度で「今」を撮る：カメラの景色に前の写真をうすく重ね、合わせて撮る（写真アプリからは選べない）
struct SnapshotCaptureView: View {
    let context: GateContext
    let reference: String?
    let onSaved: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var stage = ARStage()
    @State private var refImage: UIImage?
    @State private var ghost: Double = 0.45
    @State private var shot: UIImage?
    @State private var visibility: Visibility = .friends
    @State private var saving = false
    @State private var message: String?

    init(context: GateContext, reference: String?, onSaved: @escaping () -> Void) {
        self.context = context
        self.reference = reference
        self.onSaved = onSaved
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ARViewContainer(arView: stage.arView)
                .ignoresSafeArea()
                .opacity(shot == nil ? 1 : 0)
            if let shot {
                Image(uiImage: shot).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .ignoresSafeArea()
            } else if let refImage {
                Image(uiImage: refImage).resizable().scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    .ignoresSafeArea()
                    .opacity(ghost)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 12) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("閉じる")
                    Spacer()
                }
                Spacer()
                card
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .onAppear {
            stage.run(reset: true)
            Trace.log("今と昔：撮る画面を開く（前の写真：\(reference != nil ? "あり" : "なし")）")
        }
        .onDisappear { stage.pause() }
        .task {
            if let reference { refImage = await session.media?.photo(path: reference) }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            if shot == nil {
                Text(refImage == nil ? "いまの景色を撮る" : "うすく重なった前の写真に、形を合わせてください")
                    .font(.headline).foregroundStyle(Theme.text)
                if refImage != nil {
                    HStack(spacing: 10) {
                        Image(systemName: "circle.lefthalf.filled").foregroundStyle(Theme.textSecondary)
                        Slider(value: $ghost, in: 0...0.85).tint(Theme.accent)
                    }
                    .accessibilityLabel("前の写真の濃さ")
                }
                Button {
                    Task { await capture() }
                } label: {
                    Label("撮る", systemImage: "camera.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                Text("この写真を残しますか？").font(.headline).foregroundStyle(Theme.text)
                Picker("見せる人", selection: $visibility) {
                    ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 10) {
                    Button("撮り直す") { shot = nil }
                        .buttonStyle(SecondaryButtonStyle())
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView().tint(.white) } else { Text("残す") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(saving)
                }
            }
            if let message { NoticeText(text: message) }
        }
        .padding(18)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
    }

    private func capture() async {
        if let problem = stage.shotProblem(), !problem.contains("模様") {
            message = problem
            return
        }
        guard let image = await stage.grabPhoto() else {
            message = "カメラの準備ができていません。少し待ってからお試しください。"
            return
        }
        message = nil
        shot = image
        Haptics.tap()
    }

    private func save() async {
        guard let api = session.api, let media = session.media, let me = session.userID, let shot else { return }
        guard let visit = context.visit else {
            message = "入場の時間（20 分）が切れました。現地でもう一度入ってください。"
            return
        }
        saving = true
        defer { saving = false }
        var path: String?
        do {
            path = try await media.uploadPhoto(shot, owner: me)
            _ = try await api.addSnapshot(visit: visit, photoPath: path ?? "", visibility: visibility)
            Trace.log("今と昔：いまの景色を残しました")
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            if let path { await media.removePhoto(path: path) }
            message = ErrorText.of(error)
        }
    }
}
