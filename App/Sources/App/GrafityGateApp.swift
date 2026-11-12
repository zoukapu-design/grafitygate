import SwiftUI
import UIKit

@main
struct GrafityGateApp: App {
    @StateObject private var session = SessionModel()
    @StateObject private var location = LocationModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(location)
                .task {
                    MainWatch.shared.start()
                    let info = Bundle.main.infoDictionary
                    Trace.log("アプリを開く（\(info?["CFBundleShortVersionString"] as? String ?? "")・\(info?["CFBundleVersion"] as? String ?? "")・iOS \(UIDevice.current.systemVersion)・メモリの少ない端末：\(Perf.isLowMemoryDevice)）")
                    location.start()
                    await session.start()
                }
        }
    }
}
