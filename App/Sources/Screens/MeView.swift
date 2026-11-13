import SwiftUI

/// わたし：名前と ID、友達、自分の記録（GATE・図鑑・保存・思い出・手紙）、安全とデータ。
struct MeView: View {
    @EnvironmentObject private var session: SessionModel
    @State private var name = ""
    @State private var gates: [MyGate] = []
    @State private var friendCount = 0
    @State private var unopenedLetters = 0
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "わたし") {
                List {
                    Section {
                        HStack(spacing: 14) {
                            PersonBadge(name: name.isEmpty ? "ゲ" : name, size: 54)
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("表示する名前", text: $name)
                                    .font(.headline)
                                    .onSubmit { Task { await rename() } }
                                if let profile = session.profile {
                                    Text("ID：\(profile.handle)")
                                        .font(.caption).foregroundStyle(Theme.textSecondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        if name.trimmingCharacters(in: .whitespaces) != (session.profile?.display_name ?? "") {
                            Button("名前を保存") { Task { await rename() } }
                                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        AddFriendButtons()
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
                            .listRowBackground(Color.clear)
                    } footer: {
                        Text("QR を見せるか ID を送ると、友達がフォローできます。お互いにフォローすると「友達」です。")
                    }

                    Section("友達") {
                        NavigationLink {
                            FriendsView()
                        } label: {
                            MeRow(title: "友達・フォロー", systemImage: "person.2", detail: friendCount > 0 ? "\(friendCount) 人" : nil)
                        }
                    }

                    Section("わたしの記録") {
                        NavigationLink {
                            MyGatesView(gates: gates)
                        } label: {
                            MeRow(title: "自分の GATE", systemImage: "door.left.hand.open", detail: "\(gates.count)")
                        }
                        NavigationLink {
                            CollectionView(kind: "visited")
                        } label: {
                            MeRow(title: "図鑑（訪れた GATE）", systemImage: "books.vertical", detail: nil)
                        }
                        NavigationLink {
                            CollectionView(kind: "saved")
                        } label: {
                            MeRow(title: "保存", systemImage: "bookmark", detail: nil)
                        }
                        NavigationLink {
                            MyMemoriesView()
                        } label: {
                            MeRow(title: "思い出", systemImage: "photo.stack", detail: nil)
                        }
                        NavigationLink {
                            MyLettersView()
                        } label: {
                            MeRow(title: "手紙", systemImage: "envelope",
                                  detail: unopenedLetters > 0 ? "未開封 \(unopenedLetters)" : nil)
                        }
                    }

                    Section("安全とデータ") {
                        NavigationLink {
                            BlockedView()
                        } label: {
                            MeRow(title: "ブロックした人", systemImage: "hand.raised", detail: nil)
                        }
                        NavigationLink {
                            MyDataView()
                        } label: {
                            MeRow(title: "自分のデータ（書き出し・アカウントの削除）", systemImage: "externaldrive", detail: nil)
                        }
                        ShareLink(item: Trace.fileURL) {
                            MeRow(title: "調べものの記録を送る", systemImage: "doc.text.magnifyingglass", detail: nil)
                        }
                    }

                    if let message {
                        NoticeText(text: message.text, isError: message.isError)
                    }

                    Section {
                        Text("Grafity Gate \(appVersion)")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    } footer: {
                        Text("「調べものの記録」は、AR で何が起きたかの記録です（位置や写真は入っていません）。うまく動かないとき、開発者に送ってください。")
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
            .task(id: session.state) { await load() }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(v)（\(b)）"
    }

    private func load() async {
        name = session.profile?.display_name ?? ""
        guard let api = session.api, let me = session.userID else { return }
        do {
            gates = try await api.myGates(owner: me)
            friendCount = (try? await api.friends(me: me).count) ?? 0
            unopenedLetters = (try? await api.letters())?.filter { !$0.sent && !$0.isOpened }.count ?? 0
        } catch {
            message = (ErrorText.of(error), true)
        }
    }

    private func rename() async {
        do {
            try await session.rename(name)
            message = ("名前を保存しました。", false)
        } catch {
            message = (ErrorText.of(error), true)
        }
    }
}

/// 「わたし」の 1 行
struct MeRow: View {
    let title: String
    let systemImage: String
    let detail: String?

    var body: some View {
        HStack {
            Label {
                Text(title).foregroundStyle(Theme.text)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Theme.accent)
            }
            Spacer()
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// 自分の GATE
struct MyGatesView: View {
    let gates: [MyGate]

    var body: some View {
        List {
            if gates.isEmpty {
                Text("まだありません。「撮る」→「ここに GATE を作る」から作れます。").foregroundStyle(Theme.textSecondary)
            }
            ForEach(gates) { gate in
                NavigationLink {
                    GateDetailView(gateID: gate.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gate.title).foregroundStyle(Theme.text)
                        Text("\(Visibility.label(of: gate.visibility))・\(ServerDate.relative(gate.created_at))")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("自分の GATE")
    }
}

/// 友達・フォロー：友達（お互い）、フォロー中、フォローされている人。ID で探してフォロー。
struct FriendsView: View {
    @EnvironmentObject private var session: SessionModel
    @State private var friends: [ProfileRow] = []
    @State private var followingOnly: [ProfileRow] = []
    @State private var followersOnly: [ProfileRow] = []
    @State private var handle = ""
    @State private var found: ProfileRow?
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        List {
            Section {
                AddFriendButtons()
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            } header: {
                Text("友達を足す")
            }
            Section {
                HStack {
                    TextField("友達の ID", text: $handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await search() } }
                    Button("探す") { Task { await search() } }
                        .disabled(handle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let found {
                    NavigationLink {
                        ProfileView(userID: found.id)
                    } label: {
                        PersonRow(profile: found)
                    }
                }
                if let message {
                    NoticeText(text: message.text, isError: message.isError)
                }
            } header: {
                Text("ID で探す")
            } footer: {
                Text("お互いにフォローすると「友達」になり、友達向けの GATE が見えるようになります。")
            }

            if !followersOnly.isEmpty {
                Section("あなたをフォローしている人（フォローを返すと友達）") {
                    ForEach(followersOnly, id: \.id) { p in
                        NavigationLink { ProfileView(userID: p.id) } label: { PersonRow(profile: p) }
                    }
                }
            }
            Section("友達（\(friends.count)）") {
                if friends.isEmpty {
                    Text("まだいません").foregroundStyle(Theme.textSecondary)
                }
                ForEach(friends, id: \.id) { p in
                    NavigationLink { ProfileView(userID: p.id) } label: { PersonRow(profile: p) }
                }
            }
            if !followingOnly.isEmpty {
                Section("フォロー中（相手のフォロー待ち）") {
                    ForEach(followingOnly, id: \.id) { p in
                        NavigationLink { ProfileView(userID: p.id) } label: { PersonRow(profile: p) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("友達・フォロー")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = session.api, let me = session.userID else { return }
        do {
            let r = try await api.relations(me: me)
            let mutual = r.following.intersection(r.followers)
            friends = try await api.profiles(Array(mutual))
            followingOnly = try await api.profiles(Array(r.following.subtracting(mutual)))
            followersOnly = try await api.profiles(Array(r.followers.subtracting(mutual)))
        } catch {
            message = (ErrorText.of(error), true)
        }
    }

    private func search() async {
        guard let api = session.api, let me = session.userID else { return }
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        do {
            found = try await api.findProfile(handle: h)
            if let f = found {
                message = f.id == me ? (text: "自分の ID です。", isError: true) : nil
            } else {
                message = ("その ID の人は見つかりませんでした。", true)
            }
        } catch {
            message = (ErrorText.of(error), true)
        }
    }
}

struct PersonRow: View {
    let profile: ProfileRow

    var body: some View {
        HStack(spacing: 12) {
            PersonBadge(name: profile.display_name)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.display_name).foregroundStyle(Theme.text)
                Text("@\(profile.handle)").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// 図鑑（訪れた GATE）と保存
struct CollectionView: View {
    /// visited（図鑑）／ saved（保存）
    let kind: String

    @EnvironmentObject private var session: SessionModel
    @State private var gates: [CollectionGate] = []
    @State private var loaded = false
    @State private var message: String?

    var body: some View {
        List {
            if kind == "visited" {
                Section {
                    Text("扉を開けた GATE が、ここに集まります。「友達に見せる」を入れたものだけ、友達があなたのプロフィールから見られます（場所はおおよそだけ）。")
                        .font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
            if loaded && gates.isEmpty {
                Text(kind == "visited" ? "まだありません。GATE の扉を開けると、ここに付きます。" : "まだありません。GATE の画面の右上で保存できます。")
                    .foregroundStyle(Theme.textSecondary)
            }
            if let message { NoticeText(text: message) }
            ForEach(gates) { gate in
                VStack(alignment: .leading, spacing: 8) {
                    NavigationLink {
                        GateDetailView(gateID: gate.gate_id)
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Theme.surfaceElevated
                                if let cover = gate.cover_path {
                                    RemotePhoto(path: cover)
                                } else {
                                    Image(systemName: "door.left.hand.open").foregroundStyle(Theme.textSecondary)
                                }
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(gate.title).foregroundStyle(Theme.text)
                                Text(kind == "visited" ? "\(gate.visits) 回・最後は\(gate.last_at.map(ServerDate.relative) ?? "")"
                                                       : "\(gate.owner_name)・保存 \(gate.saved_at.map(ServerDate.relative) ?? "")")
                                    .font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    if kind == "visited" {
                        Toggle("友達に見せる", isOn: Binding(get: { gate.shared },
                                                         set: { value in Task { await setShared(gate, value) } }))
                            .font(.subheadline)
                            .tint(Theme.accent)
                    }
                }
                .swipeActions {
                    if kind == "saved" {
                        Button("外す", role: .destructive) { Task { await unsave(gate) } }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(kind == "visited" ? "図鑑" : "保存")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            gates = try await api.collection(kind)
            message = nil
        } catch {
            message = ErrorText.of(error)
        }
        loaded = true
    }

    private func setShared(_ gate: CollectionGate, _ value: Bool) async {
        guard let api = session.api else { return }
        do {
            try await api.setAtlasShared(gate.gate_id, shared: value)
            await load()
        } catch {
            message = ErrorText.of(error)
        }
    }

    private func unsave(_ gate: CollectionGate) async {
        guard let api = session.api else { return }
        do {
            try await api.setBookmark(gate.gate_id, on: false)
            await load()
        } catch {
            message = ErrorText.of(error)
        }
    }
}

/// 自分が作った・仲間に入っている思い出
struct MyMemoriesView: View {
    @EnvironmentObject private var session: SessionModel
    @State private var memories: [MyMemory] = []
    @State private var loaded = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if loaded && memories.isEmpty {
                    Text("まだありません。GATE の扉を開けて「思い出」から作れます。")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                if let message { NoticeText(text: message) }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(memories) { memory in
                        NavigationLink {
                            GateDetailView(gateID: memory.gate_id, tab: .memories)
                        } label: {
                            MemoryTile(title: memory.title, subtitle: "\(memory.gate_title)・\(memory.item_count) 枚",
                                       cover: memory.cover_path)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("思い出")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            memories = try await api.myMemories()
            message = nil
        } catch {
            message = ErrorText.of(error)
        }
        loaded = true
    }
}

/// 手紙：自分あて（開ける・まだ閉じている）と、自分が書いた手紙
struct MyLettersView: View {
    @EnvironmentObject private var session: SessionModel
    @State private var letters: [LetterInfo] = []
    @State private var loaded = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if loaded && letters.isEmpty {
                    Text("まだありません。GATE の扉を開けて「手紙」から、未来の自分や友達に書けます。")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                if let message { NoticeText(text: message) }
                let received = letters.filter { !$0.sent }
                let sent = letters.filter(\.sent)
                if !received.isEmpty {
                    Text("あなたあて").font(.headline).foregroundStyle(Theme.text)
                    ForEach(received) { letter in
                        LetterRow(letter: letter, context: nil, showsGate: true) { Task { await load() } }
                    }
                }
                if !sent.isEmpty {
                    Text("あなたが書いた手紙").font(.headline).foregroundStyle(Theme.text).padding(.top, 6)
                    ForEach(sent) { letter in
                        LetterRow(letter: letter, context: nil, showsGate: true) { Task { await load() } }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("手紙")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            letters = try await api.letters()
            message = nil
        } catch {
            message = ErrorText.of(error)
        }
        loaded = true
    }
}

/// ブロックした人（ブロックをやめられる）
struct BlockedView: View {
    @EnvironmentObject private var session: SessionModel
    @State private var blocked: [BlockedUser] = []
    @State private var loaded = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                if loaded && blocked.isEmpty {
                    Text("ブロックした人はいません。").foregroundStyle(Theme.textSecondary)
                }
                ForEach(blocked) { user in
                    HStack {
                        PersonBadge(name: user.display_name)
                        VStack(alignment: .leading) {
                            Text(user.display_name)
                            Text("@\(user.handle)").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button("やめる") { Task { await unblock(user) } }
                            .buttonStyle(.bordered)
                    }
                }
            } footer: {
                Text("ブロックは Lyric Path と共通です。ブロックすると、おたがいの GATE・記録・手紙が見えなくなります。")
            }
            if let message { NoticeText(text: message) }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("ブロックした人")
        .task { await load() }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            blocked = try await api.blocks()
        } catch {
            message = ErrorText.of(error)
        }
        loaded = true
    }

    private func unblock(_ user: BlockedUser) async {
        guard let api = session.api else { return }
        do {
            try await api.unblock(user.user_id)
            await load()
        } catch {
            message = ErrorText.of(error)
        }
    }
}

/// 自分のデータ：書き出す（JSON）・アカウントを消す
struct MyDataView: View {
    @EnvironmentObject private var session: SessionModel
    @State private var exportURL: URL?
    @State private var working: String?
    @State private var message: (text: String, isError: Bool)?
    @State private var confirmDelete = false
    @State private var deleteWord = ""

    var body: some View {
        List {
            Section {
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("書き出したファイルを送る・保存する", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        Task { await export() }
                    } label: {
                        Label("自分のデータを書き出す", systemImage: "arrow.down.doc")
                    }
                    .disabled(working != nil)
                }
            } header: {
                Text("書き出し")
            } footer: {
                Text("自分が作った GATE（正確な位置も）・記憶・作品・掲示板・手紙・思い出・保存・図鑑を、1 つのファイル（JSON）にします。写真そのものは入りません。")
            }

            Section {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("アカウントとデータを消す", systemImage: "trash")
                }
                .disabled(working != nil)
            } header: {
                Text("アカウントの削除")
            } footer: {
                Text("GATE・記憶・作品・写真・場所の記憶・手紙・思い出など、Grafity Gate のあなたのデータをすべて消します。元に戻せません。")
            }

            if let working {
                Section { HStack { ProgressView(); Text(working).foregroundStyle(Theme.textSecondary) } }
            }
            if let message {
                Section { NoticeText(text: message.text, isError: message.isError) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("自分のデータ")
        .alert("本当に消しますか？", isPresented: $confirmDelete) {
            TextField("「消す」と入れてください", text: $deleteWord)
            Button("消す", role: .destructive) {
                if deleteWord.trimmingCharacters(in: .whitespaces) == "消す" {
                    Task { await deleteAccount() }
                } else {
                    message = ("「消す」と入れると消せます。", true)
                }
                deleteWord = ""
            }
            Button("やめる", role: .cancel) { deleteWord = "" }
        } message: {
            Text("あなたの GATE や記録はすべて消え、元に戻せません。")
        }
    }

    private func export() async {
        guard let api = session.api else { return }
        working = "書き出しています…"
        defer { working = nil }
        do {
            let raw = try await api.exportMe()
            let object = try JSONSerialization.jsonObject(with: raw)
            let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("grafitygate-data.json")
            try pretty.write(to: url, options: .atomic)
            exportURL = url
            Trace.log("自分のデータを書き出しました（\(pretty.count / 1024)KB）")
        } catch {
            message = (ErrorText.of(error), true)
        }
    }

    private func deleteAccount() async {
        guard let api = session.api, let media = session.media, let me = session.userID else { return }
        working = "写真と場所の記憶を消しています…"
        defer { working = nil }
        do {
            await media.removeEverything(owner: me)
            working = "アカウントを消しています…"
            try await api.deleteMe()
            Trace.log("アカウントを消しました")
            await session.restartAfterDeletion()
            message = ("消しました。新しいアカウントで始め直しました。", false)
        } catch {
            message = (ErrorText.of(error), true)
        }
    }
}
