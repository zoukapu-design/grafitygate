#if DEBUG
import ARKit
import RealityKit
import SwiftUI

/// AR の見本（2026-11-21 オーナー「AR のエフェクトが全部ちゃんと出て、表示も変にならないか確かめて」）。
/// カメラの景色の代わりに白い壁と木の床を置いた「AR を使わない RealityKit の画面」に、本物の GATE（`GateDoor`・`GateAura`）と
/// AR カメラの効果（`StoryCamera`・`StoryEffectField`）をそのまま出す。白い壁なのは、白い部屋でも粒が見えるかを確かめるため。
/// Apple のチップの Mac のシミュレーターで撮る（`gh workflow run shots.yml -f runner=macos-15 -f screens="ar-gate ..."`。
/// Intel の Mac のシミュレーターでは RealityKit が作れない）。
///
/// 画面の名前：
/// - ar-gate / ar-gate-small：現れた GATE（大きさ 1 / 0.35）
/// - ar-gate-burst：開いた瞬間（0.35 秒で止める）
/// - ar-gate-open / ar-gate-small-open：開いたあと（中から光があふれる）
/// - ar-gate-heart / ar-gate-magic：ほかの見た目
/// - ar-fx-<効果>：開いた小さな GATE と AR カメラの効果（sparkle・hearts・confetti・snow・petals・stardust・fireflies・bubbles）
/// - ar-fx-hidden：GATE を隠したときの効果（目の前）
/// - ar-camera：AR カメラの道具を重ねた画面（GATE の中から写真を撮るとき）
struct ARLabView: View {
    let screen: String
    @StateObject private var lab = ARLab()

    var body: some View {
        ZStack {
            ARLabContainer(lab: lab, screen: screen)
                .ignoresSafeArea()
            if lab.showsControls, let story = lab.story {
                StoryCameraControls(story: story, gateTitle: "ジェネシスの水槽", artworkCount: 0, canLeaveArt: true, toast: nil,
                                    onClose: {}, onLeaveArt: {}, onUse: { _ in })
            }
        }
    }
}

@MainActor
final class ARLab: ObservableObject {
    @Published var story: StoryCamera?
    @Published var showsControls = false
    private var door: GateDoor?
    private var started = false

    struct Plan {
        var scale: Float = 1
        var design: DoorDesign = .neon
        var open = false
        var burst = false
        var effect: StoryEffect?
        var hideDoor = false
        var controls = false
        /// 景色の色（GATE の中が抜けて後ろが見えていないかを確かめるとき、白以外にする）
        var background = UIColor(white: 0.95, alpha: 1)
        /// ななめから見る
        var side = false
    }

    static func plan(for screen: String) -> Plan {
        var p = Plan()
        switch screen {
        case "ar-gate": break
        case "ar-gate-small": p.scale = 0.35
        case "ar-gate-burst": p.open = true; p.burst = true
        case "ar-gate-open": p.open = true
        case "ar-gate-open-green": p.open = true; p.background = .green
        case "ar-gate-open-side": p.open = true; p.side = true
        case "ar-gate-small-open": p.scale = 0.35; p.open = true
        case "ar-gate-heart": p.scale = 0.6; p.design = .heart; p.open = true
        case "ar-gate-magic": p.scale = 0.6; p.design = .magic; p.open = true
        case "ar-fx-hidden": p.scale = 0.35; p.open = true; p.effect = .sparkle; p.hideDoor = true
        case "ar-camera": p.scale = 0.35; p.open = true; p.effect = .sparkle; p.controls = true
        default:
            if screen.hasPrefix("ar-fx-"), let e = StoryEffect(rawValue: String(screen.dropFirst("ar-fx-".count))) {
                p.scale = 0.35; p.open = true; p.effect = e
            }
        }
        return p
    }

    func setup(arView: ARView, screen: String) {
        guard !started else { return }
        started = true
        let plan = Self.plan(for: screen)
        let s = plan.scale

        // 白い壁と木の床（カメラの景色の代わり）
        arView.environment.background = .color(plan.background)
        let room = AnchorEntity(world: matrix_identity_float4x4)
        let floor = ModelEntity(mesh: .generatePlane(width: 10, depth: 10),
                                materials: [SimpleMaterial(color: UIColor(red: 0.45, green: 0.33, blue: 0.25, alpha: 1),
                                                           roughness: 0.8, isMetallic: false)])
        room.addChild(floor)
        let wall = ModelEntity(mesh: .generatePlane(width: 10, height: 5),
                               materials: [SimpleMaterial(color: UIColor(white: 0.96, alpha: 1), roughness: 0.9, isMetallic: false)])
        // 壁は GATE の向こうの回廊（奥行き 5.5m×大きさ）より後ろに（手前に置くと、回廊を壁が切って白く見える）
        wall.position = [0, 2.5, -(GateDoor.worldDeep * s + 0.8)]
        room.addChild(wall)
        let light = DirectionalLight()
        light.light.intensity = 2500
        light.look(at: .zero, from: [1.5, 4, 3], relativeTo: nil)
        room.addChild(light)
        // カメラ：GATE を少し上から見る（物の GATE は近くから）
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 62
        let eye = plan.side ? SIMD3<Float>(1.3 * s + 0.4, 1.15 * s + 0.3, 1.5 * s + 0.4)
                            : SIMD3<Float>(0.18 * s, 1.15 * s + 0.3, 1.9 * s + 0.55)
        camera.look(at: [0, 0.95 * s, 0], from: eye, relativeTo: nil)
        room.addChild(camera)
        arView.scene.addAnchor(room)

        do {
            let door = try GateDoor(anchorEntity: AnchorEntity(world: matrix_identity_float4x4), in: arView,
                                    style: .portal, design: plan.design)
            door.setSize(s)
            door.appear()
            self.door = door
        } catch {
            Trace.log("AR の見本：GATE を作れませんでした \(error)")
            return
        }
        Trace.log(String(format: "AR の見本：%@（大きさ %.2f）カメラ %.2f, %.2f, %.2f", screen, s,
                         arView.cameraTransform.translation.x, arView.cameraTransform.translation.y,
                         arView.cameraTransform.translation.z))

        guard plan.open else { return }
        // 現れてから少しして開く（はじける星・あふれる光）
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, let door = self.door else { return }
            door.open()
            if plan.burst { door.labFreeze(after: 0.35) }
            guard let effect = plan.effect else { return }
            let story = StoryCamera()
            story.doorBase = { [weak door] in door?.base }
            story.doorScale = s
            story.onDoorHidden = { [weak door] hidden in door?.setHidden(hidden) }
            story.begin(arView: arView)
            if plan.hideDoor { story.toggleDoor() }
            if effect != story.effect { story.setEffect(effect) }
            self.story = story
            self.showsControls = plan.controls
        }
    }
}

private struct ARLabContainer: UIViewRepresentable {
    let lab: ARLab
    let screen: String

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        Task { @MainActor in lab.setup(arView: view, screen: screen) }
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
#endif
