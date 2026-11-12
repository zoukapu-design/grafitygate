import SwiftUI

/// 撮る：目の前の場所・物を写して、近くの GATE に入る／新しく GATE を作る。
/// 写真そのものは送らず、写真の特徴（数の並び）と位置だけを送る。
struct CaptureView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var location: LocationModel

    @State private var path: [GateRoute] = []
    @State private var photos: [UIImage] = []
    @State private var prints: [[Float]] = []
    @State private var showCamera = false
    @State private var working = false
    @State private var message: String?

    @State private var candidates: [MatchCandidate]?

    @State private var title = ""
    @State private var note = ""
    @State private var kind = "object"
    @State private var visibility: Visibility = .friends
    @State private var clientKey = UUID().uuidString

    private let needed = 3

    var body: some View {
        NavigationStack(path: $path) {
            ScreenScaffold(title: "撮る") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        intro
                        shots
                        if !prints.isEmpty { matchSection }
                        if candidates != nil { createSection }
                        if let message { NoticeText(text: message) }
                    }
                    .padding(16)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    Task { await add(image) }
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: 画面の部品

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("目の前の場所や物を写す").font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
            Text("近くに GATE があれば入れます。なければ、ここに新しい GATE を作れます。")
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
            if let problem = location.fixProblem {
                NoticeText(text: problem)
            } else if let fix = location.location {
                Text(String(format: "現在地の精度 ±%.0fm", fix.horizontalAccuracy))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var shots: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("写した写真 \(photos.count) 枚").font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    if !photos.isEmpty {
                        Button("やり直す") { reset() }
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if !photos.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(photos.indices, id: \.self) { i in
                            Image(uiImage: photos[i])
                                .resizable()
                                .scaledToFill()
                                .frame(width: 88, height: 88)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                if CameraPicker.isAvailable {
                    Button {
                        message = nil
                        showCamera = true
                    } label: {
                        if working { ProgressView().tint(.white) } else {
                            Label(photos.isEmpty ? "写す" : "もう 1 枚写す（角度を変えて）", systemImage: "camera")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(working || photos.count >= 6)
                } else {
                    CameraUnavailableNote()
                }
                Text("入るときは 1 枚。GATE を作るときは、正面・斜め左・斜め右など \(needed) 枚あると、友達が入りやすくなります。人の顔や車のナンバーが写らないようにしてください。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var matchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let candidates {
                Text("近くの GATE").font(.headline).foregroundStyle(Theme.text)
                if candidates.isEmpty {
                    Text("100m 以内に、入れる GATE はありません。").font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                ForEach(candidates) { c in
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                Spacer()
                                Text(similarityLabel(c.similarity)).font(.caption).foregroundStyle(Theme.accent)
                            }
                            Text("\(c.owner_name)・約 \(Int(c.distance_m.rounded()))m")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                            Button("この GATE に入る") {
                                Task { await enter(c.id) }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(working)
                        }
                    }
                }
            } else {
                Button {
                    Task { await lookUp() }
                } label: {
                    if working { ProgressView() } else { Text("近くの GATE と照らし合わせる") }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(working || location.usableFix == nil || session.api == nil)
            }
        }
    }

    private var createSection: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("ここに新しい GATE を作る").font(.headline).foregroundStyle(Theme.text)
                if let candidates, candidates.contains(where: { $0.similarity == "strong" }) {
                    Text("よく似た GATE が近くにあります。同じ場所なら、上の GATE に入ってください。自分の GATE として別に作ることもできます。")
                        .font(.caption).foregroundStyle(Theme.warm)
                }
                TextField("名前（例：駅前の街灯）", text: $title)
                    .padding(12)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                TextField("ひとこと（なくても大丈夫）", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(12)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                Picker("種類", selection: $kind) {
                    Text("場所の中の物").tag("object")
                    Text("場所").tag("place")
                }
                .pickerStyle(.segmented)
                Picker("見せる人", selection: $visibility) {
                    ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
                }
                .pickerStyle(.segmented)
                Button {
                    Task { await create() }
                } label: {
                    if working { ProgressView().tint(.white) } else { Text("GATE を作る") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(working || prints.count < needed || title.trimmingCharacters(in: .whitespaces).isEmpty
                          || location.usableFix == nil)
                if prints.count < needed {
                    Text("作るには、あと \(needed - prints.count) 枚写してください。")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func similarityLabel(_ s: String) -> String {
        switch s {
        case "strong": return "よく似ている"
        case "weak": return "少し似ている"
        case "none": return "似ていない"
        default: return "比べられない"
        }
    }

    // MARK: 動き

    private func add(_ image: UIImage) async {
        working = true
        defer { working = false }
        do {
            let p = try await makePrint(from: image)
            photos.append(image.downscaled(maxSide: 400))
            prints.append(p)
            candidates = nil
        } catch {
            message = ErrorText.of(error)
        }
    }

    private func lookUp() async {
        guard let api = session.api, let fix = location.usableFix, let latest = prints.last else {
            message = location.fixProblem
            return
        }
        working = true
        defer { working = false }
        do {
            candidates = try await api.candidates(fix, print: latest)
            message = nil
        } catch {
            message = ErrorText.of(error)
        }
    }

    private func enter(_ gate: UUID) async {
        guard let api = session.api, let fix = location.usableFix, let latest = prints.last else {
            message = location.fixProblem
            return
        }
        working = true
        defer { working = false }
        do {
            let result = try await api.enter(gate: gate, location: fix, print: latest)
            if result.ok {
                path.append(GateRoute(id: gate))
                reset()
            } else {
                message = ErrorText.enterReason(result.reason)
            }
        } catch {
            message = ErrorText.of(error)
        }
    }

    private func create() async {
        guard let api = session.api, let fix = location.usableFix else {
            message = location.fixProblem
            return
        }
        working = true
        defer { working = false }
        do {
            let gate = try await api.createGate(clientKey: clientKey,
                                                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                                kind: kind, visibility: visibility,
                                                location: fix, prints: prints)
            // 作った人も、ふつうの入場と同じ決まりで入る（いま写した写真で）
            if let latest = prints.last {
                let result = try await api.enter(gate: gate, location: fix, print: latest)
                if !result.ok { message = ErrorText.enterReason(result.reason) }
            }
            path.append(GateRoute(id: gate))
            reset()
        } catch {
            message = ErrorText.of(error)
        }
    }

    private func reset() {
        photos = []
        prints = []
        candidates = nil
        title = ""
        note = ""
        clientKey = UUID().uuidString
    }
}
