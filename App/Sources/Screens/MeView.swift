import SwiftUI

/// わたし：名前、友達を追加、自分の GATE。
struct MeView: View {
    @EnvironmentObject private var session: SessionModel
    @State private var name = ""
    @State private var gates: [MyGate] = []
    @State private var friendHandle = ""
    @State private var found: ProfileRow?
    @State private var followed = false
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        NavigationStack {
            ScreenScaffold(title: "わたし") {
                List {
                    Section("名前") {
                        TextField("表示する名前", text: $name)
                            .onSubmit { Task { await rename() } }
                        if let profile = session.profile {
                            Text("友達に教える ID：\(profile.handle)")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                        }
                        Button("名前を保存") { Task { await rename() } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Section {
                        TextField("友達の ID", text: $friendHandle)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit { Task { await search() } }
                        Button("探す") { Task { await search() } }
                            .disabled(friendHandle.trimmingCharacters(in: .whitespaces).isEmpty)
                        if let found {
                            HStack {
                                Text(found.display_name)
                                Spacer()
                                if followed {
                                    Text("フォロー中").foregroundStyle(Theme.textSecondary)
                                } else {
                                    Button("フォローする") { Task { await follow(found) } }
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    } header: {
                        Text("友達を追加")
                    } footer: {
                        Text("お互いにフォローすると「友達」になり、友達向けの GATE が見えるようになります。")
                    }

                    Section("自分の GATE") {
                        if gates.isEmpty {
                            Text("まだありません。「撮る」から作れます。").foregroundStyle(Theme.textSecondary)
                        }
                        ForEach(gates) { gate in
                            NavigationLink(value: GateRoute(id: gate.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(gate.title)
                                    Text("\(Visibility.label(of: gate.visibility))・\(ServerDate.relative(gate.created_at))")
                                        .font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                    }

                    if let message {
                        NoticeText(text: message.text, isError: message.isError)
                    }

                    Section {
                        ShareLink(item: Trace.fileURL) {
                            Label("調べものの記録を送る", systemImage: "doc.text.magnifyingglass")
                        }
                        Text("AR で何が起きたかの記録です（位置や写真は入っていません）。うまく動かないとき、開発者に送ってください。")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }

                    Section {
                        Text("GRAFITYGATE \(appVersion)")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
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

    private func search() async {
        guard let api = session.api, let me = session.userID else { return }
        let handle = friendHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            found = try await api.findProfile(handle: handle)
            if let f = found {
                followed = try await api.isFollowing(f.id, me: me)
                message = f.id == me ? (text: "自分の ID です。", isError: true) : nil
            } else {
                message = ("その ID の人は見つかりませんでした。", true)
            }
        } catch {
            message = (ErrorText.of(error), true)
        }
    }

    private func follow(_ target: ProfileRow) async {
        guard let api = session.api, let me = session.userID, target.id != me else { return }
        do {
            try await api.follow(target.id, me: me)
            followed = true
            message = ("\(target.display_name) さんをフォローしました。", false)
        } catch {
            message = (ErrorText.of(error), true)
        }
    }
}
