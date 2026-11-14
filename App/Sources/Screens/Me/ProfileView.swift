import SwiftUI

/// ほかの人のプロフィール：名前・フォロー・（友達なら）その人が見せると選んだ図鑑。通報・ブロックもここから。
struct ProfileView: View {
    let userID: UUID

    @EnvironmentObject private var session: SessionModel
    @State private var profile: ProfileRow?
    @State private var following = false
    @State private var followsMe = false
    @State private var blocked = false
    @State private var atlas: [FriendAtlasGate] = []
    @State private var message: (text: String, isError: Bool)?
    @State private var report: ReportItem?
    @State private var busy = false
    @State private var confirmBlock = false
    @State private var confirmUnfollow = false
    @State private var loaded = false

    init(userID: UUID) {
        self.userID = userID
    }

    private var isMe: Bool { userID == session.userID }
    private var isFriend: Bool { following && followsMe }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let profile {
                    // 「わたし」と同じ形のプロフィール（数は、友達が見せている図鑑の数だけ）
                    HStack(spacing: 16) {
                        NeonAvatar(name: profile.display_name, size: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.display_name).font(.title2.weight(.bold)).foregroundStyle(Theme.text).lineLimit(1)
                            Text("ID：\(profile.handle)").font(.subheadline).foregroundStyle(Theme.textSecondary)
                            if !isMe {
                                Label(relationText, systemImage: isFriend ? "person.2.fill" : "person")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(isFriend ? Theme.accent : Theme.textSecondary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(isFriend ? Theme.accentLight : Theme.surfaceElevated, in: Capsule())
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    if !isMe && !blocked {
                        Button {
                            // 友達をやめるのは、ひと呼吸おいてから（友達向けの GATE が見えなくなる）
                            if following && isFriend {
                                confirmUnfollow = true
                            } else {
                                Task { await toggleFollow() }
                            }
                        } label: {
                            Label(following ? "フォローをやめる" : (followsMe ? "フォローを返す（友達になる）" : "フォローする"),
                                  systemImage: following ? "person.badge.minus" : "person.badge.plus")
                        }
                        .buttonStyle(following ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
                        .disabled(busy)
                    }
                    if isFriend && !blocked {
                        NavigationLink {
                            ChatView(other: userID, name: profile.display_name)
                        } label: {
                            Label("メッセージを送る", systemImage: "bubble.left")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    if blocked {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("ブロックしています").font(.headline).foregroundStyle(Theme.text)
                                Text("おたがいの GATE・記録・手紙は見えません。").font(.subheadline).foregroundStyle(Theme.textSecondary)
                                Button("ブロックをやめる") { Task { await unblock() } }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                    if let message { NoticeText(text: message.text, isError: message.isError) }
                    if isFriend && !blocked {
                        Text("\(profile.display_name) さんの図鑑").font(.headline).foregroundStyle(Theme.text)
                        if atlas.isEmpty {
                            Text("見せている GATE はまだありません。").font(.subheadline).foregroundStyle(Theme.textSecondary)
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(atlas) { gate in
                                NavigationLink {
                                    GateDetailView(gateID: gate.gate_id)
                                } label: {
                                    MemoryTile(title: gate.title, subtitle: "\(gate.visits) 回・\(ServerDate.relative(gate.first_at))",
                                               cover: gate.cover_path)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else if !isMe && !blocked {
                        Text("お互いにフォローすると「友達」になり、友達向けの GATE や、その人が見せると選んだ図鑑が見えるようになります。")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                } else if loaded {
                    VStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.system(size: 40)).foregroundStyle(Theme.textSecondary)
                        Text(message?.text ?? "この人は見つかりませんでした。アカウントが消されたのかもしれません。")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                        Button("もう一度読み込む") { Task { await load() } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(profile?.display_name ?? "プロフィール")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isMe, let profile {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            report = ReportItem(id: profile.id, target: .user, userID: profile.id,
                                                userName: profile.display_name, label: profile.display_name)
                        } label: {
                            Label("通報する", systemImage: "exclamationmark.bubble")
                        }
                        if !blocked {
                            Button(role: .destructive) {
                                confirmBlock = true
                            } label: {
                                Label("ブロックする", systemImage: "hand.raised")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog("\(profile?.display_name ?? "この人") さんのフォローをやめますか？", isPresented: $confirmUnfollow,
                            titleVisibility: .visible) {
            Button("フォローをやめる", role: .destructive) { Task { await toggleFollow() } }
        } message: {
            Text("友達ではなくなり、友達向けの GATE や図鑑、メッセージが使えなくなります。")
        }
        .confirmationDialog("\(profile?.display_name ?? "この人") さんをブロックしますか？", isPresented: $confirmBlock,
                            titleVisibility: .visible) {
            Button("ブロックする", role: .destructive) { Task { await block() } }
        } message: {
            Text("おたがいの GATE・記録・手紙が見えなくなります。相手には知らせません。")
        }
        .sheet(item: $report, onDismiss: { Task { await load() } }) { item in ReportSheet(item: item) }
        .task { await load() }
        .refreshable { await load() }
    }

    private var relationText: String {
        if isFriend { return "友達（お互いにフォロー）" }
        if following { return "フォロー中" }
        if followsMe { return "あなたをフォローしています" }
        return "まだつながっていません"
    }

    private func load() async {
        guard let api = session.api, let me = session.userID else { return }
        do {
            profile = try await api.profiles([userID]).first
            let r = try await api.relations(me: me)
            following = r.following.contains(userID)
            followsMe = r.followers.contains(userID)
            blocked = (try? await api.blocks())?.contains { $0.user_id == userID } ?? false
            atlas = (isFriend && !blocked) ? ((try? await api.friendAtlas(userID)) ?? []) : []
        } catch {
            message = (ErrorText.of(error), true)
        }
        loaded = true
    }

    private func toggleFollow() async {
        guard let api = session.api, let me = session.userID else { return }
        busy = true
        defer { busy = false }
        do {
            if following {
                try await api.unfollow(userID, me: me)
            } else {
                try await api.follow(userID, me: me)
                Haptics.success()
            }
            await load()
        } catch {
            message = (ErrorText.of(error), true)
        }
    }

    private func block() async {
        guard let api = session.api else { return }
        do {
            try await api.block(userID)
            message = ("ブロックしました。", false)
            await load()
        } catch {
            message = (ErrorText.of(error), true)
        }
    }

    private func unblock() async {
        guard let api = session.api else { return }
        do {
            try await api.unblock(userID)
            message = ("ブロックをやめました。", false)
            await load()
        } catch {
            message = (ErrorText.of(error), true)
        }
    }
}

/// ボタンの見た目を、条件で入れ替えるための入れ物
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
