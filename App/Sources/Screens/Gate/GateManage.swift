import PhotosUI
import SwiftUI

// MARK: - GATE を直す

/// GATE を直す：表紙・名前・紹介（作った人と、一緒に管理する人）と、見せる範囲（作った人だけ）。
/// 写真の特徴（入るための見本）は変えない。表紙は飾りなので、写真アプリからも選べる。
struct GateEditSheet: View {
    let summary: GateSummary
    let isOwner: Bool
    let onSaved: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String
    @State private var visibility: Visibility
    @State private var photoItem: PhotosPickerItem?
    @State private var newCover: UIImage?
    @State private var saving = false
    @State private var message: String?
    /// 扉の見た目（作った人だけ変えられる。読み込むまでは nil）
    @State private var design: DoorDesign?
    @State private var savedDesign: DoorDesign?

    init(summary: GateSummary, isOwner: Bool, onSaved: @escaping () -> Void) {
        self.summary = summary
        self.isOwner = isOwner
        self.onSaved = onSaved
        _title = State(initialValue: summary.title)
        _note = State(initialValue: summary.note)
        _visibility = State(initialValue: Visibility(rawValue: summary.visibility) ?? .friends)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool {
        newCover != nil || trimmedTitle != summary.title || note != summary.note
            || (isOwner && visibility.rawValue != summary.visibility)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ZStack(alignment: .bottomTrailing) {
                        Group {
                            if let newCover {
                                Image(uiImage: newCover).resizable().scaledToFill()
                            } else if let path = summary.cover_path {
                                RemotePhoto(path: path)
                            } else {
                                ZStack {
                                    LinearGradient(colors: [Color(hex: 0x060A24), Color(hex: 0x3A1530)],
                                                   startPoint: .top, endPoint: .bottom)
                                    GateMark(size: 64, glowing: false)
                                }
                            }
                        }
                        .frame(height: 170)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        HStack(spacing: 8) {
                            if summary.cover_path != nil || newCover != nil {
                                // 横倒しの表紙を、まっすぐにする（押すたびに右へ 90°）
                                Button {
                                    Task { await rotateCover() }
                                } label: {
                                    Label("回す", systemImage: "rotate.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(.black.opacity(0.55), in: Capsule())
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("表紙の写真を右に回す")
                            }
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Label(summary.cover_path == nil && newCover == nil ? "表紙を付ける" : "表紙を変える",
                                      systemImage: "photo")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(.black.opacity(0.55), in: Capsule())
                            }
                            // 表の 1 行にボタンが 2 つあると、どこを押しても同じボタンになるので、それぞれだけを押せるようにする
                            .buttonStyle(.borderless)
                        }
                        .padding(10)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } footer: {
                    Text("表紙は地図や友達の画面に出る絵です。入るときの見本（写真の特徴）は変わりません。")
                }
                Section("名前") {
                    TextField("GATE の名前", text: $title)
                        .onChange(of: title) { _, v in if v.count > 60 { title = String(v.prefix(60)) } }
                }
                Section("紹介") {
                    TextField("どんな場所・物か（なくてもよい）", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: note) { _, v in if v.count > 400 { note = String(v.prefix(400)) } }
                }
                Section {
                    if isOwner {
                        Picker("見せる範囲", selection: $visibility) {
                            ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
                        }
                    } else {
                        LabeledContent("見せる範囲", value: Visibility.label(of: summary.visibility))
                    }
                } footer: {
                    Text(isOwner ? "「自分だけ」にすると、ほかの人は見つけられず、入れなくなります。"
                                 : "見せる範囲を変えられるのは、GATE を作った人だけです。")
                }
                if isOwner, let design {
                    Section {
                        DoorDesignGrid(selection: design) { picked in
                            self.design = picked
                            Haptics.tap()
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("扉の見た目")
                    } footer: {
                        Text("AR で見える扉の形と飾りです。次に AR で開いたときから、入った人にもこの見た目で出ます。")
                    }
                }
                if let message {
                    Section { NoticeText(text: message) }
                }
            }
            .navigationTitle("GATE を直す")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // 扉の見た目（0028 の前のサーバーではネオン）
                guard isOwner, design == nil, let api = session.api else { return }
                let current = (try? await api.doorInfo(summary.id))?.design ?? .neon
                design = current
                savedDesign = current
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("保存") { Task { await save() } }
                            .disabled(!changed || trimmedTitle.isEmpty)
                    }
                }
            }
            .onChange(of: photoItem) { _, item in Task { await loadPhoto(item) } }
        }
    }

    /// 表紙を右に 90° 回す（いまの表紙を受け取って回し、保存のときに新しい表紙として送る）
    private func rotateCover() async {
        var image = newCover
        if image == nil, let path = summary.cover_path {
            image = await session.media?.photo(path: path)
        }
        guard let image else {
            message = "表紙を読めませんでした。少し待ってから、もう一度押してください。"
            return
        }
        newCover = image.rotatedRight()
        Haptics.tap()
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
            newCover = image.downscaled(maxSide: 1600)
        } else {
            message = "写真を読めませんでした。別の写真を選んでください。"
        }
    }

    private func save() async {
        guard let api = session.api, let me = session.userID else { return }
        saving = true
        defer { saving = false }
        var uploaded: String?
        do {
            if let newCover, let media = session.media {
                uploaded = try await media.uploadPhoto(newCover, owner: me)
            }
            let old = try await api.editGate(summary.id,
                                             title: trimmedTitle,
                                             note: note,
                                             coverPath: uploaded,
                                             visibility: isOwner ? visibility : nil)
            if isOwner, let design, design != savedDesign {
                try await api.setDoorStyle(gate: summary.id, design: design)
                Trace.log("扉の見た目を変えた：\(design.label)")
            }
            // 差し替えた前の表紙が自分のフォルダのものなら消す
            if let old, old.hasPrefix(me.uuidString.lowercased() + "/") {
                await session.media?.removePhoto(path: old)
            }
            Trace.log("GATE を直した（表紙\(uploaded == nil ? "そのまま" : "を差し替え")）")
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            if let uploaded { await session.media?.removePhoto(path: uploaded) }
            message = ErrorText.isMissingFunction(error)
                ? "GATE を直すのは、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
    }
}

// MARK: - 一緒に管理する人

/// 作った人が、お互いにフォローの友達を「一緒に管理する人」に入れる・外す（5 人まで）
struct GateManagersSheet: View {
    let gateID: UUID
    let title: String
    let onChanged: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var managers: [GateManager] = []
    @State private var friends: [ProfileRow] = []
    @State private var loaded = false
    @State private var working: UUID?
    @State private var message: String?

    private static let limit = 5
    private var candidates: [ProfileRow] {
        friends.filter { f in !managers.contains { $0.user_id == f.id } }
            .sorted { $0.display_name.localizedStandardCompare($1.display_name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("「\(title)」を、友達と一緒に育てられます。").font(.subheadline.weight(.semibold))
                        Label("名前・紹介・表紙を直す", systemImage: "pencil")
                        Label("掲示板のピン留め・話題や返信を消す・「解決しました」", systemImage: "bubble.left.and.bubble.right")
                        Label("見せる範囲・閉じる・管理する人を変えるのは、あなただけ", systemImage: "lock")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(.caption)
                    .padding(.vertical, 4)
                }
                Section("一緒に管理する人（\(managers.count)/\(Self.limit)）") {
                    if managers.isEmpty {
                        Text(loaded ? "まだいません。下の友達から入れられます。" : "読み込んでいます…")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(managers) { m in
                        HStack(spacing: 12) {
                            PersonBadge(name: m.display_name, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.display_name).font(.subheadline.weight(.semibold))
                                Text("\(GateDates.shortText(m.added_at)) から").font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if working == m.user_id {
                                ProgressView()
                            } else {
                                Button("外す", role: .destructive) { Task { await remove(m.user_id) } }
                                    .buttonStyle(.bordered)
                                    .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
                Section {
                    if loaded && candidates.isEmpty {
                        Text(friends.isEmpty ? "お互いにフォローしている友達がいると、ここから入れられます。"
                                             : "友達はみんな入っています。")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(candidates, id: \.id) { f in
                        HStack(spacing: 12) {
                            PersonBadge(name: f.display_name, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.display_name).font(.subheadline.weight(.semibold))
                                Text("@\(f.handle)").font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if working == f.id {
                                ProgressView()
                            } else {
                                Button("入れる") { Task { await add(f.id) } }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Theme.accent)
                                    .font(.caption.weight(.semibold))
                                    .disabled(managers.count >= Self.limit)
                            }
                        }
                    }
                } header: {
                    Text("友達から入れる")
                } footer: {
                    Text("入れた友達にはお知らせが届きます。友達はいつでも自分で抜けられます。")
                }
                if let message {
                    Section { NoticeText(text: message) }
                }
            }
            .navigationTitle("一緒に管理する人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let api = session.api, let me = session.userID else { return }
        managers = (try? await api.gateManagers(gateID)) ?? []
        friends = (try? await api.friends(me: me)) ?? []
        loaded = true
    }

    private func add(_ user: UUID) async {
        guard let api = session.api else { return }
        working = user
        defer { working = nil }
        do {
            try await api.addGateManager(gateID, user: user)
            Haptics.success()
            message = nil
            await load()
            onChanged()
        } catch {
            message = ErrorText.isMissingFunction(error)
                ? "一緒に管理する人は、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
    }

    private func remove(_ user: UUID) async {
        guard let api = session.api else { return }
        working = user
        defer { working = nil }
        do {
            try await api.removeGateManager(gateID, user: user)
            message = nil
            await load()
            onChanged()
        } catch {
            message = ErrorText.of(error)
        }
    }
}

// MARK: - カードを直す

/// 自分のカードを直す：ひとこと・見せる範囲・「この GATE の中だけ」。文を変えると「直しました」と出る
struct GraffitiEditSheet: View {
    let item: Graffiti
    let onSaved: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var visibility: Visibility
    @State private var localOnly: Bool
    @State private var saving = false
    @State private var message: String?

    private static let limit = 280

    init(item: Graffiti, onSaved: @escaping () -> Void) {
        self.item = item
        self.onSaved = onSaved
        _text = State(initialValue: item.body)
        _visibility = State(initialValue: Visibility(rawValue: item.visibility) ?? .friends)
        _localOnly = State(initialValue: item.local_only)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool {
        trimmed != item.body || visibility.rawValue != item.visibility || localOnly != item.local_only
    }

    var body: some View {
        NavigationStack {
            Form {
                if let path = item.photo_path {
                    Section {
                        RemotePhoto(path: path)
                            .frame(height: 160)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    } footer: {
                        Text("写真は変えられません（その日に撮った写真のため）。")
                    }
                }
                Section {
                    TextField("ひとこと", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: text) { _, v in if v.count > Self.limit { text = String(v.prefix(Self.limit)) } }
                } header: {
                    Text("ひとこと")
                } footer: {
                    Text("\(text.count) / \(Self.limit)・文を変えると、カードに「直しました」と出ます。")
                }
                Section {
                    Picker("見せる範囲", selection: $visibility) {
                        ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
                    }
                    Toggle("この GATE の中だけで見せる", isOn: $localOnly)
                        .tint(Theme.accent)
                } footer: {
                    Text(localOnly ? "友達の新着・カード図鑑には出ません。GATE に入った人だけが見られます。"
                                   : "GATE の中と、友達の新着（24 時間）に出ます。")
                }
                if let message {
                    Section { NoticeText(text: message) }
                }
            }
            .navigationTitle("カードを直す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("保存") { Task { await save() } }
                            .disabled(!changed || (trimmed.isEmpty && item.photo_path == nil))
                    }
                }
            }
        }
    }

    private func save() async {
        guard let api = session.api else { return }
        saving = true
        defer { saving = false }
        do {
            try await api.editGraffiti(item.id, body: trimmed, visibility: visibility, localOnly: localOnly)
            Trace.log("カード：直した（文\(trimmed == item.body ? "そのまま" : "を変えた")・\(visibility.rawValue)）")
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            message = ErrorText.isMissingFunction(error)
                ? "カードを直すのは、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
    }
}


/// 表紙の向きを直す（グラフィティボードの表紙の「向きを直す」から。作った人・一緒に管理する人）
struct CoverRotateSheet: View {
    let summary: GateSummary
    let onSaved: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var original: UIImage?
    @State private var turns = 0
    @State private var saving = false
    @State private var message: String?

    private var shown: UIImage? {
        guard var image = original else { return nil }
        for _ in 0..<((turns % 4 + 4) % 4) { image = image.rotatedRight() }
        return image
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Group {
                    if let shown {
                        Image(uiImage: shown).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 260)
                    }
                }
                .frame(maxHeight: 380)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: turns)
                HStack(spacing: 14) {
                    Button {
                        turns -= 1
                        Haptics.tap()
                    } label: {
                        Label("左に回す", systemImage: "rotate.left")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button {
                        turns += 1
                        Haptics.tap()
                    } label: {
                        Label("右に回す", systemImage: "rotate.right")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .disabled(original == nil)
                Button {
                    Task { await save() }
                } label: {
                    if saving { ProgressView().tint(.white) } else { Text("この向きで保存") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(saving || original == nil || (turns % 4 + 4) % 4 == 0)
                if let message { NoticeText(text: message) }
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("表紙の向きを直す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }
                }
            }
            .task {
                if let path = summary.cover_path { original = await session.media?.photo(path: path) }
                if original == nil { message = "表紙を読めませんでした。少し待ってから、もう一度開いてください。" }
            }
        }
    }

    private func save() async {
        guard let api = session.api, let media = session.media, let me = session.userID, let image = shown else { return }
        saving = true
        defer { saving = false }
        var uploaded: String?
        do {
            uploaded = try await media.uploadPhoto(image, owner: me)
            let old = try await api.editGate(summary.id, title: summary.title, note: summary.note,
                                             coverPath: uploaded, visibility: nil)
            if let old, old.hasPrefix(me.uuidString.lowercased() + "/") {
                await media.removePhoto(path: old)
            }
            Trace.log("表紙の向きを直した（右に \((turns % 4 + 4) % 4) 回）")
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            if let uploaded { await media.removePhoto(path: uploaded) }
            Trace.log("表紙の向きを直せませんでした：\(ErrorText.of(error))")
            message = ErrorText.isMissingFunction(error)
                ? "表紙を直すのは、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
    }
}

extension UIImage {
    /// 右に 90° 回した絵
    func rotatedRight() -> UIImage {
        let source = size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: source.height, height: source.width), format: format).image { ctx in
            let c = ctx.cgContext
            c.translateBy(x: source.height, y: 0)
            c.rotate(by: .pi / 2)
            draw(in: CGRect(origin: .zero, size: source))
        }
    }
}
