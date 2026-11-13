import ARKit
import CoreLocation
import RealityKit
import SwiftUI

/// AR の画面の流れ。
/// 入る：向けて「ここで開く」→ サーバーが位置と写真の特徴で確かめる → 場所の記憶で同じ位置を探す
///      （見つからなければ、おおよその位置）→ 扉が現れる → 押すと開く → 中へ
/// 作る：3 方向から写す → 名前など → 扉を置く所を押す → 扉のまわりを見回して場所を覚える → 保存して開く
@MainActor
final class ARExperienceModel: ObservableObject {
    enum Mode: Equatable {
        case explore
        case enter(UUID)
    }

    enum Phase: Equatable {
        case scanning
        case working(String)
        case choosing([MatchCandidate])
        case findingPlace
        case doorClosed
        case doorOpen
        case createShoot(Int)
        /// 作る前に：近くに同じ場所らしい GATE がある
        case createSimilar([MatchCandidate])
        case createDetails
        case createPlace
        case createMapping
        case createSaving(String)
        /// 作った人が、場所の記憶を撮り直している（扉のまわりを見回す）
        case remapping
        case failed(String)
    }

    struct Shot: Identifiable {
        let id = UUID()
        let print: [Float]
        let jpeg: Data?
        let thumbnail: UIImage?
    }

    struct GateForm {
        var title = ""
        var note = ""
        var kind = "object"
        var visibility: Visibility = .friends
        var useCover = true
    }

    /// 作るときに写す 3 方向
    static let shootSteps = ["正面から", "少し左から", "少し右から"]

    @Published private(set) var phase: Phase = .scanning
    @Published var notice: String?
    @Published private(set) var nearby: [NearbyGate] = []
    @Published private(set) var shots: [Shot] = []
    @Published private(set) var placedPrecisely = false
    @Published private(set) var hasPlacedDoor = false
    @Published private(set) var mappingProgress: Double = 0
    @Published private(set) var mappingReady = false
    @Published private(set) var mapWarning: String?
    @Published var presentedGate: GateRoute?
    @Published var form = GateForm()

    // AR の作品（扉が開いたあと）
    @Published var art: ArtStep?
    @Published var draft = ArtDraft()
    @Published var previewInRange = true
    @Published var artCaption: String?
    @Published var artworkCount = 0
    @Published var myArtworkCount = 0
    @Published var reportItem: ReportItem?
    /// この入場で進んだ TRAIL（「TRAIL「…」の 2/5 に着きました」）
    @Published var trailNote: String?
    /// 扉の位置を指で合わせているあいだ（おおよその位置に出たとき。動かすのは自分の画面だけ）
    @Published private(set) var adjustingDoor = false
    /// この GATE を作った本人か（場所の記憶を撮り直せる）
    @Published private(set) var isGateOwner = false
    /// ちょっとした知らせ（数秒で消える）
    @Published private(set) var toast: String?
    let hand = HandTouch()

    let stage = ARStage()
    let mode: Mode
    var onFinished: (() -> Void)?

    weak var session: SessionModel?
    private weak var location: LocationModel?
    private(set) var door: GateDoor?
    private var doorAnchor: ARAnchor?
    /// いま扉が付いている印（場所の記憶で見つけた印か、おおよその位置に置いた印）
    private var currentAnchor: ARAnchor?
    private var rotateStartYaw: Float?
    private var toastTask: Task<Void, Never>?
    private(set) var enteredGate: UUID?
    /// いまの入場券（作品を置く・動かすのに使う）と、その期限
    var visitID: UUID?
    var visitExpires: Date?
    var artScene: ArtworkScene?
    var artImages: [UUID: UIImage] = [:]
    var artNames: [UUID: String] = [:]
    var movingArtwork: UUID?
    var captionTask: Task<Void, Never>?
    private var lastPrint: [Float]?
    private var clientKey = UUID().uuidString
    private var stopFindingRequested = false
    private var mappingTask: Task<Void, Never>?

    init(mode: Mode) {
        self.mode = mode
    }

    func attach(session: SessionModel, location: LocationModel) {
        self.session = session
        self.location = location
    }

    var showsReticle: Bool {
        switch phase {
        case .scanning, .createShoot: return true
        default: return false
        }
    }

    // MARK: 始める・やめる

    func start() {
        stage.run(reset: true)
        Trace.log("AR の画面を開く（\(mode == .explore ? "撮る" : "GATE に入る")）")
        resetToScanning()
        Task { await refreshNearby() }
    }

    func stop() {
        ChimePlayer.shared.stop()
        stopFindingRequested = true
        mappingTask?.cancel()
        captionTask?.cancel()
        clearDoor()
        stage.pause()
        DoorTextures.releaseAll()
    }

    func resetToScanning() {
        clearDoor()
        notice = nil
        mapWarning = nil
        shots = []
        enteredGate = nil
        visitID = nil
        visitExpires = nil
        trailNote = nil
        isGateOwner = false
        phase = .scanning
    }

    private func clearDoor() {
        hand.stop()
        artScene?.removeAll()
        artScene = nil
        art = nil
        artImages.removeAll()
        artworkCount = 0
        myArtworkCount = 0
        movingArtwork = nil
        door?.remove()
        door = nil
        if let anchor = doorAnchor { stage.removeAnchor(anchor) }
        doorAnchor = nil
        currentAnchor = nil
        adjustingDoor = false
        rotateStartYaw = nil
        hasPlacedDoor = false
    }

    func refreshNearby() async {
        guard mode == .explore, let api = session?.api, let here = location?.location, here.horizontalAccuracy >= 0
        else { return }
        nearby = (try? await api.nearby(here)) ?? nearby
    }

    // MARK: 入る

    func openHere() {
        Task { await openHereAsync() }
    }

    private func openHereAsync() async {
        guard let api = session?.api else {
            notice = session?.problem ?? "サーバーにつながっていません。"
            return
        }
        guard let fix = location?.usableFix else {
            notice = location?.fixProblem
            return
        }
        if let problem = stage.shotProblem() {
            notice = problem
            return
        }
        notice = nil
        phase = .working("この場所を確かめています…")
        do {
            let shot = try await stage.grabShot(withPhoto: false)
            lastPrint = shot.print
            switch mode {
            case .enter(let gate):
                await enter(gate, fix: fix, print: shot.print)
            case .explore:
                let list = try await api.candidates(fix, print: shot.print)
                Trace.log("近くの候補：\(list.map { "\($0.title)=\($0.similarity)" }.joined(separator: "、"))")
                if let best = list.first(where: { $0.similarity == "strong" }) {
                    await enter(best.id, fix: fix, print: shot.print)
                } else if list.isEmpty {
                    phase = .failed("近く（100m 以内）に入れる GATE はありません。「ここに GATE を作る」で、この場所に作れます。")
                } else {
                    phase = .choosing(list)
                }
            }
        } catch {
            phase = .failed(ErrorText.of(error))
        }
    }

    func choose(_ candidate: MatchCandidate) {
        guard let fix = location?.usableFix, let print = lastPrint else {
            notice = location?.fixProblem
            return
        }
        Task { await enter(candidate.id, fix: fix, print: print) }
    }

    private func enter(_ gate: UUID, fix: CLLocation, print: [Float]) async {
        guard let api = session?.api else { return }
        phase = .working("扉を開ける準備をしています…")
        do {
            let result = try await api.enter(gate: gate, location: fix, print: print)
            guard result.ok else {
                Trace.log("入場できませんでした：\(result.reason ?? "不明")")
                phase = .failed(ErrorText.enterReason(result.reason))
                return
            }
            Trace.log(String(format: "入場しました（位置の精度 ±%.0fm）", fix.horizontalAccuracy))
            enteredGate = gate
            visitID = result.visit_id
            visitExpires = result.expires_at.flatMap(ServerDate.parse)
            if let visit = result.visit_id { Task { await loadTrailNote(visit) } }
            await showDoor(for: gate)
        } catch {
            phase = .failed(ErrorText.of(error))
        }
    }

    /// 場所の記憶があれば作った人と同じ位置に、なければ（見つからなければ）おおよその位置に扉を出す
    private func showDoor(for gate: UUID) async {
        clearDoor()
        var anchor: ARAnchor?
        if let api = session?.api {
            isGateOwner = (try? await api.summary(gate))?.owner == session?.userID
        }
        if let api = session?.api, let media = session?.media, let info = try? await api.placeMap(gate) {
            phase = .findingPlace
            let started = Date()
            do {
                let map = try await media.worldMap(path: info.path)
                stopFindingRequested = false
                anchor = await stage.relocalize(with: map, anchorName: info.anchor_name, timeout: 20) { [weak self] in
                    self?.stopFindingRequested ?? true
                }
                // 見つかったか・何秒探したかだけを送る（見つからない日が続くと、作った人に撮り直しを知らせる）
                let seconds = Date().timeIntervalSince(started)
                let found = anchor != nil
                Trace.log(String(format: "場所の記憶：%@（%.1f 秒）", found ? "見つかった" : "見つからなかった", seconds))
                if let visit = visitID {
                    Task { try? await api.reportRelocalize(visit: visit, found: found, seconds: seconds) }
                }
            } catch {
                Trace.log("場所の記憶を受け取れませんでした：\(ErrorText.of(error))")
            }
        }
        placedPrecisely = anchor != nil
        if anchor == nil {
            _ = await stage.waitUntilTracking(timeout: 4)
            guard let transform = stage.placementInFront(distance: 2.0) else {
                phase = .failed("扉を置く場所が見つかりませんでした。周りを見回してから、もう一度お試しください。")
                return
            }
            let placed = stage.addAnchor(named: "gg.visit", transform: transform)
            doorAnchor = placed
            anchor = placed
        }
        guard let anchor else { return }
        currentAnchor = anchor
        do {
            let newDoor = try GateDoor(anchor: anchor, in: stage.arView)
            door = newDoor
            hasPlacedDoor = true
            newDoor.appear()
            Haptics.success()
            phase = .doorClosed
            Trace.log(placedPrecisely ? "扉を作った人と同じ位置に出しました" : "扉をおおよその位置（2m 前）に出しました")
            makeArtScene()
            Task { await loadDoorPhotos(gate) }
            Task { await loadArtworks(gate) }
        } catch {
            Trace.log("扉を組み立てられませんでした：\(error)")
            phase = .failed("扉を表示できませんでした。")
        }
    }

    private func loadTrailNote(_ visit: UUID) async {
        guard let api = session?.api, let reached = try? await api.trailsReached(visit: visit), !reached.isEmpty else { return }
        trailNote = reached.map { r in
            r.completed ? "TRAIL「\(r.title)」を歩き終わりました！" : "TRAIL「\(r.title)」の \(r.reached)/\(r.stop_count) に着きました"
        }.joined(separator: "\n")
        Haptics.success()
        Trace.log("TRAIL が進みました（\(reached.count) 本）")
    }

    /// 場所の記憶を探すのをやめて、おおよその位置に出す
    func stopFindingPlace() {
        stopFindingRequested = true
    }

    private func loadDoorPhotos(_ gate: UUID) async {
        guard let api = session?.api, let media = session?.media else { return }
        var paths: [String] = []
        if let cover = try? await api.summary(gate)?.cover_path { paths.append(cover) }
        if let items = try? await api.graffiti(in: gate) {
            paths += items.compactMap(\.photo_path).prefix(3)
        }
        var images: [UIImage] = []
        for path in paths.prefix(3) {
            if let image = await media.photo(path: path) { images.append(image) }
        }
        if !images.isEmpty { door?.setPhotos(images) }
    }

    func openDoor() {
        guard let door, phase == .doorClosed else { return }
        door.open()
        Haptics.open()
        phase = .doorOpen
        revealArtworks()
    }

    func goInside() {
        guard let gate = enteredGate else { return }
        switch mode {
        case .explore: presentedGate = GateRoute(id: gate)
        case .enter: onFinished?()
        }
    }

    func handleTap(at point: CGPoint) {
        guard !adjustingDoor else { return }
        switch phase {
        case .doorClosed:
            if door?.isHit(stage.arView.entity(at: point)) == true { openDoor() }
        case .doorOpen:
            tapArtwork(at: point)
        case .createPlace:
            placeNewDoor(at: point)
        default:
            break
        }
    }

    // MARK: 作る

    func startCreate() {
        clearDoor()
        visitID = nil
        visitExpires = nil
        shots = []
        clientKey = UUID().uuidString
        form = GateForm()
        notice = nil
        mapWarning = nil
        phase = .createShoot(0)
    }

    func captureCreateShot() {
        Task { await captureCreateShotAsync() }
    }

    private func captureCreateShotAsync() async {
        guard case .createShoot(let index) = phase else { return }
        if let problem = stage.shotProblem() {
            notice = problem
            return
        }
        notice = nil
        do {
            let shot = try await stage.grabShot(withPhoto: true)
            let thumbnail = shot.jpeg.flatMap(UIImage.init(data:))?.downscaled(maxSide: 240)
            shots.append(Shot(print: shot.print, jpeg: index == 0 ? shot.jpeg : nil, thumbnail: thumbnail))
            Haptics.tap()
            if shots.count >= 2, let a = shots.first?.print, let d = FeaturePrint.distance(a, shot.print) {
                Trace.log(String(format: "作る：正面と %@ の写真の特徴の距離 %.3f", Self.shootSteps[index], d))
            }
            if index + 1 < Self.shootSteps.count {
                phase = .createShoot(index + 1)
            } else {
                await checkSimilar()
            }
        } catch {
            notice = ErrorText.of(error)
        }
    }

    /// 作る前に、近く（100m 以内）に同じ場所らしい GATE がないか確かめる。あれば「入る」か「新しく作る」かを本人が選ぶ
    private func checkSimilar() async {
        guard let api = session?.api, let fix = location?.usableFix, let first = shots.first else {
            phase = .createDetails
            return
        }
        phase = .working("近くに同じ場所の GATE がないか確かめています…")
        let list = (try? await api.candidates(fix, print: first.print)) ?? []
        let similar = list.filter { $0.similarity == "strong" || $0.similarity == "weak" }
        Trace.log("作る前の確かめ：似た GATE \(similar.count) 件（\(similar.map(\.similarity).joined(separator: "、"))）")
        if similar.isEmpty {
            phase = .createDetails
        } else {
            lastPrint = first.print
            phase = .createSimilar(similar)
        }
    }

    /// 似た GATE があっても、自分の GATE を新しく作る
    func continueCreating() {
        Trace.log("似た GATE があったが、新しく作る")
        phase = .createDetails
    }

    func confirmDetails() {
        guard !form.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = "名前を入れてください。"
            return
        }
        notice = nil
        phase = .createPlace
    }

    private func placeNewDoor(at point: CGPoint) {
        guard let floor = stage.floorTransform(at: point) else {
            notice = "地面が見つかりません。iPhone を少し下に向けて、地面を映してください。"
            return
        }
        clearDoor()
        let anchor = stage.addAnchor(named: "gg.gate", transform: stage.facingCamera(at: floor))
        do {
            let newDoor = try GateDoor(anchor: anchor, in: stage.arView)
            newDoor.appear()
            door = newDoor
            doorAnchor = anchor
            hasPlacedDoor = true
            notice = nil
            Haptics.tap()
        } catch {
            stage.removeAnchor(anchor)
            notice = "扉を表示できませんでした。"
        }
    }

    func confirmPlace() {
        guard hasPlacedDoor else { return }
        phase = .createMapping
        startMappingProgress()
    }

    /// 見回した量を進み具合にする（場所を覚えるとき・撮り直すとき）
    private func startMappingProgress() {
        mappingProgress = 0
        mappingReady = false
        mappingTask?.cancel()
        mappingTask = Task { [weak self] in
            let started = Date()
            while let self, !Task.isCancelled, self.phase == .createMapping || self.phase == .remapping {
                let elapsed = Date().timeIntervalSince(started)
                let target: Double
                switch self.stage.mapping {
                case .mapped: target = 1
                case .extending: target = 0.8
                case .limited: target = 0.45
                default: target = 0.15
                }
                self.mappingProgress = min(target, 0.1 + elapsed / 7)
                self.mappingReady = elapsed >= 4 && (self.stage.mapping == .mapped || self.stage.mapping == .extending)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func saveGate() {
        Task { await saveGateAsync() }
    }

    private func saveGateAsync() async {
        guard let api = session?.api, let media = session?.media, let me = session?.userID else {
            notice = session?.problem ?? "サーバーにつながっていません。"
            return
        }
        guard let fix = location?.usableFix else {
            notice = location?.fixProblem
            return
        }
        mappingTask?.cancel()
        phase = .createSaving("GATE を作っています…")
        do {
            var cover: String?
            if form.useCover, let jpeg = shots.first?.jpeg {
                cover = try await media.uploadJPEG(jpeg, owner: me)
            }
            let gate = try await api.createGate(clientKey: clientKey,
                                                title: form.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                note: form.note.trimmingCharacters(in: .whitespacesAndNewlines),
                                                kind: form.kind, visibility: form.visibility, location: fix,
                                                heading: location?.heading, coverPath: cover,
                                                prints: shots.map(\.print))
            Trace.log(String(format: "GATE を作りました（位置の精度 ±%.0fm）", fix.horizontalAccuracy))

            phase = .createSaving("場所の記憶を保存しています…")
            do {
                let map = try await stage.captureWorldMap()
                let saved = try await media.uploadWorldMap(map, owner: me, gate: gate)
                try await api.registerPlaceMap(gate: gate, path: saved.path, size: saved.size, anchorName: "gg.gate")
            } catch {
                Trace.log("場所の記憶を保存できませんでした：\(ErrorText.of(error))")
                mapWarning = "場所の記憶を保存できませんでした。友達の iPhone では、扉がおおよその位置に出ます。"
            }

            phase = .createSaving("扉を開けています…")
            let shot = try await stage.grabShot(withPhoto: false)
            let result = try await api.enter(gate: gate, location: fix, print: shot.print)
            enteredGate = gate
            if result.ok {
                visitID = result.visit_id
                visitExpires = result.expires_at.flatMap(ServerDate.parse)
                placedPrecisely = true   // 作った人が置いたその場所（場所の記憶の印そのもの）
                makeArtScene()
                door?.open()
                Haptics.open()
                phase = .doorOpen
                revealArtworks()
            } else {
                Trace.log("作ったあとの入場ができませんでした：\(result.reason ?? "不明")")
                phase = .failed("GATE はできました。ただ、入場の確かめが通りませんでした。" + ErrorText.enterReason(result.reason))
            }
        } catch {
            phase = .failed(ErrorText.of(error))
        }
    }
}

// MARK: - 扉の位置を指で合わせる・場所の記憶を撮り直す

extension ARExperienceModel {
    /// 扉の位置を指で合わせ始める（おおよその位置に出たとき。動かすのは自分の画面だけ）
    func beginAdjust() {
        guard door != nil else { return }
        art = nil
        adjustingDoor = true
        Trace.log("扉の位置を指で合わせ始めました")
    }

    /// 指の下の地面へ扉を動かす（印から 6m まで）
    func dragDoor(to point: CGPoint) {
        guard adjustingDoor, let door, let floor = stage.floorTransform(at: point) else { return }
        let world = SIMD3<Float>(floor.columns.3.x, floor.columns.3.y, floor.columns.3.z)
        let local = door.anchorEntity.convert(position: world, from: nil)
        guard simd_length(SIMD2<Float>(local.x, local.z)) < 6 else { return }
        door.setNudge(position: local, yaw: door.nudgeYaw)
    }

    /// 2 本指で回す
    func rotateDoor(by radians: Double) {
        guard adjustingDoor, let door else { return }
        if rotateStartYaw == nil { rotateStartYaw = door.nudgeYaw }
        door.setNudge(position: door.nudgePosition, yaw: (rotateStartYaw ?? 0) - Float(radians))
    }

    func endRotate() {
        rotateStartYaw = nil
    }

    func resetAdjust() {
        door?.setNudge(position: .zero, yaw: 0)
        Haptics.tap()
    }

    func finishAdjust() {
        adjustingDoor = false
        rotateStartYaw = nil
        if let door {
            Trace.log(String(format: "扉の位置を指で合わせました（印から %.2fm・%.0f°）",
                             simd_length(door.nudgePosition), door.nudgeYaw * 180 / .pi))
        }
        Haptics.success()
    }

    /// 作った人が、いまの扉の位置で場所の記憶を撮り直す（まわりを見回してから保存）
    func startRemap() {
        guard isGateOwner, door != nil, enteredGate != nil else { return }
        adjustingDoor = false
        art = nil
        notice = nil
        phase = .remapping
        startMappingProgress()
        Trace.log("場所の記憶の撮り直しを始めました")
    }

    func cancelRemap() {
        mappingTask?.cancel()
        phase = door?.isOpen == true ? .doorOpen : .doorClosed
    }

    func saveRemap() {
        Task { await saveRemapAsync() }
    }

    private func saveRemapAsync() async {
        guard let door, let gate = enteredGate, let api = session?.api, let media = session?.media,
              let me = session?.userID else { return }
        mappingTask?.cancel()
        phase = .createSaving("場所の記憶を撮り直しています…")
        // いまの扉の台の位置に新しい印を置き、扉をその印に付け替える（見た目の位置は変わらない）
        let newAnchor = stage.addAnchor(named: "gg.gate", transform: door.baseWorldTransform)
        door.anchorEntity.reanchor(.anchor(identifier: newAnchor.identifier), preservingWorldTransform: true)
        if let old = currentAnchor, old.identifier != newAnchor.identifier { stage.removeAnchor(old) }
        currentAnchor = newAnchor
        doorAnchor = newAnchor
        do {
            let map = try await stage.captureWorldMap()
            let saved = try await media.uploadWorldMap(map, owner: me, gate: gate)
            try await api.registerPlaceMap(gate: gate, path: saved.path, size: saved.size, anchorName: "gg.gate")
            placedPrecisely = true
            mapWarning = nil
            Haptics.success()
            showToast("場所の記憶を撮り直しました。友達の iPhone でも、この位置に扉が出ます。")
            Trace.log("場所の記憶を撮り直しました（\(saved.size / 1024)KB）")
        } catch {
            notice = "場所の記憶を保存できませんでした。" + ErrorText.of(error)
            Trace.log("場所の記憶を撮り直せませんでした：\(ErrorText.of(error))")
        }
        phase = door.isOpen ? .doorOpen : .doorClosed
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
