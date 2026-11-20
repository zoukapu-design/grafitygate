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

    @State private var gateTitle = ""

    init(mode: ARExperienceModel.Mode, onClose: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: ARExperienceModel(mode: mode))
        self.onClose = onClose
    }

    /// AR カメラの道具を出しているか（AR の飾りを置いている・人を撮っているあいだは、そちらのカードを出す）
    private var storyShown: Bool {
        model.story.isOn && model.art == nil && !model.capturingPerson && model.phase == .doorOpen
    }

    /// AR カメラで、文字を指で動かせるとき
    private var storyGestures: Bool {
        storyShown && model.story.canManipulate
    }

    /// AR カメラの「AR を残す」：GATE に残る AR の飾りを置く（置けないときは、理由を知らせる）
    private func leaveArt() {
        model.startArt()
        if model.art == nil, let notice = model.notice {
            model.notice = nil
            model.showToast(notice)
        }
    }

    var body: some View {
        ZStack {
            ARViewContainer(arView: model.stage.arView)
                .ignoresSafeArea()
                .onTapGesture(coordinateSpace: .local) { point in
                    model.handleTap(at: point)
                }
                // 扉の位置を合わせるあいだ：なぞって動かす・2 本指で回す。
                // AR カメラのあいだ：文字をなぞって動かす・2 本指で傾ける・つまんで大きさ
                .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .local)
                    .onChanged { value in
                        if storyGestures {
                            model.story.drag(from: value.startLocation, to: value.location)
                        } else {
                            model.dragDoor(to: value.location)
                        }
                    }
                    .onEnded { _ in model.story.endDrag() },
                         including: (model.adjustingDoor || storyGestures) ? .all : .none)
                .simultaneousGesture(RotateGesture()
                    .onChanged { value in
                        if storyGestures { model.story.rotate(by: value.rotation.radians) } else { model.rotateDoor(by: value.rotation.radians) }
                    }
                    .onEnded { _ in
                        if storyGestures { model.story.endRotate() } else { model.endRotate() }
                    },
                                     including: (model.adjustingDoor || storyGestures) ? .all : .none)
                // 扉の大きさ：2 本の指でつまむ（置くとき・作った本人が合わせるとき）
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        if storyGestures { model.story.pinch(by: value.magnification) } else { model.pinchDoor(by: value.magnification) }
                    }
                    .onEnded { _ in
                        if storyGestures { model.story.endPinch() } else { model.endPinch() }
                    },
                                     including: (model.canResizeDoor || storyGestures) ? .all : .none)
            if model.showsReticle {
                Reticle()
                    .allowsHitTesting(false)
            }
            if model.scanningLook {
                // 写真の特徴を作っているあいだ、景色の上を光が流れる
                ScanSweep()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            HandCursorView(hand: model.hand)
            if storyShown {
                // AR カメラ（扉・みんなの AR と一緒に、グラフィティカードの写真を撮る）
                StoryCameraControls(story: model.story, gateTitle: gateTitle, artworkCount: model.artworkCount,
                                    canLeaveArt: model.visitID != nil, toast: model.toast ?? model.artCaption,
                                    onClose: { model.endStoryCamera() },
                                    onLeaveArt: { leaveArt() },
                                    onUse: { model.useStoryPhoto($0) })
                    .transition(.opacity)
            } else {
            VStack(spacing: 12) {
                ARTopBar(model: model, stage: model.stage, onClose: onClose)
                if model.phase == .scanning {
                    if let trailTarget, model.mode == .explore {
                        TrailCompassPill(target: trailTarget)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    } else if let gate = model.guideGate ?? (model.mode == .explore ? model.nearby.first.map(GuideGate.init) : nil) {
                        // GATE の画面から開いたときはその GATE、撮る画面ではいちばん近い GATE の方向
                        GateCompassPill(target: gate)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.opacity)
                    }
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
        }
        .animation(.easeInOut(duration: 0.25), value: storyShown)
        .animation(.easeInOut(duration: 0.3), value: model.scanningLook)
        .task(id: model.enteredGate) {
            // AR カメラの上に出す GATE の名前
            guard let gate = model.enteredGate, let api = session.api else { return }
            gateTitle = (try? await api.summary(gate))?.title ?? ""
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
        .overlay {
            if let goal = model.trailGoal {
                TrailGoalOverlay(goal: goal) {
                    withAnimation(.easeOut(duration: 0.25)) { model.trailGoal = nil }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: model.trailGoal)
        .overlay {
            if model.passFlash {
                PassThroughFlash()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: model.passFlash)
        .sheet(item: $model.reportItem) { item in
            ReportSheet(item: item) { model.removeArtworks(of: item.userID) }
                .environmentObject(session)
        }
        .sheet(item: $model.presentedGate, onDismiss: { model.sheetDismissed() }) { route in
            NavigationStack {
                GateDetailView(gateID: route.id)
                    // カードを作る画面の「AR カメラ」は、シートを閉じて、いまの扉のまま撮る
                    .environment(\.openARCardCamera, { gate in model.openStoryFromSheet(gate: gate) })
                    .toolbar {
                        // AR から開いた画面には下のタブが無いので、はっきりした「閉じる」を付ける（カメラの画面に戻る）
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                model.presentedGate = nil
                            } label: {
                                Label("カメラに戻る", systemImage: "xmark")
                            }
                            .accessibilityLabel("閉じて、カメラの画面に戻る")
                        }
                    }
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
    @ObservedObject var model: ARExperienceModel
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
            if let text = stageHint ?? location.fixProblem {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.text)
                    // 設定アプリでしか直せないとき（カメラ・位置情報の許可、正確な位置情報）
                    if stage.guidance == .cameraDenied || (stageHint == nil && location.needsSettings),
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

    /// 上に出す AR の案内。写真を写しているあいだは、AR の追跡だけの案内（周りの形がつかみにくい・見回して）は出さない。
    /// 写真は絵そのもので確かめる（`ShotQuality`）ので、ここで「模様が少ない」と出すと、写せるのに食い違う（2026-11-15）。
    /// AR の追跡は、このあと扉を床に置くとき・場所を覚えるときに要るので、そこでは出す。
    private var stageHint: String? {
        switch model.phase {
        case .scanning, .createKind, .createShoot, .addLooksShoot:
            if stage.guidance == .featureless || stage.guidance == .lookAround { return nil }
        default:
            break
        }
        return stage.guidance.text
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
        if model.capturingPerson {
            PersonCaptureCard(model: model)
        } else if model.adjustingDoor {
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
            Title(model.isGateOwner ? "GATE の位置・大きさ" : "GATE の位置を合わせる")
            Caption("画面をなぞると、指の下の地面へ GATE が動きます。2 本の指で回すと向きが変わります。")
            if model.isGateOwner {
                DoorSizePicker(model: model)
                Caption("大きさは、入った人にも同じ大きさで出ます。")
            }
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
                    Label("この位置で GATE の位置の記録を撮り直す", systemImage: "arrow.triangle.2.circlepath.camera")
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
            VStack(alignment: .leading, spacing: 12) {
                CardHeadline(symbol: "location.viewfinder", title: "GATE の場所を探しています", hint: "まわりをゆっくり見回してね")
                ProgressView().tint(Theme.accent)
                Button("見つからないので、目の前に出す") { model.stopFindingPlace() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .doorClosed:
            // 2026-11-21 オーナー：説明の文はやめて、何をすればよいかを 1 行と大きなボタンで
            VStack(alignment: .leading, spacing: 12) {
                CardHeadline(symbol: "sparkles", title: "GATE が現れました",
                             hint: model.doorScale < 0.6 ? "iPhone を GATE に入れても開くよ" : "くぐっても開くよ")
                if let note = model.trailNote {
                    Label(note, systemImage: "figure.walk")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.warm)
                }
                Button {
                    model.openDoor()
                } label: {
                    Label("GATE を開ける", systemImage: "door.left.hand.open")
                }
                .buttonStyle(PrimaryButtonStyle())
                if !model.placedPrecisely {
                    AdjustLink(model: model)
                }
            }
        case .doorOpen:
            DoorOpenCard(model: model)
        case .createKind:
            kindChoice
        case .addLooksShoot:
            addLooksShoot
        case .addLooksDone(let count, let max):
            VStack(alignment: .leading, spacing: 10) {
                Title("見え方を足しました")
                Caption("いまの見え方でも、友達が入りやすくなりました（見本 \(count)/\(max)）。別の時間・天気・季節にも足しておくと、もっと入りやすくなります。")
                if count < max {
                    Button("もう少し足す") { model.addMoreLooks() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Button("閉じる") { model.onFinished?() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        case .createShoot(let index):
            createShoot(index)
        case .createSimilar(let list):
            similar(list)
        case .createDetails:
            CreateDetailsForm(model: model)
        case .createPlace:
            VStack(alignment: .leading, spacing: 10) {
                Title("GATE を置く")
                Caption(model.hasPlacedDoor ? "置き直すときは、別の所の地面を押してください。2 本の指でつまむと、GATE の大きさが変わります。"
                                            : "GATE を置きたい所の地面（机の上の物なら机の上）を、画面で押してください。")
                if model.hasPlacedDoor {
                    DoorDesignPicker(selection: model.doorDesign) { model.setDoorDesign($0) }
                    DoorSizePicker(model: model)
                }
                Button("ここに置く") { model.confirmPlace() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.hasPlacedDoor)
            }
        case .createMapping:
            VStack(alignment: .leading, spacing: 10) {
                Title("場所を覚えています")
                Caption("GATE とそのまわりを、ゆっくり左右に見回してください。友達が来たとき、同じ位置に GATE を出すために使います。")
                ProgressView(value: model.mappingProgress).tint(Theme.accent)
                Button("覚えた（保存する）") { model.saveGate() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.mappingReady)
            }
        case .remapping:
            VStack(alignment: .leading, spacing: 10) {
                Title("GATE の位置の記録を撮り直す")
                Caption("GATE とそのまわりを、ゆっくり左右に見回してください。保存すると、友達の iPhone でも、いまの位置に GATE が出ます。")
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
                Caption("写真・名前・GATE の位置はそのままです。電波の良い所で「もう一度送る」を押してください（同じ GATE が 2 つできることはありません）。")
                Button("もう一度送る") { model.saveGate() }
                    .buttonStyle(PrimaryButtonStyle())
                Button(model.createRetryHasGate ? "ここで終える" : "作るのをやめる") { model.abandonCreate() }
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .failed(let message):
            if model.lastEnterReason == "no_match" {
                // 写真が合わなかったとき：見本の景色を大きめに見せて、すぐ写し直せるように
                VStack(alignment: .leading, spacing: 12) {
                    GuideLook(cover: model.guideCover, title: "まだ見つかりません", detail: "この景色と同じように写して")
                    Button {
                        model.retry()
                        model.openHere()
                    } label: {
                        Label("もう一度写す", systemImage: "viewfinder")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    NoticeText(text: message)
                    Button("もう一度") { model.retry() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.mode == .explore {
                if model.nearbyChecked && model.nearby.isEmpty {
                    // 近くに何もない：いちばん大きいボタンは「作る」
                    Title("この辺りに GATE はまだありません")
                    Button("ここに GATE を作る") { model.startCreate() }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("ここで開く") { model.openHere() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                } else {
                    Title(model.nearby.isEmpty ? "目の前の場所や物に向けてください"
                          : "近くに GATE が \(model.nearby.count) つあります")
                    if !model.nearby.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.nearby.prefix(6)) { gate in
                                    NearbyChip(gate: gate)
                                }
                            }
                        }
                    }
                    Button("ここで開く") { model.openHere() }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("ここに GATE を作る") { model.startCreate() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                // 作った人が写した景色を見本に出す（同じように写すと開く）
                GuideLook(cover: model.guideCover, title: "この景色にカメラを向けて", detail: model.guideGate?.title)
                Button {
                    model.openHere()
                } label: {
                    Label("ここで開く", systemImage: "viewfinder")
                }
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
                    HStack(spacing: 10) {
                        if let cover = candidate.cover_path {
                            RemotePhoto(path: cover)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
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
            Caption("同じ場所の GATE なら、そこに入ってグラフィティカードを足せます。ちがう場所なら、そのまま新しく作れます。")
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

    /// 作る：はじめに、何を GATE にするか
    private var kindChoice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Title("何を GATE にしますか？")
            ForEach(GateKind.allCases) { kind in
                Button {
                    model.chooseKind(kind)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(kind == .view ? Theme.warm : Theme.accent)
                            .frame(width: 44, height: 44)
                            .background(kind == .view ? Theme.warm.opacity(0.12) : Theme.accentLight,
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.label).font(.headline).foregroundStyle(Theme.text)
                            Text(kind.hint).font(.caption).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(10)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Button("やめる") { model.resetToScanning() }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// 見え方を足す（作った本人が現地で）
    private var addLooksShoot: some View {
        VStack(alignment: .leading, spacing: 10) {
            Title("見え方を足す（\(model.lookShots.count)/\(ARExperienceModel.maxLookShots)）")
            Caption(model.targetKind == .view
                    ? "作ったときと同じ所に立って、いまの景色を写してください。夕方・夜・雨の日・別の季節に足すと、その時間に来た友達も入りやすくなります。"
                    : "作ったときと同じ物・場所を、いまの明るさで写してください。夜や別の季節に足すと、その時間に来た友達も入りやすくなります。")
            if let rc = model.refCount {
                Text("いまの見本 \(rc.count)/\(rc.max)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            if !model.lookShots.isEmpty {
                HStack(spacing: 8) {
                    ForEach(model.lookShots) { shot in
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
            if model.lookShots.isEmpty {
                Button("写す") { model.captureLookShot() }
                    .buttonStyle(PrimaryButtonStyle())
            } else if model.lookShots.count < ARExperienceModel.maxLookShots {
                Button("もう 1 枚写す（少し向きを変えて）") { model.captureLookShot() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if !model.lookShots.isEmpty {
                Button("この見え方を足す（\(model.lookShots.count) 枚）") { model.sendLooks() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func createShoot(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Title("\(model.createKind == .view ? "景色の" : "")GATE を作る（\(index + 1)/\(model.createKind.shootSteps.count)）")
            Caption(model.createKind.shootCaption(index))
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

/// 撮る画面の、近くの GATE の小さな札（表紙・名前・距離）
private struct NearbyChip: View {
    let gate: NearbyGate

    var body: some View {
        HStack(spacing: 8) {
            GateCoverImage(path: gate.cover_path, markSize: 18)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(gate.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("約 \(Int(gate.distance_m.rounded()))m").font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 5)
        .frame(maxWidth: 180, alignment: .leading)
        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
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
                ForEach(GateKind.allCases) { kind in Text(kind.label).tag(kind.rawValue) }
            }
            .pickerStyle(.segmented)
            Picker("見せる範囲", selection: $model.form.visibility) {
                ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
            }
            .pickerStyle(.segmented)
            Toggle("正面の写真を表紙にする", isOn: $model.form.useCover)
                .font(.subheadline)
                .tint(Theme.accent)
            Button("次へ（GATE を置く）") {
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

/// カードの見出し：光る丸のしるし・題・ひとことの案内（1 行ずつ。狭い iPhone では少し小さくして入れる）
private struct CardHeadline: View {
    let symbol: String
    let title: String
    var hint: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Theme.neonBand, in: Circle())
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let hint {
                    Text(hint)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            Spacer(minLength: 4)
        }
    }
}

/// 仮の位置に出た GATE を、指で合わせる（小さく）
private struct AdjustLink: View {
    @ObservedObject var model: ARExperienceModel

    var body: some View {
        Button {
            model.beginAdjust()
        } label: {
            Label("ずれていたら、GATE の位置を合わせる", systemImage: "hand.draw")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.accent)
        .frame(maxWidth: .infinity)
    }
}

/// 作った人が写した景色（GATE の表紙）を見本に出す。押すと大きく見られる
private struct GuideLook: View {
    let cover: String?
    let title: String
    var detail: String?
    @State private var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let cover, !large {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { large = true }
                        Haptics.tap()
                    } label: {
                        RemotePhoto(path: cover)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.neonBand, lineWidth: 2))
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(4)
                                    .background(.black.opacity(0.45), in: Circle())
                                    .padding(4)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("見本の景色を大きく見る")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            if large, let cover {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { large = false }
                } label: {
                    Color.clear
                        .frame(height: 190)
                        .frame(maxWidth: .infinity)
                        .overlay { RemotePhoto(path: cover) }
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.neonBand, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
                .accessibilityLabel("見本の景色を小さくする")
            }
        }
    }
}

/// 写真の特徴を作っているあいだ、カメラの景色の上を流れる光（「確かめている」が目で分かるように）
private struct ScanSweep: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let p = t.truncatingRemainder(dividingBy: 1.3) / 1.3
                let y = h * (0.1 + 0.7 * p)
                ZStack {
                    RoundedRectangle(cornerRadius: 38)
                        .strokeBorder(Theme.neonBand, lineWidth: 5)
                        .opacity(0.55 + 0.35 * abs(sin(t * 3)))
                        .blur(radius: 1.5)
                        .padding(8)
                    LinearGradient(colors: [.clear, Color(hex: 0xFF5FD2).opacity(0.28), .white.opacity(0.7),
                                            Color(hex: 0x3FD0FF).opacity(0.28), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(width: w, height: 110)
                        .position(x: w / 2, y: y)
                    ForEach(0..<7, id: \.self) { i in
                        let phase = Double(i) * 0.9
                        Image(systemName: "sparkle")
                            .font(.system(size: 12 + 10 * abs(sin(t * 3 + phase)), weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: Color(hex: i % 2 == 0 ? 0xFF5FD2 : 0x9B5CFF), radius: 6)
                            .position(x: w * (0.08 + 0.84 * Double(i) / 6), y: y + 14 * sin(t * 4 + phase))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// GATE が開いたとき（2026-11-20 オーナー「選ぶボタンが多くわかりにくい」）：
/// 大きなボタンは「中へ入る」と「AR カメラでカードを撮る」の 2 つだけ。AR の飾りを置く・位置や大きさ・位置の記録は右上の「そのほか」へ
private struct DoorOpenCard: View {
    @ObservedObject var model: ARExperienceModel
    @ObservedObject var hand: HandTouch

    init(model: ARExperienceModel) {
        _model = ObservedObject(wrappedValue: model)
        _hand = ObservedObject(wrappedValue: model.hand)
    }

    private var artLeft: Int { max(0, ARExperienceModel.artworksPerPerson - model.myArtworkCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                CardHeadline(symbol: "sparkles", title: "GATE が開きました",
                             hint: model.doorScale < 0.6 ? "iPhone を GATE に入れても中へ" : "くぐっても中へ入れるよ")
                if model.visitID != nil || model.isGateOwner {
                    moreMenu
                }
            }
            if model.artworkCount > 0 {
                Label(hand.isActive ? "AR の飾りが \(model.artworkCount) 個。手をのばして触れると動きます"
                                    : "AR の飾りが \(model.artworkCount) 個。押すと動きます",
                      systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            if let warning = model.mapWarning { Caption(warning) }
            // 2 つの大きなボタンを横に並べて、カードを低くする（GATE のまわりの光が、カードに隠れないように）
            HStack(spacing: 10) {
                Button {
                    model.goInside()
                } label: {
                    Label("中へ入る", systemImage: "door.left.hand.open")
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .buttonStyle(PrimaryButtonStyle())
                // AR カメラ：GATE・みんなの AR・効果・文字と一緒に撮って、グラフィティカードに
                Button {
                    model.startStoryCamera()
                } label: {
                    Label("AR カメラで撮る", systemImage: "camera.viewfinder")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if !model.placedPrecisely {
                // 仮の位置に出ているときだけ、小さく
                AdjustLink(model: model)
            }
        }
    }

    /// そのほか：AR の飾りを置く・（作った人）大きさ・位置の記録を撮り直す
    private var moreMenu: some View {
        Menu {
            if model.visitID != nil {
                Button {
                    model.startArt()
                } label: {
                    Label(model.myArtworkCount > 0 ? "AR の飾りを置く（あと \(artLeft) つ）" : "AR の飾りを置く",
                          systemImage: "sparkles")
                }
                .disabled(artLeft == 0)
            }
            if model.isGateOwner {
                Button {
                    model.beginAdjust()
                } label: {
                    Label(model.placedPrecisely ? "GATE の大きさを変える" : "GATE の位置・大きさを合わせる",
                          systemImage: "arrow.up.left.and.arrow.down.right")
                }
                if model.placedPrecisely {
                    Button {
                        model.startRemap()
                    } label: {
                        Label("GATE の位置の記録を撮り直す", systemImage: "arrow.triangle.2.circlepath.camera")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(Theme.accentLight, in: Circle())
        }
        .accessibilityLabel("そのほか（AR の飾りを置く など）")
    }
}

/// AR の飾りを置く・自分の AR の飾りを直すカード
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
                    Text("AR の飾りを置いています…").font(.subheadline).foregroundStyle(Theme.text)
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
            Title("どんな AR の飾りを置きますか？")
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
            Picker("見せる範囲", selection: $model.draft.visibility) {
                ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
            }
            .pickerStyle(.segmented)
            Toggle(isOn: $model.draft.asDraft) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("まず自分だけで試す").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
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
                GateCoverImage.nightSky
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
                // いちばん大きいのは「この場で撮る」：いまカメラに映っている人を数秒撮って、そのまま残す
                Button {
                    model.beginPersonCapture()
                } label: {
                    Label(model.draft.person == nil ? "この場で撮る" : "この場で撮り直す", systemImage: "record.circle")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.warm)
                .disabled(personProgress != nil)
                PhotosPicker(selection: $personItem, matching: .videos) {
                    Label("写真アプリの動画から", systemImage: "film")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
                .disabled(personProgress != nil)
                if let progress = personProgress {
                    ProgressView(value: progress).tint(Theme.accent)
                    Text("人を切り抜いています… \(Int(progress * 100))%")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                } else {
                    Text(model.draft.person.map { "\(durationText($0.duration)) の人物の映像ができました" }
                         ?? "10 秒まで。頭から足もとまで（全身）はっきり写っている動画が向いています。")
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
            if model.draft.kind == .person && model.movingArtwork == nil && model.doorStyleIsPortal {
                // 扉の向こうから手を振る：扉の中（回廊）に立たせる
                Picker("置き方", selection: Binding(get: { model.draft.insideDoor },
                                                  set: { model.setPersonInsideDoor($0) })) {
                    Text("GATE の中に立たせる").tag(true)
                    Text("好きな所に置く").tag(false)
                }
                .pickerStyle(.segmented)
            }
            Caption(model.draft.insideDoor
                    ? "GATE の中に立ちます。GATE が開くと流れて、来た人に中から手を振ります（撮るときに手を振ったり、手まねきしたりするのがおすすめ）。"
                    : "置きたい所に iPhone を向けてください。見本がついてきます。歩いて近づいたり離れたりもできます。")
            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(Theme.textSecondary)
                Slider(value: Binding(get: { Double(model.draft.scale) },
                                      set: { model.setPreviewScale(Float($0)) }),
                       in: (model.draft.insideDoor ? 0.3 : 0.5)...2.0)
                    .tint(Theme.accent)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(Theme.textSecondary)
            }
            .accessibilityLabel("大きさ")
            if !model.previewInRange {
                NoticeText(text: "GATE から離れすぎています。GATE から 4m 以内に向けてください。")
            }
            Button("ここに置く") { model.confirmArtPlacement() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.previewInRange)
            Button("戻る") { model.backFromPlacing() }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // ほかの人の AR の飾り
    private func viewing(_ id: UUID) -> some View {
        let artwork = model.artScene?.artwork(id)
        return VStack(alignment: .leading, spacing: 10) {
            Title("\(model.artworkOwnerName(id)) さんの\(artwork?.artKind.label ?? "AR の飾り")")
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

    // 自分の AR の飾り
    private func selected(_ id: UUID) -> some View {
        let artwork = model.artScene?.artwork(id)
        return VStack(alignment: .leading, spacing: 10) {
            Title(artwork?.isDraft == true ? "下書きの\(artwork?.artKind.label ?? "AR の飾り")" : "あなたの\(artwork?.artKind.label ?? "AR の飾り")")
            if let artwork {
                if artwork.isDraft {
                    Caption("あなたにだけ見えています。触れたり近づいたりして動きを確かめたら、公開してください。")
                } else {
                    Caption("見せる範囲：\(Visibility.label(of: artwork.visibility))・\(ServerDate.relative(artwork.created_at))")
                }
                if artwork.needs_replace == true {
                    Label("GATE の位置の記録が撮り直されました。位置がずれていたら、置き直してください。", systemImage: "exclamationmark.triangle")
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

/// 指先の印（手が見えているあいだ。AR の飾りに近いと光り、触れるとふくらむ）
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


/// 扉の大きさ：小・中・大（いまの大きさに近いものが選ばれて見える）。つまんで細かく変えることもできる
private struct DoorSizePicker: View {
    @ObservedObject var model: ARExperienceModel

    var body: some View {
        HStack(spacing: 8) {
            Text("大きさ").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            ForEach(ARExperienceModel.doorSizes, id: \.label) { size in
                let selected = abs(model.doorScale - size.scale) < 0.08
                Button {
                    withAnimation(.snappy) { model.setDoorScale(size.scale) }
                    model.endPinch()
                    Haptics.tap()
                } label: {
                    Text(size.label)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 32)
                        .foregroundStyle(selected ? .white : Theme.text)
                        .background(selected ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            Text(String(format: "%.0f%%", model.doorScale * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
    }
}


/// その場で人を撮る：映したい人にカメラを向けて、赤いボタンで撮り始める・止める（10 秒まで）。止めると人を切り抜く
private struct PersonCaptureCard: View {
    @ObservedObject var model: ARExperienceModel
    @ObservedObject var recorder: ARPersonRecorder

    init(model: ARExperienceModel) {
        _model = ObservedObject(wrappedValue: model)
        _recorder = ObservedObject(wrappedValue: model.personRecorder)
    }

    private var recording: Bool { recorder.state == .recording }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let progress = model.personCutProgress {
                Title("人を切り抜いています")
                ProgressView(value: progress).tint(Theme.accent)
                Caption("\(Int(progress * 100))%（iPhone の中だけで行います。背景は残りません）")
            } else {
                HStack {
                    Title(recording ? "撮っています" : "その場で人を撮る")
                    Spacer()
                    if recording {
                        HStack(spacing: 6) {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text(String(format: "%.1f / %.0f 秒", recorder.elapsed, ARPersonRecorder.limit))
                                .font(.caption.monospacedDigit().weight(.semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.red.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.red)
                    }
                }
                Caption(recording
                        ? "止めるときは、もう一度押します。10 秒で自動で止まります。"
                        : "映したい人の頭から足もとまで（全身）が入るように、2〜3m 離れてカメラを向け、赤いボタンで撮り始めます。声も一緒に残ります。足もとまで写すと、その場に立っているように見えます（明るい所・1 人だけが切り抜きやすいです）。手を振ったり手まねきしたりして撮ると、GATE の中から来た人を誘えます。")
                if recording {
                    ProgressView(value: min(recorder.elapsed, ARPersonRecorder.limit), total: ARPersonRecorder.limit)
                        .tint(.red)
                }
                HStack {
                    Spacer()
                    Button {
                        model.togglePersonRecording()
                    } label: {
                        ZStack {
                            Circle().stroke(Color.red.opacity(0.35), lineWidth: 4).frame(width: 74, height: 74)
                            RoundedRectangle(cornerRadius: recording ? 8 : 30, style: .continuous)
                                .fill(Color.red)
                                .frame(width: recording ? 30 : 60, height: recording ? 30 : 60)
                                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: recording)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(recorder.state == .finishing)
                    .accessibilityLabel(recording ? "止める" : "撮り始める")
                    Spacer()
                }
                if !recording {
                    Button("やめる") { model.cancelPersonCapture() }
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .disabled(recorder.state == .finishing)
                }
            }
        }
    }
}


/// TRAIL を歩き終えたときの「ゴール！」（扉の足もとから光が舞い上がったあとに出す）
struct TrailGoalOverlay: View {
    let goal: TrailReached
    let onClose: () -> Void

    @State private var glow = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture(perform: onClose)
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Theme.neonBand)
                        .frame(width: 112, height: 112)
                        .blur(radius: glow ? 22 : 10)
                        .opacity(0.8)
                    GateMark(size: 76, glowing: true)
                }
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: glow)
                Text("ゴール！")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.neonBand)
                Text("TRAIL「\(goal.title)」")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                Text("\(goal.stop_count) か所の GATE を、順番に歩き終えました。")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("GATE に戻る", action: onClose)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: 340)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.35), radius: 30, y: 10)
            .padding(24)
        }
        .onAppear { glow = true }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}


/// 扉をくぐった瞬間：白い光が広がって消え、「扉をくぐった！」
private struct PassThroughFlash: View {
    @State private var bloom = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [.white.opacity(0.95), Color(hex: 0xFFB37A).opacity(0.55), Color(hex: 0x8A4DF5).opacity(0.25), .clear],
                           center: .center, startRadius: 0, endRadius: bloom ? 900 : 120)
                .opacity(bloom ? 0.0 : 1)
                .animation(.easeOut(duration: 1.4), value: bloom)
            VStack(spacing: 8) {
                Text("GATE をくぐった！")
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(color: Color(hex: 0x8A4DF5).opacity(0.9), radius: 16)
                Text("GATE の中へ入ります")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.4), radius: 6)
            }
            .scaleEffect(bloom ? 1 : 0.85)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: bloom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear { bloom = true }
        .accessibilityElement(children: .combine)
    }
}
