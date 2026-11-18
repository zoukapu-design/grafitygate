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

/// カードを作る画面の「AR カメラで撮る」（いちばん目立つ入口。夜空の札に、できることを並べる）
struct ARCameraCallout: View {
    let hasPhoto: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(AngularGradient(colors: [Color(hex: 0xFF9A3D), Color(hex: 0xFF3D7F), Color(hex: 0x9B5CFF),
                                                               Color(hex: 0x3DC8FF), Color(hex: 0xFF9A3D)],
                                                      center: .center), lineWidth: 3)
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hasPhoto ? "AR カメラで撮り直す" : "AR カメラで撮る")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.white)
                    Text("扉・みんなの AR・キラキラや文字と一緒に")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ForEach(["door.left.hand.open", "person.2.wave.2.fill", "sparkles", "textformat", "heart.fill"], id: \.self) { s in
                            Image(systemName: s)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(14)
            .background(
                LinearGradient(colors: [Color(hex: 0x2A1650), Color(hex: 0x1B1235)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.neonBand, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasPhoto ? "AR カメラで撮り直す" : "AR カメラで撮る")
    }
}
