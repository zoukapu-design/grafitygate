import SwiftUI

/// 掲示板：GATE ごとの話題（思い出話・質問・お知らせ）と返信。読む・書くのは現地で扉を開けているあいだ。
struct BoardSection: View {
    let context: GateContext
    let refreshToken: Int

    @EnvironmentObject private var session: SessionModel
    @State private var threads: [BoardThread] = []
    @State private var query = ""
    @State private var error: String?
    @State private var showNew = false

    init(context: GateContext, refreshToken: Int) {
        self.context = context
        self.refreshToken = refreshToken
    }

    private var filtered: [BoardThread] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return threads }
        return threads.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.body.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if context.isInside {
                Button {
                    showNew = true
                } label: {
                    Label("話題を立てる", systemImage: "square.and.pencil")
                }
                .buttonStyle(SecondaryButtonStyle())
                if threads.count >= 3 {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                        TextField("話題を探す", text: $query)
                    }
                    .padding(10)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                }
            } else if threads.isEmpty {
                Text("掲示板は、現地で扉を開けると読めます。思い出話・質問・注意したいことを、ここに来た人どうしで話せます。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            } else {
                Text("あなたが立てた話題（ほかの人の話題と返信は、現地で読めます）")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            if let error { NoticeText(text: error) }
            if context.isInside && threads.isEmpty && error == nil {
                Text("まだ話題はありません。最初の話題を立ててみましょう。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            if !query.trimmingCharacters(in: .whitespaces).isEmpty && filtered.isEmpty && !threads.isEmpty {
                Text("「\(query)」をふくむ話題は見つかりませんでした。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            ForEach(filtered) { thread in
                NavigationLink {
                    ThreadView(context: context, thread: thread) {
                        Task { await load() }
                    }
                } label: {
                    ThreadRow(thread: thread)
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: "\(context.isInside)-\(refreshToken)") { await load() }
        .sheet(isPresented: $showNew) {
            NewThreadSheet(context: context) {
                Task { await load() }
            }
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            threads = try await api.boardThreads(in: context.gateID)
            error = nil
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}

private struct ThreadRow: View {
    let thread: BoardThread

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: thread.boardTopic.symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(thread.boardTopic == .notice ? Theme.warm : Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if thread.pinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(Theme.warm)
                    }
                    Text(thread.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    if thread.unread {
                        Circle().fill(Theme.accent).frame(width: 8, height: 8)
                            .accessibilityLabel("未読")
                    }
                }
                if let progress = thread.investigationProgress, thread.boardTopic == .investigation {
                    ProgressBadge(progress: progress)
                } else if thread.resolved == true {
                    ResolvedBadge()
                }
                if !thread.body.isEmpty {
                    Text(thread.body).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                HStack(spacing: 10) {
                    Text(thread.author_name)
                    Text(ServerDate.relative(thread.last_activity_at))
                    if thread.edited_at != nil { Text("直しました") }
                    Label("\(thread.reply_count)", systemImage: "bubble.left")
                }
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }
}

/// 話題を立てる
struct NewThreadSheet: View {
    let context: GateContext
    let onPosted: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var topic: BoardTopic = .memory
    @State private var title = ""
    @State private var text = ""
    @State private var posting = false
    @State private var message: String?

    init(context: GateContext, onPosted: @escaping () -> Void) {
        self.context = context
        self.onPosted = onPosted
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("種類") {
                    Picker("種類", selection: $topic) {
                        ForEach(BoardTopic.allCases) { t in Label(t.label, systemImage: t.symbol).tag(t) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    TextField("題（60 文字まで）", text: $title)
                    TextField("本文（なくても大丈夫）", text: $text, axis: .vertical)
                        .lineLimit(4...10)
                } footer: {
                    Text("この GATE に入った人だけが読めます。人の名前や、家の場所などは書かないでください。")
                }
                if let message {
                    Section { NoticeText(text: message) }
                }
            }
            .navigationTitle("話題を立てる")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await post() }
                    } label: {
                        if posting { ProgressView() } else { Text("立てる").bold() }
                    }
                    .disabled(posting || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func post() async {
        guard let api = session.api, let visit = context.visit else {
            message = "扉が閉じました（GATE から離れたため）。現地でもう一度扉を開けてください。"
            return
        }
        posting = true
        defer { posting = false }
        do {
            _ = try await api.postThread(visit: visit, topic: topic,
                                         title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)),
                                         body: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000)))
            Haptics.success()
            onPosted()
            dismiss()
        } catch {
            message = ErrorText.of(error)
        }
    }
}

/// 話題と返信
struct ThreadView: View {
    let context: GateContext
    /// 一覧へ戻ったときに読み直す（直した・消したとき）
    var onChanged: (() -> Void)?

    @EnvironmentObject private var session: SessionModel
    @State private var thread: BoardThread
    @State private var editing: BoardEditTarget?
    @State private var editingProgress = false
    /// 調べる話題の返信の並べ方（なるほどが多い順）
    @State private var byVotes = false
    @Environment(\.dismiss) private var dismiss
    @State private var replies: [BoardReply] = []
    @State private var draft = ""
    @State private var sending = false
    @State private var message: String?
    @State private var pinned: Bool
    @State private var report: ReportItem?
    @State private var confirmDelete = false
    @State private var label: EvidenceLabel?
    @State private var source = ""
    @State private var filter: EvidenceLabel?

    init(context: GateContext, thread: BoardThread, onChanged: (() -> Void)? = nil) {
        self.context = context
        self.onChanged = onChanged
        _thread = State(initialValue: thread)
        _pinned = State(initialValue: thread.pinned)
    }

    /// GATE を作った人か、一緒に管理する人
    private var isGateOwner: Bool { context.canManage || context.ownerID == session.userID }
    private var isInvestigation: Bool { thread.boardTopic == .investigation }
    /// 調べる話題の進み具合・まとめを書けるか：立てた本人か GATE を管理する人（0023 のサーバーだけ）
    private var canSetProgress: Bool {
        isInvestigation && thread.progress != nil && (thread.author == session.userID || isGateOwner)
    }

    /// 「解決しました」にできるか：質問・調べるの話題で、立てた本人か GATE を作った人（0018 のサーバーだけ）
    private var canResolve: Bool {
        thread.resolved != nil && (thread.boardTopic == .question || isInvestigation)
            && (thread.author == session.userID || isGateOwner)
    }
    private var shownReplies: [BoardReply] {
        let list = filter.map { f in replies.filter { $0.evidence == f } } ?? replies
        return byVotes ? list.sorted { ($0.votes ?? 0) > ($1.votes ?? 0) } : list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Label(thread.boardTopic.label, systemImage: thread.boardTopic.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(thread.boardTopic == .notice ? Theme.warm : Theme.accent)
                        if let progress = thread.investigationProgress, isInvestigation {
                            ProgressBadge(progress: progress)
                        } else if thread.resolved == true {
                            ResolvedBadge()
                        }
                    }
                    Text(thread.title).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                    if !thread.body.isEmpty {
                        Text(thread.body).font(.body).foregroundStyle(Theme.text)
                    }
                    Text("\(thread.author_name)・\(ServerDate.relative(thread.created_at))"
                         + (thread.edited_at != nil ? "・直しました" : ""))
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.line))
                if isInvestigation, let conclusion = thread.conclusion, !conclusion.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("まとめ", systemImage: "text.badge.checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.accent)
                        Text(conclusion).font(.subheadline).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.accentLight, in: RoundedRectangle(cornerRadius: 14))
                }

                if isInvestigation && !replies.isEmpty {
                    evidenceFilter
                }
                HStack {
                    Text(replies.isEmpty ? "まだ返信はありません" : "返信 \(shownReplies.count) 件")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if isInvestigation && replies.contains(where: { ($0.votes ?? 0) > 0 }) {
                        Toggle(isOn: $byVotes) {
                            Label("なるほど順", systemImage: "lightbulb")
                        }
                        .toggleStyle(.button)
                        .font(.caption.weight(.semibold))
                        .tint(Theme.warm)
                    }
                }
                ForEach(shownReplies) { reply in
                    ReplyRow(reply: reply, canDelete: reply.author == session.userID || isGateOwner,
                             isMine: reply.author == session.userID,
                             canVote: isInvestigation && reply.votes != nil && reply.author != session.userID,
                             onVote: { Task { await vote(reply) } },
                             onEdit: { editing = .reply(reply) },
                             onDelete: { Task { await deleteReply(reply) } },
                             onReport: {
                                 report = ReportItem(id: reply.id, target: .reply, userID: reply.author,
                                                     userName: reply.author_name, label: "返信")
                             })
                }
                if let message { NoticeText(text: message) }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("掲示板")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if context.isInside {
                VStack(spacing: 8) {
                    if isInvestigation {
                        evidenceComposer
                    }
                    HStack(spacing: 10) {
                        TextField("返信を書く", text: $draft, axis: .vertical)
                            .lineLimit(1...4)
                            .padding(10)
                            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14))
                        Button {
                            Task { await send() }
                        } label: {
                            if sending {
                                ProgressView()
                            } else {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 42, height: 42)
                                    .background(Theme.accent, in: Circle())
                            }
                        }
                        .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("送る")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if canSetProgress {
                        Button {
                            editingProgress = true
                        } label: {
                            Label("進み具合・まとめを書く", systemImage: "text.badge.checkmark")
                        }
                    }
                    if canResolve && !isInvestigation {
                        Button {
                            Task { await toggleResolved() }
                        } label: {
                            Label(thread.resolved == true ? "「解決しました」を外す" : "解決しました",
                                  systemImage: thread.resolved == true ? "circle" : "checkmark.circle")
                        }
                    }
                    if isGateOwner {
                        Button {
                            Task { await togglePin() }
                        } label: {
                            Label(pinned ? "ピン留めをやめる" : "いちばん上にピン留め", systemImage: "pin")
                        }
                    }
                    if thread.author == session.userID {
                        Button {
                            editing = .thread(thread)
                        } label: {
                            Label("話題を直す", systemImage: "pencil")
                        }
                    }
                    if thread.author == session.userID || isGateOwner {
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("話題を消す", systemImage: "trash")
                        }
                    }
                    if thread.author != session.userID {
                        Button {
                            report = ReportItem(id: thread.id, target: .thread, userID: thread.author,
                                                userName: thread.author_name, label: thread.title)
                        } label: {
                            Label("通報する", systemImage: "exclamationmark.bubble")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("この話題を消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("消す", role: .destructive) { Task { await deleteThread() } }
        } message: {
            Text("返信も一緒に見えなくなります。")
        }
        .sheet(item: $report) { item in ReportSheet(item: item) }
        .sheet(isPresented: $editingProgress) {
            InvestigationProgressSheet(thread: thread) { progress, conclusion in
                thread.progress = progress.rawValue
                thread.conclusion = conclusion.isEmpty ? nil : conclusion
                if progress == .concluded { thread.resolved = true }
                onChanged?()
            }
            .environmentObject(session)
        }
        .sheet(item: $editing) { target in
            BoardEditSheet(target: target) { title, body in
                switch target {
                case .thread:
                    thread.title = title
                    thread.body = body
                    thread.edited_at = ISO8601DateFormatter().string(from: Date())
                case .reply(let reply):
                    if let i = replies.firstIndex(where: { $0.id == reply.id }) {
                        replies[i].body = body
                        replies[i].edited_at = ISO8601DateFormatter().string(from: Date())
                    }
                }
                onChanged?()
            }
            .environmentObject(session)
        }
        .task { await load() }
        .refreshable { await load() }
    }

    /// しるしごとに分けて見る
    private var evidenceFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("すべて \(replies.count)", selected: filter == nil) { filter = nil }
                ForEach(EvidenceLabel.allCases) { e in
                    let n = replies.filter { $0.evidence == e }.count
                    chip("\(e.label) \(n)", selected: filter == e) { filter = (filter == e ? nil : e) }
                }
            }
        }
    }

    /// 返信に付けるしるしと出典
    private var evidenceComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EvidenceLabel.allCases) { e in
                        chip(e.label, selected: label == e) { label = (label == e ? nil : e) }
                    }
                }
            }
            if let label {
                Text(label.caption).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            TextField("出典（本・記事・石碑など。なくても大丈夫）", text: $source)
                .font(.footnote)
                .padding(8)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? .white : Theme.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? Theme.accent : Theme.surfaceElevated, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            replies = try await api.boardReplies(thread.id)
            message = nil
        } catch {
            message = ErrorText.of(error)
        }
    }

    private func send() async {
        guard let api = session.api, let visit = context.visit else {
            message = "扉が閉じました（GATE から離れたため）。現地でもう一度扉を開けてください。"
            return
        }
        sending = true
        defer { sending = false }
        do {
            _ = try await api.reply(visit: visit, thread: thread.id,
                                    body: String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000)),
                                    label: isInvestigation ? label : nil,
                                    source: isInvestigation ? String(source.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)) : nil)
            draft = ""
            source = ""
            Haptics.tap()
            await load()
        } catch {
            message = ErrorText.of(error)
        }
    }

    /// 「なるほど」を付ける・外す（先に見た目を変え、だめなら戻す）
    private func vote(_ reply: BoardReply) async {
        guard let api = session.api, let i = replies.firstIndex(where: { $0.id == reply.id }) else { return }
        let on = !(reply.my_vote ?? false)
        let before = replies[i]
        replies[i].my_vote = on
        replies[i].votes = max(0, (reply.votes ?? 0) + (on ? 1 : -1))
        Haptics.tap()
        do {
            let count = try await api.voteReply(reply.id, on: on)
            if let j = replies.firstIndex(where: { $0.id == reply.id }) { replies[j].votes = count }
        } catch {
            if let j = replies.firstIndex(where: { $0.id == reply.id }) { replies[j] = before }
            message = ErrorText.of(error)
        }
    }

    private func toggleResolved() async {
        guard let api = session.api else { return }
        let on = !(thread.resolved ?? false)
        do {
            try await api.resolveThread(thread.id, on: on)
            thread.resolved = on
            Haptics.success()
            onChanged?()
        } catch {
            message = ErrorText.of(error)
        }
    }

    private func togglePin() async {
        guard let api = session.api else { return }
        do {
            try await api.pinThread(thread.id, pinned: !pinned)
            pinned.toggle()
        } catch {
            message = ErrorText.of(error)
        }
    }

    private func deleteThread() async {
        guard let api = session.api else { return }
        do {
            try await api.deleteBoard(kind: "thread", id: thread.id)
            onChanged?()
            dismiss()
        } catch {
            message = ErrorText.of(error)
        }
    }

    private func deleteReply(_ reply: BoardReply) async {
        guard let api = session.api else { return }
        do {
            try await api.deleteBoard(kind: "reply", id: reply.id)
            await load()
        } catch {
            message = ErrorText.of(error)
        }
    }
}

struct ReplyRow: View {
    let reply: BoardReply
    let canDelete: Bool
    let isMine: Bool
    /// 調べる話題の「なるほど」を押せるか（ほかの人の返信）
    let canVote: Bool
    let onVote: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onReport: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PersonBadge(name: reply.author_name, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(isMine ? "あなた" : reply.author_name).font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(ServerDate.relative(reply.created_at) + (reply.edited_at != nil ? "・直しました" : ""))
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Menu {
                        if isMine {
                            Button(action: onEdit) { Label("直す", systemImage: "pencil") }
                        }
                        if canDelete {
                            Button("消す", role: .destructive, action: onDelete)
                        }
                        if !isMine {
                            Button(action: onReport) { Label("通報する", systemImage: "exclamationmark.bubble") }
                        }
                    } label: {
                        Image(systemName: "ellipsis").font(.caption).foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, height: 20)
                    }
                }
                if let e = reply.evidence {
                    Text(e.label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(e == .fact ? Theme.accent : (e == .rumor ? Theme.alert : Theme.warm))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.surfaceElevated, in: Capsule())
                }
                Text(reply.body).font(.subheadline).foregroundStyle(Theme.text)
                if let source = reply.source, !source.isEmpty {
                    Label(source, systemImage: "book.closed")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                if let votes = reply.votes, canVote || votes > 0 {
                    Button(action: onVote) {
                        Label("なるほど \(votes)", systemImage: reply.my_vote == true ? "lightbulb.fill" : "lightbulb")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(reply.my_vote == true ? Theme.warm : Theme.textSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(reply.my_vote == true ? Theme.warm.opacity(0.12) : Theme.surfaceElevated,
                                        in: Capsule())
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canVote)
                    .accessibilityLabel(reply.my_vote == true ? "なるほどを外す" : "なるほど")
                }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }
}


/// 直すもの（話題か返信）
enum BoardEditTarget: Identifiable {
    case thread(BoardThread)
    case reply(BoardReply)

    var id: UUID {
        switch self {
        case .thread(let t): return t.id
        case .reply(let r): return r.id
        }
    }
}

/// 自分の話題・返信を直す画面
struct BoardEditSheet: View {
    let target: BoardEditTarget
    let onSaved: (_ title: String, _ body: String) -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var text: String
    @State private var saving = false
    @State private var message: String?

    init(target: BoardEditTarget, onSaved: @escaping (_ title: String, _ body: String) -> Void) {
        self.target = target
        self.onSaved = onSaved
        switch target {
        case .thread(let t):
            _title = State(initialValue: t.title)
            _text = State(initialValue: t.body)
        case .reply(let r):
            _title = State(initialValue: "")
            _text = State(initialValue: r.body)
        }
    }

    private var isThread: Bool {
        if case .thread = target { return true }
        return false
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        if saving { return false }
        if isThread { return (1...60).contains(trimmedTitle.count) && trimmedText.count <= 1000 }
        return (1...1000).contains(trimmedText.count)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isThread {
                        TextField("題（60 文字まで）", text: $title)
                    }
                    TextField(isThread ? "本文（なくても大丈夫）" : "返信", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                } footer: {
                    HStack(alignment: .top) {
                        Text("直すと「直しました」と出ます。")
                        Spacer()
                        Text("\(trimmedText.count)/1000")
                            .monospacedDigit()
                            .foregroundStyle(trimmedText.count > 1000 ? Theme.alert : Theme.textSecondary)
                    }
                }
                if let message {
                    Section { NoticeText(text: message) }
                }
            }
            .navigationTitle(isThread ? "話題を直す" : "返信を直す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("保存").bold() }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func save() async {
        guard let api = session.api else { return }
        saving = true
        defer { saving = false }
        do {
            switch target {
            case .thread(let t):
                try await api.editBoard(kind: "thread", id: t.id, title: trimmedTitle, body: trimmedText)
            case .reply(let r):
                try await api.editBoard(kind: "reply", id: r.id, title: nil, body: trimmedText)
            }
            Haptics.success()
            Trace.log("掲示板：\(isThread ? "話題" : "返信")を直した")
            onSaved(trimmedTitle, trimmedText)
            dismiss()
        } catch {
            message = ErrorText.of(error)
        }
    }
}


/// 「解決しました」の札
struct ResolvedBadge: View {
    var body: some View {
        Label("解決しました", systemImage: "checkmark.circle.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.accentLight, in: Capsule())
    }
}


/// 調べる話題の進み具合の札
struct ProgressBadge: View {
    let progress: InvestigationProgress

    var body: some View {
        Label(progress.label, systemImage: progress.symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(progress == .concluded ? Theme.accent : Theme.warm)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(progress == .concluded ? Theme.accentLight : Theme.warm.opacity(0.12), in: Capsule())
    }
}

/// 調べる話題の進み具合とまとめを書く（話題を立てた人・GATE を管理する人）
struct InvestigationProgressSheet: View {
    let thread: BoardThread
    let onSaved: (InvestigationProgress, String) -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var progress: InvestigationProgress
    @State private var conclusion: String
    @State private var saving = false
    @State private var message: String?

    init(thread: BoardThread, onSaved: @escaping (InvestigationProgress, String) -> Void) {
        self.thread = thread
        self.onSaved = onSaved
        _progress = State(initialValue: thread.investigationProgress ?? .open)
        _conclusion = State(initialValue: thread.conclusion ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("進み具合", selection: $progress) {
                        ForEach(InvestigationProgress.allCases) { p in
                            Label(p.label, systemImage: p.symbol).tag(p)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("進み具合")
                } footer: {
                    Text("「まとまった」にすると、話題に「解決しました」も付きます。")
                }
                Section {
                    TextField("分かったこと・確かな出典など（なくてもよい）", text: $conclusion, axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: conclusion) { _, v in if v.count > 600 { conclusion = String(v.prefix(600)) } }
                } header: {
                    Text("まとめ")
                } footer: {
                    Text("\(conclusion.count) / 600・話題のいちばん上に出ます。")
                }
                if let message {
                    Section { NoticeText(text: message) }
                }
            }
            .navigationTitle("進み具合・まとめ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("保存") { Task { await save() } }
                    }
                }
            }
        }
    }

    private func save() async {
        guard let api = session.api else { return }
        saving = true
        defer { saving = false }
        let text = conclusion.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await api.setInvestigationProgress(thread.id, progress: progress, conclusion: text)
            Haptics.success()
            Trace.log("調べる：進み具合を「\(progress.label)」にした")
            onSaved(progress, text)
            dismiss()
        } catch {
            message = ErrorText.of(error)
        }
    }
}
