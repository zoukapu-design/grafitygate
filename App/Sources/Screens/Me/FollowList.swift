import SwiftUI

/// 友達・フォロワー・フォロー中の一覧（2026-11-20 オーナー「わたしの画面でフォローとフォロワーを見たい。その人のページに行きたい」）。
/// わたしの数を押すと開く。1 人ずつ押すと、その人のプロフィールへ。フォロワーには「フォローを返す」をその場で。
struct FollowListView: View {
    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case friends, followers, following
        var id: String { rawValue }
        var label: String {
            switch self {
            case .friends: return "友達"
            case .followers: return "フォロワー"
            case .following: return "フォロー中"
            }
        }
    }

    @EnvironmentObject private var session: SessionModel
    @State private var tab: Tab
    @State private var following: Set<UUID> = []
    @State private var followers: Set<UUID> = []
    @State private var people: [UUID: ProfileRow] = [:]
    @State private var loaded = false
    @State private var busy: UUID?
    @State private var message: String?

    init(initial: Tab) {
        _tab = State(initialValue: initial)
    }

    private var friends: Set<UUID> { following.intersection(followers) }

    private func ids(_ t: Tab) -> Set<UUID> {
        switch t {
        case .friends: return friends
        case .followers: return followers
        case .following: return following
        }
    }

    private var rows: [ProfileRow] {
        ids(tab).compactMap { people[$0] }.sorted { $0.display_name < $1.display_name }
    }

    var body: some View {
        VStack(spacing: 0) {
            UnderlineTabs(items: Tab.allCases, selection: $tab) { t in
                "\(t.label) \(loaded ? String(ids(t).count) : "")"
            }
            .padding(.horizontal, 16)
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let message { NoticeText(text: message) }
                    if loaded && rows.isEmpty {
                        emptyNote
                    }
                    ForEach(rows, id: \.id) { person in
                        row(person)
                    }
                }
                .padding(16)
            }
            .refreshable { await load() }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("つながり")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var emptyNote: some View {
        VStack(spacing: 12) {
            Image(systemName: tab == .followers ? "person.crop.circle.badge.plus" : "person.2")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(tab == .friends ? "まだ友達はいません" : (tab == .followers ? "まだフォロワーはいません" : "まだだれもフォローしていません"))
                .font(.headline)
                .foregroundStyle(Theme.text)
            AddFriendButtons(compact: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func row(_ p: ProfileRow) -> some View {
        let isFriend = friends.contains(p.id)
        let iFollow = following.contains(p.id)
        return HStack(spacing: 12) {
            NavigationLink {
                ProfileView(userID: p.id)
            } label: {
                HStack(spacing: 12) {
                    NeonAvatar(name: p.display_name, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(p.display_name)
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text("@\(p.handle)")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isFriend {
                Label("友達", systemImage: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Theme.accentLight, in: Capsule())
            } else if !iFollow {
                Button {
                    Task { await follow(p.id) }
                } label: {
                    Text(followers.contains(p.id) ? "フォローを返す" : "フォローする")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(busy == p.id)
            } else {
                Text("フォロー中")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Theme.surfaceElevated, in: Capsule())
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
    }

    private func load() async {
        guard let api = session.api, let me = session.userID else { return }
        do {
            let r = try await api.relations(me: me)
            following = r.following
            followers = r.followers
            let all = Array(r.following.union(r.followers))
            let list = try await api.profiles(all)
            people = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            message = nil
        } catch {
            message = ErrorText.of(error)
        }
        loaded = true
        Trace.log("つながり：友達 \(friends.count)・フォロワー \(followers.count)・フォロー中 \(following.count)")
    }

    private func follow(_ id: UUID) async {
        guard let api = session.api, let me = session.userID else { return }
        busy = id
        defer { busy = nil }
        do {
            try await api.follow(id, me: me)
            Haptics.success()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { following.insert(id) }
        } catch {
            message = ErrorText.of(error)
        }
    }
}
