import SwiftUI
import UIKit

@main
struct GrafityGateApp: App {
    @StateObject private var session = SessionModel()
    @StateObject private var location = LocationModel()
    @StateObject private var nav = AppNavigator()
    @AppStorage("gg.onboarded") private var onboarded = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                if onboarded {
                    RootView()
                        .transition(.opacity)
                } else {
                    OnboardingView {
                        withAnimation(.easeInOut(duration: 0.35)) { onboarded = true }
                        location.start()
                        Task { await session.applyPendingName() }
                    }
                    .transition(.opacity)
                }
            }
            .environmentObject(session)
            .environmentObject(location)
            .environmentObject(nav)
            // 友達の QR を iPhone のカメラで読んだときなど（grafitygate://friend/<ID>）
            .onOpenURL { nav.open($0) }
            .task {
                MainWatch.shared.start()
                let info = Bundle.main.infoDictionary
                Trace.log("アプリを開く（\(info?["CFBundleShortVersionString"] as? String ?? "")・\(info?["CFBundleVersion"] as? String ?? "")・iOS \(UIDevice.current.systemVersion)・メモリの少ない端末：\(Perf.isLowMemoryDevice)）")
                // 位置情報の許可は、はじめの案内で理由を説明してから求める
                if onboarded { location.start() }
                await session.start()
            }
        }
    }
}
