import SwiftUI

/// 撮る：AR のカメラ。目の前の場所・物に向けて、近くの GATE を開く／新しく GATE を作る。
/// AR（カメラと 3D の仕組み）は、はじめて「撮る」を開いたときに作る。
/// 下のタブはアプリを開いたときに全部の画面を用意するので、ここで作ると、ホームを見ているだけでも
/// AR の仕組みが動き出してメモリを使っていた（2026-11-16 に画面の見本で分かった）。
struct CaptureView: View {
    @EnvironmentObject private var nav: AppNavigator
    @State private var opened = false

    var body: some View {
        Group {
            if opened {
                ARExperienceView(mode: .explore)
            } else {
                placeholder
            }
        }
        .onAppear { openIfShown(nav.tab) }
        .onChange(of: nav.tab) { _, tab in openIfShown(tab) }
    }

    private func openIfShown(_ tab: AppNavigator.Tab) {
        guard tab == .capture, !opened else { return }
        #if DEBUG
        // 画面の見本（シミュレーター）では AR を作れない
        if DemoMode.screen != nil { return }
        #endif
        Trace.log("撮る：AR を用意する")
        opened = true
    }

    private var placeholder: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ProgressView().tint(.white)
        }
    }
}
