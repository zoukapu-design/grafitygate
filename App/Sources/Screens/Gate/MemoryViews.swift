import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 思い出：何枚かの写真を 1 つにまとめる。一緒にいた友達を仲間に入れると、それぞれが自分の写真を足せる。
struct MemorySection: View {
    let context: GateContext
    let refreshToken: Int
    let onReport: (ReportItem) -> Void

    @EnvironmentObject private var session: SessionModel
    @State private var memories: [MemorySummary] = []
    @State private var error: String?
    @State private var showComposer = false

    init(context: GateContext, refreshToken: Int, onReport: @escaping (ReportItem) -> Void) {
        self.context = context
        self.refreshToken = refreshToken
        self.onReport = onReport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if context.isInside {
                Button {
                    showComposer = true
                } label: {
                    Label("思い出を作る", systemImage: "rectangle.stack.badge.plus")
                }
                .buttonStyle(SecondaryButtonStyle())
            } else if memories.isEmpty {
                Text("思い出は、現地で扉を開けると見られます。何枚かの写真を 1 つにまとめ、一緒にいた友達も写真を足せます。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            if let error { NoticeText(text: error) }
            if context.isInside && memories.isEmpty && error == nil {
                Text("まだ思い出はありません。").font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(memories) { memory in
                    NavigationLink {
                        MemoryDetailView(memory: memory, context: context) { Task { await load() } }
                    } label: {
                        MemoryTile(title: memory.title, subtitle: "\(memory.owner_name)・\(memory.item_count) 枚",
                                   cover: memory.cover_path)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: "\(context.isInside)-\(refreshToken)") { await load() }
        .sheet(isPresented: $showComposer) {
            MemoryComposer(context: context) { Task { await load() } }
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            memories = try await api.memories(in: context.gateID)
            error = nil
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}

/// 思い出の表紙（写真と題）
struct MemoryTile: View {
    let title: String
    let subtitle: String
    let cover: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Theme.surfaceElevated
                if let cover {
                    RemotePhoto(path: cover)
                } else {
                    Image(systemName: "photo.stack").font(.title2).foregroundStyle(Theme.textSecondary.opacity(0.5))
                }
            }
            .frame(height: 130)
            .clipped()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }
}

/// 思い出に足す前の 1 つ（写真・動画・声）
struct MemoryDraftItem: Identifiable {
    enum Kind {
        case photo(UIImage)
        case video(MediaPrep.PreparedVideo)
        case voice(URL, Double)
    }

    let id = UUID()
    let kind: Kind

    var thumbnail: UIImage? {
        switch kind {
        case .photo(let image): return image
        case .video(let v): return v.thumbnail
        case .voice: return nil
        }
    }

    var duration: Double? {
        switch kind {
        case .photo: return nil
        case .video(let v): return v.duration
        case .voice(_, let d): return d
        }
    }
}

/// 写真アプリから選んだもの（写真か動画）を、送れる形にする
enum MemoryDraftLoader {
    static func load(_ items: [PhotosPickerItem]) async -> (drafts: [MemoryDraftItem], trimmed: Bool, failed: Int) {
        var drafts: [MemoryDraftItem] = []
        var trimmed = false
        var failed = 0
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                do {
                    guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                        failed += 1
                        continue
                    }
                    let video = try await MediaPrep.prepareVideo(movie.url)
                    trimmed = trimmed || video.trimmed
                    drafts.append(MemoryDraftItem(kind: .video(video)))
                } catch {
                    Trace.log("動画を読み込めませんでした：\(error.localizedDescription)")
                    failed += 1
                }
            } else if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                drafts.append(MemoryDraftItem(kind: .photo(image.downscaled(maxSide: 1600))))
            } else {
                failed += 1
            }
        }
        return (drafts, trimmed, failed)
    }

    /// 1 つを送って思い出に足す（足せなかったら、送ったファイルを消す）
    static func add(_ draft: MemoryDraftItem, to memory: UUID, api: GateAPI, media: MediaStore, me: UUID) async throws {
        switch draft.kind {
        case .photo(let image):
            let path = try await media.uploadPhoto(image, owner: me)
            do {
                _ = try await api.addMemoryItem(memory, photoPath: path, caption: "")
            } catch {
                await media.removePhoto(path: path)
                throw error
            }
        case .video(let video):
            let thumb = try await media.uploadPhoto(video.thumbnail, owner: me)
            var path: String?
            do {
                path = try await media.uploadFile(video.file, owner: me, kind: .video)
                _ = try await api.addMemoryMedia(memory, kind: .video, path: path ?? "", thumbPath: thumb,
                                                 duration: video.duration, caption: "")
                try? FileManager.default.removeItem(at: video.file)
            } catch {
                await media.removePhoto(path: thumb)
                if let path { await media.removePhoto(path: path) }
                throw error
            }
        case .voice(let url, let seconds):
            let path = try await media.uploadFile(url, owner: me, kind: .voice)
            do {
                _ = try await api.addMemoryMedia(memory, kind: .voice, path: path, thumbPath: nil, duration: seconds,
                                                 caption: "")
                try? FileManager.default.removeItem(at: url)
            } catch {
                await media.removePhoto(path: path)
                throw error
            }
        }
    }

    /// 送らずにやめたものの一時ファイルを消す
    static func discard(_ drafts: [MemoryDraftItem]) {
        for draft in drafts {
            switch draft.kind {
            case .photo: break
            case .video(let v): try? FileManager.default.removeItem(at: v.file)
            case .voice(let url, _): try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func label(_ draft: MemoryDraftItem) -> String {
        switch draft.kind {
        case .photo: return "写真"
        case .video: return "動画"
        case .voice: return "声"
        }
    }
}

/// 選んだもの・録った声の小さな並び（× で外せる）
struct MemoryDraftStrip: View {
    let drafts: [MemoryDraftItem]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(drafts) { draft in
                    ZStack(alignment: .topTrailing) {
                        ZStack(alignment: .bottomLeading) {
                            if let image = draft.thumbnail {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                Theme.accentLight.overlay(Image(systemName: "waveform").foregroundStyle(Theme.accent))
                            }
                            if let d = draft.duration {
                                Label(durationText(d), systemImage: draft.thumbnail == nil ? "mic.fill" : "play.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(.black.opacity(0.45), in: Capsule())
                                    .padding(3)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        Button {
                            onRemove(draft.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white, .black.opacity(0.5))
                        }
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("外す")
                    }
                    .padding(.top, 6)
                }
            }
        }
    }
}

/// 思い出を作る：題・ひとこと・見せる人 → 写真・動画（12 まで）・声 → 一緒にいた友達
struct MemoryComposer: View {
    let context: GateContext
    let onCreated: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var note = ""
    @State private var visibility: Visibility = .friends
    @State private var items: [PhotosPickerItem] = []
    @State private var picked: [MemoryDraftItem] = []
    @State private var voices: [MemoryDraftItem] = []
    @State private var loading = false
    @State private var recording = false
    @State private var members: Set<UUID> = []
    @State private var progress: String?
    @State private var message: String?

    init(context: GateContext, onCreated: @escaping () -> Void) {
        self.context = context
        self.onCreated = onCreated
    }

    private var drafts: [MemoryDraftItem] { picked + voices }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("題（例：2026 年の花見）", text: $title)
                    TextField("ひとこと（なくても大丈夫）", text: $note, axis: .vertical).lineLimit(2...4)
                    Picker("見せる人", selection: $visibility) {
                        ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
                    }
                }
                Section {
                    PhotosPicker(selection: $items, maxSelectionCount: 12, matching: .any(of: [.images, .videos])) {
                        Label(picked.isEmpty ? "写真・動画を選ぶ（12 まで）" : "写真・動画を選び直す（\(picked.count)）",
                              systemImage: "photo.on.rectangle.angled")
                    }
                    Button {
                        recording = true
                    } label: {
                        Label("声を残す（60 秒まで）", systemImage: "mic")
                    }
                    if loading {
                        HStack { ProgressView(); Text("動画を整えています…").foregroundStyle(Theme.textSecondary) }
                    }
                    if !drafts.isEmpty {
                        MemoryDraftStrip(drafts: drafts) { id in
                            MemoryDraftLoader.discard(drafts.filter { $0.id == id })
                            picked.removeAll { $0.id == id }
                            voices.removeAll { $0.id == id }
                        }
                    }
                } header: {
                    Text("写真・動画・声")
                } footer: {
                    Text("動画ははじめの 15 秒まで。位置情報などは消し、iPhone の中で小さくしてから送ります。人の顔や声が入るときは、その人に断ってから。")
                }
                Section {
                    NavigationLink {
                        FriendPicker(title: "一緒にいた友達", multiple: true, selection: $members)
                    } label: {
                        HStack {
                            Text("一緒にいた友達")
                            Spacer()
                            Text(members.isEmpty ? "なし" : "\(members.count) 人").foregroundStyle(Theme.textSecondary)
                        }
                    }
                } footer: {
                    Text("仲間に入った友達は、作ってから 72 時間のあいだ、ここにいなくても自分の写真・動画・声を足せます。")
                }
                if let progress {
                    Section { HStack { ProgressView(); Text(progress).foregroundStyle(Theme.textSecondary) } }
                }
                if let message {
                    Section { NoticeText(text: message) }
                }
            }
            .navigationTitle("思い出を作る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作る") { Task { await create() } }
                        .bold()
                        .disabled(progress != nil || loading || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || drafts.isEmpty)
                }
            }
            .onChange(of: items) { _, newItems in
                Task { await loadPicked(newItems) }
            }
            .sheet(isPresented: $recording) {
                VoiceRecorderSheet { url, seconds in
                    voices.append(MemoryDraftItem(kind: .voice(url, seconds)))
                }
            }
        }
        .interactiveDismissDisabled(progress != nil)
        .onDisappear { MemoryDraftLoader.discard(drafts) }
    }

    private func loadPicked(_ newItems: [PhotosPickerItem]) async {
        loading = true
        defer { loading = false }
        let result = await MemoryDraftLoader.load(newItems)
        MemoryDraftLoader.discard(picked)
        picked = result.drafts
        var notes: [String] = []
        if result.trimmed { notes.append("15 秒より長い動画は、はじめの 15 秒にしました。") }
        if result.failed > 0 { notes.append("\(result.failed) つ読み込めませんでした。") }
        message = notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    private func create() async {
        guard let api = session.api, let media = session.media, let me = session.userID else { return }
        guard let visit = context.visit else {
            message = "入場の時間（20 分）が切れました。現地でもう一度入ってください。"
            return
        }
        message = nil
        progress = "思い出を作っています…"
        defer { progress = nil }
        do {
            let memory = try await api.createMemory(visit: visit,
                                                    title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)),
                                                    note: String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)),
                                                    visibility: visibility)
            let all = drafts
            for (i, draft) in all.enumerated() {
                progress = "\(MemoryDraftLoader.label(draft))を送っています（\(i + 1)/\(all.count)）…"
                try await MemoryDraftLoader.add(draft, to: memory, api: api, media: media, me: me)
            }
            for friend in members {
                try? await api.inviteToMemory(memory, user: friend)
            }
            Trace.log("思い出を作りました（\(all.count) つ・仲間 \(members.count) 人）")
            Haptics.success()
            onCreated()
            dismiss()
        } catch {
            message = ErrorText.of(error)
            onCreated()
        }
    }
}

/// 思い出の中：写真・動画・声を並べて見る・足す・仲間・消す
struct MemoryDetailView: View {
    let memory: MemorySummary
    let context: GateContext?
    let onChanged: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [MemoryItem] = []
    @State private var names: [UUID: String] = [:]
    @State private var members: [UUID] = []
    @State private var adding: [PhotosPickerItem] = []
    @State private var recording = false
    @State private var progress: String?
    @State private var message: String?
    @State private var viewer: MemoryItem?
    @State private var report: ReportItem?
    @State private var inviting: Set<UUID> = []
    @State private var showInvite = false
    @State private var confirmDelete = false

    init(memory: MemorySummary, context: GateContext?, onChanged: @escaping () -> Void) {
        self.memory = memory
        self.context = context
        self.onChanged = onChanged
    }

    private var isOwner: Bool { memory.owner == session.userID }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(memory.title).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                    if !memory.note.isEmpty {
                        Text(memory.note).font(.body).foregroundStyle(Theme.text)
                    }
                    Text("\(memory.owner_name)・\(ServerDate.relative(memory.created_at))・\(Visibility.label(of: memory.visibility))")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    if !members.isEmpty {
                        Label("仲間：" + members.map { names[$0] ?? "友達" }.joined(separator: "、"), systemImage: "person.2")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
                if memory.can_add {
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $adding, maxSelectionCount: 12, matching: .any(of: [.images, .videos])) {
                            Label("写真・動画", systemImage: "plus.square.on.square")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button {
                            recording = true
                        } label: {
                            Label("声", systemImage: "mic")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if let progress {
                    HStack { ProgressView(); Text(progress).font(.subheadline).foregroundStyle(Theme.textSecondary) }
                }
                if let message { NoticeText(text: message) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                    ForEach(items) { item in
                        Button {
                            viewer = item
                        } label: {
                            MemoryItemTile(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if item.author == session.userID || isOwner {
                                Button("消す", role: .destructive) { Task { await deleteItem(item) } }
                            }
                            if item.author != session.userID {
                                Button {
                                    report = ReportItem(id: item.id, target: .memory_item, userID: item.author,
                                                        userName: names[item.author], label: "思い出の\(Self.kindLabel(item))")
                                } label: {
                                    Label("通報する", systemImage: "exclamationmark.bubble")
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("思い出")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if isOwner {
                        Button {
                            inviting = []
                            showInvite = true
                        } label: {
                            Label("友達を仲間に入れる", systemImage: "person.badge.plus")
                        }
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("思い出を消す", systemImage: "trash")
                        }
                    } else {
                        if memory.is_member {
                            Button(role: .destructive) {
                                Task { await leave() }
                            } label: {
                                Label("仲間から抜ける", systemImage: "person.badge.minus")
                            }
                        }
                        Button {
                            report = ReportItem(id: memory.id, target: .memory, userID: memory.owner,
                                                userName: memory.owner_name, label: memory.title)
                        } label: {
                            Label("通報する", systemImage: "exclamationmark.bubble")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("この思い出を消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("消す", role: .destructive) { Task { await deleteMemory() } }
        } message: {
            Text("仲間が足した写真・動画・声も一緒に消えます。")
        }
        .sheet(item: $report) { item in ReportSheet(item: item) }
        .sheet(isPresented: $showInvite, onDismiss: { Task { await invite() } }) {
            NavigationStack {
                FriendPicker(title: "仲間に入れる友達", multiple: true, selection: $inviting)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("決める") { showInvite = false }.bold()
                        }
                    }
            }
        }
        .sheet(isPresented: $recording) {
            VoiceRecorderSheet { url, seconds in
                Task { await addDrafts([MemoryDraftItem(kind: .voice(url, seconds))]) }
            }
        }
        .fullScreenCover(item: $viewer) { item in
            MemoryPager(items: items, start: items.firstIndex(of: item) ?? 0,
                        captions: items.map { names[$0.author] ?? "" })
        }
        .onChange(of: adding) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                progress = "整えています…"
                let result = await MemoryDraftLoader.load(newItems)
                adding = []
                if result.trimmed { message = "15 秒より長い動画は、はじめの 15 秒にしました。" }
                await addDrafts(result.drafts)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    static func kindLabel(_ item: MemoryItem) -> String {
        switch item.kind {
        case .photo: return "写真"
        case .video: return "動画"
        case .voice: return "声"
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            items = try await api.memoryItems(memory.id)
            members = try await api.memoryMembers(memory.id)
            let people = Array(Set(items.map(\.author) + members + [memory.owner]))
            names = try await api.names(of: people)
            message = nil
        } catch {
            message = ErrorText.of(error)
        }
    }

    private func addDrafts(_ drafts: [MemoryDraftItem]) async {
        guard let api = session.api, let media = session.media, let me = session.userID, !drafts.isEmpty else {
            progress = nil
            return
        }
        defer { progress = nil }
        do {
            for (i, draft) in drafts.enumerated() {
                progress = "\(MemoryDraftLoader.label(draft))を送っています（\(i + 1)/\(drafts.count)）…"
                try await MemoryDraftLoader.add(draft, to: memory.id, api: api, media: media, me: me)
            }
            Haptics.success()
        } catch {
            message = ErrorText.of(error)
        }
        await load()
        onChanged()
    }

    private func deleteItem(_ item: MemoryItem) async {
        guard let api = session.api else { return }
        do {
            let paths = try await api.deleteMemoryItem(item.id)
            if item.author == session.userID {
                for path in paths { await session.media?.removePhoto(path: path) }
            }
            await load()
            onChanged()
        } catch {
            message = ErrorText.of(error)
        }
    }

    private func invite() async {
        guard let api = session.api, !inviting.isEmpty else { return }
        for friend in inviting where !members.contains(friend) {
            do {
                try await api.inviteToMemory(memory.id, user: friend)
            } catch {
                message = ErrorText.of(error)
            }
        }
        inviting = []
        await load()
    }

    private func leave() async {
        guard let api = session.api else { return }
        do {
            try await api.leaveMemory(memory.id)
            onChanged()
            dismiss()
        } catch {
            message = ErrorText.of(error)
        }
    }

    private func deleteMemory() async {
        guard let api = session.api else { return }
        do {
            let mine = items.filter { $0.author == session.userID }.flatMap { [$0.photo_path] + ($0.thumb_path.map { [$0] } ?? []) }
            try await api.deleteMemory(memory.id)
            for path in mine { await session.media?.removePhoto(path: path) }
            onChanged()
            dismiss()
        } catch {
            message = ErrorText.of(error)
        }
    }
}

/// 思い出の並びの 1 つ（写真・動画の表紙・声）
struct MemoryItemTile: View {
    let item: MemoryItem

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let picture = item.picturePath {
                    RemotePhoto(path: picture)
                } else {
                    ZStack {
                        Theme.accentLight
                        Image(systemName: "waveform").font(.title2).foregroundStyle(Theme.accent)
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.kind != .photo {
                    Label(durationText(item.duration ?? 0), systemImage: item.kind == .video ? "play.fill" : "mic.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(MemoryDetailView.kindLabel(item))
    }
}

/// 思い出を 1 つずつ大きく見る（左右にめくる。動画・声はその場で流す）
struct MemoryPager: View {
    let items: [MemoryItem]
    let captions: [String]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(items: [MemoryItem], start: Int, captions: [String] = []) {
        self.items = items
        self.captions = captions
        _index = State(initialValue: start)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    VStack {
                        Spacer()
                        switch item.kind {
                        case .photo:
                            RemotePhoto(path: item.photo_path, contentMode: .fit, placeholder: .black)
                        case .video:
                            MemoryVideoView(path: item.photo_path, active: index == i)
                        case .voice:
                            MemoryVoiceView(path: item.photo_path, duration: item.duration ?? 0, active: index == i)
                        }
                        Spacer()
                        if i < captions.count, !captions[i].isEmpty {
                            Text(captions[i]).font(.footnote).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 24)
                        }
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .padding(16)
            .accessibilityLabel("閉じる")
        }
    }
}
