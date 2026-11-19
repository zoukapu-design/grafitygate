import SwiftUI

// 画面の共通の部品（2026-11-20 オーナー「全体的にもっとわかりやすく、見やすく、オシャレに」）。
// ・どの画面も「段の見出し」を SectionHeader にそろえる（題は太く・数は小さな札・右に「すべて」などの操作）。
// ・画面の説明は ScreenIntro（灰色の地の箱に入れない。題のすぐ下に 1〜2 行）。
// ・プロフィールの上は ProfileBanner（夜空の窓に顔・名前・数。わたし・友達のプロフィールで同じ形）。
// ・横に並べる小さめの操作は CompactButtonStyle。

/// 段の見出し：題・数・ひとことの説明・右の操作
struct SectionHeader<Trailing: View>: View {
    let title: String
    var count: Int? = nil
    var subtitle: String? = nil
    var onDark = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(onDark ? .white : Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.footnote.weight(.heavy).monospacedDigit())
                        .foregroundStyle(onDark ? Color(hex: 0x1B1235) : Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(onDark ? Color.white : Theme.accentLight, in: Capsule())
                }
                Spacer(minLength: 8)
                trailing()
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(onDark ? .white : Theme.accent)
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(onDark ? .white.opacity(0.7) : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil, subtitle: String? = nil, onDark: Bool = false) {
        self.init(title: title, count: count, subtitle: subtitle, onDark: onDark) { EmptyView() }
    }
}

/// 画面の説明（題のすぐ下に。箱に入れない）
struct ScreenIntro: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 横に並べる小さめの操作（白い地に細い枠。押すと少し沈む）
struct CompactButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(prominent ? .white : Theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 42)
            .padding(.horizontal, 10)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent)
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(prominent ? Color.clear : Theme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// プロフィールの上：夜空の窓に、ネオンの輪の顔・名前・ID・3 つの数（わたし・友達のプロフィールで同じ形）
struct ProfileBanner: View {
    let name: String
    let handle: String?
    /// 名前の下の小さな札（友達・フォロー中など）
    var relation: String? = nil
    var stats: [(value: Int?, label: String)] = []
    var onEditName: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                NeonAvatar(name: name, size: 74)
                VStack(alignment: .leading, spacing: 5) {
                    if let onEditName {
                        Button(action: onEditName) {
                            HStack(spacing: 6) {
                                nameText
                                Image(systemName: "pencil")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("名前を直す")
                    } else {
                        // 押せない名前は、ふつうの文字（押せないボタンにすると色がうすくなる）
                        nameText
                    }
                    if let handle {
                        Text("ID：\(handle)")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                            .textSelection(.enabled)
                    }
                    if let relation {
                        Text(relation)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.16), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
            }
            if !stats.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(stats.enumerated()), id: \.offset) { i, stat in
                        if i > 0 {
                            Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 30)
                        }
                        VStack(spacing: 2) {
                            Text(stat.value.map(String.init) ?? "–")
                                .font(.title3.weight(.heavy).monospacedDigit())
                                .foregroundStyle(.white)
                                .contentTransition(.numericText())
                            Text(stat.label)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1B1235), Color(hex: 0x2A1650), Color(hex: 0x4A2160)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                BannerStars()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(alignment: .bottom) {
            // 下の縁にネオンの帯（アイコンと同じ色の並び）
            Theme.neonBand.frame(height: 3)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .padding(.horizontal, 24)
                .opacity(0.9)
        }
    }
}

extension ProfileBanner {
    fileprivate var nameText: some View {
        Text(name.isEmpty ? "ゲスト" : name)
            .font(.title2.weight(.heavy))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// 夜空の窓の小さな星（1 回だけ描く）
private struct BannerStars: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRandom(seed: 2026)
            for _ in 0..<38 {
                let x = CGFloat(rng.next()) * size.width
                let y = CGFloat(rng.next()) * size.height
                let r = 0.6 + CGFloat(rng.next()) * 1.3
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity(0.25 + rng.next() * 0.45)))
            }
        }
        .allowsHitTesting(false)
    }
}

/// タブの画面のいちばん上（ナビゲーションの帯の代わり）：左に題かロゴ、右に丸いボタン。スクロールしても上に残る
struct TabHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leading()
            Spacer(minLength: 8)
            HStack(spacing: 10) { trailing() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background {
            Theme.background.opacity(0.97)
                .ignoresSafeArea(edges: .top)
        }
    }
}

/// タブの画面の大きな題（わたし など）
struct TabTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// ホームのいちばん上のしるし（アイコンと文字）
struct BrandHeaderMark: View {
    var body: some View {
        HStack(spacing: 9) {
            GateMark(size: 32, glowing: false)
            Wordmark(size: 23)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Grafity Gate")
        .accessibilityAddTraits(.isHeader)
    }
}

/// 上の丸いボタンの見た目（白い丸・細い枠・新しい数の札）
struct HeaderIcon: View {
    let systemImage: String
    var count: Int = 0

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.text)
            .frame(width: 42, height: 42)
            .background(Theme.surface, in: Circle())
            .overlay(Circle().stroke(Theme.line))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text(count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 19, minHeight: 19)
                        .background(Theme.alert, in: Capsule())
                        .overlay(Capsule().stroke(Theme.background, lineWidth: 2))
                        .offset(x: 5, y: -4)
                }
            }
    }
}

/// 地図の上に浮かべる切り替え（押した方が濃い色になる）
struct FloatingChip: View {
    let title: String
    let systemImage: String
    var count: Int = 0
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(selected ? Theme.accent : .white)
                        .frame(minWidth: 20, minHeight: 20)
                        .padding(.horizontal, 2)
                        .background(selected ? Color.white : Theme.warm, in: Capsule())
                }
            }
            .foregroundStyle(selected ? .white : Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background {
                if selected {
                    Capsule().fill(Theme.accent)
                } else {
                    Capsule().fill(.regularMaterial)
                }
            }
            .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0 : 0.7), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 小さなボタンの中の「しるし＋文字」（しるしは強調の色）
struct AccentIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.accent)
            configuration.title
        }
    }
}

/// 文字だけのタブ（下に色の線。プロフィールの「GATE／カード図鑑…」など。四角い切り替えより軽く見せる）
struct UnderlineTabs<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String
    @Namespace private var bar

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                let on = selection == item
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { selection = item }
                } label: {
                    VStack(spacing: 8) {
                        Text(title(item))
                            .font(.subheadline.weight(on ? .heavy : .semibold))
                            .foregroundStyle(on ? Theme.text : Theme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        ZStack {
                            Color.clear.frame(height: 3)
                            if on {
                                Capsule().fill(Theme.neonBand).frame(height: 3)
                                    .matchedGeometryEffect(id: "bar", in: bar)
                            }
                        }
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
