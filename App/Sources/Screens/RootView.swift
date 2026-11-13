import SwiftUI

/// GATE の画面へ進むための印（どのタブからでも同じ画面を開く）
struct GateRoute: Hashable, Identifiable {
    let id: UUID
}

/// 下のタブは 4 つ：ホーム／地図／撮る／わたし（設計書「画面の構成」）
struct RootView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var nav: AppNavigator
    @StateObject private var inbox = InboxModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $nav.tab) {
            HomeView()
                .tabItem { Label("ホーム", systemImage: "house") }
                .badge(inbox.total)
                .tag(AppNavigator.Tab.home)
            NearbyMapView()
                .tabItem { Label("地図", systemImage: "map") }
                .tag(AppNavigator.Tab.map)
            CaptureView()
                .tabItem { Label("撮る", systemImage: "camera.viewfinder") }
                .tag(AppNavigator.Tab.capture)
            MeView()
                .tabItem { Label("わたし", systemImage: "person.crop.circle") }
                .tag(AppNavigator.Tab.me)
        }
        .tint(Theme.accent)
        .environmentObject(inbox)
        .sheet(item: $nav.friendInvite) { invite in
            FriendInviteSheet(handle: invite.handle)
        }
        .task(id: session.state) {
            if session.state == .signedIn { inbox.start(session: session) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: if session.state == .signedIn { inbox.start(session: session) }
            case .background: inbox.stop()
            default: break
            }
        }
        .safeAreaInset(edge: .top) {
            if let problem = session.problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accentLight)
            }
        }
    }
}

/// どの画面でも同じ背景と見出し
struct ScreenScaffold<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(title)
            .navigationDestination(for: GateRoute.self) { route in
                GateDetailView(gateID: route.id)
            }
    }
}

/// 中身がないときの説明
struct EmptyNote: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .foregroundStyle(Theme.textSecondary)
    }
}
