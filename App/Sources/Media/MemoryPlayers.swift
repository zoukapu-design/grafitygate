import AVFoundation
import AVKit
import SwiftUI

/// 思い出の動画を流す（受け取ってから。見ているページのときだけ流し、めくったら止める）
struct MemoryVideoView: View {
    let path: String
    let active: Bool

    @EnvironmentObject private var session: SessionModel
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.title2)
                    Text("動画を受け取れませんでした").font(.footnote)
                }
                .foregroundStyle(.white.opacity(0.8))
            } else {
                ProgressView().tint(.white)
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .task(id: path) {
            guard player == nil, let url = await session.media?.localFile(path: path) else {
                failed = player == nil
                if failed { Trace.log("思い出の動画を受け取れませんでした") }
                return
            }
            let p = AVPlayer(url: url)
            p.actionAtItemEnd = .pause
            player = p
            if active { MemoryPlayback.start(p) }
        }
        .onChange(of: active) { _, isActive in
            guard let player else { return }
            if isActive { MemoryPlayback.start(player) } else { player.pause() }
        }
        .onDisappear { player?.pause() }
    }
}

enum MemoryPlayback {
    /// マナーモードでも音が出るようにしてから流す（終わっていたら初めから）
    @MainActor
    static func start(_ player: AVPlayer) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        if let item = player.currentItem, item.currentTime() >= item.duration - CMTime(seconds: 0.1, preferredTimescale: 600) {
            player.seek(to: .zero)
        }
        player.play()
    }
}

/// 思い出の声を流す（大きな丸いボタン・進み具合）
@MainActor
final class MemoryVoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var position: Double = 0
    @Published private(set) var length: Double = 0
    @Published private(set) var failed = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL?) {
        guard let url, let p = try? AVAudioPlayer(contentsOf: url) else {
            failed = true
            Trace.log("思い出の声を受け取れませんでした")
            return
        }
        p.delegate = self
        p.prepareToPlay()
        player = p
        length = p.duration
    }

    var ready: Bool { player != nil }

    func toggle() {
        playing ? pause() : play()
    }

    func play() {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.play()
        playing = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
            }
        }
    }

    func pause() {
        player?.pause()
        playing = false
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.pause()
            self.position = self.length
        }
    }
}

struct MemoryVoiceView: View {
    let path: String
    let duration: Double
    let active: Bool

    @EnvironmentObject private var session: SessionModel
    @StateObject private var voice = MemoryVoicePlayer()

    var body: some View {
        VStack(spacing: 28) {
            Image(systemName: "waveform")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Theme.accentLight)
                .symbolEffect(.variableColor.iterative, isActive: voice.playing)
            Button {
                voice.toggle()
            } label: {
                ZStack {
                    Circle().fill(.white.opacity(0.14)).frame(width: 104, height: 104)
                    Image(systemName: voice.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .disabled(!voice.ready)
            .accessibilityLabel(voice.playing ? "止める" : "聞く")
            VStack(spacing: 8) {
                ProgressView(value: min(voice.position, max(total, 0.01)), total: max(total, 0.01))
                    .tint(Theme.accentLight)
                HStack {
                    Text(durationText(voice.position))
                    Spacer()
                    Text(durationText(total))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 40)
            if voice.failed {
                Text("声を受け取れませんでした").font(.footnote).foregroundStyle(.white.opacity(0.8))
            } else if !voice.ready {
                ProgressView().tint(.white)
            }
        }
        .task(id: path) {
            guard !voice.ready else { return }
            voice.load(await session.media?.localFile(path: path))
            if active { voice.play() }
        }
        .onChange(of: active) { _, isActive in
            if isActive { voice.play() } else { voice.pause() }
        }
        .onDisappear { voice.pause() }
    }

    private var total: Double { voice.length > 0 ? voice.length : duration }
}
