import SwiftUI

// GATE の画面の「できること」（2026-11-19 オーナー「扉の中でできることを選ぶタブが見にくい・わかりにくい。
// 各機能に移りやすく」）。前の切り替えの帯をやめ、アルバム・掲示板・手紙・今と昔を大きな札にして、押すと
// それぞれの画面（GateFeaturePage）へ移る。グラフィティボード（扉が閉じているとき）も同じ札で、できること・鍵を見せる。

extension GateTab {
    var symbol: String {
        switch self {
        case .graffiti: return "rectangle.portrait.on.rectangle.portrait.angled.fill"
        case .memories: return "photo.stack.fill"
        case .board: return "bubble.left.and.text.bubble.right.fill"
        case .letters: return "envelope.fill"
        case .thenNow: return "clock.arrow.2.circlepath"
        }
    }

    var tint: [Color] {
        switch self {
        case .graffiti: return [Color(hex: 0xFF9A3D), Color(hex: 0xFF3D7F)]
        case .memories: return [Color(hex: 0xFF7A59), Color(hex: 0xFF3D7F)]
        case .board: return [Color(hex: 0x6B5CFF), Color(hex: 0x3DA8FF)]
        case .letters: return [Color(hex: 0xF5A623), Color(hex: 0xE8693C)]
        case .thenNow: return [Color(hex: 0x2EC4B6), Color(hex: 0x3D7BFF)]
        }
    }

    /// 札の一言（扉の中か・一度開けたことがあるかで変わる）
    func caption(_ context: GateContext) -> String {
        switch self {
        case .graffiti:
            return "その場の写真とひとことのカード"
        case .memories:
            return context.isInside ? "みんなで写真・動画・声を集める" : "GATE の中で見られます"
        case .board:
            if context.isInside { return "この場所のことを話す・聞く・調べる" }
            return context.opened ? "話題が読めます" : "話題の題名が見られます"
        case .letters:
            return context.isInside ? "未来の自分や友達へ。カードを添えて" : "あなたあての手紙を開く"
        case .thenNow:
            return context.isInside ? "同じ場所の昔と今の写真を並べる" : "GATE の中で見られます"
        }
    }

    /// 機能の画面のいちばん上の説明
    var intro: String {
        switch self {
        case .graffiti:
            return "この場所で撮った写真とひとことを、トレーディングカードにして残します。1 つの GATE に 1 日 1 枚。"
        case .memories:
            return "友達と一緒に、この場所の写真・動画・声を集めるアルバムです。作った人が招いた人も足せます。"
        case .board:
            return "この場所について、話題を立てて話したり、質問したり、みんなで調べたりできます。"
        case .letters:
            return "未来の自分や友達へ手紙を残せます。開く日を決めたり、ここに来たときだけ開けるようにしたりできます。グラフィティカードを添えられます。"
        case .thenNow:
            return "同じ場所の「昔」と「今」の写真を並べて、移り変わりを残します。写真はその場のカメラで撮ります。"
        }
    }

    /// 扉が閉じているときの、この機能の決まり
    func lockNote(_ context: GateContext) -> String? {
        guard !context.isInside else { return nil }
        switch self {
        case .graffiti, .board:
            return context.opened ? "一度開けた GATE なので、遠くからも読めます。書く・いいね・返信は、現地で GATE を開けているあいだにできます。"
                                  : "現地で GATE を開けると、ぜんぶ読めて、書けるようになります。"
        case .memories, .thenNow:
            return "現地で GATE を開けると、見たり足したりできます。"
        case .letters:
            return "手紙を書くのは、現地で GATE を開けているあいだです。あなたあての手紙は、開く条件がそろうと開けます。"
        }
    }
}

/// 札に出す数（分からないものは nil）
struct GateFeatureCounts: Equatable {
    var albums: Int?
    var threads: Int?
    /// まだ開けていない、あなたあての手紙
    var lettersForMe: Int?
    var snapshots: Int?
}

/// 「扉の中でできること」の札（2 列）
struct GateFeatureTiles: View {
    let context: GateContext
    let counts: GateFeatureCounts
    var onDark = false
    let onOpen: (GateTab) -> Void

    private let features: [GateTab] = [.memories, .board, .letters, .thenNow]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: context.isInside ? "door.left.hand.open" : "lock.fill")
                Text("GATE の中でできること")
            }
            .font(.title3.weight(.heavy))
            .foregroundStyle(onDark ? .white : Theme.text)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(features) { tab in
                    Button {
                        Haptics.tap()
                        onOpen(tab)
                    } label: {
                        tile(tab)
                    }
                    .buttonStyle(TilePressStyle())
                    .accessibilityLabel("\(tab.label)。\(tab.caption(context))")
                }
            }
        }
    }

    private func badge(_ tab: GateTab) -> String? {
        switch tab {
        case .memories: return counts.albums.flatMap { $0 > 0 ? "\($0)" : nil }
        case .board: return counts.threads.flatMap { $0 > 0 ? "\($0) 件" : nil }
        case .letters: return counts.lettersForMe.flatMap { $0 > 0 ? "\($0) 通届いています" : nil }
        case .thenNow: return counts.snapshots.flatMap { $0 > 0 ? "\($0)" : nil }
        case .graffiti: return nil
        }
    }

    private func locked(_ tab: GateTab) -> Bool {
        guard !context.isInside else { return false }
        switch tab {
        case .board: return !context.opened
        case .letters: return false
        default: return true
        }
    }

    private func tile(_ tab: GateTab) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(LinearGradient(colors: tab.tint, startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer(minLength: 4)
                if let badge = badge(tab) {
                    Text(badge)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(tab == .letters ? Theme.warm : Theme.accent, in: Capsule())
                } else if locked(tab) {
                    Image(systemName: "lock.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(onDark ? .white.opacity(0.6) : Theme.textSecondary)
                }
            }
            HStack(spacing: 4) {
                Text(tab.label)
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(onDark ? .white : Theme.text)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(onDark ? .white.opacity(0.6) : Theme.textSecondary)
            }
            Text(tab.caption(context))
                .font(.caption)
                .foregroundStyle(onDark ? .white.opacity(0.75) : Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(onDark ? AnyShapeStyle(Color.white.opacity(0.1)) : AnyShapeStyle(Theme.surface),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(onDark ? Color.white.opacity(0.18) : Theme.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// 押したとき少し沈む
private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 機能ごとの画面（アルバム・掲示板・手紙・今と昔）
struct GateFeaturePage: View {
    let tab: GateTab
    let context: GateContext
    let refreshToken: Int

    @EnvironmentObject private var session: SessionModel
    @State private var report: ReportItem?

    var body: some View {
        if tab == .thenNow {
            // 今と昔は、写真を大きく見比べる専用の画面（夜空の地）
            NowAndThenView(context: context, refreshToken: refreshToken) { item in report = item }
                .sheet(item: $report) { item in ReportSheet(item: item) }
                .onAppear { Trace.log("GATE：\(tab.label)を開いた") }
        } else {
            listPage
        }
    }

    private var listPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(LinearGradient(colors: tab.tint, startPoint: .topLeading, endPoint: .bottomTrailing),
                                    in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tab.label)
                            .font(.title2.weight(.heavy))
                            .foregroundStyle(Theme.text)
                        Text(context.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                if let lock = tab.lockNote(context) {
                    Label(lock, systemImage: context.opened ? "key.fill" : "lock.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.accentLight, in: RoundedRectangle(cornerRadius: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                section
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(tab.label)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $report) { item in ReportSheet(item: item) }
        .onAppear { Trace.log("GATE：\(tab.label)を開いた") }
    }

    @ViewBuilder private var section: some View {
        switch tab {
        case .graffiti:
            GateCardWall(context: context, refreshToken: refreshToken)
        case .memories:
            MemorySection(context: context, refreshToken: refreshToken) { item in report = item }
        case .board:
            BoardSection(context: context, refreshToken: refreshToken)
        case .letters:
            LetterSection(context: context, refreshToken: refreshToken)
        case .thenNow:
            EmptyView()
        }
    }
}

/// 扉の中のいちばん上：今日の 1 枚（まだなら「AR カメラでカードを作る」、残したら「今日は残しました」）
struct TodayCardPanel: View {
    let today: CardToday?
    let onARCamera: () -> Void
    let onMaker: () -> Void

    var body: some View {
        if today?.posted == true {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFFB35C), Color(hex: 0xFF3D7F)],
                                                    startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日のグラフィティカードは残しました")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.white)
                    Text("明日また残せます")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.18)))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日の 1 枚を残そう")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(.white)
                }
                Button(action: onARCamera) {
                    Label("AR カメラでカードを作る", systemImage: "camera.viewfinder")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button(action: onMaker) {
                    Text("ふつうのカメラ・写真なしで作る")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .underline()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.neonBand, lineWidth: 1.5))
        }
    }
}
