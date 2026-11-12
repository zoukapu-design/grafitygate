import SwiftUI

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
                    location.start()
                    await session.start()
                }
        }
    }
}
