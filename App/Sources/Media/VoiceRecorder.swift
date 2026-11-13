import AVFoundation
import SwiftUI

/// 声を録る（60 秒まで・AAC のモノラル）。録ったあとに聞き直せる。録った声は iPhone の中に置き、残すときだけ送る。
@MainActor
final class VoiceRecorder: NSObject, ObservableObject, AVAudioPlayerDelegate {
    enum State: Equatable {
        case idle
        case recording
        case recorded
        case playing
        case denied
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: Double = 0
    /// 声の大きさ（0〜1。波の形を描く）
    @Published private(set) var levels: [Float] = []

    private(set) var file: URL?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func start() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            state = .denied
            Trace.log("声：マイクの許可がありません")
            return
        }
        stopPlayback()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record(forDuration: MediaPrep.voiceLimit) else {
                Trace.log("声：録音を始められませんでした")
                return
            }
            if let old = file { try? FileManager.default.removeItem(at: old) }
            recorder = r
            file = url
            elapsed = 0
            levels = []
            state = .recording
            Haptics.tap()
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            Trace.log("声：録音を始められませんでした：\(error.localizedDescription)")
        }
    }

    private func tick() {
        guard let recorder else { return }
        if state == .recording {
            if !recorder.isRecording {
                finish()
                return
            }
            recorder.updateMeters()
            let db = recorder.averagePower(forChannel: 0)
            let level = max(0, min(1, (db + 50) / 50))
            levels.append(level)
            if levels.count > 90 { levels.removeFirst(levels.count - 90) }
            elapsed = recorder.currentTime
        } else if state == .playing, let player {
            elapsed = player.currentTime
        }
    }

    func stop() {
        guard state == .recording else { return }
        elapsed = recorder?.currentTime ?? elapsed
        recorder?.stop()
        finish()
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        state = file != nil && elapsed > 0.5 ? .recorded : .idle
        Haptics.tap()
        Trace.log(String(format: "声を録りました（%.1f 秒）", elapsed))
    }

    func play() {
        guard let file, state == .recorded else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            let p = try AVAudioPlayer(contentsOf: file)
            p.delegate = self
            p.play()
            player = p
            state = .playing
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            Trace.log("声：聞き直せませんでした：\(error.localizedDescription)")
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        if state == .playing {
            timer?.invalidate()
            timer = nil
            state = .recorded
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stopPlayback() }
    }

    /// 録った長さ（秒）
    var recordedLength: Double {
        guard let file, let p = try? AVAudioPlayer(contentsOf: file) else { return elapsed }
        return p.duration
    }

    func discard() {
        stopPlayback()
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        elapsed = 0
        levels = []
        state = .idle
    }

    func release() {
        stopPlayback()
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// 声を録るシート：大きな丸いボタン・時間・声の波・聞き直す・使う
struct VoiceRecorderSheet: View {
    let onUse: (URL, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceRecorder()

    init(onUse: @escaping (URL, Double) -> Void) {
        self.onUse = onUse
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                Text(durationText(recorder.elapsed) + " / " + durationText(MediaPrep.voiceLimit))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                LevelBars(levels: recorder.levels)
                    .frame(height: 64)
                    .padding(.horizontal, 24)
                Button {
                    Task {
                        switch recorder.state {
                        case .recording: recorder.stop()
                        default: await recorder.start()
                        }
                    }
                } label: {
                    ZStack {
                        Circle().fill(Theme.alert.opacity(0.12)).frame(width: 112, height: 112)
                        if recorder.state == .recording {
                            RoundedRectangle(cornerRadius: 8).fill(Theme.alert).frame(width: 38, height: 38)
                        } else {
                            Circle().fill(Theme.alert).frame(width: 76, height: 76)
                        }
                    }
                }
                .accessibilityLabel(recorder.state == .recording ? "止める" : "録る")
                Text(hint).font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if recorder.state == .recorded || recorder.state == .playing {
                    HStack(spacing: 12) {
                        Button(recorder.state == .playing ? "止める" : "聞き直す") {
                            recorder.state == .playing ? recorder.stopPlayback() : recorder.play()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button("この声を使う") {
                            guard let file = recorder.file else { return }
                            let length = recorder.recordedLength
                            recorder.release()
                            onUse(file, min(length, MediaPrep.voiceLimit))
                            dismiss()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    .padding(.horizontal, 24)
                }
                Spacer()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("声を残す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") {
                        recorder.discard()
                        recorder.release()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(recorder.state == .recording)
    }

    private var hint: String {
        switch recorder.state {
        case .idle: return "丸いボタンを押すと録り始めます（60 秒まで）。まわりの人の声が入らない所で。"
        case .recording: return "もう一度押すと止まります。"
        case .recorded, .playing: return "聞き直して、よければ「この声を使う」。録り直すときは丸いボタンをもう一度。"
        case .denied: return "マイクが使えません。設定アプリ → Grafity Gate で、マイクを許可してください。"
        }
    }
}

/// 声の大きさの棒
struct LevelBars: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            let count = 45
            let recent = Array(levels.suffix(count))
            let width = geo.size.width / CGFloat(count)
            HStack(alignment: .center, spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    let value = i < count - recent.count ? 0 : CGFloat(recent[i - (count - recent.count)])
                    Capsule()
                        .fill(Theme.alert.opacity(0.75))
                        .frame(width: max(2, width * 0.55), height: max(3, geo.size.height * value))
                        .frame(width: width)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
