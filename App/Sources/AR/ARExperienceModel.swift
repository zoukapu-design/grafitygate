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
        case createDetails
        case createPlace
        case createMapping
        case createSaving(String)
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
    let hand = HandTouch()

    let stage = ARStage()
    let mode: Mode
    var onFinished: (() -> Void)?

    weak var session: SessionModel?
    private weak var location: LocationModel?
    private(set) var door: GateDoor?
    private var doorAnchor: ARAnchor?
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
        if let api = session?.api, let media = session?.media, let info = try? await api.placeMap(gate) {
            phase = .findingPlace
            do {
                let map = try await media.worldMap(path: info.path)
                stopFindingRequested = false
                anchor = await stage.relocalize(with: map, anchorName: info.anchor_name, timeout: 20) { [weak self] in
                    self?.stopFindingRequested ?? true
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
            phase = index + 1 < Self.shootSteps.count ? .createShoot(index + 1) : .createDetails
        } catch {
            notice = ErrorText.of(error)
        }
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
        mappingProgress = 0
        mappingReady = false
        mappingTask?.cancel()
        mappingTask = Task { [weak self] in
            let started = Date()
            while let self, !Task.isCancelled, self.phase == .createMapping {
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
