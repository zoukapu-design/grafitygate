import Foundation
import SwiftUI

/// まだ見ていないお知らせとメッセージの数（ホームのタブの印・ベルの印）。開いているあいだ 1 分ごとに確かめる。
@MainActor
final class InboxModel: ObservableObject {
    @Published private(set) var notifications = 0
    @Published private(set) var messages = 0

    var total: Int { notifications + messages }

    private var loop: Task<Void, Never>?

    func start(session: SessionModel) {
        guard loop == nil else { return }
        loop = Task { [weak self, weak session] in
            while !Task.isCancelled {
                if let session, let self { await self.refresh(session: session) }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    func refresh(session: SessionModel) async {
        guard session.state == .signedIn, let api = session.api,
              let counts = try? await api.unreadCounts() else { return }
        notifications = counts.notifications
        messages = counts.messages
    }

    func clearNotifications() {
        notifications = 0
    }
}
