import SwiftUI

/// 白を基調にした色と形。強調の色はアイコンのネオンに合わせる（2026-11-14 オーナーが見本 B「ネオンの帯」を選んだ）：
/// ふだんの強調は夜空のむらさき、いちばん大事なボタンだけ夕焼け→夜空の帯（`PrimaryButtonStyle`）、自分のもの・TRAIL は夕焼けのだいだい。
enum Theme {
    static let background = Color(hex: 0xFAFBF9)
    static let surface = Color.white
    static let surfaceElevated = Color(hex: 0xF3F3F7)
    static let text = Color(hex: 0x17181F)
    static let textSecondary = Color(hex: 0x6A6D78)
    static let line = Color(hex: 0xE6E6EE)
    /// 夜空のむらさき（白い地で読みやすい濃さ）
    static let accent = Color(hex: 0x5B3FE0)
    static let accentLight = Color(hex: 0xECE8FF)
    /// 夕焼けのだいだい（自分の GATE・TRAIL）
    static let warm = Color(hex: 0xF0702A)
    static let alert = Color(hex: 0xC83A3A)
    /// いちばん大事なボタンの帯（アイコンのネオンと同じ並び）
    static let neonBand = LinearGradient(colors: Brand.neonOnLight, startPoint: .leading, endPoint: .trailing)

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
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusButton)
                    .fill(Theme.neonBand)
                    .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.32)
            )
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

/// 消すなど、取り消せない操作のボタン（枠だけ・赤）
struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.alert)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.surface.opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: Theme.radiusButton))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusButton).stroke(Theme.alert.opacity(0.5)))
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
