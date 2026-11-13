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
        var image: UIImage?
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
            let list = try await api.artworks(in: gate).filter { $0.status == "published" }
            guard enteredGate == gate, let scene = artScene else { return }
            for artwork in list { scene.add(artwork, image: nil, animated: false) }
            refreshArtCounts()
            Trace.log("作品を \(list.count) 個受け取りました（写真パネル \(list.filter { $0.artKind == .photo }.count) 個）")
            if phase == .doorOpen { startHandIfNeeded() }
            let owners = Array(Set(list.map(\.owner)))
            if let names = try? await api.names(of: owners) { artNames.merge(names) { _, new in new } }
            await loadArtPhotos(list)
        } catch {
            Trace.log("作品を受け取れませんでした：\(ErrorText.of(error))")
        }
    }

    private func loadArtPhotos(_ list: [Artwork]) async {
        guard let media = session?.media else { return }
        for artwork in list where artwork.artKind == .photo {
            guard let path = artwork.photo_path, let image = await media.photo(path: path) else { continue }
            artImages[artwork.id] = image
            artScene?.setPhoto(image, for: artwork.id)
        }
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
        draft = ArtDraft()
        art = .choosing
    }

    func chooseArtKind(_ kind: ArtworkKind) {
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

    var draftProblem: String? {
        switch draft.kind {
        case .photo where draft.image == nil: return "写真を選ぶか、いまの景色を写してください。"
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
                             rules: Self.rules(for: draft.action), visibility: draft.visibility.rawValue,
                             status: "published", revision: 1, created_at: "")
        scene.previewDistance = draft.kind == .photo || draft.kind == .text ? 1.0 : 0.9
        scene.beginPreview(sample, image: draft.image)
        previewInRange = true
        art = .placing
    }

    func setPreviewScale(_ value: Float) {
        draft.scale = value
        artScene?.previewScale = value
    }

    /// 決まった形のルール：触れる・押すと選んだ動き、近づく・扉が開くとやわらかく光る
    static func rules(for action: ArtworkAction) -> [ArtworkRule] {
        [ArtworkRule(.touch, action, cooldownMS: 1200),
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

        var uploaded: String?
        do {
            if draft.kind == .photo, let image = draft.image {
                uploaded = try await media.uploadPhoto(image, owner: me)
            }
            let text = String(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.artTextLimit))
            let rules = Self.rules(for: draft.action)
            let id = try await api.placeArtwork(visit: visit, kind: draft.kind, body: draft.kind == .text ? text : "",
                                                photoPath: uploaded, color: draft.color, position: pose.position,
                                                yaw: pose.yaw, scale: pose.scale, rules: rules,
                                                visibility: draft.visibility)
            let placed = Artwork(id: id, gate_id: gate, owner: me, kind: draft.kind.rawValue,
                                 body: draft.kind == .text ? text : "", photo_path: uploaded,
                                 color: draft.color.rawValue, px: pose.position.x, py: pose.position.y,
                                 pz: pose.position.z, yaw: pose.yaw, scale: pose.scale, rules: rules,
                                 visibility: draft.visibility.rawValue, status: "published", revision: 1,
                                 created_at: ISO8601DateFormatter().string(from: Date()))
            scene.endPreview()
            let item = scene.add(placed, image: draft.image, animated: true)
            if let image = draft.image { artImages[id] = image }
            item.perform(.glow)
            item.perform(draft.action)
            refreshArtCounts()
            startHandIfNeeded()
            art = nil
            Haptics.success()
            Trace.log(String(format: "作品を置きました（%@・扉から 横 %.2f 高さ %.2f 奥 %.2f m・大きさ %.1f）",
                             draft.kind.label, pose.position.x, pose.position.y, pose.position.z, pose.scale))
        } catch {
            if let uploaded { await media.removePhoto(path: uploaded) }
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
                let photo = artScene?.artwork(id)?.photo_path
                try await api.deleteArtwork(id)
                artScene?.remove(id)
                artImages[id] = nil
                refreshArtCounts()
                art = nil
                if let photo { await session?.media?.removePhoto(path: photo) }
                Trace.log("自分の作品を消しました")
            } catch {
                notice = ErrorText.of(error)
            }
        }
    }
}
