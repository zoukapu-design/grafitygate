import SwiftUI

/// 白を基調にした色と形（設計書「画面の構成」の色の案）。ロゴが決まったら見直す。
enum Theme {
    static let background = Color(hex: 0xFAFBF9)
    static let surface = Color.white
    static let surfaceElevated = Color(hex: 0xF2F4F1)
    static let text = Color(hex: 0x17201D)
    static let textSecondary = Color(hex: 0x68736D)
    static let line = Color(hex: 0xE5E9E5)
    static let accent = Color(hex: 0x227D69)
    static let accentLight = Color(hex: 0xD6F4E9)
    static let warm = Color(hex: 0xC59C66)
    static let alert = Color(hex: 0xB94242)

    static let radiusCard: CGFloat = 20
    static let radiusButton: CGFloat = 14
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// いちばん大事な操作（GATE を開く・作る・投稿する）のボタン
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35),
                        in: RoundedRectangle(cornerRadius: Theme.radiusButton))
    }
}

/// 二番目の操作のボタン（枠だけ）
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.surface.opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.radiusButton))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusButton).stroke(Theme.accent.opacity(0.5)))
    }
}

/// 白いカード
struct Card<Content: View>: View {
    private let content: Content

    init(@ViewBuilder _ content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusCard))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.line))
    }
}

/// 短いお知らせ（だめだった理由など）
struct NoticeText: View {
    let text: String
    var isError = true

    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
            .font(.subheadline)
            .foregroundStyle(isError ? Theme.alert : Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
