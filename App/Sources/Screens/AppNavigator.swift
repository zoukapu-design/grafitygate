import SwiftUI

/// アプリのどこからでも、タブを切り替えたり、友達の招待（QR・リンク）を開いたりするための入れ物
@MainActor
final class AppNavigator: ObservableObject {
    enum Tab: Hashable {
        case home, map, capture, me
    }

    /// QR・リンクで届いた友達の ID
    struct FriendInvite: Identifiable, Equatable {
        let id = UUID()
        let handle: String
    }

    @Published var tab: Tab = .home
    @Published var friendInvite: FriendInvite?
    /// リンクで届いた GATE（見てよいかはサーバーが決める）
    @Published var gateLink: GateRoute?

    /// アプリを開くリンクの頭（`grafitygate://friend/<ID>`）
    nonisolated static let scheme = "grafitygate"

    /// 友達になってもらうためのリンク（QR の中身にも使う）
    nonisolated static func friendURL(handle: String) -> URL {
        URL(string: "\(scheme)://friend/\(handle)") ?? URL(string: "\(scheme)://")!
    }

    /// GATE を友達に送るリンク
    nonisolated static func gateURL(_ id: UUID) -> URL {
        URL(string: "\(scheme)://gate/\(id.uuidString.lowercased())") ?? URL(string: "\(scheme)://")!
    }

    /// GATE を送るときの文（現地でしか中は見られないことも書く）
    nonisolated static func gateShareText(title: String, id: UUID) -> String {
        "Grafity Gate の「\(title)」\n現地で扉を開けると、中の記憶が見られます。\n\(gateURL(id).absoluteString)"
    }

    /// QR・リンク・打った文字から、友達の ID を取り出す（ID の形でなければ nil）
    nonisolated static func handle(from text: String) -> String? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: raw), url.scheme?.lowercased() == scheme, url.host?.lowercased() == "friend" {
            raw = url.pathComponents.filter { $0 != "/" }.first ?? ""
        }
        raw = raw.trimmingCharacters(in: CharacterSet(charactersIn: "@")).lowercased()
        // ID は英小文字・数字・_ の 3〜20 文字（Lyric Path と共通の profiles の決まり）
        let allowed: (Character) -> Bool = { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
        guard (3...20).contains(raw.count), raw.allSatisfy(allowed) else { return nil }
        return raw
    }

    /// アプリを開いたリンク（QR を iPhone のカメラで読んだときなど）
    func open(_ url: URL) {
        if url.scheme?.lowercased() == Self.scheme, url.host?.lowercased() == "gate",
           let raw = url.pathComponents.filter({ $0 != "/" }).first, let id = UUID(uuidString: raw) {
            Trace.log("GATE のリンクで開きました")
            friendInvite = nil
            gateLink = GateRoute(id: id)
            return
        }
        guard let handle = Self.handle(from: url.absoluteString) else {
            Trace.log("知らないリンクで開きました（\(url.scheme ?? "")://\(url.host ?? "")）")
            return
        }
        Trace.log("友達のリンクで開きました")
        friendInvite = FriendInvite(handle: handle)
    }

    /// 読んだ QR・打った ID から、友達の画面を開く
    @discardableResult
    func openFriend(text: String) -> Bool {
        guard let handle = Self.handle(from: text) else { return false }
        friendInvite = FriendInvite(handle: handle)
        return true
    }
}
