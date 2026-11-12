import ARKit
import RealityKit
import SwiftUI

/// AR の画面。カメラの景色が主役で、下に白いカードを 1 枚だけ置く（その時にやることだけを出す）。
struct ARExperienceView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var location: LocationModel
    @StateObject private var model: ARExperienceModel
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
            if model.showsReticle {
                Reticle()
                    .allowsHitTesting(false)
            }
            VStack(spacing: 12) {
                ARTopBar(stage: model.stage, onClose: onClose)
                Spacer()
                ExperienceCard(model: model)
            }
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
                Text(text)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.text)
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
    }

    @ViewBuilder private var content: some View {
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
                Caption(model.placedPrecisely ? "作った人が扉を置いた場所です。扉を押すと開きます。"
                                              : "おおよその位置に出しています。扉を押すと開きます。")
                Button("扉を開く") { model.openDoor() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        case .doorOpen:
            VStack(alignment: .leading, spacing: 10) {
                Title("扉が開きました")
                if let warning = model.mapWarning { Caption(warning) }
                Button("中へ") { model.goInside() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        case .createShoot(let index):
            createShoot(index)
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
                Caption("扉とそのまわりを、ゆっくり左右に見回してください。友達が来たとき、同じ位置に扉を出すために使います。")
                ProgressView(value: model.mappingProgress).tint(Theme.accent)
                Button("覚えた（保存する）") { model.saveGate() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.mappingReady)
            }
        case .createSaving(let text):
            HStack(spacing: 12) {
                ProgressView()
                Text(text).font(.subheadline).foregroundStyle(Theme.text)
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
