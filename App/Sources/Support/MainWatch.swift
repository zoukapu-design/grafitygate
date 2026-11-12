import Foundation
import os

/// 画面（メインの列）が止まっていないかを見張る。0.5 秒より止まったら、そのときの作業の名前を記録に残す。
/// 止まりを「待つ」でごまかさず、記録で何が止めたかを確かめて元を直すための道具。
final class MainWatch {
    static let shared = MainWatch()

    private let lock = NSLock()
    private var lastBeat = Date()
    private var activity = "なし"
    private var stalled = false
    private var timer: DispatchSourceTimer?

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 0.2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// 重くなりうる作業を名前付きで囲む（止まったときに、何をしていたかが記録に出る）
    @discardableResult
    static func run<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let started = Date()
        shared.setActivity(name)
        defer {
            shared.setActivity("なし")
            let took = Date().timeIntervalSince(started)
            if took > 0.25 { Trace.log(String(format: "重い作業：%@ %.2f 秒", name, took)) }
        }
        return try body()
    }

    private func setActivity(_ name: String) {
        lock.lock()
        activity = name
        lock.unlock()
    }

    private func tick() {
        DispatchQueue.main.async { [weak self] in self?.beat() }
        lock.lock()
        let gap = Date().timeIntervalSince(lastBeat)
        let name = activity
        let already = stalled
        if gap > 0.5 { stalled = true }
        lock.unlock()
        if gap > 0.5 && !already {
            let mb = Double(os_proc_available_memory()) / 1_048_576
            Trace.log(String(format: "画面が止まっています（%.1f 秒・作業：%@・使えるメモリの残り %.0fMB）", gap, name, mb))
        }
    }

    private func beat() {
        lock.lock()
        let gap = Date().timeIntervalSince(lastBeat)
        let wasStalled = stalled
        lastBeat = Date()
        stalled = false
        lock.unlock()
        if wasStalled {
            Trace.log(String(format: "画面が動き出しました（止まっていたのは約 %.1f 秒）", gap))
        }
    }
}
