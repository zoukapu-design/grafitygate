import Foundation

/// 調べものの記録。AR で何が起きたか（扉を置いた・場所の記憶が見つかった・座標が飛んだ・画面が止まった など）を
/// 1 行ずつ端末の中に残す。「わたし」→「調べものの記録を送る」で共有できる。サーバーには送らない。
enum Trace {
    private static let queue = DispatchQueue(label: "gg.trace", qos: .utility)
    private static let maxBytes = 2_000_000

    static let fileURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("grafitygate-trace.log")
    }()

    static func log(_ message: String) {
        let now = Date()
        queue.async {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "MM-dd HH:mm:ss.SSS"
            let line = "\(f.string(from: now)) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
            trimIfNeeded()
        }
    }

    /// 大きくなりすぎたら、新しい半分だけ残す
    private static func trimIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int,
              size > maxBytes, let data = try? Data(contentsOf: fileURL) else { return }
        let tail = data.suffix(maxBytes / 2)
        try? Data(tail).write(to: fileURL, options: .atomic)
    }
}
