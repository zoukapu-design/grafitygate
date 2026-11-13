import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI
import VisionKit

/// 友達を足す 3 つの入口：QR を見せる・QR を読む・ID を送る
struct AddFriendButtons: View {
    @EnvironmentObject private var session: SessionModel
    @State private var showingQR = false
    @State private var scanning = false

    var body: some View {
        HStack(spacing: 10) {
            tile("QR を見せる", systemImage: "qrcode") { showingQR = true }
            tile("QR を読む", systemImage: "qrcode.viewfinder") { scanning = true }
            if let handle = session.profile?.handle {
                ShareLink(item: FriendShare.text(handle: handle, name: session.profile?.display_name ?? "")) {
                    tileLabel("ID を送る", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(isPresented: $showingQR) { MyQRSheet() }
        .sheet(isPresented: $scanning) { FriendScannerSheet() }
    }

    private func tile(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { tileLabel(title, systemImage: systemImage) }
            .buttonStyle(.plain)
    }

    private func tileLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, minHeight: 84)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }
}

enum FriendShare {
    /// ID を送るときの文（リンクは、受け取った人の iPhone に Grafity Gate が入っていれば開ける）
    static func text(handle: String, name: String) -> String {
        let who = name.isEmpty || name == "ゲスト" ? "" : "（\(name)）"
        return "Grafity Gate で友達になろう\(who)\nID：\(handle)\n「わたし」→「友達・フォロー」→「ID で探す」に入れてね\n\(AppNavigator.friendURL(handle: handle).absoluteString)"
    }

    /// QR コードの絵（くっきり大きく）
    static func qrImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"    // 真ん中にしるしを重ねても読めるように
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// 自分の QR：友達が「QR を読む」か iPhone のカメラで読むと、自分の画面が開いてフォローできる
struct MyQRSheet: View {
    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer(minLength: 0)
                if let profile = session.profile {
                    VStack(spacing: 6) {
                        Text(profile.display_name).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                        Text("ID：\(profile.handle)").font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    if let image = FriendShare.qrImage(AppNavigator.friendURL(handle: profile.handle).absoluteString) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 240, height: 240)
                            .padding(18)
                            .background(.white, in: RoundedRectangle(cornerRadius: 24))
                            .overlay(alignment: .center) {
                                GateMark(size: 46, glowing: false)
                            }
                            .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
                            .accessibilityLabel("自分の QR コード")
                    }
                    Text("友達に、Grafity Gate の「QR を読む」か、iPhone のカメラで読んでもらってください。お互いにフォローすると友達になります。")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    HStack(spacing: 10) {
                        Button(copied ? "コピーしました" : "ID をコピー") {
                            UIPasteboard.general.string = profile.handle
                            copied = true
                            Haptics.tap()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        ShareLink(item: FriendShare.text(handle: profile.handle, name: profile.display_name)) {
                            Text("ID を送る")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(.horizontal, 24)
                } else {
                    ProgressView()
                    Text("サーバーにつないでいます…").font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("わたしの QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}

/// 友達の QR を読む（読めたら、その人の画面を開く）
struct FriendScannerSheet: View {
    @EnvironmentObject private var nav: AppNavigator
    @Environment(\.dismiss) private var dismiss
    @State private var notice: String?
    @State private var typed = ""
    /// カメラの許可を聞き終えたか（はじめての人には、ここで許可を聞く）
    @State private var checked = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !checked {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScannerView { text in
                        guard AppNavigator.handle(from: text) != nil else {
                            notice = "Grafity Gate の友達の QR ではないようです。"
                            return
                        }
                        Haptics.success()
                        openAfterClosing(text)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text(notice ?? "友達の「わたしの QR」を、枠の中に入れてください。")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 28)
                    }
                } else {
                    // カメラが使えないとき：ID を打つ
                    VStack(alignment: .leading, spacing: 12) {
                        NoticeText(text: "この iPhone では QR を読めません（カメラの許可がないか、対応していない機種です）。友達の ID を入れてください。")
                        TextField("友達の ID", text: $typed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        Button("探す") {
                            if AppNavigator.handle(from: typed) != nil {
                                openAfterClosing(typed)
                            } else {
                                notice = "ID は英小文字・数字・_ の 3〜20 文字です。"
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        if let notice { NoticeText(text: notice) }
                        Spacer()
                    }
                    .padding(20)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("QR を読む")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                }
                checked = true
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
            }
        }
    }
}

extension FriendScannerSheet {
    /// 閉じてから友達の画面を開く（シートの上にシートを重ねない）
    func openAfterClosing(_ text: String) {
        dismiss()
        let nav = nav
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            nav.openFriend(text: text)
        }
    }
}

/// VisionKit の読み取り（QR だけ）。同じものを続けて何度も知らせない。
private struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        private var last: String?

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let code) = item, let text = code.payloadStringValue, text != last else { continue }
                last = text
                onFound(text)
                return
            }
        }
    }
}

/// QR・リンクで届いた友達：ID からその人を探して、フォローできる画面を出す
struct FriendInviteSheet: View {
    let handle: String

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var found: ProfileRow?
    @State private var message: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            Group {
                if let found, found.id != session.userID {
                    ProfileView(userID: found.id)
                } else {
                    VStack(spacing: 14) {
                        if loading {
                            ProgressView()
                            Text("ID：\(handle) の人を探しています…").font(.subheadline).foregroundStyle(Theme.textSecondary)
                        } else if let message {
                            NoticeText(text: message)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background.ignoresSafeArea())
                }
            }
            .navigationTitle("友達")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
        }
        .task(id: session.state) { await look() }
    }

    private func look() async {
        guard let api = session.api, session.state == .signedIn else {
            message = session.problem
            loading = session.state == .starting
            return
        }
        loading = true
        defer { loading = false }
        do {
            found = try await api.findProfile(handle: handle)
            if found == nil {
                message = "ID「\(handle)」の人は見つかりませんでした。"
            } else if found?.id == session.userID {
                message = "これは、あなた自身の QR です。"
            }
            Trace.log("友達の招待：\(found == nil ? "見つからない" : "見つかった")")
        } catch {
            message = ErrorText.of(error)
        }
    }
}
