import ARKit
import Combine
import CoreLocation
import RealityKit
import SwiftUI

/// AR の画面の流れ。
/// 入る：向けて「ここで開く」→ サーバーが位置と写真の特徴で確かめる → GATE の位置の記録で同じ位置を探す
///      （見つからなければ、おおよその位置）→ 扉が現れる → 押すと開く → 中へ
/// 作る：3 方向から写す → 名前など → 扉を置く所を押す → 扉のまわりを見回して場所を覚える → 保存して開く
@MainActor
final class ARExperienceModel: ObservableObject {
    enum Mode: Equatable {
        case explore
        case enter(UUID)
        /// 作った本人が、別の時間の見え方（見本の写真の特徴）を足す
        case addLooks(UUID)
    }

    enum Phase: Equatable {
        case scanning
        /// 作る：はじめに、何を GATE にするか（物・場所・景色）を選ぶ
        case createKind
        /// 見え方を足す：写す（作った本人が現地で）
        case addLooksShoot
        /// 見え方を足した（足したあとの数・上限）
        case addLooksDone(Int, Int)
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
        /// 送れなかった（写真・名前・扉の位置は残っている。「もう一度送る」で続きから）
        case createRetry(String)
        /// 作った人が、GATE の位置の記録を撮り直している（扉のまわりを見回す）
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

    /// 作るときの種類（はじめに選ぶ）
    var createKind: GateKind { GateKind(raw: form.kind) }
    /// 扉の大きさ（1 = 人が通る大きさ）。作る人が置くときに選び、サーバーに残して見る人にも同じ大きさで出す
    @Published private(set) var doorScale: Float = 1
    static let doorSizes: [(label: String, scale: Float)] = [("小", 0.3), ("中", 0.6), ("大", 1.0)]
    /// 種類ごとのはじめの大きさ（机の上の物に人の大きさの扉は大きすぎる）
    static func defaultDoorScale(for kind: GateKind) -> Float {
        switch kind {
        case .object: return 0.35
        case .place, .view: return 1.0
        }
    }
    /// つまんで大きさを変えるときの、つまみ始めの大きさ
    private var pinchStartScale: Float?
    /// サーバーに残っている扉の大きさ
    private var savedDoorScale: Float = 1

    func setDoorScale(_ value: Float) {
        doorScale = min(max(value, 0.2), 1.5)
        door?.setSize(doorScale)
    }

    func pinchDoor(by magnification: CGFloat) {
        let start = pinchStartScale ?? doorScale
        pinchStartScale = start
        setDoorScale(start * Float(magnification))
    }

    func endPinch() {
        pinchStartScale = nil
        Trace.log(String(format: "扉の大きさ：%.2f 倍", doorScale))
    }

    /// 扉の大きさを変えられるとき（作って置くとき・作った本人が位置を合わせるとき）
    var canResizeDoor: Bool {
        (phase == .createPlace && hasPlacedDoor) || (adjustingDoor && isGateOwner)
    }
    /// 入る・見え方を足す GATE の種類（分かったら入れる。景色なら写真の確かめを景色用にする）
    @Published private(set) var targetKind: GateKind?
    /// 見え方を足すときに写した写真の特徴
    @Published private(set) var lookShots: [Shot] = []
    /// 見本の数と上限（見え方を足すとき。作った本人だけが分かる）
    @Published private(set) var refCount: (count: Int, max: Int)?
    static let maxLookShots = 3

    @Published private(set) var phase: Phase = .scanning
    @Published var notice: String?
    @Published private(set) var nearby: [NearbyGate] = []
    /// 近くの GATE を一度でも調べ終えたか（調べる前に「ありません」と出さないため）
    @Published private(set) var nearbyChecked = false
    @Published private(set) var shots: [Shot] = []
    @Published private(set) var placedPrecisely = false
    @Published private(set) var hasPlacedDoor = false
    @Published private(set) var mappingProgress: Double = 0
    @Published private(set) var mappingReady = false
    @Published private(set) var mapWarning: String?
    @Published var presentedGate: GateRoute?
    @Published var form = GateForm()

    // AR の飾り（扉が開いたあと）
    @Published var art: ArtStep?
    @Published var draft = ArtDraft()
    /// その場で人を撮る（人物の映像）
    let personRecorder = ARPersonRecorder()
    @Published var capturingPerson = false
    /// 撮ったあと、人を切り抜いているあいだの進み具合（0〜1）
    @Published var personCutProgress: Double?
    @Published var previewInRange = true
    @Published var artCaption: String?
    @Published var artworkCount = 0
    @Published var myArtworkCount = 0
    /// いま流している映像パネル・声の玉
    @Published var playingArtwork: UUID?
    @Published var reportItem: ReportItem?
    /// この入場で進んだ TRAIL（「TRAIL「…」の 2/5 に着きました」）
    @Published var trailNote: String?
    /// 歩き終えた TRAIL（「ゴール！」を出す）
    @Published var trailGoal: TrailReached?
    /// 扉が出たら光を出す、着いた TRAIL
    private var pendingTrail: [TrailReached] = []
    /// 扉の位置を指で合わせているあいだ（仮の位置に出たとき。動かすのは自分の画面だけ）
    @Published private(set) var adjustingDoor = false
    /// この GATE を作った本人か（GATE の位置の記録を撮り直せる）
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
    /// いま扉が付いている印（GATE の位置の記録で見つけた印か、おおよその位置に置いた印）
    private var currentAnchor: ARAnchor?
    private var rotateStartYaw: Float?
    private var toastTask: Task<Void, Never>?
    private(set) var enteredGate: UUID?
    /// いまの入場券（AR の飾りを置く・動かすのに使う）と、その期限
    var visitID: UUID?
    /// 入ろうとしている GATE の方向の案内（GATE の画面から開いたとき）
    @Published var guideGate: GuideGate?
    private var keeperWatch: AnyCancellable?
    var visitExpires: Date?
    var artScene: ArtworkScene?
    var artImages: [UUID: UIImage] = [:]
    var artNames: [UUID: String] = [:]
    var movingArtwork: UUID?
    /// 受け取っている途中の映像・声（同じものを何度も受け取らない）
    var artMediaLoading: Set<UUID> = []
    var captionTask: Task<Void, Never>?
    private var lastPrint: [Float]?
    private var clientKey = UUID().uuidString
    /// 送り直しのための途中の記録（できた GATE・送った表紙・GATE の位置の記録を保存したか）
    private var createdGate: UUID?
    private var uploadedCover: String?
    private var placeMapSaved = false
    private var stopFindingRequested = false
    private var mappingTask: Task<Void, Never>?

    init(mode: Mode) {
        self.mode = mode
    }

    func attach(session: SessionModel, location: LocationModel) {
        self.session = session
        self.location = location
        keeperWatch = VisitKeeper.shared.$entries.sink { [weak self] entries in
            guard let self, let visit = self.visitID, let entry = entries[visit] else { return }
            // その場にいるあいだ延びた時刻（離れて閉じかけたときも、ここで短くなる）
            self.visitExpires = entry.expires
        }
    }

    /// 扉は、その場にいるあいだ開いたまま（位置を送るのは VisitKeeper）
    private func keepDoorOpen(gate: UUID) {
        guard let visit = visitID, let session, let location else { return }
        VisitKeeper.shared.track(visit: visit, gate: gate, expires: visitExpires, session: session, location: location)
    }

    var showsReticle: Bool {
        switch phase {
        case .scanning, .createShoot, .addLooksShoot: return true
        default: return false
        }
    }

    /// いまの写真を景色用に確かめるか。作るときは選んだ種類、入る・見え方を足すときはその GATE の種類、
    /// 「ここで開く」のときは近くに景色の GATE があるか
    private var checksAsView: Bool {
        switch phase {
        case .createShoot: return createKind == .view
        default: break
        }
        switch mode {
        case .explore: return nearby.contains { $0.kind == GateKind.view.rawValue }
        case .enter, .addLooks: return targetKind == .view
        }
    }

    // MARK: 始める・やめる

    func start() {
        stage.run(reset: true)
        switch mode {
        case .explore: Trace.log("AR の画面を開く（撮る）")
        case .enter: Trace.log("AR の画面を開く（GATE に入る）")
        case .addLooks: Trace.log("AR の画面を開く（見え方を足す）")
        }
        resetToScanning()
        Task { await refreshNearby() }
        Task { await loadTargetKind() }
    }

    /// 入る・見え方を足す GATE の種類と、見本の数（作った本人だけ）
    private func loadTargetKind() async {
        guard let api = session?.api else { return }
        switch mode {
        case .explore:
            return
        case .enter(let gate):
            let summary = try? await api.summary(gate)
            targetKind = GateKind(raw: summary?.kind)
            if let summary {
                // カメラの景色に、この GATE の方向と距離を出す（場所はおおよそ）
                guideGate = GuideGate(id: summary.id, title: summary.title,
                                      latitude: summary.approx_lat, longitude: summary.approx_lon)
            }
        case .addLooks(let gate):
            targetKind = GateKind(raw: try? await api.summary(gate)?.kind)
            if let c = try? await api.gateRefCount(gate) { refCount = (c.count, c.max) }
        }
    }

    func stop() {
        personRecorder.cancel()
        capturingPerson = false
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
        trailGoal = nil
        pendingTrail = []
        isGateOwner = false
        lookShots = []
        if case .addLooks = mode {
            phase = .addLooksShoot
        } else {
            phase = .scanning
        }
    }

    private func clearDoor() {
        hand.stop()
        artScene?.removeAll()
        artScene = nil
        discardArtMedia()
        art = nil
        artImages.removeAll()
        playingArtwork = nil
        artMediaLoading.removeAll()
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
        if let list = try? await api.nearby(here) {
            nearby = list.sorted { $0.distance_m < $1.distance_m }
            nearbyChecked = true
        }
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
            location?.askFullAccuracyIfNeeded()
            return
        }
        if let problem = stage.shotProblem(view: checksAsView) {
            notice = problem
            return
        }
        notice = nil
        phase = .working("この場所を確かめています…")
        do {
            let shot = try await stage.grabShot(withPhoto: false)
            lastPrint = shot.print
            switch mode {
            case .enter(let gate), .addLooks(let gate):
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
            location?.askFullAccuracyIfNeeded()
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
            keepDoorOpen(gate: gate)
            if let visit = result.visit_id { Task { await loadTrailNote(visit) } }
            await showDoor(for: gate)
        } catch {
            phase = .failed(ErrorText.of(error))
        }
    }

    /// GATE の位置の記録があれば作った人と同じ位置に、なければ（見つからなければ）おおよその位置に扉を出す
    private func showDoor(for gate: UUID) async {
        clearDoor()
        var anchor: ARAnchor?
        if let api = session?.api, let summary = try? await api.summary(gate) {
            isGateOwner = summary.owner == session?.userID
            // 景色の GATE は、扉の向こうに本物の景色が見える額縁にする
            targetKind = GateKind(raw: summary.kind)
            // 扉の大きさは作った人が決めたもの（前のサーバーでは 1 倍）
            doorScale = (try? await api.doorScale(gate)) ?? 1
            savedDoorScale = doorScale
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
                Trace.log(String(format: "GATE の位置の記録：%@（%.1f 秒）", found ? "見つかった" : "見つからなかった", seconds))
                if let visit = visitID {
                    Task { try? await api.reportRelocalize(visit: visit, found: found, seconds: seconds) }
                }
            } catch {
                Trace.log("GATE の位置の記録を受け取れませんでした：\(ErrorText.of(error))")
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
            let newDoor = try GateDoor(anchor: anchor, in: stage.arView, style: targetKind == .view ? .window : .portal)
            newDoor.setSize(doorScale)
            door = newDoor
            hasPlacedDoor = true
            newDoor.appear()
            Haptics.success()
            phase = .doorClosed
            if !pendingTrail.isEmpty {
                let reached = pendingTrail
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    celebrateTrail(reached)
                }
            }
            Trace.log(placedPrecisely ? "扉を作った人と同じ位置に出しました" : "扉を仮の位置（2m 前）に出しました")
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
        if door != nil {
            celebrateTrail(reached)
        } else {
            pendingTrail = reached
        }
    }

    /// TRAIL の地点に着いた・歩き終えたときの演出（扉の足もとの光・鐘・ゴールの画面）
    private func celebrateTrail(_ reached: [TrailReached]) {
        pendingTrail = []
        let goal = reached.first(where: \.completed)
        door?.celebrate(big: goal != nil)
        let notes: [ArtworkColor] = goal != nil ? [.warm, .sakura, .mint, .sky, .sky] : [.warm, .sky]
        Task {
            for (i, note) in notes.enumerated() {
                if i > 0 { try? await Task.sleep(nanoseconds: 180_000_000) }
                ChimePlayer.shared.play(note)
            }
        }
        if let goal {
            Haptics.success()
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                trailGoal = goal
            }
        } else if let first = reached.first {
            showToast("TRAIL「\(first.title)」 \(first.reached)/\(first.stop_count) に着きました")
        }
    }

    /// GATE の位置の記録を探すのをやめて、仮の位置に出す
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
        case .enter, .addLooks: onFinished?()
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
        createdGate = nil
        uploadedCover = nil
        placeMapSaved = false
        form = GateForm()
        notice = nil
        mapWarning = nil
        phase = .createKind
    }

    // MARK: 見え方を足す（作った本人が現地で）

    func captureLookShot() {
        Task { await captureLookShotAsync() }
    }

    private func captureLookShotAsync() async {
        guard phase == .addLooksShoot, lookShots.count < Self.maxLookShots else { return }
        if let problem = stage.shotProblem(view: checksAsView) {
            notice = problem
            return
        }
        notice = nil
        do {
            let shot = try await stage.grabShot(withPhoto: true)
            let thumbnail = shot.jpeg.flatMap(UIImage.init(data:))?.downscaled(maxSide: 240)
            // 写真そのものは送らない（特徴だけ）。縮めた絵は、この画面で見せるだけ
            lookShots.append(Shot(print: shot.print, jpeg: nil, thumbnail: thumbnail))
            Haptics.tap()
            Trace.log("見え方を足す：\(lookShots.count) 枚め")
        } catch {
            notice = ErrorText.of(error)
        }
    }

    func sendLooks() {
        Task { await sendLooksAsync() }
    }

    private func sendLooksAsync() async {
        guard case .addLooks(let gate) = mode, !lookShots.isEmpty, let api = session?.api else { return }
        guard let fix = location?.usableFix else {
            notice = location?.fixProblem
            location?.askFullAccuracyIfNeeded()
            return
        }
        notice = nil
        phase = .working("見え方を足しています…")
        do {
            let count = try await api.addGateRefs(gate: gate, location: fix, prints: lookShots.map(\.print))
            let max = refCount?.max ?? 12
            refCount = (count, max)
            Trace.log(String(format: "見え方を足しました（%d 枚・見本 %d/%d・位置の精度 ±%.0fm）",
                             lookShots.count, count, max, fix.horizontalAccuracy))
            lookShots = []
            Haptics.success()
            phase = .addLooksDone(count, max)
        } catch {
            Trace.log("見え方を足せませんでした：\(ErrorText.of(error))")
            phase = .addLooksShoot
            notice = ErrorText.of(error)
        }
    }

    func addMoreLooks() {
        lookShots = []
        notice = nil
        phase = .addLooksShoot
    }

    /// 何を GATE にするかを選んで、写し始める
    func chooseKind(_ kind: GateKind) {
        form.kind = kind.rawValue
        doorScale = Self.defaultDoorScale(for: kind)
        notice = nil
        Trace.log("作る：種類「\(kind.label)」")
        phase = .createShoot(0)
    }

    func captureCreateShot() {
        Task { await captureCreateShotAsync() }
    }

    private func captureCreateShotAsync() async {
        guard case .createShoot(let index) = phase else { return }
        if let problem = stage.shotProblem(view: createKind == .view) {
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
                Trace.log(String(format: "作る：正面と %@ の写真の特徴の距離 %.3f", createKind.shootSteps[index], d))
            }
            if index + 1 < createKind.shootSteps.count {
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
            let newDoor = try GateDoor(anchor: anchor, in: stage.arView, style: createKind == .view ? .window : .portal)
            newDoor.setSize(doorScale)
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
            location?.askFullAccuracyIfNeeded()
            return
        }
        mappingTask?.cancel()
        notice = nil
        let retrying = createdGate != nil || uploadedCover != nil
        phase = .createSaving(retrying ? "続きから送っています…" : "GATE を作っています…")
        do {
            // 1. GATE を作る（同じ client_key なので、送り直しても 1 つしかできない）
            let gate: UUID
            if let createdGate {
                gate = createdGate
            } else {
                if form.useCover, uploadedCover == nil, let jpeg = shots.first?.jpeg {
                    uploadedCover = try await media.uploadJPEG(jpeg, owner: me)
                }
                gate = try await api.createGate(clientKey: clientKey,
                                                title: form.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                                note: form.note.trimmingCharacters(in: .whitespacesAndNewlines),
                                                kind: form.kind, visibility: form.visibility, location: fix,
                                                heading: location?.heading, coverPath: form.useCover ? uploadedCover : nil,
                                                prints: shots.map(\.print))
                createdGate = gate
                // 扉の大きさ（前のサーバーでは無いので、送れなくても続ける）
                savedDoorScale = 1
                if abs(doorScale - 1) > 0.01 {
                    do {
                        try await api.setDoorScale(gate: gate, scale: doorScale)
                        savedDoorScale = doorScale
                    } catch {
                        Trace.log("扉の大きさを残せませんでした：\(ErrorText.of(error))")
                    }
                }
                Trace.log(String(format: "GATE を作りました（位置の精度 ±%.0fm%@）", fix.horizontalAccuracy,
                                 retrying ? "・送り直し" : ""))
            }

            // 2. GATE の位置の記録（失敗しても GATE は使える。友達の iPhone では、仮の位置に出る）
            if !placeMapSaved {
                phase = .createSaving("GATE の位置の記録を保存しています…")
                do {
                    let map = try await stage.captureWorldMap()
                    let saved = try await media.uploadWorldMap(map, owner: me, gate: gate)
                    try await api.registerPlaceMap(gate: gate, path: saved.path, size: saved.size, anchorName: "gg.gate")
                    placeMapSaved = true
                    mapWarning = nil
                } catch {
                    Trace.log("GATE の位置の記録を保存できませんでした：\(ErrorText.of(error))")
                    mapWarning = "GATE の位置の記録を保存できませんでした。友達の iPhone では、扉が仮の位置に出ます。"
                    placeMapSaved = true   // 送り直しのたびに見回しをやり直させない（あとで「撮り直す」ができる）
                }
            }

            // 3. 作った人も、同じ手順で入る（新しい合言葉・いまの位置・写真の特徴をサーバーが確かめる）。
            // 写真の特徴は、さっき正面から写したもの。前はここでカメラの絵を写し直していたが、扉を置いて見回したあとの
            // カメラは床や別の方向を向いているので、登録した物と合わず「写したものが合いません」になっていた（2026-11-15）。
            phase = .createSaving("扉を開けています…")
            let print: [Float]
            if let front = shots.first?.print {
                print = front
            } else {
                print = try await stage.grabShot(withPhoto: false).print
            }
            let result = try await api.enter(gate: gate, location: fix, print: print)
            enteredGate = gate
            if result.ok {
                visitID = result.visit_id
                visitExpires = result.expires_at.flatMap(ServerDate.parse)
                keepDoorOpen(gate: gate)
                placedPrecisely = true   // 作った人が置いたその場所（GATE の位置の記録の印そのもの）
                isGateOwner = true
                makeArtScene()
                door?.open()
                Haptics.open()
                phase = .doorOpen
                revealArtworks()
            } else {
                Trace.log("作ったあとの入場ができませんでした：\(result.reason ?? "不明")")
                phase = .createRetry("GATE はできました。ただ、扉を開ける確かめが通りませんでした。"
                                     + ErrorText.enterReason(result.reason))
            }
        } catch {
            let message = ErrorText.of(error)
            Trace.log("GATE を送れませんでした（\(createdGate == nil ? "作る前" : "作ったあと")）：\(message)")
            phase = .createRetry(message)
        }
    }

    /// 送れなかったあと：やめる（GATE ができていれば、それは残る）
    func abandonCreate() {
        if createdGate != nil {
            showToast("GATE はできています。「わたし」→「自分の GATE」から開けます。")
        }
        resetToScanning()
    }

    /// 送れなかったときに、まだ GATE ができていないか（画面の言葉を変える）
    var createRetryHasGate: Bool { createdGate != nil }
}

// MARK: - 扉の位置を指で合わせる・GATE の位置の記録を撮り直す

extension ARExperienceModel {
    /// 扉の位置を指で合わせ始める（仮の位置に出たとき。動かすのは自分の画面だけ）
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
        // 作った本人が大きさを変えたら、サーバーに残す（入った人にも同じ大きさで出る）
        if isGateOwner, abs(doorScale - savedDoorScale) > 0.01, let gate = enteredGate, let api = session?.api {
            let scale = doorScale
            Task {
                do {
                    try await api.setDoorScale(gate: gate, scale: scale)
                    savedDoorScale = scale
                    showToast("扉の大きさを保存しました")
                    Trace.log(String(format: "扉の大きさを保存しました（%.2f 倍）", scale))
                } catch {
                    notice = ErrorText.of(error)
                }
            }
        }
        if let door {
            Trace.log(String(format: "扉の位置を指で合わせました（印から %.2fm・%.0f°）",
                             simd_length(door.nudgePosition), door.nudgeYaw * 180 / .pi))
        }
        Haptics.success()
    }

    /// 作った人が、いまの扉の位置で GATE の位置の記録を撮り直す（まわりを見回してから保存）
    func startRemap() {
        guard isGateOwner, door != nil, enteredGate != nil else { return }
        adjustingDoor = false
        art = nil
        notice = nil
        phase = .remapping
        startMappingProgress()
        Trace.log("GATE の位置の記録の撮り直しを始めました")
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
        phase = .createSaving("GATE の位置の記録を撮り直しています…")
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
            showToast("GATE の位置の記録を撮り直しました。友達の iPhone でも、この位置に扉が出ます。")
            Trace.log("GATE の位置の記録を撮り直しました（\(saved.size / 1024)KB）")
        } catch {
            notice = "GATE の位置の記録を保存できませんでした。" + ErrorText.of(error)
            Trace.log("GATE の位置の記録を撮り直せませんでした：\(ErrorText.of(error))")
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
