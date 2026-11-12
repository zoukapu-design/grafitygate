import SwiftUI

/// 通報するもの（シートを開くための印）
struct ReportItem: Identifiable {
    let id: UUID
    let target: ReportTarget
    /// だれのものか（ブロックも一緒にできるように）
    var userID: UUID?
    var userName: String?
    var label: String
}

/// 通報のシート：理由を選ぶ → ひとこと（なくてよい）→ 送る。だれのものかが分かれば、ブロックも一緒にできる。
struct ReportSheet: View {
    let item: ReportItem
    var onBlocked: (() -> Void)?

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason?
    @State private var note = ""
    @State private var alsoBlock = false
    @State private var sending = false
    @State private var message: String?
    @State private var done = false

    init(item: ReportItem, onBlocked: (() -> Void)? = nil) {
        self.item = item
        self.onBlocked = onBlocked
    }

    var body: some View {
        NavigationStack {
            Form {
                if done {
                    Section {
                        Label("通報を受け付けました。運営が確かめます。", systemImage: "checkmark.circle")
                            .foregroundStyle(Theme.accent)
                        if alsoBlock, let name = item.userName {
                            Text("\(name) さんをブロックしました。おたがいの GATE や記録が見えなくなります。")
                                .font(.subheadline).foregroundStyle(Theme.textSecondary)
                        }
                    }
                } else {
                    Section {
                        ForEach(ReportReason.allCases) { r in
                            Button {
                                reason = r
                            } label: {
                                HStack {
                                    Text(r.label).foregroundStyle(Theme.text)
                                    Spacer()
                                    if reason == r {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("「\(item.label)」を通報する理由")
                    }
                    Section("ひとこと（なくても大丈夫）") {
                        TextField("どこが問題か", text: $note, axis: .vertical)
                            .lineLimit(2...5)
                    }
                    if let name = item.userName, item.userID != nil, item.userID != session.userID {
                        Section {
                            Toggle("\(name) さんをブロックする", isOn: $alsoBlock)
                                .tint(Theme.alert)
                        } footer: {
                            Text("ブロックすると、おたがいの GATE・記録・手紙が見えなくなります。あとで「わたし」→「ブロックした人」から戻せます。")
                        }
                    }
                    if let message {
                        Section { NoticeText(text: message) }
                    }
                }
            }
            .navigationTitle("通報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(done ? "閉じる" : "やめる") { dismiss() }
                }
                if !done {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await send() }
                        } label: {
                            if sending { ProgressView() } else { Text("送る").bold() }
                        }
                        .disabled(reason == nil || sending)
                    }
                }
            }
        }
    }

    private func send() async {
        guard let api = session.api, let reason else { return }
        sending = true
        defer { sending = false }
        do {
            try await api.report(item.target, id: item.id, reason: reason,
                                 note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            if alsoBlock, let user = item.userID {
                try await api.block(user)
                onBlocked?()
            }
            Trace.log("通報しました（\(item.target.rawValue)\(alsoBlock ? "・ブロックも" : "")）")
            done = true
            Haptics.success()
        } catch {
            message = ErrorText.of(error)
        }
    }
}

/// お互いにフォローしている友達から選ぶ（1 人か、何人か）
struct FriendPicker: View {
    let title: String
    let multiple: Bool
    @Binding var selection: Set<UUID>

    @EnvironmentObject private var session: SessionModel
    @State private var friends: [ProfileRow] = []
    @State private var loaded = false
    @State private var error: String?

    init(title: String, multiple: Bool, selection: Binding<Set<UUID>>) {
        self.title = title
        self.multiple = multiple
        _selection = selection
    }

    var body: some View {
        List {
            if let error {
                NoticeText(text: error)
            }
            if loaded && friends.isEmpty {
                Text("まだ友達がいません。「わたし」で友達の ID を探してフォローし、相手にもフォローしてもらうと「友達」になります。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            ForEach(friends, id: \.id) { friend in
                Button {
                    toggle(friend.id)
                } label: {
                    HStack {
                        PersonBadge(name: friend.display_name)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(friend.display_name).foregroundStyle(Theme.text)
                            Text("@\(friend.handle)").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if selection.contains(friend.id) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        } else {
                            Image(systemName: "circle").foregroundStyle(Theme.line)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let api = session.api, let me = session.userID else { return }
            do {
                friends = try await api.friends(me: me)
            } catch {
                self.error = ErrorText.of(error)
            }
            loaded = true
        }
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            if !multiple { selection.removeAll() }
            selection.insert(id)
        }
    }
}

/// 名前の頭文字の丸（顔写真の代わり）
struct PersonBadge: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        Text(String(name.prefix(1)))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.accentLight, in: Circle())
    }
}
