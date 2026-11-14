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
            // 今日・この 1 週間・それより前に分ける
            ForEach(NotificationGroup.allCases) { group in
                let inGroup = items.filter { NotificationGroup.of($0.created_at) == group }
                if !inGroup.isEmpty {
                    Section(group.label) {
                        ForEach(inGroup) { item in
                            NavigationLink {
                                destination(item)
                            } label: {
                                NotificationRow(item: item)
                            }
                            .listRowBackground(item.unread ? Theme.accentLight.opacity(0.45) : Theme.surface)
                        }
                    }
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

/// お知らせの区切り
enum NotificationGroup: Int, CaseIterable, Identifiable {
    case today, week, older

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .today: return "今日"
        case .week: return "この 1 週間"
        case .older: return "それより前"
        }
    }

    static func of(_ text: String) -> NotificationGroup {
        guard let date = ServerDate.parse(text) else { return .older }
        if Calendar.current.isDateInToday(date) { return .today }
        return Date().timeIntervalSince(date) < 7 * 86400 ? .week : .older
    }
}

/// お知らせの 1 行：した人の顔に、何が起きたかの小さな印
private struct NotificationRow: View {
    let item: NotificationItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                NeonAvatar(name: item.actor_name, size: 40)
                Image(systemName: item.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(item.kind == "like" ? Theme.alert : Theme.accent, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text).font(.subheadline).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
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

/// 1 人とのメッセージ。開いているあいだ 8 秒ごとに新しいものを確かめる（送れるかどうかは 1 分ごと）。
struct ChatView: View {
    let other: UUID
    let name: String?

    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var inbox: InboxModel
    @State private var messages: [DMMessage] = []
    @State private var pending: [PendingMessage] = []
    @State private var otherName: String?
    @State private var canSend = true
    @State private var loaded = false
    @State private var draft = ""
    @State private var error: String?
    @State private var report: ReportItem?
    @State private var lastRelationCheck = Date.distantPast
    @FocusState private var typing: Bool

    init(other: UUID, name: String?) {
        self.other = other
        self.name = name
    }

    /// 送っている途中のメッセージ（サーバーに入るまで、うすく出す）
    struct PendingMessage: Identifiable, Equatable {
        let id = UUID()
        let body: String
        var failed = false
    }

    private var displayName: String { otherName ?? name ?? "友達" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if loaded && messages.isEmpty && pending.isEmpty {
                        emptyState
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let date = ServerDate.parse(message.created_at)
                        if startsNewDay(at: index), let date {
                            Text(ServerDate.dayHeading(date))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Theme.surfaceElevated, in: Capsule())
                                .padding(.top, index == 0 ? 4 : 18)
                                .padding(.bottom, 10)
                        }
                        bubble(message, index: index)
                            .id(message.id)
                    }
                    ForEach(pending) { item in
                        pendingBubble(item).id(item.id)
                    }
                    if !canSend && loaded {
                        Label("お互いにフォローしているときだけ送れます", systemImage: "lock")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                            .padding(.top, 16)
                    }
                    if let error { NoticeText(text: error).padding(.top, 12) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.last?.id) { old, _ in
                // 開いたときはすぐ下へ、そのあと届いたものはなめらかに
                if old == nil {
                    proxy.scrollTo("bottom", anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: pending.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: typing) { _, now in
                if now {
                    Task {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    ProfileView(userID: other)
                } label: {
                    PersonBadge(name: displayName, size: 30)
                }
                .accessibilityLabel("\(displayName) さんのプロフィール")
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .sheet(item: $report) { item in ReportSheet(item: item) }
        .task {
            await load(checkRelation: true)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled { break }
                await load(checkRelation: Date().timeIntervalSince(lastRelationCheck) > 60)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            PersonBadge(name: displayName, size: 64)
            Text(displayName).font(.headline).foregroundStyle(Theme.text)
            Text(canSend ? "最初のひとことを送ってみましょう。" : "お互いにフォローすると、メッセージを送れます。")
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(canSend ? "メッセージ" : "いまは送れません", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($typing)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.line))
                .disabled(!canSend)
            Button {
                send(draft)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.neonBand.opacity(canSendNow ? 1 : 0.3), in: Circle())
            }
            .disabled(!canSendNow)
            .accessibilityLabel("送る")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSendNow: Bool {
        canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startsNewDay(at index: Int) -> Bool {
        guard index > 0 else { return true }
        guard let a = ServerDate.parse(messages[index - 1].created_at),
              let b = ServerDate.parse(messages[index].created_at) else { return false }
        return !Calendar.current.isDate(a, inSameDayAs: b)
    }

    /// 同じ人が 5 分以内に続けて送ったものは 1 つのかたまりにして、時刻はかたまりの最後だけに出す
    private func closesRun(at index: Int) -> Bool {
        guard index + 1 < messages.count else { return true }
        let a = messages[index], b = messages[index + 1]
        guard a.sender == b.sender,
              let ta = ServerDate.parse(a.created_at), let tb = ServerDate.parse(b.created_at),
              Calendar.current.isDate(ta, inSameDayAs: tb) else { return true }
        return tb.timeIntervalSince(ta) > 300
    }

    private func bubble(_ message: DMMessage, index: Int) -> some View {
        let mine = message.sender == session.userID
        let last = closesRun(at: index)
        let date = ServerDate.parse(message.created_at)
        return HStack(alignment: .bottom, spacing: 6) {
            if mine { Spacer(minLength: 56) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                Text(message.body)
                    .font(.body)
                    .foregroundStyle(mine ? .white : Theme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(mine ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface),
                                in: bubbleShape(mine: mine, tail: last))
                    .overlay(bubbleShape(mine: mine, tail: last).stroke(mine ? Color.clear : Theme.line))
                    .textSelection(.enabled)
                if last, let date {
                    Text(ServerDate.clock(date) + (mine && message.read_at != nil ? "・既読" : ""))
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 4)
                }
            }
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.body
                } label: {
                    Label("コピー", systemImage: "doc.on.doc")
                }
                if mine {
                    Button(role: .destructive) {
                        Task { await delete(message) }
                    } label: {
                        Label("送信を取り消す", systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        report = ReportItem(id: message.id, target: .dm, userID: other,
                                            userName: displayName, label: "メッセージ")
                    } label: {
                        Label("通報する", systemImage: "exclamationmark.bubble")
                    }
                }
            }
            if !mine { Spacer(minLength: 56) }
        }
        .padding(.bottom, last ? 10 : 3)
    }

    private func pendingBubble(_ item: PendingMessage) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.body)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Theme.accent.opacity(item.failed ? 0.35 : 0.6), in: bubbleShape(mine: true, tail: true))
                if item.failed {
                    HStack(spacing: 12) {
                        Text("送れませんでした").foregroundStyle(Theme.alert)
                        Button("もう一度") {
                            pending.removeAll { $0.id == item.id }
                            send(item.body)
                        }
                        Button("消す") { pending.removeAll { $0.id == item.id } }
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(.caption2.weight(.semibold))
                } else {
                    Text("送っています…").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.bottom, 10)
    }

    /// かたまりの最後だけ、送った人の側の下の角を小さくする
    private func bubbleShape(mine: Bool, tail: Bool) -> UnevenRoundedRectangle {
        let big: CGFloat = 18, small: CGFloat = tail ? 5 : 18
        return UnevenRoundedRectangle(topLeadingRadius: big,
                                      bottomLeadingRadius: mine ? big : small,
                                      bottomTrailingRadius: mine ? small : big,
                                      topTrailingRadius: big,
                                      style: .continuous)
    }

    private func load(checkRelation: Bool) async {
        guard let api = session.api else { return }
        do {
            let latest = try await api.dmMessages(with: other)
            if latest != messages { messages = latest }
            if otherName == nil { otherName = try? await api.profiles([other]).first?.display_name }
            if checkRelation, let me = session.userID, let r = try? await api.relations(me: me) {
                canSend = r.following.contains(other) && r.followers.contains(other)
                lastRelationCheck = Date()
            }
            error = nil
            if latest.contains(where: { $0.sender == other && $0.read_at == nil }) || !loaded {
                await inbox.refresh(session: session)
            }
        } catch {
            if !loaded { self.error = ErrorText.of(error) }
        }
        loaded = true
    }

    private func send(_ raw: String) {
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
        guard !text.isEmpty, let api = session.api else { return }
        let item = PendingMessage(body: text)
        pending.append(item)
        if raw == draft { draft = "" }
        Task {
            do {
                _ = try await api.sendDM(to: other, body: text)
                let latest = try? await api.dmMessages(with: other)
                pending.removeAll { $0.id == item.id }
                if let latest { messages = latest }
            } catch {
                if let i = pending.firstIndex(where: { $0.id == item.id }) { pending[i].failed = true }
                Trace.log("メッセージ：送れなかった \(ErrorText.of(error))")
            }
        }
    }

    private func delete(_ message: DMMessage) async {
        guard let api = session.api else { return }
        do {
            try await api.deleteDM(message.id)
            messages.removeAll { $0.id == message.id }
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}
