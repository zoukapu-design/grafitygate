import Foundation

/// 端末の余力。iPhone 12（メモリ 4GB）でも固まらないよう、重い表現を加減する。
enum Perf {
    /// メモリ 4GB 以下の端末（iPhone 12 など）
    static let isLowMemoryDevice = ProcessInfo.processInfo.physicalMemory <= 4_600_000_000

    /// 端末が熱いとき（重い処理を止める）
    static var isHot: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    static var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "ふつう"
        case .fair: return "少し温かい"
        case .serious: return "熱い"
        case .critical: return "とても熱い"
        @unknown default: return "不明"
        }
    }
}
