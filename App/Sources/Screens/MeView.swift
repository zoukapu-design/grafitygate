import SwiftUI

/// わたし：プロフィール（名前・ID・3 つの数）、友達を足す、自分の GATE、自分の記録、安全とデータ。
struct MeView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var nav: AppNavigator
    @State private var gates: [MyGate] = []
    @State private var visitedCount: Int?
    @State private var friendCount: Int?
    @State private var unopenedLetters = 0
    @State private var message: (text: String, isError: Bool)?
    @State private var editingName = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "わたし") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ProfileHeader(name: session.profile?.display_name ?? "",
                                      handle: session.profile?.handle,
                                      gateCount: loaded ? gates.count : nil,
                                      visitedCount: visitedCount,
                                      friendCount: friendCount,
                                      onEditName: { editingName = true })
                        AddFriendButtons()
                        myGatesStrip
                        MeGroup(title: "わたしの記録") {
                            MeLink(title: "図鑑（訪れた GATE）", systemImage: "books.vertical") { CollectionView(kind: "visited") }
                            MeLink(title: "保存", systemImage: "bookmark") { CollectionView(kind: "saved") }
                            MeLink(title: "思い出", systemImage: "photo.stack") { MyMemoriesView() }
                            MeLink(title: "手紙", systemImage: "envelope",
                                   detail: unopenedLetters > 0 ? "未開封 \(unopenedLetters)" : nil) { MyLettersView() }
                            MeLink(title: "友達・フォロー", systemImage: "person.2",
                                   detail: friendCount.map { "\($0) 人" }) { FriendsView() }
                        }
                        MeGroup(title: "安全とデータ") {
                            MeLink(title: "ブロックした人", systemImage: "hand.raised") { BlockedView() }
                            MeLink(title: "自分のデータ（書き出し・アカウントの削除）", systemImage: "externaldrive") { MyDataView() }
                            MeLink(title: "利用規約", systemImage: "doc.plaintext") { LegalDocumentView(document: .terms) }
                            MeLink(title: "プライバシーポリシー", systemImage: "hand.raised.square") { LegalDocumentView(document: .privacy) }
                            ShareLink(item: Trace.fileURL) {
                                MeRow(title: "調べものの記録を送る", systemImage: "doc.text.magnifyingglass", detail: nil)
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 14)
                            }
                        }
                        if let message {
                            NoticeText(text: message.text, isError: message.isError)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Grafity Gate \(appVersion)")
                                .font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                            Text("「調べものの記録」は、AR で何が起きたかの記録です（位置や写真は入っていません）。うまく動かないとき、開発者に送ってください。")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
                .refreshable { await load() }
            }
            .task(id: session.state) { await load() }
            .sheet(isPresented: $editingName) {
                NameEditSheet(current: session.profile?.display_name ?? "") { newName in
                    try await session.rename(newName)
                    message = ("名前を保存しました。", false)
                }
            }
        }
    }

    /// 自分の GATE（表紙を横に並べる）。まだ無いときは作る入口
    @ViewBuilder private var myGatesStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自分の GATE").font(.headline).foregroundStyle(Theme.text)
                Spacer()
                if !gates.isEmpty {
                    NavigationLink("すべて") { MyGatesView(gates: gates) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            if gates.isEmpty && loaded {
                Button {
                    nav.tab = .capture
                } label: {
                    HStack(spacing: 12) {
                        GateMark(size: 46, glowing: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("最初の GATE を作る").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            Text("思い出の場所や物に、記憶の扉を置きます").font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(gates.prefix(12)) { gate in
                            NavigationLink {
                                GateDetailView(gateID: gate.id)
                            } label: {
                                GateCoverTile(title: gate.title, coverPath: gate.cover_path,
                                              caption: ServerDate.relative(gate.created_at))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(v)（\(b)）"
    }

    private func load() async {
        guard let api = session.api, let me = session.userID else { return }
        do {
            gates = try await api.myGates(owner: me)
            message = nil
        } catch {
            message = (ErrorText.of(error), true)
        }
        friendCount = try? await api.friends(me: me).count
        visitedCount = try? await api.collection("visited").count
        unopenedLetters = (try? await api.letters())?.filter { !$0.sent && !$0.isOpened }.count ?? 0
        loaded = true
    }
}

/// プロフィールの上の段：ネオンの輪の顔、名前（押すと直す）、ID、3 つの数
struct ProfileHeader: View {
    let name: String
    let handle: String?
    let gateCount: Int?
    let visitedCount: Int?
    let friendCount: Int?
    var onEditName: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                NeonAvatar(name: name, size: 76)
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        onEditName?()
                    } label: {
                        HStack(spacing: 6) {
                            Text(name.isEmpty ? "ゲスト" : name)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            if onEditName != nil {
                                Image(systemName: "pencil").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(onEditName == nil)
                    .accessibilityLabel(onEditName == nil ? name : "名前を直す")
                    if let handle {
                        Text("ID：\(handle)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                stat(gateCount, "作った GATE")
                divider
                stat(visitedCount, "訪れた")
                divider
                stat(friendCount, "友達")
            }
            .padding(.vertical, 12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
        }
        .padding(.top, 4)
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 30)
    }

    private func stat(_ value: Int?, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.map(String.init) ?? "–")
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.text)
                .contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// 顔の印：名前の頭文字に、アイコンと同じネオンの輪
struct NeonAvatar: View {
    let name: String
    var size: CGFloat = 60

    var body: some View {
        Text(String((name.isEmpty ? "ゲ" : name).prefix(1)))
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.accentLight, in: Circle())
            .overlay(
                Circle().strokeBorder(AngularGradient(colors: Brand.neonOnLight + [Brand.neonOnLight[0]], center: .center),
                                      lineWidth: size * 0.05)
            )
            .accessibilityHidden(true)
    }
}

/// GATE の表紙の小さなカード（表紙が無いときは、夜空の色にしるし）
struct GateCoverTile: View {
    let title: String
    let coverPath: String?
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GateCoverImage(path: coverPath, markSize: 40)
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Text(caption).font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .frame(width: 132)
    }
}

/// 白いカードにまとめた行の集まり（見出しつき）
struct MeGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(Theme.text)
            VStack(spacing: 0) {
                _VariadicView.Tree(DividedRows()) { content() }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
        }
    }
}

/// 行と行のあいだに、うすい線を入れる
private struct DividedRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 48)
            }
        }
    }
}

/// 押すと先の画面へ進む 1 行
struct MeLink<Destination: View>: View {
    let title: String
    let systemImage: String
    var detail: String? = nil
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                MeRow(title: title, systemImage: systemImage, detail: detail)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 名前を直す
struct NameEditSheet: View {
    let current: String
    let save: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("友達に見える名前", text: $name)
                    .focused($focused)
                    .font(.title3)
                    .padding(14)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                    .onChange(of: name) { _, value in
                        if value.count > 30 { name = String(value.prefix(30)) }
                    }
                Text("30 文字まで。友達のホームや GATE の記憶に、この名前で出ます。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                if let error { NoticeText(text: error) }
                Spacer()
            }
            .padding(20)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("名前")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            saving = true
                            defer { saving = false }
                            do {
                                try await save(name.trimmingCharacters(in: .whitespacesAndNewlines))
                                dismiss()
                            } catch {
                                self.error = ErrorText.of(error)
                            }
                        }
                    }
                    .bold()
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                name = current
                focused = true
            }
        }
        .presentationDetents([.medium])
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
                            GateCoverImage(path: gate.cover_path, markSize: 28)
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
