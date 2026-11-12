import PhotosUI
import SwiftUI

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

/// 思い出を作る：題・ひとこと・見せる人 → 写真（12 枚まで）→ 一緒にいた友達
struct MemoryComposer: View {
    let context: GateContext
    let onCreated: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var note = ""
    @State private var visibility: Visibility = .friends
    @State private var items: [PhotosPickerItem] = []
    @State private var photos: [UIImage] = []
    @State private var members: Set<UUID> = []
    @State private var progress: String?
    @State private var message: String?

    init(context: GateContext, onCreated: @escaping () -> Void) {
        self.context = context
        self.onCreated = onCreated
    }

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
                    PhotosPicker(selection: $items, maxSelectionCount: 12, matching: .images) {
                        Label(photos.isEmpty ? "写真を選ぶ（12 枚まで）" : "写真を選び直す（\(photos.count) 枚）",
                              systemImage: "photo.on.rectangle.angled")
                    }
                    if !photos.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(photos.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                } header: {
                    Text("写真")
                } footer: {
                    Text("位置情報などは消して送ります。")
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
                    Text("仲間に入った友達は、作ってから 72 時間のあいだ、ここにいなくても自分の写真を足せます。")
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
                        .disabled(progress != nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || photos.isEmpty)
                }
            }
            .onChange(of: items) { _, newItems in
                Task { await loadPhotos(newItems) }
            }
        }
        .interactiveDismissDisabled(progress != nil)
    }

    private func loadPhotos(_ newItems: [PhotosPickerItem]) async {
        var loaded: [UIImage] = []
        for item in newItems {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                loaded.append(image.downscaled(maxSide: 1600))
            }
        }
        photos = loaded
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
            for (i, photo) in photos.enumerated() {
                progress = "写真を送っています（\(i + 1)/\(photos.count)）…"
                let path = try await media.uploadPhoto(photo, owner: me)
                do {
                    _ = try await api.addMemoryItem(memory, photoPath: path, caption: "")
                } catch {
                    await media.removePhoto(path: path)
                    throw error
                }
            }
            for friend in members {
                try? await api.inviteToMemory(memory, user: friend)
            }
            Trace.log("思い出を作りました（写真 \(photos.count) 枚・仲間 \(members.count) 人）")
            Haptics.success()
            onCreated()
            dismiss()
        } catch {
            message = ErrorText.of(error)
            onCreated()
        }
    }
}

/// 思い出の中：写真を並べて見る・足す・仲間・消す
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
                    PhotosPicker(selection: $adding, maxSelectionCount: 12, matching: .images) {
                        Label("写真を足す", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(SecondaryButtonStyle())
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
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(RemotePhoto(path: item.photo_path))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if item.author == session.userID || isOwner {
                                Button("消す", role: .destructive) { Task { await deleteItem(item) } }
                            }
                            if item.author != session.userID {
                                Button {
                                    report = ReportItem(id: item.id, target: .memory_item, userID: item.author,
                                                        userName: names[item.author], label: "思い出の写真")
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
            Text("仲間が足した写真も一緒に消えます。")
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
        .fullScreenCover(item: $viewer) { item in
            PhotoPager(paths: items.map(\.photo_path), start: items.firstIndex(of: item) ?? 0,
                       captions: items.map { names[$0.author] ?? "" })
        }
        .onChange(of: adding) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task { await add(newItems) }
        }
        .task { await load() }
        .refreshable { await load() }
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

    private func add(_ newItems: [PhotosPickerItem]) async {
        guard let api = session.api, let media = session.media, let me = session.userID else { return }
        defer {
            progress = nil
            adding = []
        }
        do {
            for (i, item) in newItems.enumerated() {
                progress = "写真を送っています（\(i + 1)/\(newItems.count)）…"
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data)
                else { continue }
                let path = try await media.uploadPhoto(image, owner: me)
                do {
                    _ = try await api.addMemoryItem(memory.id, photoPath: path, caption: "")
                } catch {
                    await media.removePhoto(path: path)
                    throw error
                }
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
            let path = try await api.deleteMemoryItem(item.id)
            if let path, item.author == session.userID { await session.media?.removePhoto(path: path) }
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
            let mine = items.filter { $0.author == session.userID }.map(\.photo_path)
            try await api.deleteMemory(memory.id)
            for path in mine { await session.media?.removePhoto(path: path) }
            onChanged()
            dismiss()
        } catch {
            message = ErrorText.of(error)
        }
    }
}

/// 写真を 1 枚ずつ大きく見る（左右にめくる）
struct PhotoPager: View {
    let paths: [String]
    let captions: [String]
    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(paths: [String], start: Int, captions: [String] = []) {
        self.paths = paths
        self.captions = captions
        _index = State(initialValue: start)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(paths.enumerated()), id: \.offset) { i, path in
                    VStack {
                        Spacer()
                        RemotePhoto(path: path, contentMode: .fit, placeholder: .black)
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
