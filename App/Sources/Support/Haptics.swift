import UIKit

/// 手ざわりの合図（扉が現れた・開いた・写した）。強すぎない短い振動だけ。
@MainActor
enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func open() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.9)
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
