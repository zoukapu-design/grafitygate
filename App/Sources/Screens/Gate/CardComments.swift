import SwiftUI

/// カードへの返信（GATE の中の小さな会話）。読める・書けるのは、カードが見える人（現地の人と、書いた本人）。
/// 消せるのは、返信を書いた本人とカードを書いた本人。ほかの人の返信には「通報する」。
struct CardCommentsSheet: View {
    let card: Graffiti
    let authorName: String
    /// 書けるか（GATE の中にいる・自分のカード）
    let canWrite: Bool
    /// 返信の数が変わったとき
    let onCountChanged: (Int) -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var comments: [CardComment] = []
    @State private var loading = true
    @State private var text = ""
    @State private var sending = false
    @State private var message: String?
    @State private var reporting: ReportItem?
    @State private var deleting: CardComment?
    @FocusState private var focused: Bool

    private static let limit = 200
    private var isMyCard: Bool { card.author == session.userID }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        cardSummary
                        if loading {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
                        } else if comments.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.title2)
                                    .foregroundStyle(Theme.accent.opacity(0.6))
                                Text(canWrite ? "最初のひとことを返してみましょう。" : "まだ返信はありません。")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                        } else {
                            ForEach(comments) { comment in
                                row(comment)
                            }
                        }
                        if let message {
                            NoticeText(text: message)
                        }
                    }
                    .padding(16)
                }
                .scrollDismissesKeyboard(.interactively)
                composer
            }
            .background(Theme.background)
            .navigationTitle("返信")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
        .sheet(item: $reporting) { item in
            ReportSheet(item: item) { Task { await load() } }
                .environmentObject(session)
        }
        .confirmationDialog("この返信を消しますか？", isPresented: Binding(get: { deleting != nil },
                                                                     set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("消す", role: .destructive) {
                if let comment = deleting { Task { await delete(comment) } }
            }
        }
    }

    // MARK: 部品

    private var cardSummary: some View {
        HStack(alignment: .top, spacing: 12) {
            if let path = card.photo_path {
                RemotePhoto(path: path)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(isMyCard ? "あなたのカード" : "\(authorName.isEmpty ? "だれか" : authorName)さんのカード")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                if !card.body.isEmpty {
                    Text(card.body)
                        .font(.subheadline)
                        .foregroundStyle(Theme.text)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }

    private func row(_ comment: CardComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            PersonBadge(name: comment.mine ? "あなた" : comment.author_name, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.mine ? "あなた" : comment.author_name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    if comment.author == card.author {
                        Text("カードを書いた人")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.warm)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.warm.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    Text(ServerDate.relative(comment.created_at))
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(comment.body)
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Menu {
                if comment.can_delete {
                    Button("消す", role: .destructive) { deleting = comment }
                }
                if !comment.mine {
                    Button {
                        reporting = ReportItem(id: comment.id, target: .card_comment, userID: comment.author,
                                               userName: comment.author_name, label: "カードへの返信")
                    } label: {
                        Label("通報する", systemImage: "exclamationmark.bubble")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 24)
            }
            .accessibilityLabel("そのほか")
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var composer: some View {
        if canWrite {
            VStack(spacing: 6) {
                Divider()
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("ひとこと返す", text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.line))
                        .onChange(of: text) { _, value in
                            if value.count > Self.limit { text = String(value.prefix(Self.limit)) }
                        }
                    Button {
                        Task { await send() }
                    } label: {
                        Group {
                            if sending { ProgressView().tint(.white) } else { Image(systemName: "arrow.up") }
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(trimmed.isEmpty ? Theme.textSecondary.opacity(0.4) : Theme.accent, in: Circle())
                    }
                    .disabled(trimmed.isEmpty || sending)
                    .accessibilityLabel("送る")
                }
                .padding(.horizontal, 16)
                if !text.isEmpty {
                    Text("\(text.count) / \(Self.limit)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 10)
            .background(Theme.background)
        } else {
            Text("返信を書けるのは、この GATE に入っているあいだだけです。")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(Theme.surfaceElevated)
        }
    }

    // MARK: 動き

    private func load() async {
        guard let api = session.api else { return }
        do {
            comments = try await api.cardComments(card.id)
            message = nil
            onCountChanged(comments.count)
        } catch {
            message = ErrorText.of(error)
        }
        loading = false
    }

    private func send() async {
        guard let api = session.api, !trimmed.isEmpty else { return }
        sending = true
        defer { sending = false }
        do {
            try await api.addCardComment(card.id, body: trimmed)
            text = ""
            Haptics.success()
            Trace.log("カード：返信を書いた")
            await load()
        } catch {
            message = ErrorText.of(error)
        }
    }

    private func delete(_ comment: CardComment) async {
        guard let api = session.api else { return }
        do {
            try await api.deleteCardComment(comment.id)
            deleting = nil
            await load()
        } catch {
            message = ErrorText.of(error)
        }
    }
}
