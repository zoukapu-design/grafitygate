import SwiftUI
import UIKit

@main
struct GrafityGateApp: App {
    @StateObject private var session = SessionModel()
    @StateObject private var location = LocationModel()
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
                    }
                    .transition(.opacity)
                }
            }
            .environmentObject(session)
            .environmentObject(location)
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
