import RealityKit
import SwiftUI
import UIKit

/// 扉が開いたあとの「AR の作品」：見る・触れる・置く・置き直す・隠す・消す。
extension ARExperienceModel {
    enum ArtStep: Equatable {
        /// 種類を選ぶ
        case choosing
        /// 中身（写真・文字・色・触れたときの動き・見せる人）
        case composing
        /// 置く所（見本がカメラの前についてくる）
        case placing
        case saving
        /// 自分の作品を押した
        case selected(UUID)
        /// ほかの人の作品を押した（だれの作品か・通報）
        case viewing(UUID)
    }

    struct ArtDraft {
        var kind: ArtworkKind = .text
        var text = ""
        /// 写真パネルの写真・映像パネルの表紙の絵
        var image: UIImage?
        /// 映像パネルの動画（iPhone の中で作り直したもの）
        var video: MediaPrep.PreparedVideo?
        /// 人物の映像（切り抜いたもの）
        var person: PersonCutout.Result?
        /// 声の玉の声
        var voiceFile: URL?
        var voiceDuration: Double = 0
        /// まず自分だけで試す（下書き。ほかの人には見えない）
        var asDraft = false
        var color: ArtworkColor = .warm
        var action: ArtworkAction = .glow
        var visibility: Visibility = .friends
        var scale: Float = 1
    }

    /// 1 人が 1 つの GATE に置ける作品の数（サーバーの artworks_per_user_gate と同じ）
    static let artworksPerPerson = 3
    /// 光る文字の長さ（読みやすさのため。サーバーは 120 文字まで）
    static let artTextLimit = 40

    var canPlaceArt: Bool {
        guard phase == .doorOpen, visitID != nil, artScene != nil, placedPrecisely else { return false }
        if let expires = visitExpires, expires <= Date() { return false }
        return myArtworkCount < Self.artworksPerPerson
    }

    var visitRemainingText: String? {
        guard let expires = visitExpires else { return nil }
        let minutes = Int(ceil(expires.timeIntervalSinceNow / 60))
        return minutes > 0 ? "入場の残り 約 \(minutes) 分" : "入場の時間が切れました"
    }

    // MARK: 出す

    func makeArtScene() {
        guard artScene == nil, let door else { return }
        let scene = ArtworkScene(parent: door.base, arView: stage.arView)
        scene.onPreviewRangeChange = { [weak self] inRange in self?.previewInRange = inRange }
        scene.onApproach = { _ in Haptics.soft() }
        scene.onPlayRequest = { [weak self] id in self?.playArtwork(id) }
        scene.onPlaybackChange = { [weak self] id in self?.playingArtwork = id }
        artScene = scene
        hand.targets = { [weak scene] in scene?.targets(within: 2.5) ?? [] }
        hand.onTouch = { [weak self] id in
            guard let self, let scene = self.artScene else { return }
            if scene.fire(.touch, on: id) { Haptics.tap() }
        }
        hand.onHover = { [weak scene] id in scene?.setHover(id) }
    }

    func loadArtworks(_ gate: UUID) async {
        guard let api = session?.api else { return }
        do {
            // 公開中と、自分の下書き（ほかの人の下書きはサーバーが返さない）
            let list = try await api.artworks(in: gate).filter { $0.status != "hidden" }
            guard enteredGate == gate, let scene = artScene else { return }
            for artwork in list { scene.add(artwork, image: nil, animated: false) }
            refreshArtCounts()
            Trace.log("作品を \(list.count) 個受け取りました（写真パネル \(list.filter { $0.artKind == .photo }.count) 個・"
                      + "映像 \(list.filter { $0.artKind == .video }.count) 個・声 \(list.filter { $0.artKind == .voice }.count) 個）")
            if phase == .doorOpen { startHandIfNeeded() }
            let me = session?.userID
            let mine = list.filter { $0.owner == me }
            let toCheck = mine.filter { $0.needs_replace == true }.count
            let drafts = mine.filter(\.isDraft).count
            if toCheck > 0 {
                showToast("扉の場所の記憶が撮り直されました。あなたの作品 \(toCheck) つの位置を確かめてください。")
            } else if drafts > 0 {
                showToast("あなたの下書きの作品が \(drafts) つあります。押すと公開できます。")
            }
            let owners = Array(Set(list.map(\.owner)))
            if let names = try? await api.names(of: owners) { artNames.merge(names) { _, new in new } }
            await loadArtPhotos(list)
            await prefetchArtMedia(list)
        } catch {
            Trace.log("作品を受け取れませんでした：\(ErrorText.of(error))")
        }
    }

    private func loadArtPhotos(_ list: [Artwork]) async {
        guard let media = session?.media else { return }
        // 人物の映像は、一覧用の絵（透けない）ではなく、動画の最初の 1 コマ（透ける）を出す＝prefetchArtMedia で
        for artwork in list where artwork.artKind != .person {
            guard let path = artwork.picturePath, let image = await media.photo(path: path) else { continue }
            artImages[artwork.id] = image
            artScene?.setPhoto(image, for: artwork.id)
        }
    }

    /// 声（小さい）と、新しい映像 4 つまでを先に受け取っておく（触れたらすぐ流れるように）
    private func prefetchArtMedia(_ list: [Artwork]) async {
        guard let media = session?.media else { return }
        // 人物（立ち姿を出すのに要る）を先に、次に声（小さい）、映像は新しい 4 つまで
        let persons = list.filter { $0.artKind == .person }
        let voices = list.filter { $0.artKind == .voice }
        let videos = list.filter { $0.artKind == .video }.suffix(4)
        var count = 0
        for artwork in persons + voices + videos {
            guard enteredGate == artwork.gate_id, let path = artwork.photo_path, !artMediaLoading.contains(artwork.id) else { continue }
            var file = media.cachedFile(path: path)
            if file == nil {
                artMediaLoading.insert(artwork.id)
                file = await media.localFile(path: path)
                artMediaLoading.remove(artwork.id)
                if file != nil { count += 1 }
            }
            if artwork.artKind == .person, let file { await showPersonPoster(artwork.id, file: file) }
        }
        if count > 0 { Trace.log("作品の映像・声を \(count) 個、先に受け取りました") }
    }

    /// 人物の映像の最初の 1 コマ（透けるところのある絵）を、立ち姿として出す
    func showPersonPoster(_ id: UUID, file: URL) async {
        guard artImages[id] == nil, let image = await PersonCutout.poster(of: file) else { return }
        artImages[id] = image
        artScene?.setPhoto(image, for: id)
    }

    // MARK: 流す

    func playArtwork(_ id: UUID) {
        guard let scene = artScene, let artwork = scene.artwork(id), artwork.artKind.isMedia,
              let path = artwork.photo_path, let media = session?.media else { return }
        if scene.playingID == id { return }
        if let file = media.cachedFile(path: path) {
            scene.play(id, file: file)
            return
        }
        guard !artMediaLoading.contains(id) else { return }
        artMediaLoading.insert(id)
        showToast(artwork.artKind == .video ? "映像を受け取っています…" : "声を受け取っています…")
        Task {
            let file = await media.localFile(path: path)
            artMediaLoading.remove(id)
            guard artScene === scene, scene.artwork(id) != nil else { return }
            guard let file else {
                showToast("受け取れませんでした。電波の良い所で、もう一度触れてください。")
                Trace.log("作品の映像・声を受け取れませんでした")
                return
            }
            scene.play(id, file: file)
            if artwork.artKind == .person { await showPersonPoster(id, file: file) }
        }
    }

    func stopArtworkPlayback() {
        artScene?.stopPlayback()
    }

    func revealArtworks() {
        guard let scene = artScene else { return }
        scene.reveal()
        startHandIfNeeded()
    }

    func startHandIfNeeded() {
        guard let scene = artScene, scene.isRevealed, !scene.isEmpty else { return }
        hand.start(stage: stage)
    }

    func refreshArtCounts() {
        guard let scene = artScene else {
            artworkCount = 0
            myArtworkCount = 0
            return
        }
        let me = session?.userID
        let all = scene.items.values.map(\.artwork)
        artworkCount = all.count
        myArtworkCount = all.filter { $0.owner == me }.count
    }

    // MARK: 押す

    func tapArtwork(at point: CGPoint) {
        guard let scene = artScene, art != .placing, art != .saving,
              let id = scene.artworkID(at: stage.arView.entity(at: point)),
              let artwork = scene.artwork(id) else { return }
        if scene.fire(.tap, on: id) { Haptics.tap() }
        if artwork.owner == session?.userID {
            art = .selected(id)
        } else {
            art = .viewing(id)
        }
    }

    func artworkOwnerName(_ id: UUID) -> String {
        guard let owner = artScene?.artwork(id)?.owner else { return "だれか" }
        return artNames[owner] ?? "だれか"
    }

    /// ブロックした人の作品を、すぐ見えなくする
    func removeArtworks(of user: UUID?) {
        guard let user, let scene = artScene else { return }
        let ids = scene.items.filter { $0.value.artwork.owner == user }.map(\.key)
        for id in ids { scene.remove(id) }
        refreshArtCounts()
        art = nil
        Trace.log("ブロックした人の作品を \(ids.count) 個外しました")
    }

    func reportArtwork(_ id: UUID) {
        guard let artwork = artScene?.artwork(id) else { return }
        reportItem = ReportItem(id: id, target: .artwork, userID: artwork.owner, userName: artNames[artwork.owner],
                                label: artwork.artKind.label)
    }

    private func showArtCaption(_ text: String) {
        captionTask?.cancel()
        artCaption = text
        captionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            self?.artCaption = nil
        }
    }

    // MARK: 置く

    func startArt() {
        guard canPlaceArt else {
            if !placedPrecisely {
                notice = "扉がおおよその位置に出ているため、作品は置けません（置くと、ほかの人にはずれた所に見えます）。作った人が扉を置いた辺りを見回して、扉を出し直してください。"
            } else if myArtworkCount >= Self.artworksPerPerson {
                notice = "1 つの GATE に置ける作品は、1 人 3 つまでです。前の作品を押して消すと置けます。"
            } else {
                notice = "入場の時間が切れました。現地でもう一度入ると置けます。"
            }
            return
        }
        notice = nil
        discardArtMedia()
        draft = ArtDraft()
        art = .choosing
    }

    func chooseArtKind(_ kind: ArtworkKind) {
        if draft.kind != kind {
            discardArtMedia()
            draft.image = nil
        }
        draft.kind = kind
        draft.action = kind.defaultAction
        draft.color = kind == .petals ? .sakura : .warm
        notice = nil
        art = .composing
    }

    /// いまのカメラの景色を、写真パネルの写真にする（AR の飾りは写らない）
    func useCameraForArtPhoto() {
        Task {
            guard let image = await stage.grabPhoto() else {
                notice = "カメラの準備ができていません。少し待ってからお試しください。"
                return
            }
            draft.image = image
            notice = nil
            Haptics.tap()
        }
    }

    /// 映像パネルの動画を決める（前に選んだものは消す）
    func setArtVideo(_ video: MediaPrep.PreparedVideo) {
        if let old = draft.video, old.file != video.file { try? FileManager.default.removeItem(at: old.file) }
        draft.video = video
        draft.image = video.thumbnail
        notice = video.trimmed ? "15 秒より長い動画は、はじめの 15 秒にしました。" : nil
    }

    /// 人物の映像を決める（前に作ったものは消す）
    func setArtPerson(_ result: PersonCutout.Result) {
        if let old = draft.person, old.file != result.file { try? FileManager.default.removeItem(at: old.file) }
        draft.person = result
        draft.image = result.poster
        notice = result.trimmed ? "10 秒より長い動画は、はじめの 10 秒にしました。" : nil
    }

    /// 声の玉の声を決める（前に録ったものは消す）
    func setArtVoice(_ file: URL, duration: Double) {
        if let old = draft.voiceFile, old != file { try? FileManager.default.removeItem(at: old) }
        draft.voiceFile = file
        draft.voiceDuration = duration
        notice = nil
    }

    /// 置かなかった動画・声の一時ファイルを消す
    func discardArtMedia() {
        if let video = draft.video { try? FileManager.default.removeItem(at: video.file) }
        if let person = draft.person { try? FileManager.default.removeItem(at: person.file) }
        draft.person = nil
        if let voice = draft.voiceFile { try? FileManager.default.removeItem(at: voice) }
        draft.video = nil
        draft.voiceFile = nil
        draft.voiceDuration = 0
    }

    var draftProblem: String? {
        switch draft.kind {
        case .photo where draft.image == nil: return "写真を選ぶか、いまの景色を写してください。"
        case .video where draft.video == nil: return "動画を選んでください（15 秒まで）。"
        case .person where draft.person == nil: return "人が写っている動画を選んでください（10 秒まで）。"
        case .voice where draft.voiceFile == nil: return "声を録ってください（60 秒まで）。"
        case .text where draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: return "文字を入れてください。"
        default: return nil
        }
    }

    func beginArtPlacement() {
        if let problem = draftProblem {
            notice = problem
            return
        }
        guard let scene = artScene, let me = session?.userID, let gate = enteredGate else { return }
        notice = nil
        movingArtwork = nil
        let text = String(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.artTextLimit))
        let sample = Artwork(id: UUID(), gate_id: gate, owner: me, kind: draft.kind.rawValue,
                             body: draft.kind == .text ? text : "", photo_path: nil, color: draft.color.rawValue,
                             px: 0, py: 1.2, pz: 1, yaw: 0, scale: draft.scale,
                             rules: Self.rules(for: draft.action, kind: draft.kind), visibility: draft.visibility.rawValue,
                             status: "published", revision: 1, created_at: "")
        switch draft.kind {
        case .person: scene.previewDistance = 1.8
        case .photo, .text, .video: scene.previewDistance = 1.0
        default: scene.previewDistance = 0.9
        }
        scene.beginPreview(sample, image: draft.image)
        previewInRange = true
        art = .placing
    }

    func setPreviewScale(_ value: Float) {
        draft.scale = value
        artScene?.previewScale = value
    }

    /// 決まった形のルール：触れる・押すと選んだ動き（映像・声は流す）、近づく・扉が開くとやわらかく光る
    static func rules(for action: ArtworkAction, kind: ArtworkKind) -> [ArtworkRule] {
        let action = kind.isMedia ? ArtworkAction.play : (action == .play ? .glow : action)
        return [ArtworkRule(.touch, action, cooldownMS: 1200),
         ArtworkRule(.tap, action, cooldownMS: 600),
         ArtworkRule(.approach, .glow, cooldownMS: 5000),
         ArtworkRule(.open, .glow)]
    }

    func backFromPlacing() {
        artScene?.endPreview()
        if let id = movingArtwork {
            movingArtwork = nil
            art = .selected(id)
        } else {
            art = .composing
        }
    }

    func cancelArt() {
        artScene?.endPreview()
        if art == .placing || art == .composing || art == .choosing { discardArtMedia() }
        movingArtwork = nil
        notice = nil
        art = nil
    }

    func confirmArtPlacement() {
        Task { await confirmArtPlacementAsync() }
    }

    private func confirmArtPlacementAsync() async {
        guard let scene = artScene, let pose = scene.previewPose() else { return }
        guard previewInRange else {
            notice = "扉から離れすぎています。扉から 4m 以内・地面から 3.5m までの所に向けてください。"
            return
        }
        guard let api = session?.api, let media = session?.media, let me = session?.userID,
              let visit = visitID, let gate = enteredGate else {
            notice = session?.problem ?? "サーバーにつながっていません。"
            return
        }
        notice = nil
        art = .saving
        if let id = movingArtwork, let current = scene.artwork(id) {
            await moveArtwork(current, to: pose, visit: visit, api: api)
            return
        }

        var uploaded: [String] = []
        do {
            var mainPath: String?
            var thumbPath: String?
            var duration: Double?
            switch draft.kind {
            case .photo:
                if let image = draft.image {
                    let path = try await media.uploadPhoto(image, owner: me)
                    uploaded.append(path)
                    mainPath = path
                }
            case .video:
                guard let video = draft.video else { throw MediaPrep.Failure.unreadable }
                let thumb = try await media.uploadPhoto(video.thumbnail, owner: me)
                uploaded.append(thumb)
                thumbPath = thumb
                let path = try await media.uploadFile(video.file, owner: me, kind: .video)
                uploaded.append(path)
                mainPath = path
                duration = video.duration
            case .person:
                guard let person = draft.person else { throw MediaPrep.Failure.unreadable }
                let thumb = try await media.uploadPhoto(person.thumbnail, owner: me)
                uploaded.append(thumb)
                thumbPath = thumb
                let path = try await media.uploadFile(person.file, owner: me, fileExtension: "mov",
                                                      contentType: "video/quicktime", label: "人物の映像")
                uploaded.append(path)
                mainPath = path
                duration = person.duration
            case .voice:
                guard let file = draft.voiceFile else { throw MediaPrep.Failure.unreadable }
                let path = try await media.uploadFile(file, owner: me, kind: .voice)
                uploaded.append(path)
                mainPath = path
                duration = draft.voiceDuration
            case .text, .petals, .light:
                break
            }
            let text = String(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.artTextLimit))
            let rules = Self.rules(for: draft.action, kind: draft.kind)
            let asDraft = draft.asDraft
            let id = try await api.placeArtwork(visit: visit, kind: draft.kind, body: draft.kind == .text ? text : "",
                                                photoPath: mainPath, thumbPath: thumbPath, duration: duration,
                                                color: draft.color, position: pose.position,
                                                yaw: pose.yaw, scale: pose.scale, rules: rules,
                                                visibility: draft.visibility, draft: asDraft)
            var placed = Artwork(id: id, gate_id: gate, owner: me, kind: draft.kind.rawValue,
                                 body: draft.kind == .text ? text : "", photo_path: mainPath,
                                 color: draft.color.rawValue, px: pose.position.x, py: pose.position.y,
                                 pz: pose.position.z, yaw: pose.yaw, scale: pose.scale, rules: rules,
                                 visibility: draft.visibility.rawValue, status: asDraft ? "draft" : "published", revision: 1,
                                 created_at: ISO8601DateFormatter().string(from: Date()))
            placed.thumb_path = thumbPath
            placed.duration = duration
            discardArtMedia()
            scene.endPreview()
            let item = scene.add(placed, image: draft.image, animated: true)
            if let image = draft.image { artImages[id] = image }
            item.perform(.glow)
            item.perform(placed.artKind.isMedia ? .play : draft.action)
            refreshArtCounts()
            startHandIfNeeded()
            // 下書きなら、試したあとに公開できるカードを出したままにする
            art = asDraft ? .selected(id) : nil
            Haptics.success()
            if asDraft { showToast("下書きで置きました。あなたにだけ見えています。") }
            Trace.log(String(format: "作品を置きました（%@・%@・扉から 横 %.2f 高さ %.2f 奥 %.2f m・大きさ %.1f）",
                             placed.artKind.label, asDraft ? "下書き" : "公開", pose.position.x, pose.position.y,
                             pose.position.z, pose.scale))
        } catch {
            for path in uploaded { await media.removePhoto(path: path) }
            let message = ErrorText.of(error)
            Trace.log("作品を置けませんでした：\(message)")
            notice = message
            if message.contains("入場の時間") {
                scene.endPreview()
                art = nil
                visitExpires = Date()
            } else {
                art = .placing
            }
        }
    }

    private func moveArtwork(_ current: Artwork, to pose: (position: SIMD3<Float>, yaw: Float, scale: Float),
                             visit: UUID, api: GateAPI) async {
        guard let scene = artScene else { return }
        do {
            let revision = try await api.moveArtwork(current.id, visit: visit, position: pose.position, yaw: pose.yaw,
                                                     scale: pose.scale, revision: current.revision)
            scene.endPreview()
            scene.items[current.id]?.setPose(position: pose.position, yaw: pose.yaw, scale: pose.scale, revision: revision)
            scene.update(current.id, needsReplace: false)
            scene.items[current.id]?.perform(.glow)
            movingArtwork = nil
            art = nil
            Haptics.success()
            Trace.log(String(format: "作品を置き直しました（版 %d・扉から 横 %.2f 高さ %.2f 奥 %.2f m）",
                             revision, pose.position.x, pose.position.y, pose.position.z))
        } catch {
            let message = ErrorText.of(error)
            Trace.log("作品を置き直せませんでした：\(message)")
            notice = message
            scene.endPreview()
            movingArtwork = nil
            art = nil
            if message.contains("ほかの iPhone"), let gate = enteredGate {
                // 新しい位置を読み込み直す
                for id in Array(scene.items.keys) { scene.remove(id) }
                await loadArtworks(gate)
                scene.reveal()
            }
        }
    }

    // MARK: 自分の作品

    func startMovingArtwork(_ id: UUID) {
        guard let scene = artScene, let artwork = scene.artwork(id) else { return }
        guard placedPrecisely else {
            notice = "扉がおおよその位置に出ているため、置き直せません。扉が作った人と同じ位置に出たときに置き直せます。"
            return
        }
        guard visitID != nil, (visitExpires ?? .distantFuture) > Date() else {
            notice = "入場の時間が切れました。現地でもう一度入ると置き直せます。"
            return
        }
        notice = nil
        movingArtwork = id
        draft.scale = artwork.scale
        scene.previewDistance = max(0.6, min(2.0, simd_distance(scene.items[id]?.worldCenter ?? .zero,
                                                                 stage.arView.cameraTransform.translation)))
        scene.beginPreview(artwork, image: artImages[id], hiding: id)
        previewInRange = true
        art = .placing
    }

    /// 下書きを公開する（ほかの人にも見えるようになる）
    func publishArtwork(_ id: UUID) {
        Task {
            guard let api = session?.api else { return }
            do {
                try await api.setArtworkStatus(id, status: "published")
                artScene?.update(id, status: "published")
                artScene?.items[id]?.perform(.glow)
                art = nil
                Haptics.success()
                showToast("公開しました。友達がここで扉を開けると見えます。")
                Trace.log("下書きの作品を公開しました")
            } catch {
                notice = ErrorText.of(error)
            }
        }
    }

    /// 「置き直しが必要」を、いまの位置のままで外す
    func keepArtworkPlace(_ id: UUID) {
        Task {
            guard let api = session?.api else { return }
            do {
                try await api.keepArtworkPlace(id)
                artScene?.update(id, needsReplace: false)
                art = nil
                Trace.log("作品の位置をこのままにしました")
            } catch {
                notice = ErrorText.of(error)
            }
        }
    }

    func hideArtwork(_ id: UUID) {
        Task {
            guard let api = session?.api else { return }
            do {
                try await api.setArtworkStatus(id, hidden: true)
                artScene?.remove(id)
                refreshArtCounts()
                art = nil
                Trace.log("自分の作品を隠しました")
            } catch {
                notice = ErrorText.of(error)
            }
        }
    }

    func deleteArtwork(_ id: UUID) {
        Task {
            guard let api = session?.api else { return }
            do {
                let artwork = artScene?.artwork(id)
                let known = [artwork?.photo_path, artwork?.thumb_path].compactMap { $0 }
                let paths = try await api.deleteArtwork(id, knownPaths: known)
                artScene?.remove(id)
                artImages[id] = nil
                refreshArtCounts()
                art = nil
                for path in paths { await session?.media?.removePhoto(path: path) }
                Trace.log("自分の作品を消しました")
            } catch {
                notice = ErrorText.of(error)
            }
        }
    }
}
