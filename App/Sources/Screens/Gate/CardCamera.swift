import SwiftUI

/// グラフィティカードの写真を、その場で撮る（カメラだけ。写真アプリからは選ばない＝その場の 1 枚）。
/// 撮った写真は、iPhone の持ち方どおりにまっすぐ立てる（`ARStage.grabPhoto`）。
struct CardCameraView: View {
    let onShot: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var stage = ARStage()
    @State private var shot: UIImage?
    @State private var message: String?
    @State private var flash = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ARViewContainer(arView: stage.arView)
                .ignoresSafeArea()
                .opacity(shot == nil ? 1 : 0)
            if let shot {
                Image(uiImage: shot).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
            Color.white.opacity(flash ? 0.8 : 0).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 14) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .accessibilityLabel("閉じる")
                    Spacer()
                }
                Spacer()
                if let message {
                    Text(message)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
                if shot == nil {
                    Text("カードにする景色を写してください")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                    Button {
                        Task { await capture() }
                    } label: {
                        Circle()
                            .strokeBorder(.white, lineWidth: 5)
                            .frame(width: 78, height: 78)
                            .overlay(Circle().fill(.white).padding(10))
                    }
                    .accessibilityLabel("撮る")
                } else {
                    HStack(spacing: 12) {
                        Button("撮り直す") { shot = nil }
                            .buttonStyle(SecondaryButtonStyle())
                        Button("この写真を使う") {
                            if let shot { onShot(shot) }
                            dismiss()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .onAppear {
            stage.run(reset: true)
            Trace.log("カード：その場で撮るカメラを開く")
        }
        .onDisappear { stage.pause() }
    }

    private func capture() async {
        guard let image = await stage.grabPhoto() else {
            message = "カメラの準備ができていません。少し待ってからお試しください。"
            return
        }
        message = nil
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        try? await Task.sleep(nanoseconds: 120_000_000)
        withAnimation(.easeIn(duration: 0.25)) { flash = false }
        shot = image
        Haptics.success()
    }
}
