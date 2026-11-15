import SwiftUI

// MARK: - チャットの中のグラフィティカード

/// メッセージに添えられたグラフィティカード（送った人のカード）。押すと大きく見られる
struct ChatCardBubble: View {
    let message: DMMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                if let photo = message.card_photo {
                    RemotePhoto(path: photo)
                } else {
                    LinearGradient(colors: [Color(hex: 0x140F3A), Color(hex: 0x3A1530)], startPoint: .top, endPoint: .bottom)
                    Text(message.card_body ?? "")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(4)
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Label("グラフィティカード", systemImage: "rectangle.portrait.on.rectangle.portrait")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(8)
            }
            .frame(width: 220, height: 170)
            .clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(message.card_gate_title ?? "GATE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if let date = message.card_created_at {
                    Text(GateDates.shortText(date)).font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                if message.card_photo != nil, let body = message.card_body, !body.isEmpty {
                    Text(body).font(.caption).foregroundStyle(Theme.text).lineLimit(2)
                }
            }
            .padding(10)
            .frame(width: 220, alignment: .leading)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.warm.opacity(0.45), lineWidth: 1.5))
    }
}

/// 添えられたグラフィティカードを大きく見る：写真・ひとこと・GATE（GATE の中は現地だけのまま）
struct ChatCardSheet: View {
    let message: DMMessage
    let senderName: String

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var viewer: PhotoViewerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let photo = message.card_photo {
                        Button {
                            viewer = PhotoViewerItem(path: photo, caption: message.card_body ?? "")
                        } label: {
                            RemotePhoto(path: photo)
                                .frame(height: 340)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("写真を大きく見る")
                    }
                    HStack(spacing: 10) {
                        NeonAvatar(name: senderName, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(senderName)のグラフィティカード").font(.headline).foregroundStyle(Theme.text)
                            if let date = message.card_created_at {
                                Text(GateDates.fullText(date)).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    if let body = message.card_body, !body.isEmpty {
                        Text(body).font(.title3).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                    }
                    if let gate = message.card_gate_id {
                        NavigationLink {
                            GateDetailView(gateID: gate)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "door.left.hand.open").foregroundStyle(Theme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(message.card_gate_title ?? "GATE").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                    Text("この GATE の場所と、ほかのグラフィティカード（現地で）")
                                        .font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(14)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("グラフィティカード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .fullScreenCover(item: $viewer) { item in
                PhotoViewer(path: item.path, caption: item.caption)
                    .environmentObject(session)
            }
        }
    }
}

// MARK: - 友達に送る

/// 自分のグラフィティカードを、お互いにフォローの友達に送る（ひとこと添えられる）
struct SendCardSheet: View {
    let card: Graffiti
    let gateTitle: String
    let onSent: (String) -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var friends: [ProfileRow] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var chosen: ProfileRow?
    @State private var note = ""
    @State private var sending = false
    @State private var message: String?

    private var shown: [ProfileRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = friends.sorted { $0.display_name.localizedStandardCompare($1.display_name) == .orderedAscending }
        guard !q.isEmpty else { return list }
        return list.filter { $0.display_name.localizedCaseInsensitiveContains(q) || $0.handle.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        ZStack {
                            Theme.surfaceElevated
                            if let photo = card.photo_path {
                                RemotePhoto(path: photo)
                            } else {
                                Image(systemName: "text.quote").foregroundStyle(Theme.accent)
                            }
                        }
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(gateTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if !card.body.isEmpty {
                                Text(card.body).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
                            }
                        }
                    }
                } footer: {
                    Text("送った友達は、このカードの写真・ひとこと・GATE の名前を見られます。カードを消すと、送ったものも見えなくなります。")
                }
                Section("だれに送る？") {
                    if loaded && friends.isEmpty {
                        Text("お互いにフォローしている友達がいると、ここから送れます。")
                            .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(shown, id: \.id) { friend in
                        Button {
                            chosen = friend
                        } label: {
                            HStack(spacing: 12) {
                                PersonBadge(name: friend.display_name, size: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friend.display_name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                    Text("@\(friend.handle)").font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                Image(systemName: chosen?.id == friend.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(chosen?.id == friend.id ? Theme.accent : Theme.textSecondary)
                                    .font(.title3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section("ひとこと（なくてもよい）") {
                    TextField("例：今日ここに来たよ！", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .onChange(of: note) { _, v in if v.count > 200 { note = String(v.prefix(200)) } }
                }
                if let message {
                    Section { NoticeText(text: message) }
                }
            }
            .searchable(text: $query, prompt: "友達の名前で探す")
            .navigationTitle("友達に送る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("送る") { Task { await send() } }
                            .disabled(chosen == nil)
                    }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let api = session.api, let me = session.userID else { return }
        friends = (try? await api.friends(me: me)) ?? []
        loaded = true
    }

    private func send() async {
        guard let api = session.api, let friend = chosen else { return }
        sending = true
        defer { sending = false }
        do {
            try await api.sendCard(to: friend.id, card: card.id, body: note.trimmingCharacters(in: .whitespacesAndNewlines))
            Haptics.success()
            Trace.log("グラフィティカードを友達に送った")
            onSent("\(friend.display_name)さんに送りました。メッセージから見られます。")
            dismiss()
        } catch {
            message = ErrorText.isMissingFunction(error)
                ? "カードを送るのは、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
    }
}
