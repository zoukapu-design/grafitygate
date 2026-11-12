import PhotosUI
import SwiftUI

/// GATE の中のどこを見ているか
enum GateTab: String, CaseIterable, Identifiable {
    case graffiti, memories, board, letters, thenNow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .graffiti: return "記憶"
        case .memories: return "思い出"
        case .board: return "掲示板"
        case .letters: return "手紙"
        case .thenNow: return "今と昔"
        }
    }
}

/// GATE の中の画面に渡す、いまの状態
struct GateContext: Equatable {
    let gateID: UUID
    let title: String
    let ownerID: UUID
    let ownerName: String
    let coverPath: String?
    let createdAt: String
    /// いま有効な入場券（現地で扉を開けているあいだだけ）
    let visit: UUID?
    let visitExpires: Date?

    var isInside: Bool { visit != nil && (visitExpires ?? .distantPast) > Date() }
}

/// GATE の画面。上に表紙、まん中に「記憶／思い出／掲示板／手紙」の切り替え。
/// 中身の多くは、現地で扉を開けているあいだ（20 分）だけ読める・書ける。
struct GateDetailView: View {
    let gateID: UUID

    @EnvironmentObject private var session: SessionModel
    @State private var summary: GateSummary?
    @State private var loadError: String?
    @State private var loaded = false
    @State private var showAR = false
    @State private var tab: GateTab = .graffiti
    @State private var saved = false
    @State private var report: ReportItem?
    @State private var refreshToken = 0
    @State private var actionMessage: String?
    @State private var trails: [TrailSummary] = []

    init(gateID: UUID, tab: GateTab = .graffiti) {
        self.gateID = gateID
        _tab = State(initialValue: tab)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary {
                    header(summary)
                    if !trails.isEmpty {
                        trailStrip
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        let context = makeContext(summary, now: timeline.date)
                        VStack(alignment: .leading, spacing: 16) {
                            visitBanner(context, now: timeline.date)
                            Picker("GATE の中", selection: $tab) {
                                ForEach(GateTab.allCases) { t in Text(t.label).tag(t) }
                            }
                            .pickerStyle(.segmented)
                            section(context)
                        }
                    }
                } else if let loadError {
                    NoticeText(text: loadError)
                } else if loaded {
                    EmptyNote(title: "GATE が見つかりません",
                              message: "公開範囲が変わったか、閉じられた可能性があります。",
                              systemImage: "door.left.hand.closed")
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(summary?.title ?? "GATE")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await reload() }
        .refreshable {
            await reload()
            refreshToken += 1
        }
        .fullScreenCover(isPresented: $showAR) {
            ARExperienceView(mode: .enter(gateID)) {
                showAR = false
                Task {
                    await reload()
                    refreshToken += 1
                }
            }
        }
        .sheet(item: $report) { item in
            ReportSheet(item: item)
        }
    }

    private func makeContext(_ s: GateSummary, now: Date) -> GateContext {
        let active = (s.visitExpiresAt ?? .distantPast) > now
        return GateContext(gateID: s.id, title: s.title, ownerID: s.owner, ownerName: s.owner_name,
                           coverPath: s.cover_path, createdAt: s.created_at,
                           visit: active ? s.my_visit : nil, visitExpires: active ? s.visitExpiresAt : nil)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let summary {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await toggleSaved() }
                } label: {
                    Image(systemName: saved ? "bookmark.fill" : "bookmark")
                }
                .accessibilityLabel(saved ? "保存をやめる" : "保存する")
                if summary.owner != session.userID {
                    Menu {
                        Button {
                            report = ReportItem(id: summary.id, target: .gate, userID: summary.owner,
                                                userName: summary.owner_name, label: summary.title)
                        } label: {
                            Label("この GATE を通報する", systemImage: "exclamationmark.bubble")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("そのほか")
                }
            }
        }
    }

    // MARK: 表紙

    private func header(_ s: GateSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let cover = s.cover_path {
                RemotePhoto(path: cover)
                    .frame(height: 220)
                    .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(s.title).font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                if !s.note.isEmpty {
                    Text(s.note).font(.body).foregroundStyle(Theme.text)
                }
                HStack(spacing: 12) {
                    if s.owner == session.userID {
                        Label("あなたの GATE", systemImage: "person")
                    } else {
                        NavigationLink {
                            ProfileView(userID: s.owner)
                        } label: {
                            Label(s.owner_name, systemImage: "person")
                        }
                    }
                    Label("\(s.graffiti_count) 枚の記憶", systemImage: "square.stack")
                    Label(Visibility.label(of: s.visibility), systemImage: "eye")
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                if let actionMessage {
                    NoticeText(text: actionMessage, isError: false)
                }
            }
            .padding(16)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.line))
    }

    /// この GATE をふくむ TRAIL
    private var trailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(trails) { trail in
                    NavigationLink {
                        TrailDetailView(trailID: trail.id, title: trail.title)
                    } label: {
                        Label(trail.inProgress ? "\(trail.title)（\(trail.reached)/\(trail.stop_count)）" : trail.title,
                              systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.accentLight, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 入場中は残り時間、入る前は「現地で扉を開ける」
    @ViewBuilder private func visitBanner(_ context: GateContext, now: Date) -> some View {
        if let expires = context.visitExpires, context.isInside {
            let minutes = max(1, Int(expires.timeIntervalSince(now) / 60 + 0.5))
            Label("扉が開いています・あと約 \(minutes) 分", systemImage: "door.left.hand.open")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentLight, in: RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showAR = true
                } label: {
                    Label("現地で扉を開ける", systemImage: "door.left.hand.open")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(session.api == nil)
                Text("作った人が写した場所・物にカメラを向けます。位置（120m 以内）と景色の両方が合うと扉が現れ、20 分のあいだ中の記憶を読んだり残したりできます。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder private func section(_ context: GateContext) -> some View {
        switch tab {
        case .graffiti:
            GraffitiSection(context: context, refreshToken: refreshToken) { item in report = item }
        case .memories:
            MemorySection(context: context, refreshToken: refreshToken) { item in report = item }
        case .board:
            BoardSection(context: context, refreshToken: refreshToken)
        case .letters:
            LetterSection(context: context, refreshToken: refreshToken)
        case .thenNow:
            SnapshotSection(context: context, refreshToken: refreshToken) { item in report = item }
        }
    }

    // MARK: 動き

    private func reload() async {
        guard let api = session.api else { return }
        do {
            summary = try await api.summary(gateID)
            loadError = nil
            if let saved = try? await api.collection("saved") {
                self.saved = saved.contains { $0.gate_id == gateID }
            }
            trails = (try? await api.trails(including: gateID)) ?? []
        } catch {
            loadError = ErrorText.of(error)
        }
        loaded = true
    }

    private func toggleSaved() async {
        guard let api = session.api else { return }
        let next = !saved
        do {
            try await api.setBookmark(gateID, on: next)
            saved = next
            actionMessage = next ? "保存しました。「わたし」→「保存」から開けます。" : "保存をやめました。"
            Haptics.tap()
        } catch {
            actionMessage = ErrorText.of(error)
        }
    }
}

// MARK: - 記憶（グラフィティ）

/// みんなの記憶：入場中は 1 枚残せて、みんなのカードが読める。入る前は自分のカードだけ。
struct GraffitiSection: View {
    let context: GateContext
    let refreshToken: Int
    let onReport: (ReportItem) -> Void

    @EnvironmentObject private var session: SessionModel
    @State private var graffiti: [Graffiti] = []
    @State private var names: [UUID: String] = [:]
    @State private var likes: [UUID: (count: Int, mine: Bool)] = [:]
    @State private var error: String?

    @State private var draft = ""
    @State private var draftVisibility: Visibility = .friends
    @State private var draftLocalOnly = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var posting = false
    @State private var postMessage: (text: String, isError: Bool)?

    init(context: GateContext, refreshToken: Int, onReport: @escaping (ReportItem) -> Void) {
        self.context = context
        self.refreshToken = refreshToken
        self.onReport = onReport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if context.isInside {
                composer
            }
            let shown = context.isInside ? graffiti : graffiti.filter { $0.author == session.userID }
            if !context.isInside && !shown.isEmpty {
                Text("ここに残した自分の記憶").font(.headline).foregroundStyle(Theme.text)
            }
            if context.isInside && shown.isEmpty {
                Text("まだ記憶はありません。最初の 1 枚を残せます。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            if !context.isInside && shown.isEmpty {
                Text("みんなの記憶は、現地で扉を開けると読めます。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            if let error { NoticeText(text: error) }
            ForEach(shown) { item in
                GraffitiCard(item: item, author: names[item.author] ?? "",
                             isMine: item.author == session.userID,
                             likeCount: likes[item.id]?.count ?? 0, liked: likes[item.id]?.mine ?? false,
                             onLike: { Task { await toggleLike(item) } },
                             onDelete: { Task { await delete(item) } },
                             onReport: {
                                 onReport(ReportItem(id: item.id, target: .graffiti, userID: item.author,
                                                     userName: names[item.author], label: "記憶のカード"))
                             })
            }
        }
        .task(id: "\(context.isInside)-\(refreshToken)") { await load() }
        .onChange(of: photoItem) { _, item in
            Task { await loadPhoto(item) }
        }
    }

    private var composer: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("ここに 1 枚残す").font(.headline).foregroundStyle(Theme.text)
                if let photo {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 200)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        Button {
                            self.photo = nil
                            photoItem = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white, .black.opacity(0.45))
                        }
                        .padding(8)
                        .accessibilityLabel("写真を外す")
                    }
                }
                TextField("この場所の思い出・ひとこと", text: $draft, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(12)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(photo == nil ? "写真を付ける" : "写真を選び直す", systemImage: "photo")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.accent)
                }
                Picker("見せる人", selection: $draftVisibility) {
                    ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
                }
                .pickerStyle(.segmented)
                Toggle("現地だけで見せる（友達の新着に出さない）", isOn: $draftLocalOnly)
                    .font(.subheadline)
                    .tint(Theme.accent)
                Button {
                    Task { await post() }
                } label: {
                    if posting { ProgressView().tint(.white) } else { Text("残す") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(posting || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photo == nil))
                Text("1 回の入場で 1 枚。同じ GATE には 12 時間あけると、また残せます。写真の位置情報などは消して送ります。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                if let postMessage {
                    NoticeText(text: postMessage.text, isError: postMessage.isError)
                }
            }
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            graffiti = try await api.graffiti(in: context.gateID)
            names = try await api.names(of: Array(Set(graffiti.map(\.author))))
            if let me = session.userID {
                likes = (try? await api.likes(for: graffiti.map(\.id), me: me)) ?? [:]
            }
            error = nil
        } catch {
            self.error = ErrorText.of(error)
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
            photo = image.downscaled(maxSide: 1600)
        } else {
            postMessage = ("写真を読み込めませんでした。", true)
        }
    }

    private func post() async {
        guard let api = session.api, let visit = context.visit else { return }
        posting = true
        defer { posting = false }
        var photoPath: String?
        do {
            if let photo, let media = session.media, let me = session.userID {
                photoPath = try await media.uploadPhoto(photo, owner: me)
            }
            _ = try await api.postGraffiti(visit: visit, body: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                           photoPath: photoPath, visibility: draftVisibility, localOnly: draftLocalOnly)
            draft = ""
            photo = nil
            photoItem = nil
            postMessage = ("残しました。", false)
            Haptics.success()
            await load()
        } catch {
            if let photoPath { await session.media?.removePhoto(path: photoPath) }
            postMessage = (ErrorText.of(error), true)
        }
    }

    private func delete(_ item: Graffiti) async {
        guard let api = session.api else { return }
        do {
            try await api.deleteGraffiti(item.id)
            if let path = item.photo_path { await session.media?.removePhoto(path: path) }
            await load()
        } catch {
            postMessage = (ErrorText.of(error), true)
        }
    }

    private func toggleLike(_ item: Graffiti) async {
        guard let api = session.api, let me = session.userID else { return }
        let current = likes[item.id] ?? (0, false)
        let next = !current.mine
        likes[item.id] = (max(0, current.count + (next ? 1 : -1)), next)
        do {
            try await api.setLike(item.id, me: me, on: next)
            if next { Haptics.tap() }
        } catch {
            likes[item.id] = current
            postMessage = (ErrorText.of(error), true)
        }
    }
}

/// グラフィティのカード（写真が主役。文字は写真の下に）
struct GraffitiCard: View {
    let item: Graffiti
    let author: String
    let isMine: Bool
    let likeCount: Int
    let liked: Bool
    let onLike: () -> Void
    let onDelete: () -> Void
    let onReport: () -> Void

    @State private var confirmDelete = false

    init(item: Graffiti, author: String, isMine: Bool, likeCount: Int, liked: Bool,
         onLike: @escaping () -> Void, onDelete: @escaping () -> Void, onReport: @escaping () -> Void) {
        self.item = item
        self.author = author
        self.isMine = isMine
        self.likeCount = likeCount
        self.liked = liked
        self.onLike = onLike
        self.onDelete = onDelete
        self.onReport = onReport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = item.photo_path {
                RemotePhoto(path: path)
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if isMine {
                        Text("あなた").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    } else {
                        NavigationLink {
                            ProfileView(userID: item.author)
                        } label: {
                            Text(author.isEmpty ? "だれか" : author)
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        }
                    }
                    Spacer()
                    Text(ServerDate.relative(item.created_at)).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                if !item.body.isEmpty {
                    Text(item.body).font(.body).foregroundStyle(Theme.text)
                }
                HStack(spacing: 12) {
                    Button(action: onLike) {
                        Label("\(likeCount)", systemImage: liked ? "heart.fill" : "heart")
                            .foregroundStyle(liked ? Theme.alert : Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(liked ? "いいねをやめる" : "いいね")
                    Label(Visibility.label(of: item.visibility), systemImage: "eye")
                    if item.local_only {
                        Label("現地だけ", systemImage: "mappin.and.ellipse")
                    }
                    Spacer()
                    Menu {
                        if isMine {
                            Button("消す", role: .destructive) { confirmDelete = true }
                        } else {
                            Button(action: onReport) {
                                Label("通報する", systemImage: "exclamationmark.bubble")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 32, height: 24)
                    }
                    .accessibilityLabel("そのほか")
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.line))
        .confirmationDialog("この記憶を消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("消す", role: .destructive, action: onDelete)
        } message: {
            Text("友達の新着や GATE からも見えなくなります。")
        }
    }
}
