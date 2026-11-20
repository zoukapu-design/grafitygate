import ARKit
import RealityKit
import SwiftUI

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
            // 写真は画面の大きさの中に収める（scaledToFill をそのまま置くと、画面より大きくなって
            // 下の札まで横にはみ出し、前の写真がとても大きく写っていた＝2026-11-20 オーナー）
            if let shot {
                FullScreenPhoto(image: shot)
            } else if let refImage {
                FullScreenPhoto(image: refImage)
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
                Picker("見せる範囲", selection: $visibility) {
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
            message = "GATE が閉じました（離れたため）。現地でもう一度 GATE を開けてください。"
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

/// 画面いっぱいの写真（カメラの映像と同じく、縦横の比を保って画面をうめる。画面より大きくならない）
struct FullScreenPhoto: View {
    let image: UIImage

    var body: some View {
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
            .ignoresSafeArea()
    }
}
