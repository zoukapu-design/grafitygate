import ARKit
import PhotosUI
import RealityKit
import SwiftUI

/// AR の画面。カメラの景色が主役で、下に白いカードを 1 枚だけ置く（その時にやることだけを出す）。
struct ARExperienceView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var location: LocationModel
    @StateObject private var model: ARExperienceModel
    /// 歩いている TRAIL の次の地点（撮る画面で、方向と距離を出す）
    @State private var trailTarget: TrailGuide.Target?
    private let onClose: (() -> Void)?

    init(mode: ARExperienceModel.Mode, onClose: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: ARExperienceModel(mode: mode))
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            ARViewContainer(arView: model.stage.arView)
                .ignoresSafeArea()
                .onTapGesture(coordinateSpace: .local) { point in
                    model.handleTap(at: point)
                }
                // 扉の位置を合わせるあいだだけ：なぞって動かす・2 本指で回す
                .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .local)
                    .onChanged { value in model.dragDoor(to: value.location) },
                         including: model.adjustingDoor ? .all : .none)
                .simultaneousGesture(RotateGesture()
                    .onChanged { value in model.rotateDoor(by: value.rotation.radians) }
                    .onEnded { _ in model.endRotate() },
                                     including: model.adjustingDoor ? .all : .none)
            if model.showsReticle {
                Reticle()
                    .allowsHitTesting(false)
            }
            HandCursorView(hand: model.hand)
            VStack(spacing: 12) {
                ARTopBar(stage: model.stage, onClose: onClose)
                if let trailTarget, model.mode == .explore, model.phase == .scanning {
                    TrailCompassPill(target: trailTarget)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
                if let caption = model.toast ?? model.artCaption {
                    Text(caption)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                Spacer()
                ExperienceCard(model: model)
            }
            .animation(.easeInOut(duration: 0.2), value: model.artCaption)
            .animation(.easeInOut(duration: 0.2), value: model.toast)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .onAppear {
            model.attach(session: session, location: location)
            model.onFinished = onClose
            model.start()
        }
        .onDisappear {
            model.stop()
        }
        .task(id: session.state) {
            guard model.mode == .explore, let api = session.api, session.state == .signedIn else { return }
            trailTarget = await TrailGuide.load(api: api, nearby: model.nearby)
        }
        .onChange(of: model.phase) { _, phase in
            // 扉を開けて TRAIL が進んだあと、撮る画面に戻ったら次の地点を取り直す
            guard phase == .scanning, model.mode == .explore, let api = session.api, session.state == .signedIn else { return }
            Task { trailTarget = await TrailGuide.load(api: api, nearby: model.nearby) }
        }
        .onChange(of: model.nearby) { _, nearby in
            // 次の地点が 100m 以内に入ったら、少し細かい位置で案内する
            if let t = trailTarget { trailTarget = TrailGuide.target(trail: t.trail, stop: t.stop, nearby: nearby) ?? t }
        }
        .sheet(item: $model.reportItem) { item in
            ReportSheet(item: item) { model.removeArtworks(of: item.userID) }
                .environmentObject(session)
        }
        .sheet(item: $model.presentedGate, onDismiss: { model.resetToScanning() }) { route in
            NavigationStack {
                GateDetailView(gateID: route.id)
            }
            .environmentObject(session)
            .environmentObject(location)
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let arView: ARView

    func makeUIView(context: Context) -> ARView { arView }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// 画面の中央の、向ける所の印
private struct Reticle: View {
    var body: some View {
        CornerBrackets()
            .stroke(.white.opacity(0.92), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            .frame(width: 236, height: 236)
            .shadow(color: .black.opacity(0.3), radius: 6)
    }
}

/// 四隅の角だけの枠
private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let arm: CGFloat = 36
        let round: CGFloat = 22
        var p = Path()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
        ]
        for (corner, sx, sy) in corners {
            p.move(to: CGPoint(x: corner.x, y: corner.y + sy * arm))
            p.addLine(to: CGPoint(x: corner.x, y: corner.y + sy * round))
            p.addQuadCurve(to: CGPoint(x: corner.x + sx * round, y: corner.y), control: corner)
            p.addLine(to: CGPoint(x: corner.x + sx * arm, y: corner.y))
        }
        return p
    }
}

/// 上の帯：閉じる・AR の案内（問題があるときだけ）
private struct ARTopBar: View {
    @ObservedObject var stage: ARStage
    @EnvironmentObject private var location: LocationModel
    let onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("閉じる")
            }
            if let text = stage.guidance.text ?? location.fixProblem {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.text)
                    // 設定アプリでしか直せないとき（カメラ・位置情報の許可、正確な位置情報）
                    if stage.guidance == .cameraDenied || (stage.guidance.text == nil && location.needsSettings),
                       let url = URL(string: UIApplication.openSettingsURLString) {
                        Button("設定アプリを開く") { UIApplication.shared.open(url) }
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.25), value: stage.guidance)
    }
}

/// 下の白いカード。その時にやることだけを出す。
private struct ExperienceCard: View {
    @ObservedObject var model: ARExperienceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            if let notice = model.notice {
                NoticeText(text: notice)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .animation(.easeInOut(duration: 0.2), value: model.adjustingDoor)
        .animation(.easeInOut(duration: 0.2), value: model.art)
    }

    @ViewBuilder private var content: some View {
        if model.adjustingDoor {
            adjustCard
        } else if model.phase == .doorOpen, let step = model.art {
            ArtCard(model: model, step: step)
        } else {
            phaseContent
        }
    }

    /// 扉の位置を指で合わせる
    private var adjustCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Title("扉の位置を合わせる")
            Caption("画面をなぞると、指の下の地面へ扉が動きます。2 本の指で回すと向きが変わります。動かしたのは、あなたの画面の中だけです。")
            HStack(spacing: 10) {
                Button("元に戻す") { model.resetAdjust() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("決める") { model.finishAdjust() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            if model.isGateOwner {
                Button {
                    model.startRemap()
                } label: {
                    Label("この位置で場所の記憶を撮り直す", systemImage: "arrow.triangle.2.circlepath.camera")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
        }
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .scanning:
            scanning
        case .working(let text):
            HStack(spacing: 12) {
                ProgressView()
                Text(text).font(.subheadline).foregroundStyle(Theme.text)
            }
        case .choosing(let list):
            choosing(list)
        case .findingPlace:
            VStack(alignment: .leading, spacing: 10) {
                Title("扉の場所を探しています")
                Caption("作った人が扉を置いた辺りを、ゆっくり見回してください。見つかると、同じ位置に扉が現れます。")
                ProgressView().tint(Theme.accent)
                Button("見つからないので、目の前に出す") { model.stopFindingPlace() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .doorClosed:
            VStack(alignment: .leading, spacing: 10) {
                Title("扉が現れました")
                if let note = model.trailNote {
                    Label(note, systemImage: "figure.walk")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.warm)
                }
                Caption(model.placedPrecisely ? "作った人が扉を置いた場所です。扉を押すと開きます。"
                                              : "場所の記憶が見つからなかったので、おおよその位置に出しています。扉を押すと開きます。")
                Button("扉を開く") { model.openDoor() }
                    .buttonStyle(PrimaryButtonStyle())
                if !model.placedPrecisely {
                    Button {
                        model.beginAdjust()
                    } label: {
                        Label("扉の位置を合わせる", systemImage: "hand.draw")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                }
            }
        case .doorOpen:
            DoorOpenCard(model: model)
        case .createShoot(let index):
            createShoot(index)
        case .createSimilar(let list):
            similar(list)
        case .createDetails:
            CreateDetailsForm(model: model)
        case .createPlace:
            VStack(alignment: .leading, spacing: 10) {
                Title("扉を置く")
                Caption(model.hasPlacedDoor ? "置き直すときは、別の所の地面を押してください。"
                                            : "扉を置きたい所の地面を、画面で押してください。")
                Button("ここに置く") { model.confirmPlace() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.hasPlacedDoor)
            }
        case .createMapping:
            VStack(alignment: .leading, spacing: 10) {
                Title("場所を覚えています")
                Caption("扉とそのまわりを、ゆっくり左右に見回してください。友達が来たとき、同じ位置に扉を出すために使います（まわりの景色の特徴が、入場した人の iPhone に届きます。写真そのものは送りません）。")
                ProgressView(value: model.mappingProgress).tint(Theme.accent)
                Button("覚えた（保存する）") { model.saveGate() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.mappingReady)
            }
        case .remapping:
            VStack(alignment: .leading, spacing: 10) {
                Title("場所の記憶を撮り直す")
                Caption("扉とそのまわりを、ゆっくり左右に見回してください。保存すると、入場した友達の iPhone でも、いまの位置に扉と作品が出ます（まわりの景色の特徴が、入場した人に届きます）。")
                ProgressView(value: model.mappingProgress).tint(Theme.accent)
                HStack(spacing: 10) {
                    Button("やめる") { model.cancelRemap() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("保存する") { model.saveRemap() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!model.mappingReady)
                }
            }
        case .createSaving(let text):
            HStack(spacing: 12) {
                ProgressView()
                Text(text).font(.subheadline).foregroundStyle(Theme.text)
            }
        case .createRetry(let message):
            VStack(alignment: .leading, spacing: 10) {
                Title(model.createRetryHasGate ? "続きを送れませんでした" : "GATE を送れませんでした")
                NoticeText(text: message)
                Caption("写真・名前・扉の位置はそのままです。電波の良い所で「もう一度送る」を押してください（同じ GATE が 2 つできることはありません）。")
                Button("もう一度送る") { model.saveGate() }
                    .buttonStyle(PrimaryButtonStyle())
                Button(model.createRetryHasGate ? "ここで終える" : "作るのをやめる") { model.abandonCreate() }
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                NoticeText(text: message)
                Button("もう一度") { model.resetToScanning() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.mode == .explore {
                Title("目の前の場所や物に向けてください")
                if model.nearby.isEmpty {
                    Caption("近く（100m 以内）に GATE があれば、ここで開けます。")
                } else {
                    Caption("近くの GATE：" + model.nearby.prefix(3)
                        .map { "\($0.title)（約 \(Int($0.distance_m.rounded()))m）" }
                        .joined(separator: "、"))
                }
                Button("ここで開く") { model.openHere() }
                    .buttonStyle(PrimaryButtonStyle())
                Button("ここに GATE を作る") { model.startCreate() }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Title("作った人が写した場所・物に向けてください")
                Caption("位置（120m 以内）と景色の両方が合うと、扉が現れます。")
                Button("ここで開く") { model.openHere() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func choosing(_ list: [MatchCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Title("どの GATE ですか？")
            Caption("景色がはっきり合う GATE が見つかりませんでした。近くの GATE から選ぶと、もう一度確かめます。")
            ForEach(list.prefix(4)) { candidate in
                Button {
                    model.choose(candidate)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            Text("\(candidate.owner_name)・約 \(Int(candidate.distance_m.rounded()))m・\(Self.similarity(candidate.similarity))")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
                    }
                    .padding(12)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            Button("写し直す") { model.resetToScanning() }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// 作る前に：近くに同じ場所らしい GATE がある
    private func similar(_ list: [MatchCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Title("近くに似た GATE があります")
            Caption("同じ場所の GATE なら、そこに入って記憶を足せます。ちがう場所なら、そのまま新しく作れます。")
            ForEach(list.prefix(3)) { candidate in
                Button {
                    model.choose(candidate)
                } label: {
                    HStack(spacing: 10) {
                        if let cover = candidate.cover_path {
                            RemotePhoto(path: cover)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            Text("\(candidate.owner_name)・約 \(Int(candidate.distance_m.rounded()))m・\(Self.similarity(candidate.similarity))")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text("入る").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                    .padding(10)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            Button("ちがう場所なので、新しく作る") { model.continueCreating() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func createShoot(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Title("GATE を作る（\(index + 1)/\(ARExperienceModel.shootSteps.count)）")
            Caption("残したい場所や物を、\(ARExperienceModel.shootSteps[index])写してください。友達が来たとき、この景色で GATE を見分けます。人の顔や車のナンバーが写らないように。")
            if !model.shots.isEmpty {
                HStack(spacing: 8) {
                    ForEach(model.shots) { shot in
                        if let image = shot.thumbnail {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            Button("写す") { model.captureCreateShot() }
                .buttonStyle(PrimaryButtonStyle())
            Button("やめる") { model.resetToScanning() }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private static func similarity(_ s: String) -> String {
        switch s {
        case "strong": return "よく似ている"
        case "weak": return "少し似ている"
        case "none": return "似ていない"
        default: return "比べられない"
        }
    }
}

/// GATE の名前・ひとこと・種類・見せる人
private struct CreateDetailsForm: View {
    @ObservedObject var model: ARExperienceModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Title("GATE の名前")
            TextField("例：駅前の街灯", text: $model.form.title)
                .focused($focused)
                .padding(12)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
            TextField("ひとこと（なくても大丈夫）", text: $model.form.note, axis: .vertical)
                .lineLimit(1...3)
                .focused($focused)
                .padding(12)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
            Picker("種類", selection: $model.form.kind) {
                Text("場所の中の物").tag("object")
                Text("場所").tag("place")
            }
            .pickerStyle(.segmented)
            Picker("見せる人", selection: $model.form.visibility) {
                ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
            }
            .pickerStyle(.segmented)
            Toggle("正面の写真を表紙にする", isOn: $model.form.useCover)
                .font(.subheadline)
                .tint(Theme.accent)
            Button("次へ（扉を置く）") {
                focused = false
                model.confirmDetails()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }
}

private struct Title: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.headline).foregroundStyle(Theme.text)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 扉が開いたとき：作品の案内・中へ・作品を置く
private struct DoorOpenCard: View {
    @ObservedObject var model: ARExperienceModel
    @ObservedObject var hand: HandTouch

    init(model: ARExperienceModel) {
        _model = ObservedObject(wrappedValue: model)
        _hand = ObservedObject(wrappedValue: model.hand)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Title("扉が開きました")
            if model.artworkCount > 0 {
                Caption(hand.isActive ? "作品が \(model.artworkCount) 個あります。手をのばして触れてみてください（画面で押しても動きます）。"
                                      : "作品が \(model.artworkCount) 個あります。近づいたり、画面で押したりすると動きます。")
            }
            if let warning = model.mapWarning { Caption(warning) }
            Button("中へ") { model.goInside() }
                .buttonStyle(PrimaryButtonStyle())
            if !model.placedPrecisely {
                Button {
                    model.beginAdjust()
                } label: {
                    Label("扉の位置を合わせる", systemImage: "hand.draw")
                }
                .buttonStyle(SecondaryButtonStyle())
            } else if model.isGateOwner {
                Button {
                    model.startRemap()
                } label: {
                    Label("場所の記憶を撮り直す", systemImage: "arrow.triangle.2.circlepath.camera")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
            }
            if model.visitID != nil {
                Button {
                    model.startArt()
                } label: {
                    Label(model.myArtworkCount > 0 ? "作品を置く（あと \(max(0, ARExperienceModel.artworksPerPerson - model.myArtworkCount)) つ）"
                                                   : "作品を置く",
                          systemImage: "sparkles")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.myArtworkCount >= ARExperienceModel.artworksPerPerson)
            }
        }
    }
}

/// 作品を置く・自分の作品を直すカード
private struct ArtCard: View {
    @ObservedObject var model: ARExperienceModel
    let step: ARExperienceModel.ArtStep
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var loadingVideo = false
    @State private var personItem: PhotosPickerItem?
    /// 人を切り抜いているあいだの進み具合（0〜1）
    @State private var personProgress: Double?
    @State private var recordingVoice = false
    @State private var confirmDelete = false
    @FocusState private var focused: Bool

    init(model: ARExperienceModel, step: ARExperienceModel.ArtStep) {
        _model = ObservedObject(wrappedValue: model)
        self.step = step
    }

    var body: some View {
        Group {
            switch step {
            case .choosing: choosing
            case .composing: composing
            case .placing: placing
            case .saving:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("作品を置いています…").font(.subheadline).foregroundStyle(Theme.text)
                }
            case .selected(let id): selected(id)
            case .viewing(let id): viewing(id)
            }
        }
        .onChange(of: step) { _, _ in confirmDelete = false }
    }

    // 種類を選ぶ
    private var choosing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Title("どんな作品を置きますか？")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(ArtworkKind.allCases) { kind in
                    Button {
                        model.chooseArtKind(kind)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            Text(kind.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            Text(kind.caption).font(.caption).foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                        .padding(12)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("やめる") { model.cancelArt() }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // 中身
    private var composing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Title(model.draft.kind.label)
            switch model.draft.kind {
            case .photo: photoInput
            case .video: videoInput
            case .person: personInput
            case .text: textInput
            case .voice: voiceInput
            case .petals, .light: EmptyView()
            }
            if model.draft.kind != .photo, model.draft.kind != .video, model.draft.kind != .person {
                colorRow
            }
            if model.draft.kind.isMedia {
                Caption("触れる・押すと流れます。近づくと、やわらかく光ります。")
            } else {
                actionRow
            }
            Picker("見せる人", selection: $model.draft.visibility) {
                ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $model.draft.asDraft) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("まず自分だけで試す").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text("下書きで置き、触れて動きを確かめてから公開します").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.accent)
            Button("次へ（置く所を決める）") {
                focused = false
                model.beginArtPlacement()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(loadingVideo || personProgress != nil)
            Button("種類を選び直す") { model.art = .choosing }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    model.draft.image = image.downscaled(maxSide: 1600)
                    model.notice = nil
                }
                pickerItem = nil
            }
        }
        .onChange(of: videoItem) { _, item in
            guard let item else { return }
            Task {
                loadingVideo = true
                defer {
                    loadingVideo = false
                    videoItem = nil
                }
                do {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                        throw MediaPrep.Failure.unreadable
                    }
                    let video = try await MediaPrep.prepareVideo(movie.url)
                    model.setArtVideo(video)
                } catch {
                    Trace.log("映像パネルの動画を読み込めませんでした：\(error.localizedDescription)")
                    model.notice = (error as? LocalizedError)?.errorDescription ?? "動画を読み込めませんでした。"
                }
            }
        }
        .onChange(of: personItem) { _, item in
            guard let item else { return }
            Task {
                personProgress = 0
                defer {
                    personProgress = nil
                    personItem = nil
                }
                do {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                        throw PersonCutout.Failure.unreadable
                    }
                    let result = try await PersonCutout.make(from: movie.url) { value in
                        Task { @MainActor in personProgress = value }
                    }
                    model.setArtPerson(result)
                } catch {
                    Trace.log("人物の映像を作れませんでした：\(error.localizedDescription)")
                    model.notice = (error as? LocalizedError)?.errorDescription ?? "人物の映像を作れませんでした。"
                }
            }
        }
        .sheet(isPresented: $recordingVoice) {
            VoiceRecorderSheet { url, seconds in
                model.setArtVoice(url, duration: seconds)
            }
        }
    }

    private var videoInput: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceElevated)
                if let image = model.draft.image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "play.rectangle").foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
                if loadingVideo { ProgressView() }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottomLeading) {
                if let video = model.draft.video {
                    Text(durationText(video.duration))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: Capsule())
                        .padding(4)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                PhotosPicker(selection: $videoItem, matching: .videos) {
                    Label(model.draft.video == nil ? "動画を選ぶ" : "動画を選び直す", systemImage: "film")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .disabled(loadingVideo)
                Text(loadingVideo ? "動画を整えています…" : "15 秒まで。位置などの情報は消して送ります。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var personInput: some View {
        HStack(spacing: 12) {
            ZStack {
                // 透けるところが分かるように、夜空の色の上に重ねる
                LinearGradient(colors: [Color(hex: 0x0A1029), Color(hex: 0x2C1445), Color(hex: 0x6B2A3D)],
                               startPoint: .top, endPoint: .bottom)
                if let image = model.draft.person?.poster {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "figure.stand").font(.title2).foregroundStyle(.white.opacity(0.7))
                }
                if personProgress != nil { ProgressView().tint(.white) }
            }
            .frame(width: 64, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 6) {
                PhotosPicker(selection: $personItem, matching: .videos) {
                    Label(model.draft.person == nil ? "人が写った動画を選ぶ" : "動画を選び直す", systemImage: "film")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .disabled(personProgress != nil)
                if let progress = personProgress {
                    ProgressView(value: progress).tint(Theme.accent)
                    Text("人を切り抜いています… \(Int(progress * 100))%（iPhone の中だけで行います）")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    Text(model.draft.person.map { "\(durationText($0.duration)) の人物の映像ができました" }
                         ?? "10 秒まで。全身か上半身がはっきり写っている動画が向いています。")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var voiceInput: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.accentLight)
                Image(systemName: "waveform").font(.title3).foregroundStyle(Theme.accent)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    recordingVoice = true
                } label: {
                    Label(model.draft.voiceFile == nil ? "声を録る" : "録り直す", systemImage: "mic")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                Text(model.draft.voiceFile == nil ? "60 秒まで。この場所で聞いてほしいことを。"
                                                  : "\(durationText(model.draft.voiceDuration)) の声を録りました")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var photoInput: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceElevated)
                if let image = model.draft.image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(Theme.textSecondary.opacity(0.6))
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(spacing: 8) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("写真を選ぶ", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                Button {
                    model.useCameraForArtPhoto()
                } label: {
                    Label("いまの景色を写す", systemImage: "camera")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            }
        }
    }

    private var textInput: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextField("例：また春に会おう", text: $model.draft.text, axis: .vertical)
                .lineLimit(1...3)
                .focused($focused)
                .padding(12)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: model.draft.text) { _, value in
                    if value.count > ARExperienceModel.artTextLimit {
                        model.draft.text = String(value.prefix(ARExperienceModel.artTextLimit))
                    }
                }
            Text("\(model.draft.text.count)/\(ARExperienceModel.artTextLimit)")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("色").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 12) {
                ForEach(ArtworkColor.allCases) { color in
                    let selected = model.draft.color == color
                    Button {
                        model.draft.color = color
                    } label: {
                        VStack(spacing: 4) {
                            Circle()
                                .fill(color.swatch)
                                .frame(width: 30, height: 30)
                                .overlay(Circle().stroke(selected ? Theme.accent : Theme.line, lineWidth: selected ? 3 : 1))
                            Text(color.label).font(.caption2).foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.label)
                }
            }
        }
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("触れたとき").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ArtworkAction.visual) { action in
                        let selected = model.draft.action == action
                        Button(action.label) { model.draft.action = action }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? .white : Theme.text)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 34)
                            .background(selected ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                    }
                }
            }
        }
    }

    // 置く所
    private var placing: some View {
        VStack(alignment: .leading, spacing: 10) {
            Title(model.movingArtwork == nil ? "置く所を決める" : "置き直す")
            Caption("置きたい所に iPhone を向けてください。見本がついてきます。歩いて近づいたり離れたりもできます。")
            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(Theme.textSecondary)
                Slider(value: Binding(get: { Double(model.draft.scale) },
                                      set: { model.setPreviewScale(Float($0)) }),
                       in: 0.5...2.0)
                    .tint(Theme.accent)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.textSecondary)
            }
            .accessibilityLabel("大きさ")
            if !model.previewInRange {
                NoticeText(text: "扉から離れすぎています。扉から 4m 以内に向けてください。")
            }
            Button("ここに置く") { model.confirmArtPlacement() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.previewInRange)
            Button("戻る") { model.backFromPlacing() }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // ほかの人の作品
    private func viewing(_ id: UUID) -> some View {
        let artwork = model.artScene?.artwork(id)
        return VStack(alignment: .leading, spacing: 10) {
            Title("\(model.artworkOwnerName(id)) さんの\(artwork?.artKind.label ?? "作品")")
            if let artwork {
                Caption("\(ServerDate.relative(artwork.created_at))に置かれました。"
                        + (artwork.artKind.isMedia ? "触れる・押すと流れます。" : "近づいたり、手で触れたりすると動きます。"))
                playButton(id, artwork)
            }
            HStack(spacing: 10) {
                Button("閉じる") { model.cancelArt() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("通報する") { model.reportArtwork(id) }
                    .buttonStyle(DangerButtonStyle())
            }
        }
    }

    // 自分の作品
    private func selected(_ id: UUID) -> some View {
        let artwork = model.artScene?.artwork(id)
        return VStack(alignment: .leading, spacing: 10) {
            Title(artwork?.isDraft == true ? "下書きの\(artwork?.artKind.label ?? "作品")" : "あなたの\(artwork?.artKind.label ?? "作品")")
            if let artwork {
                if artwork.isDraft {
                    Caption("あなたにだけ見えています。触れたり近づいたりして動きを確かめたら、公開してください。")
                } else {
                    Caption("見せる人：\(Visibility.label(of: artwork.visibility))・\(ServerDate.relative(artwork.created_at))")
                }
                if artwork.needs_replace == true {
                    Label("扉の場所の記憶が撮り直されました。位置がずれていたら、置き直してください。", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.warm)
                    Button("このままでよい") { model.keepArtworkPlace(id) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                playButton(id, artwork)
                if artwork.isDraft {
                    Button("公開する") { model.publishArtwork(id) }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            Button("置き直す") { model.startMovingArtwork(id) }
                .buttonStyle(SecondaryButtonStyle())
            HStack(spacing: 10) {
                Button("隠す") { model.hideArtwork(id) }
                    .buttonStyle(SecondaryButtonStyle())
                Button(confirmDelete ? "本当に消す" : "消す") {
                    if confirmDelete {
                        model.deleteArtwork(id)
                    } else {
                        confirmDelete = true
                    }
                }
                .buttonStyle(DangerButtonStyle())
            }
            Button("閉じる") {
                confirmDelete = false
                model.cancelArt()
            }
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
        }
    }
}

extension ArtCard {
    /// 映像パネル・声の玉の「流す／止める」
    @ViewBuilder
    func playButton(_ id: UUID, _ artwork: Artwork) -> some View {
        if artwork.artKind.isMedia {
            let playing = model.playingArtwork == id
            Button {
                playing ? model.stopArtworkPlayback() : model.playArtwork(id)
            } label: {
                Label(playing ? "止める" : "流す（\(durationText(artwork.duration ?? 0))）",
                      systemImage: playing ? "stop.fill" : "play.fill")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }
}

/// 指先の印（手が見えているあいだ。作品に近いと光り、触れるとふくらむ）
private struct HandCursorView: View {
    @ObservedObject var hand: HandTouch

    var body: some View {
        ZStack {
            if let cursor = hand.cursor {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(cursor.touching ? 0.95 : (cursor.near ? 0.55 : 0.25)))
                        .frame(width: cursor.touching ? 26 : 16, height: cursor.touching ? 26 : 16)
                    Circle()
                        .stroke(Color.white.opacity(cursor.near ? 0.95 : 0.5), lineWidth: 2)
                        .frame(width: cursor.near ? 44 : 30, height: cursor.near ? 44 : 30)
                }
                .shadow(color: Color(hex: 0xFFD79A).opacity(cursor.near ? 0.95 : 0.35), radius: cursor.touching ? 18 : 8)
                .position(cursor.point)
                .animation(.easeOut(duration: 0.12), value: cursor)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: hand.cursor == nil)
    }
}

private extension ArtworkColor {
    var swatch: Color {
        let (r, g, b) = rgb
        return Color(red: Double(r), green: Double(g), blue: Double(b))
    }
}
