import SwiftUI

/// GATE の画面。入る前は概要だけ。現地で入ると（20 分）、中のグラフィティを読み、1 枚書ける。
struct GateDetailView: View {
    let gateID: UUID

    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var location: LocationModel
    @State private var summary: GateSummary?
    @State private var graffiti: [Graffiti] = []
    @State private var names: [UUID: String] = [:]
    @State private var loadError: String?
    @State private var loaded = false

    @State private var showCamera = false
    @State private var entering = false
    @State private var enterMessage: String?

    @State private var draft = ""
    @State private var draftVisibility: Visibility = .friends
    @State private var draftLocalOnly = false
    @State private var posting = false
    @State private var postMessage: (text: String, isError: Bool)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary {
                    header(summary)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let expires = summary.visitExpiresAt, expires > context.date {
                            inside(summary, expires: expires, now: context.date)
                        } else {
                            outside(summary)
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
        .task { await reload() }
        .refreshable { await reload() }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                Task { await enter(with: image) }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: 表紙

    private func header(_ s: GateSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(s.title).font(.title2.weight(.semibold)).foregroundStyle(Theme.text)
                if !s.note.isEmpty {
                    Text(s.note).font(.body).foregroundStyle(Theme.text)
                }
                HStack(spacing: 12) {
                    Label(s.owner_name, systemImage: "person")
                    Label("\(s.graffiti_count) 枚", systemImage: "square.stack")
                    Label(Visibility.label(of: s.visibility), systemImage: "eye")
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: 入る前

    private func outside(_ s: GateSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("中の記録は、現地で入ると見られます。")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            if let problem = location.fixProblem {
                NoticeText(text: problem)
            }
            if CameraPicker.isAvailable {
                Button {
                    enterMessage = nil
                    showCamera = true
                } label: {
                    if entering {
                        ProgressView().tint(.white)
                    } else {
                        Label("現地で写して入る", systemImage: "camera.viewfinder")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(entering || location.usableFix == nil || session.api == nil)
            } else {
                CameraUnavailableNote()
            }
            Text("作った人が写した場所・物を、正面から写してください。位置（120m 以内）と写真の両方が合うと、20 分入れます。")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            if let enterMessage {
                NoticeText(text: enterMessage)
            }
            mine
        }
    }

    // MARK: 入場中

    private func inside(_ s: GateSummary, expires: Date, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            let minutes = max(1, Int(expires.timeIntervalSince(now) / 60 + 0.5))
            Label("入場中・あと約 \(minutes) 分", systemImage: "door.left.hand.open")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)

            composer(visit: s.my_visit)

            Text("みんなの記憶").font(.headline).foregroundStyle(Theme.text)
            if graffiti.isEmpty {
                Text("まだ記録はありません。最初の 1 枚を残せます。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            ForEach(graffiti) { item in
                GraffitiCard(item: item, author: names[item.author] ?? "",
                             isMine: item.author == session.userID) {
                    Task { await delete(item) }
                }
            }
        }
    }

    /// 入場していなくても、自分のグラフィティは見られる
    @ViewBuilder private var mine: some View {
        let own = graffiti.filter { $0.author == session.userID }
        if !own.isEmpty {
            Text("ここに残した自分の記録").font(.headline).foregroundStyle(Theme.text).padding(.top, 8)
            ForEach(own) { item in
                GraffitiCard(item: item, author: names[item.author] ?? "", isMine: true) {
                    Task { await delete(item) }
                }
            }
        }
    }

    private func composer(visit: UUID?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("ここに 1 枚残す").font(.headline).foregroundStyle(Theme.text)
                TextField("この場所の思い出・ひとこと", text: $draft, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(12)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                Picker("見せる人", selection: $draftVisibility) {
                    ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
                }
                .pickerStyle(.segmented)
                Toggle("現地だけで見せる（友達の新着に出さない）", isOn: $draftLocalOnly)
                    .font(.subheadline)
                    .tint(Theme.accent)
                Button {
                    Task { await post(visit: visit) }
                } label: {
                    if posting { ProgressView().tint(.white) } else { Text("残す") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(posting || visit == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("1 回の入場で 1 枚。同じ GATE には 12 時間あけると、また書けます。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                if let postMessage {
                    NoticeText(text: postMessage.text, isError: postMessage.isError)
                }
            }
        }
    }

    // MARK: 動き

    private func reload() async {
        guard let api = session.api else { return }
        do {
            summary = try await api.summary(gateID)
            graffiti = try await api.graffiti(in: gateID)
            names = try await api.names(of: Array(Set(graffiti.map(\.author))))
            loadError = nil
        } catch {
            loadError = ErrorText.of(error)
        }
        loaded = true
    }

    private func enter(with image: UIImage) async {
        guard let api = session.api else { return }
        guard let fix = location.usableFix else {
            enterMessage = location.fixProblem
            return
        }
        entering = true
        defer { entering = false }
        do {
            let print = try await makePrint(from: image)
            let result = try await api.enter(gate: gateID, location: fix, print: print)
            if result.ok {
                enterMessage = nil
                await reload()
            } else {
                enterMessage = ErrorText.enterReason(result.reason)
            }
        } catch {
            enterMessage = ErrorText.of(error)
        }
    }

    private func post(visit: UUID?) async {
        guard let api = session.api, let visit else { return }
        posting = true
        defer { posting = false }
        do {
            _ = try await api.postGraffiti(visit: visit, body: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                           visibility: draftVisibility, localOnly: draftLocalOnly)
            draft = ""
            postMessage = ("残しました。", false)
            await reload()
        } catch {
            postMessage = (ErrorText.of(error), true)
        }
    }

    private func delete(_ item: Graffiti) async {
        guard let api = session.api else { return }
        do {
            try await api.deleteGraffiti(item.id)
            await reload()
        } catch {
            postMessage = (ErrorText.of(error), true)
        }
    }
}

/// グラフィティのカード
struct GraffitiCard: View {
    let item: Graffiti
    let author: String
    let isMine: Bool
    var onDelete: () -> Void

    @State private var confirmDelete = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(author.isEmpty ? "だれか" : author)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(ServerDate.relative(item.created_at)).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Text(item.body).font(.body).foregroundStyle(Theme.text)
                HStack(spacing: 12) {
                    Label(Visibility.label(of: item.visibility), systemImage: "eye")
                    if item.local_only {
                        Label("現地だけ", systemImage: "mappin.and.ellipse")
                    }
                    Spacer()
                    if isMine {
                        Button("消す", role: .destructive) { confirmDelete = true }
                            .font(.caption)
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .confirmationDialog("このグラフィティを消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("消す", role: .destructive, action: onDelete)
        } message: {
            Text("友達の新着や GATE からも見えなくなります。")
        }
    }
}
