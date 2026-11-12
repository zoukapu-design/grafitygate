import SwiftUI

/// お知らせ：自分の GATE に残されたもの・返信・手紙・思い出・いいね・フォロー。現地だけの中身は出さない。
struct NotificationsView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var inbox: InboxModel
    @State private var items: [NotificationItem] = []
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                NoticeText(text: error)
            }
            if loaded && items.isEmpty && error == nil {
                Text("まだお知らせはありません。あなたの GATE に記憶が残されたり、手紙が届いたりすると、ここに出ます。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            ForEach(items) { item in
                NavigationLink {
                    destination(item)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(item.kind == "like" ? Theme.alert : Theme.accent)
                            .frame(width: 34, height: 34)
                            .background(Theme.surfaceElevated, in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.text).font(.subheadline).foregroundStyle(Theme.text)
                            Text(ServerDate.relative(item.created_at)).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        if item.unread {
                            Circle().fill(Theme.accent).frame(width: 8, height: 8).padding(.top, 6)
                                .accessibilityLabel("新しい")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("お知らせ")
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder private func destination(_ item: NotificationItem) -> some View {
        if let gate = item.gate_id {
            GateDetailView(gateID: gate, tab: item.gateTab)
        } else {
            ProfileView(userID: item.actor)
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            items = try await api.notifications()
            error = nil
            try? await api.markNotificationsSeen()
            inbox.clearNotifications()
        } catch {
            self.error = ErrorText.of(error)
        }
        loaded = true
    }
}

/// メッセージ：お互いにフォローしている友達との DM の一覧
struct MessagesView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var inbox: InboxModel
    @State private var threads: [DMThread] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var picking = false
    @State private var picked: Set<UUID> = []
    @State private var openWith: DMThreadRoute?

    var body: some View {
        List {
            if let error { NoticeText(text: error) }
            if loaded && threads.isEmpty && error == nil {
                Text("まだメッセージはありません。右上から、お互いにフォローしている友達に送れます。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            ForEach(threads) { thread in
                NavigationLink {
                    ChatView(other: thread.other, name: thread.other_name)
                } label: {
                    HStack(spacing: 12) {
                        PersonBadge(name: thread.other_name, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(thread.other_name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                Spacer()
                                Text(ServerDate.relative(thread.last_at)).font(.caption2).foregroundStyle(Theme.textSecondary)
                            }
                            Text((thread.last_from_me ? "あなた：" : "") + thread.last_body)
                                .font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        if thread.unread > 0 {
                            Text("\(thread.unread)")
                                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Theme.accent, in: Capsule())
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("メッセージ")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    picked = []
                    picking = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("新しいメッセージ")
            }
        }
        .sheet(isPresented: $picking, onDismiss: {
            if let id = picked.first { openWith = DMThreadRoute(id: id) }
        }) {
            NavigationStack {
                FriendPicker(title: "送る相手", multiple: false, selection: $picked)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("決める") { picking = false }.bold().disabled(picked.isEmpty)
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button("やめる") {
                                picked = []
                                picking = false
                            }
                        }
                    }
            }
        }
        .navigationDestination(item: $openWith) { route in
            ChatView(other: route.id, name: threads.first { $0.other == route.id }?.other_name)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            threads = try await api.dmThreads()
            error = nil
            await inbox.refresh(session: session)
        } catch {
            self.error = ErrorText.of(error)
        }
        loaded = true
    }
}

struct DMThreadRoute: Hashable, Identifiable {
    let id: UUID
}

/// 1 人とのメッセージ。開いているあいだ 8 秒ごとに新しいものを確かめる。
struct ChatView: View {
    let other: UUID
    let name: String?

    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var inbox: InboxModel
    @State private var messages: [DMMessage] = []
    @State private var otherName: String?
    @State private var canSend = true
    @State private var draft = ""
    @State private var sending = false
    @State private var error: String?
    @State private var report: ReportItem?

    init(other: UUID, name: String?) {
        self.other = other
        self.name = name
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if !canSend {
                        Text("お互いにフォローしているときだけ送れます。")
                            .font(.caption).foregroundStyle(Theme.textSecondary).padding(.top, 8)
                    }
                    ForEach(messages) { message in
                        bubble(message)
                            .id(message.id)
                    }
                    if let error { NoticeText(text: error) }
                }
                .padding(16)
            }
            .onChange(of: messages.last?.id) { _, last in
                if let last { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(otherName ?? name ?? "メッセージ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ProfileView(userID: other)
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityLabel("プロフィール")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                TextField(canSend ? "メッセージ" : "送れません", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(10)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 18))
                    .disabled(!canSend)
                Button {
                    Task { await send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Theme.accent.opacity(canSendNow ? 1 : 0.35), in: Circle())
                }
                .disabled(!canSendNow)
                .accessibilityLabel("送る")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .sheet(item: $report) { item in ReportSheet(item: item) }
        .task {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { break }
                await load()
            }
        }
    }

    private var canSendNow: Bool {
        canSend && !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func bubble(_ message: DMMessage) -> some View {
        let mine = message.sender == session.userID
        return HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
                Text(message.body)
                    .font(.body)
                    .foregroundStyle(mine ? .white : Theme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(mine ? Theme.accent : Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(mine ? Color.clear : Theme.line))
                    .textSelection(.enabled)
                Text(ServerDate.relative(message.created_at) + (mine && message.read_at != nil ? "・既読" : ""))
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            .contextMenu {
                if mine {
                    Button("送信を取り消す", role: .destructive) { Task { await delete(message) } }
                } else {
                    Button {
                        report = ReportItem(id: message.id, target: .dm, userID: other,
                                            userName: otherName ?? name, label: "メッセージ")
                    } label: {
                        Label("通報する", systemImage: "exclamationmark.bubble")
                    }
                }
            }
            if !mine { Spacer(minLength: 48) }
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            let latest = try await api.dmMessages(with: other)
            if latest != messages { messages = latest }
            if otherName == nil { otherName = try? await api.profiles([other]).first?.display_name }
            if let me = session.userID, let r = try? await api.relations(me: me) {
                canSend = r.following.contains(other) && r.followers.contains(other)
            }
            error = nil
            await inbox.refresh(session: session)
        } catch {
            self.error = ErrorText.of(error)
        }
    }

    private func send() async {
        guard let api = session.api else { return }
        let text = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        sending = true
        defer { sending = false }
        do {
            _ = try await api.sendDM(to: other, body: text)
            draft = ""
            await load()
        } catch {
            self.error = ErrorText.of(error)
        }
    }

    private func delete(_ message: DMMessage) async {
        guard let api = session.api else { return }
        do {
            try await api.deleteDM(message.id)
            await load()
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}
