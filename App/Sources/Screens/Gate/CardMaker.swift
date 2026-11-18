import SwiftUI

// グラフィティカードを作る画面（2026-11-19 オーナー「作る画面がわかりにくい。AR カメラのボタンはいちばん上。
// 名前やメッセージは、表示しているカードの中を押して直接書く。写真も撮ったらカードに入り、押せば編集」）。
// 上に「AR カメラで撮る」、まん中に作っているカード（名前・写真・ひとことはカードの上で）、下に仕上げ・見せる人、
// いちばん下に「このカードを残す」。書きかけは GATE ごとに覚えておく（AR カメラへ行って戻っても消えない）。

/// 書きかけのカード
@MainActor
final class CardDraft: ObservableObject {
    @Published var title = ""
    @Published var body = ""
    @Published var photo: UIImage?
    /// 整える前の写真（整え直すときは、ここから）
    @Published var photoSource: UIImage?
    @Published var finish: CardFinish = .normal
    @Published var visibility: Visibility = .friends
    @Published var localOnly = false
    @Published var inAtlas = true

    static let titleLimit = 30
    static let bodyLimit = 100

    var isEmpty: Bool {
        photo == nil && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setPhoto(_ image: UIImage) {
        photo = image
        photoSource = image
    }
}

/// GATE ごとの書きかけ（アプリを開いているあいだだけ）
@MainActor
final class CardDraftStore {
    static let shared = CardDraftStore()
    private var drafts: [UUID: CardDraft] = [:]

    func draft(for gate: UUID) -> CardDraft {
        if let d = drafts[gate] { return d }
        let d = CardDraft()
        drafts[gate] = d
        return d
    }

    func clear(_ gate: UUID) {
        drafts[gate] = nil
    }
}

struct CardMakerView: View {
    let context: GateContext
    /// AR の画面から開いた扉の中なら、いまの AR のまま AR カメラを開く（シートを閉じる）。nil なら、この画面から開く
    let externalARCamera: (() -> Bool)?
    let onPosted: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var draft: CardDraft
    @ObservedObject private var inbox = CardPhotoInbox.shared
    @FocusState private var focus: CardEditField?
    @State private var showARCamera = false
    @State private var showCamera = false
    @State private var editingPhoto: PhotoToEdit?
    @State private var photoMenu = false
    @State private var posting = false
    @State private var message: String?

    init(context: GateContext, externalARCamera: (() -> Bool)?, onPosted: @escaping () -> Void) {
        self.context = context
        self.externalARCamera = externalARCamera
        self.onPosted = onPosted
        _draft = ObservedObject(wrappedValue: CardDraftStore.shared.draft(for: context.gateID))
    }

    private var myName: String { session.profile?.display_name ?? "あなた" }

    private var titleBinding: Binding<String> {
        Binding(get: { draft.title },
                set: { draft.title = String($0.replacingOccurrences(of: "\n", with: "").prefix(CardDraft.titleLimit)) })
    }

    private var bodyBinding: Binding<String> {
        Binding(get: { draft.body }, set: { draft.body = String($0.prefix(CardDraft.bodyLimit)) })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    photoActions
                    TradingCard(content: TradingCardContent(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c0")!,
                                                            image: draft.photo,
                                                            body: draft.body.trimmingCharacters(in: .whitespacesAndNewlines),
                                                            author: myName,
                                                            title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                            gateTitle: context.title,
                                                            createdAt: ISO8601DateFormatter().string(from: Date()),
                                                            finish: draft.finish, badge: .mine),
                                animated: focus == nil,
                                editor: TradingCardEditor(title: titleBinding, body: bodyBinding, titlePlaceholder: myName,
                                                          focus: $focus, onPhotoTap: photoTapped))
                        .frame(maxWidth: 330)
                        .frame(maxWidth: .infinity)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: draft.finish)
                    Label("カードの名前・ひとことは、カードの上を押して書けます。写真を押すと撮る・整える。", systemImage: "hand.tap")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("仕上げ").font(.subheadline.weight(.heavy)).foregroundStyle(Theme.text)
                        CardFinishPicker(selection: $draft.finish)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    visibilityRow
                    if let message {
                        NoticeText(text: message)
                    }
                }
                .padding(16)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { postBar }
            .navigationTitle("グラフィティカードを作る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("決める") { focus = nil }
                }
            }
        }
        .confirmationDialog("写真", isPresented: $photoMenu, titleVisibility: .hidden) {
            Button("整える（向き・拡大・色・エフェクト）") { edit() }
            Button("AR カメラで撮り直す") { openARCamera() }
            Button("ふつうのカメラで撮り直す") { showCamera = true }
            Button("写真を外す", role: .destructive) {
                draft.photo = nil
                draft.photoSource = nil
            }
        }
        .fullScreenCover(isPresented: $showARCamera) {
            ARExperienceView(mode: .cardCamera(context.gateID, visit: context.visit)) {
                showARCamera = false
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CardCameraView { image in
                draft.setPhoto(image)
                Trace.log("カード：ふつうのカメラで撮った")
            }
        }
        .fullScreenCover(item: $editingPhoto) { item in
            CardPhotoEditor(original: item.image) { edited in
                draft.photo = edited
            }
        }
        // AR カメラで撮った写真を、カードに入れる
        .onReceive(inbox.$pending) { pending in
            guard pending?.gate == context.gateID, let image = inbox.take(for: context.gateID) else { return }
            draft.setPhoto(image)
            message = nil
            Trace.log("カード：AR カメラの写真をカードに入れた")
        }
        .onAppear { Trace.log("カードを作る画面を開いた（写真\(draft.photo == nil ? "なし" : "あり")）") }
    }

    // MARK: いちばん上：写真

    @ViewBuilder private var photoActions: some View {
        if draft.photo == nil {
            VStack(spacing: 10) {
                ARCameraCallout(hasPhoto: false) { openARCamera() }
                Button {
                    showCamera = true
                } label: {
                    Label("ふつうのカメラで撮る", systemImage: "camera")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack(spacing: 10) {
                Button {
                    openARCamera()
                } label: {
                    Label("AR カメラで撮り直す", systemImage: "camera.viewfinder")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(LinearGradient(colors: [Color(hex: 0x2A1650), Color(hex: 0x4A2A8A)],
                                                   startPoint: .leading, endPoint: .trailing),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                Button {
                    edit()
                } label: {
                    Label("整える", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Theme.accentLight, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var visibilityRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("見せる人").font(.subheadline.weight(.heavy)).foregroundStyle(Theme.text)
            Menu {
                Picker("見せる人", selection: $draft.visibility) {
                    ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
                }
                Toggle("この GATE の中だけで見せる（友達の新着に出さない）", isOn: $draft.localOnly)
                Toggle("友達のカード図鑑に写真を載せる", isOn: $draft.inAtlas)
                    .disabled(draft.localOnly)
            } label: {
                HStack {
                    Image(systemName: "eye")
                    Text(draft.visibility.label + (draft.localOnly ? "・この GATE の中だけ" : ""))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var postBar: some View {
        VStack(spacing: 6) {
            Button {
                Task { await post() }
            } label: {
                if posting { ProgressView().tint(.white) } else { Text("このカードを残す") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(posting || draft.isEmpty || context.visit == nil)
            Text(context.visit == nil ? "扉が閉じました。現地で扉を開けると残せます。"
                                      : "1 つの GATE に 1 日 1 枚。残したあとも、名前・ひとことは直せます。")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.regularMaterial)
    }

    // MARK: 動き

    private func photoTapped() {
        focus = nil
        if draft.photo == nil {
            openARCamera()
        } else {
            photoMenu = true
        }
    }

    private func edit() {
        if let source = draft.photoSource ?? draft.photo { editingPhoto = PhotoToEdit(image: source) }
    }

    /// AR カメラを開く（AR の画面から開いた扉の中なら、この画面を閉じて、いまの AR のまま）
    private func openARCamera() {
        focus = nil
        Trace.log("カードを作る：AR カメラを開く")
        if let external = externalARCamera {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                if !external() { Trace.log("カードを作る：AR の画面の AR カメラを開けなかった") }
            }
            return
        }
        showARCamera = true
    }

    private func post() async {
        guard let api = session.api, let visit = context.visit else {
            message = "扉が閉じました（GATE から離れたため）。現地でもう一度扉を開けてください。"
            return
        }
        focus = nil
        posting = true
        defer { posting = false }
        var photoPath: String?
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if let photo = draft.photo, let media = session.media, let me = session.userID {
                photoPath = try await media.uploadPhoto(photo, owner: me)
            }
            let newID = try await api.postGraffiti(visit: visit, body: body, photoPath: photoPath,
                                                   visibility: draft.visibility, localOnly: draft.localOnly)
            // 写真つきで「この GATE の中だけ」でなければ、選んだとおり友達のカード図鑑に載せる
            if photoPath != nil, !draft.localOnly, draft.inAtlas, draft.visibility != .private {
                try? await api.setGraffitiAtlas(newID, on: true)
            }
            if draft.finish != .normal {
                do {
                    try await api.setCardFinish(newID, finish: draft.finish)
                } catch {
                    Trace.log("カードの仕上げを付けられませんでした：\(ErrorText.of(error))")
                }
            }
            if !title.isEmpty {
                do {
                    try await api.setCardTitle(newID, title: title)
                } catch {
                    Trace.log("カードの名前を付けられませんでした：\(ErrorText.of(error))")
                }
            }
            Trace.log("カード：残した（写真\(photoPath == nil ? "なし" : "あり")・仕上げ \(draft.finish.rawValue)・名前\(title.isEmpty ? "なし" : "あり")）")
            CardDraftStore.shared.clear(context.gateID)
            Haptics.success()
            onPosted()
            dismiss()
        } catch {
            if let photoPath { await session.media?.removePhoto(path: photoPath) }
            message = ErrorText.of(error)
            Trace.log("カード：残せなかった（\(ErrorText.of(error))）")
        }
    }
}
