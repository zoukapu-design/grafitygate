import AVFoundation
import Foundation

/// AR の画面の音（作品の鐘・映像・声）の決まり。
/// 作品の音は、触れた・押したときだけ鳴るので、消音スイッチが入っていても鳴らす（playback）。
/// ほかのアプリの音（音楽など）は止めずに重ねる（mixWithOthers）。
/// 途中で種類を変えると鐘の音の仕組みが止まるので、AR の画面ではいつもこの 1 つにそろえる。
enum ARAudio {
    static func prepare() {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback || !session.categoryOptions.contains(.mixWithOthers) {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
        } catch {
            Trace.log("AR の音の準備ができませんでした：\(error.localizedDescription)")
        }
    }
}

/// 作品の「鳴る」：やさしい鐘の音をその場で作って鳴らす（音のファイルは持たない）。
/// 音の決まりは `ARAudio`。同時に鳴るのは 4 つまで。
final class ChimePlayer: @unchecked Sendable {
    static let shared = ChimePlayer()

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private let format: AVAudioFormat?
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private let queue = DispatchQueue(label: "gg.chime")
    private var started = false

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        // 声を録ったあとなど、音の決まりが変わると仕組みが止まる。次に鳴らすときに動かし直す
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                               queue: nil) { [weak self] _ in
            self?.queue.async { self?.started = false }
        }
    }

    /// 色ごとに音の高さを変える（夕日＝ド、白＝ミ、桜＝ソ、若葉＝ラ、空＝高いド）
    func play(_ color: ArtworkColor) {
        let frequency: Double
        switch color {
        case .warm: frequency = 523.25
        case .white: frequency = 659.25
        case .sakura: frequency = 783.99
        case .mint: frequency = 880.0
        case .sky: frequency = 1046.5
        }
        queue.async { [self] in
            guard startIfNeeded(), let buffer = buffer(for: frequency, key: color.rawValue) else { return }
            let player = players[next]
            next = (next + 1) % players.count
            player.stop()
            player.scheduleBuffer(buffer, at: nil, options: [])
            player.play()
        }
    }

    private func startIfNeeded() -> Bool {
        if started, engine.isRunning { return true }
        guard let format else { return false }
        do {
            ARAudio.prepare()
            if players.isEmpty {
                for _ in 0..<4 {
                    let p = AVAudioPlayerNode()
                    engine.attach(p)
                    engine.connect(p, to: engine.mainMixerNode, format: format)
                    players.append(p)
                }
            }
            engine.mainMixerNode.outputVolume = 0.7
            try engine.start()
            started = true
            return true
        } catch {
            Trace.log("鐘の音を鳴らせませんでした：\(error.localizedDescription)")
            return false
        }
    }

    /// 基音と倍音を重ね、すぐ立ち上がってゆっくり消える音を作る（1.6 秒）
    private func buffer(for frequency: Double, key: String) -> AVAudioPCMBuffer? {
        if let cached = buffers[key] { return cached }
        guard let format else { return nil }
        let rate = format.sampleRate
        let length = AVAudioFrameCount(rate * 1.6)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length),
              let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = length
        let partials: [(ratio: Double, gain: Double, decay: Double)] = [(1, 0.55, 2.4), (2.76, 0.22, 4.0),
                                                                         (5.4, 0.10, 6.5), (0.5, 0.08, 2.0)]
        for i in 0..<Int(length) {
            let t = Double(i) / rate
            let attack = min(1, t / 0.004)
            var v = 0.0
            for p in partials {
                v += sin(2 * .pi * frequency * p.ratio * t) * p.gain * exp(-p.decay * t)
            }
            data[i] = Float(v * attack * 0.5)
        }
        buffers[key] = buffer
        return buffer
    }

    func stop() {
        queue.async { [self] in
            guard started else { return }
            players.forEach { $0.stop() }
            engine.stop()
            started = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }
}
