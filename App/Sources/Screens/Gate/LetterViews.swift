import PhotosUI
import SwiftUI

/// 手紙・タイムカプセル：未来の自分や友達へ。開く条件（日時・現地）がそろうまで、「手紙がある」ことだけが分かる。
struct LetterSection: View {
    let context: GateContext
    let refreshToken: Int

    @EnvironmentObject private var session: SessionModel
    @State private var letters: [LetterInfo] = []
    @State private var error: String?
    @State private var showComposer = false

    init(context: GateContext, refreshToken: Int) {
        self.context = context
        self.refreshToken = refreshToken
    }

    private var received: [LetterInfo] { letters.filter { !$0.sent } }
    private var sent: [LetterInfo] { letters.filter(\.sent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if context.isInside {
                Button {
                    showComposer = true
                } label: {
                    Label("手紙を書く", systemImage: "envelope.badge")
                }
                .buttonStyle(SecondaryButtonStyle())
                Text("未来の自分や友達へ。開く日を決めたり、ここに来たときだけ開けるようにしたりできます。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            } else if letters.isEmpty {
                Text("手紙は、現地で扉を開けると書けます。あなたあての手紙がここにあれば、ここに出ます。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            if let error { NoticeText(text: error) }
            if !received.isEmpty {
                Text("あなたあて").font(.headline).foregroundStyle(Theme.text).padding(.top, 4)
                ForEach(received) { letter in
                    LetterRow(letter: letter, context: context) { Task { await load() } }
                }
            }
            if !sent.isEmpty {
                Text("あなたが書いた手紙").font(.headline).foregroundStyle(Theme.text).padding(.top, 4)
                ForEach(sent) { letter in
                    LetterRow(letter: letter, context: context) { Task { await load() } }
                }
            }
        }
        .task(id: "\(context.isInside)-\(refreshToken)") { await load() }
        .sheet(isPresented: $showComposer) {
            LetterComposer(context: context) { Task { await load() } }
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            letters = try await api.letters(at: context.gateID)
            error = nil
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}

/// 手紙の 1 行（開けるなら押すと開く）
struct LetterRow: View {
    let letter: LetterInfo
    var context: GateContext?
    var showsGate = false
    let onChanged: () -> Void

    @EnvironmentObject private var session: SessionModel
    @State private var confirmDelete = false
    @State private var message: String?

    init(letter: LetterInfo, context: GateContext?, showsGate: Bool = false, onChanged: @escaping () -> Void) {
        self.letter = letter
        self.context = context
        self.showsGate = showsGate
        self.onChanged = onChanged
    }

    private var title: String {
        if letter.isToSelf { return "未来の自分へ" }
        return letter.sent ? "\(letter.recipient_name) さんへ" : "\(letter.author_name) さんから"
    }

    private var status: String {
        if letter.sent {
            return letter.isOpened ? "開かれました" : "まだ開かれていません"
        }
        if letter.isOpened { return "開封済み" }
        return letter.lockReason ?? "いま開けます"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if canRead {
                NavigationLink {
                    LetterView(info: letter) { onChanged() }
                } label: {
                    row
                }
                .buttonStyle(.plain)
            } else {
                row
            }
            if let message { NoticeText(text: message) }
        }
        .confirmationDialog("この手紙を消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("消す", role: .destructive) { Task { await delete() } }
        }
    }

    /// 書いた人はいつでも読める（自分あてのタイムカプセルは開く日まで）。宛先の人は開けるときだけ
    private var canRead: Bool {
        if letter.sent { return true }
        return letter.canOpenNow
    }

    private var row: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(letter.isOpened || letter.sent ? Theme.surfaceElevated : Theme.accentLight)
                Image(systemName: letter.isOpened ? "envelope.open" : (canRead ? "envelope.badge" : "envelope"))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(canRead && !letter.isOpened && !letter.sent ? Theme.accent : Theme.textSecondary)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text(status).font(.caption).foregroundStyle(canRead && !letter.sent && !letter.isOpened ? Theme.accent : Theme.textSecondary)
                if showsGate {
                    Label(letter.gate_title, systemImage: "door.left.hand.open")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if canDelete {
                Menu {
                    Button("消す", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.textSecondary).frame(width: 30, height: 30)
                }
            } else if canRead {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }

    private var canDelete: Bool {
        if letter.sent { return !letter.isOpened }
        return letter.isOpened
    }

    private func delete() async {
        guard let api = session.api else { return }
        do {
            try await api.deleteLetter(letter.id)
            onChanged()
        } catch {
            message = ErrorText.of(error)
        }
    }
}

/// 手紙を開く（はじめて開くときは、封筒が開いて中身が出てくる）
struct LetterView: View {
    let info: LetterInfo
    let onOpened: () -> Void

    @EnvironmentObject private var session: SessionModel
    @State private var content: LetterContent?
    @State private var error: String?
    @State private var revealed = false
    @State private var report: ReportItem?

    init(info: LetterInfo, onOpened: @escaping () -> Void) {
        self.info = info
        self.onOpened = onOpened
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let content {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(info.isToSelf ? "未来の自分へ" : "\(content.recipient_name) さんへ")
                            .font(.headline).foregroundStyle(Theme.text)
                        if let path = content.photo_path {
                            RemotePhoto(path: path)
                                .frame(height: 240)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        Text(content.body)
                            .font(.system(.body, design: .serif))
                            .foregroundStyle(Theme.text)
                            .lineSpacing(6)
                            .textSelection(.enabled)
                        HStack {
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(info.isToSelf ? "あの日の自分より" : "\(content.author_name) より")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                if let date = ServerDate.parse(content.created_at) {
                                    Text("\(ServerDate.day(date))・\(info.gate_title) で")
                                        .font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: 0xFFFDF7), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.warm.opacity(0.35)))
                    .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
                    .scaleEffect(revealed ? 1 : 0.92)
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 30)
                } else if let error {
                    NoticeText(text: error)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Theme.warm)
                            .symbolEffect(.pulse)
                        Text("手紙を開いています…").font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.top, 60)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("手紙")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if content != nil, !info.sent, !info.isToSelf {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            report = ReportItem(id: info.id, target: .letter, userID: info.author,
                                                userName: info.author_name, label: "手紙")
                        } label: {
                            Label("通報する", systemImage: "exclamationmark.bubble")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $report) { item in ReportSheet(item: item) }
        .task { await open() }
    }

    private func open() async {
        guard content == nil, let api = session.api else { return }
        let firstTime = !info.isOpened && !info.sent
        do {
            content = try await api.openLetter(info.id)
            if content == nil { error = "手紙が見つかりませんでした。" }
            if firstTime {
                Haptics.open()
                Trace.log("手紙を開きました")
                onOpened()
            }
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(firstTime ? 0.25 : 0)) {
                revealed = true
            }
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}

/// 手紙を書く：宛先（自分・友達）→ 本文と写真 → 開く条件（現地で・日時）
struct LetterComposer: View {
    let context: GateContext
    let onSent: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var toSelf = true
    @State private var friend: Set<UUID> = []
    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var onsite = true
    @State private var useDate = false
    @State private var openAt = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    @State private var sending = false
    @State private var message: String?

    init(context: GateContext, onSent: @escaping () -> Void) {
        self.context = context
        self.onSent = onSent
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (onsite || useDate) && (toSelf || !friend.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("宛先") {
                    Picker("宛先", selection: $toSelf) {
                        Text("未来の自分").tag(true)
                        Text("友達").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if !toSelf {
                        NavigationLink {
                            FriendPicker(title: "宛先の友達", multiple: false, selection: $friend)
                        } label: {
                            HStack {
                                Text("友達を選ぶ")
                                Spacer()
                                Text(friend.isEmpty ? "未選択" : "選びました").foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
                Section {
                    TextField(toSelf ? "いまの気持ち、未来の自分に伝えたいこと" : "伝えたいこと", text: $text, axis: .vertical)
                        .lineLimit(5...12)
                    if let photo {
                        HStack {
                            Image(uiImage: photo).resizable().scaledToFill()
                                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                            Spacer()
                            Button("写真を外す", role: .destructive) {
                                self.photo = nil
                                photoItem = nil
                            }
                        }
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(photo == nil ? "写真を入れる" : "写真を選び直す", systemImage: "photo")
                    }
                } header: {
                    Text("手紙")
                } footer: {
                    Text("\(text.count)/2000")
                }
                Section {
                    Toggle("ここに来たときだけ開ける", isOn: $onsite).tint(Theme.accent)
                    Toggle("開く日を決める", isOn: $useDate).tint(Theme.accent)
                    if useDate {
                        DatePicker("開く日", selection: $openAt,
                                   in: Date().addingTimeInterval(3600)...Date().addingTimeInterval(3600 * 24 * 365 * 10),
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                } header: {
                    Text("開く条件")
                } footer: {
                    Text(conditionText)
                }
                if let message {
                    Section { NoticeText(text: message) }
                }
            }
            .navigationTitle("手紙を書く")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await send() }
                    } label: {
                        if sending { ProgressView() } else { Text("封をする").bold() }
                    }
                    .disabled(!canSend || sending)
                }
            }
            .onChange(of: photoItem) { _, item in
                Task {
                    guard let item else { return }
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        photo = image.downscaled(maxSide: 1600)
                    }
                }
            }
            .onChange(of: text) { _, value in
                if value.count > 2000 { text = String(value.prefix(2000)) }
            }
        }
    }

    private var conditionText: String {
        switch (onsite, useDate) {
        case (true, true): return "\(ServerDate.day(openAt)) を過ぎてから、\(context.title) で扉を開けると読めます。"
        case (true, false): return "次に \(context.title) で扉を開けたときに読めます。"
        case (false, true): return "\(ServerDate.day(openAt)) を過ぎると、どこからでも読めます。"
        case (false, false): return "どちらか 1 つは選んでください。"
        }
    }

    private func send() async {
        guard let api = session.api, let visit = context.visit else {
            message = "入場の時間（20 分）が切れました。現地でもう一度入ってください。"
            return
        }
        sending = true
        defer { sending = false }
        var photoPath: String?
        do {
            if let photo, let media = session.media, let me = session.userID {
                photoPath = try await media.uploadPhoto(photo, owner: me)
            }
            _ = try await api.writeLetter(visit: visit, to: toSelf ? nil : friend.first,
                                          body: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                          photoPath: photoPath, openAt: useDate ? openAt : nil, onsite: onsite)
            Trace.log("手紙を書きました（\(toSelf ? "自分あて" : "友達あて")・現地：\(onsite)・日時：\(useDate)）")
            Haptics.success()
            onSent()
            dismiss()
        } catch {
            if let photoPath { await session.media?.removePhoto(path: photoPath) }
            message = ErrorText.of(error)
        }
    }
}
