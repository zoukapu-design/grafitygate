import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// アルバム：何枚かの写真を 1 つにまとめる。一緒にいた友達を仲間に入れると、それぞれが自分の写真を足せる。
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
                    Label("アルバムを作る", systemImage: "rectangle.stack.badge.plus")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            if let error { NoticeText(text: error) }
            if memories.isEmpty && error == nil {
                EmptyNote(title: context.isInside ? "最初のアルバムを作ろう" : "GATE を開けると見られます",
                          message: "", systemImage: "photo.stack")
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

/// アルバムの表紙（写真と題）
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

/// アルバムに足す前の 1 つ（写真・動画・声）
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

    /// 1 つを送ってアルバムに足す（足せなかったら、送ったファイルを消す）
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

/// アルバムを作る（2026-11-20 オーナー「どこを触ればいいのか分からない」）：
/// いちばん上がアルバムの表紙（名前・ひとことは表紙の上に直接書く。1 枚目の写真が表紙になる）。
/// その下に「入れるもの」を大きな札で（写真・動画／声／グラフィティカード）、一緒にいた友達、見せる範囲。
/// いちばん下のボタンは、足りないものを教えてくれる（名前を入れよう → 写真を入れよう → アルバムを作る）。
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
    @State private var cards: [MyCard] = []
    @State private var loading = false
    @State private var recording = false
    @State private var choosingCard = false
    @State private var choosingFriends = false
    @State private var members: Set<UUID> = []
    @State private var memberNames: [UUID: String] = [:]
    @State private var progress: String?
    @State private var message: String?
    @FocusState private var focus: Field?

    enum Field { case title, note }

    init(context: GateContext, onCreated: @escaping () -> Void) {
        self.context = context
        self.onCreated = onCreated
    }

    private var drafts: [MemoryDraftItem] { picked + voices }
    private var hasTitle: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasItems: Bool { !drafts.isEmpty || !cards.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    cover
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "入れるもの", count: drafts.count + cards.count)
                        addTiles
                        if loading {
                            Label("動画を整えています…", systemImage: "hourglass")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        if hasItems { itemsGrid }
                    }
                    friendsRow
                    visibilityRow
                    if let message { NoticeText(text: message) }
                }
                .padding(16)
                .padding(.bottom, 90)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { createBar }
            .navigationTitle("アルバムを作る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
            }
            .onChange(of: items) { _, newItems in
                Task { await loadPicked(newItems) }
            }
            .onChange(of: members) { _, ids in Task { await loadNames(ids) } }
            .sheet(isPresented: $recording) {
                VoiceRecorderSheet { url, seconds in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        voices.append(MemoryDraftItem(kind: .voice(url, seconds)))
                    }
                }
            }
            .sheet(isPresented: $choosingCard) {
                MyCardPicker(preferGate: context.gateID, title: "入れるカードを選ぶ") { card in
                    guard !cards.contains(where: { $0.id == card.id }) else { return }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { cards.append(card) }
                    Haptics.tap()
                }
                .environmentObject(session)
            }
            .navigationDestination(isPresented: $choosingFriends) {
                FriendPicker(title: "一緒にいた友達", multiple: true, selection: $members)
            }
        }
        .interactiveDismissDisabled(progress != nil)
        .onDisappear { MemoryDraftLoader.discard(drafts) }
    }

    // MARK: 表紙（名前とひとことは、ここに直接書く）

    private var coverImage: UIImage? { picked.first?.thumbnail }

    private var cover: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = coverImage {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    LinearGradient(colors: [Color(hex: 0xF0702A), Color(hex: 0xE0457B), Color(hex: 0x5B3FE0)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "photo.stack.fill")
                                .font(.system(size: 64, weight: .bold))
                                .foregroundStyle(.white.opacity(0.22))
                                .padding(22)
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 230)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 6) {
                TextField("", text: $title, prompt: Text("アルバムの名前").foregroundColor(.white.opacity(0.75)))
                    .font(.title2.weight(.heavy))
                    .foregroundStyle(.white)
                    .focused($focus, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focus = .note }
                TextField("", text: $note, prompt: Text("ひとこと（なくても大丈夫）").foregroundColor(.white.opacity(0.65)),
                          axis: .vertical)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1...3)
                    .focused($focus, equals: .note)
            }
            .padding(18)
            .overlay(alignment: .topTrailing) {
                if !hasTitle && focus == nil {
                    Image(systemName: "pencil")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.3), in: Circle())
                        .offset(x: -8, y: -28)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(alignment: .top) {
            // 本のような綴じ目
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { _ in
                    Capsule().fill(.white.opacity(0.85)).frame(width: 18, height: 6)
                }
            }
            .padding(.top, 10)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .onTapGesture { if focus == nil { focus = .title } }
    }

    // MARK: 入れるもの

    private var addTiles: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $items, maxSelectionCount: 12, matching: .any(of: [.images, .videos])) {
                addTile("写真・動画", systemImage: "photo.on.rectangle.angled",
                        colors: [Color(hex: 0xFF9A5A), Color(hex: 0xF0457B)])
            }
            .buttonStyle(.plain)
            Button {
                recording = true
            } label: {
                addTile("声を録る", systemImage: "mic.fill", colors: [Color(hex: 0x6E7CFF), Color(hex: 0x5B3FE0)])
            }
            .buttonStyle(.plain)
            Button {
                choosingCard = true
            } label: {
                addTile("カード", systemImage: "rectangle.portrait.on.rectangle.portrait.angled.fill",
                        colors: [Color(hex: 0x2FC1A8), Color(hex: 0x2F86C9)])
            }
            .buttonStyle(.plain)
        }
    }

    private func addTile(_ title: String, systemImage: String, colors: [Color]) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white, Theme.text)
                        .offset(x: 7, y: -7)
                }
            Text(title)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 104)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line))
    }

    /// 入れたもの（3 列）。右上の × で外す。1 枚目の写真が表紙
    private var itemsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(Array(drafts.enumerated()), id: \.element.id) { index, draft in
                draftTile(draft, isCover: index == 0 && draft.thumbnail != nil)
            }
            ForEach(cards, id: \.id) { card in
                TradingCard(content: MyCardPicker.content(card, author: session.profile?.display_name ?? "あなた"),
                            animated: false)
                    .overlay(alignment: .topTrailing) {
                        removeButton {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { cards.removeAll { $0.id == card.id } }
                        }
                    }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }

    private func draftTile(_ draft: MemoryDraftItem, isCover: Bool) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { draftFace(draft) }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .topLeading) {
                if isCover {
                    Text("表紙")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.warm, in: Capsule())
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                removeButton {
                    MemoryDraftLoader.discard([draft])
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        picked.removeAll { $0.id == draft.id }
                        voices.removeAll { $0.id == draft.id }
                    }
                }
            }
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private func draftFace(_ draft: MemoryDraftItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let image = draft.thumbnail {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(hex: 0x6E7CFF), Color(hex: 0x5B3FE0)], startPoint: .top, endPoint: .bottom)
                    .overlay(Image(systemName: "waveform").font(.system(size: 30, weight: .bold)).foregroundStyle(.white))
            }
            if let d = draft.duration {
                Label(durationText(d), systemImage: draft.thumbnail == nil ? "mic.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.white, .black.opacity(0.55))
        }
        .buttonStyle(.plain)
        .padding(4)
        .accessibilityLabel("外す")
    }

    // MARK: 一緒にいた友達・見せる範囲

    private var friendsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "一緒にいた友達", count: members.count)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    Button {
                        choosingFriends = true
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 56, height: 56)
                                .background(Theme.accentLight, in: Circle())
                                .overlay(Circle().strokeBorder(Theme.accent.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                            Text(members.isEmpty ? "えらぶ" : "かえる")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    ForEach(Array(members), id: \.self) { id in
                        VStack(spacing: 6) {
                            NeonAvatar(name: memberNames[id] ?? "友", size: 56)
                            Text(memberNames[id] ?? "…")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                                .frame(maxWidth: 64)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var visibilityRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "見せる範囲")
            HStack(spacing: 8) {
                ForEach(Visibility.allCases) { v in
                    let on = visibility == v
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { visibility = v }
                        Haptics.tap()
                    } label: {
                        Text(v.label)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(on ? .white : Theme.text)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(on ? Theme.accent : Theme.surface, in: Capsule())
                            .overlay(Capsule().stroke(on ? Color.clear : Theme.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    // MARK: 作る

    private var createBar: some View {
        VStack(spacing: 8) {
            if let progress {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(progress).font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
                }
            }
            Button {
                if !hasTitle {
                    focus = .title
                } else if hasItems {
                    Task { await create() }
                }
            } label: {
                Label(!hasTitle ? "まず、アルバムの名前を入れよう" : (hasItems ? "アルバムを作る" : "写真・声・カードを入れよう"),
                      systemImage: !hasTitle ? "pencil" : (hasItems ? "sparkles" : "arrow.up"))
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(progress != nil || loading || (hasTitle && !hasItems))
            .opacity(hasTitle && hasItems ? 1 : 0.85)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func loadNames(_ ids: Set<UUID>) async {
        guard let api = session.api else { return }
        let missing = ids.filter { memberNames[$0] == nil }
        guard !missing.isEmpty else { return }
        if let names = try? await api.names(of: Array(missing)) {
            memberNames.merge(names) { a, _ in a }
        }
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
            message = "GATE が閉じました（離れたため）。現地でもう一度 GATE を開けてください。"
            return
        }
        message = nil
        progress = "アルバムを作っています…"
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
            for card in cards {
                progress = "グラフィティカードを入れています…"
                try? await api.addMemoryCard(memory: memory, card: card.id)
            }
            for friend in members {
                try? await api.inviteToMemory(memory, user: friend)
            }
            Trace.log("アルバムを作りました（\(all.count) つ・カード \(cards.count) 枚・仲間 \(members.count) 人）")
            Haptics.success()
            onCreated()
            dismiss()
        } catch {
            message = ErrorText.of(error)
            onCreated()
        }
    }
}

/// アルバムの中：写真・動画・声を並べて見る・足す・仲間・消す
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
    /// 入れたグラフィティカードの中身（アルバムの 1 つの ID ごと）
    @State private var cards: [UUID: AttachedCard] = [:]
    @State private var pickingCard = false
    @State private var cardViewer: TradingCardContent?

    init(memory: MemorySummary, context: GateContext?, onChanged: @escaping () -> Void) {
        self.memory = memory
        self.context = context
        self.onChanged = onChanged
    }

    private var isOwner: Bool { memory.owner == session.userID }

    /// 出すもの（中身の分からないカード＝消された・ブロックの相手のものは出さない）
    private var shownItems: [MemoryItem] {
        items.filter { $0.kind != .card || cards[$0.id] != nil }
    }

    /// 左右にめくって見るもの（カードは押すとカードの形で大きく見る）
    private var pagerItems: [MemoryItem] { shownItems.filter { $0.kind != .card } }

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
                    VStack(spacing: 10) {
                        // グラフィティカードを入れる（2026-11-19 オーナー「カードとほかの機能を連動」）
                        Button {
                            pickingCard = true
                        } label: {
                            Label("グラフィティカードを入れる", systemImage: "rectangle.portrait.on.rectangle.portrait.angled")
                        }
                        .buttonStyle(SecondaryButtonStyle())
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
                }
                if let progress {
                    HStack { ProgressView(); Text(progress).font(.subheadline).foregroundStyle(Theme.textSecondary) }
                }
                if let message { NoticeText(text: message) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                    ForEach(shownItems) { item in
                        Button {
                            if item.kind == .card, let card = cards[item.id] {
                                cardViewer = card.content
                            } else {
                                viewer = item
                            }
                        } label: {
                            MemoryItemTile(item: item, card: cards[item.id])
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if item.author == session.userID || isOwner {
                                Button("消す", role: .destructive) { Task { await deleteItem(item) } }
                            }
                            if item.author != session.userID {
                                Button {
                                    report = ReportItem(id: item.id, target: .memory_item, userID: item.author,
                                                        userName: names[item.author], label: "アルバムの\(Self.kindLabel(item))")
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
        .navigationTitle("アルバム")
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
                            Label("アルバムを消す", systemImage: "trash")
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
        .confirmationDialog("このアルバムを消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
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
            MemoryPager(items: pagerItems, start: pagerItems.firstIndex(of: item) ?? 0,
                        captions: pagerItems.map { names[$0.author] ?? "" })
        }
        .fullScreenCover(item: $cardViewer) { card in
            TradingCardViewer(content: card)
        }
        .sheet(isPresented: $pickingCard) {
            MyCardPicker(preferGate: context?.gateID, title: "アルバムに入れるカード") { card in
                Task { await addCard(card) }
            }
            .environmentObject(session)
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
        case .card: return "グラフィティカード"
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            items = try await api.memoryItems(memory.id)
            if items.contains(where: { $0.kind == .card }) {
                let list = (try? await api.memoryCards(memory.id)) ?? []
                cards = Dictionary(list.compactMap { c in c.item_id.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
            } else {
                cards = [:]
            }
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

    /// グラフィティカードを入れる
    private func addCard(_ card: MyCard) async {
        guard let api = session.api else { return }
        do {
            try await api.addMemoryCard(memory: memory.id, card: card.id)
            Haptics.success()
            Trace.log("アルバム：カードを入れた")
            await load()
            onChanged()
        } catch {
            message = ErrorText.isMissingFunction(error)
                ? "カードを入れるのは、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
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
            // カードはカードのファイルなので消さない（自分のフォルダの写真・動画・声だけ）
            let mine = items.filter { $0.author == session.userID }.flatMap(\.ownFiles)
            try await api.deleteMemory(memory.id)
            for path in mine { await session.media?.removePhoto(path: path) }
            onChanged()
            dismiss()
        } catch {
            message = ErrorText.of(error)
        }
    }
}

/// アルバムの並びの 1 つ（写真・動画の表紙・声）
struct MemoryItemTile: View {
    let item: MemoryItem
    /// グラフィティカードのときの中身
    var card: AttachedCard? = nil

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if item.kind == .card, let card {
                    ZStack {
                        LinearGradient(colors: [Color(hex: 0x2A1650), Color(hex: 0x1B1235)], startPoint: .top, endPoint: .bottom)
                        TradingCard(content: card.content, animated: false)
                            .padding(6)
                    }
                } else if let picture = item.picturePath {
                    RemotePhoto(path: picture)
                } else {
                    ZStack {
                        Theme.accentLight
                        Image(systemName: "waveform").font(.title2).foregroundStyle(Theme.accent)
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video || item.kind == .voice {
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

/// アルバムを 1 つずつ大きく見る（左右にめくる。動画・声はその場で流す）
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
                            ZoomableRemotePhoto(path: item.photo_path)
                        case .video:
                            MemoryVideoView(path: item.photo_path, active: index == i)
                        case .voice:
                            MemoryVoiceView(path: item.photo_path, duration: item.duration ?? 0, active: index == i)
                        case .card:
                            EmptyView()
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
