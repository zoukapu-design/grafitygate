import SwiftUI

/// はじめて開いたときの案内（3 枚）。位置情報の許可は、理由を説明してから求める。
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0
    /// はじめに決める名前（サーバーにつながったら、そのまま使う。あとで「わたし」で変えられる）
    @AppStorage(SessionModel.pendingNameKey) private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var agreed = false

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    private let pages: [(title: String, body: String, symbol: String?)] = [
        ("場所に、記憶の扉を。",
         "思い出の場所や物に、写真・言葉・手紙・AR の作品を残せます。友達がそこを訪れたとき、または何年後かの自分が戻ってきたとき、その扉に出会えます。",
         nil),
        ("扉は、現地でだけ開く",
         "カメラを場所や物に向けると、位置と景色の両方が合ったときにだけ扉が現れます。中の記憶は、扉を開けているあいだ（20 分）だけ読んだり残したりできます。",
         "door.left.hand.open"),
        ("安心して使うために",
         "景色を確かめるときは、写真そのものではなく、写真から作った「特徴」の数字だけを送ります。ほかの人に見えるのは、おおよその位置（約 100m）だけ。友達向け・自分だけも選べます。",
         "lock.shield"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                    VStack(spacing: 28) {
                        Spacer()
                        if let symbol = item.symbol {
                            // アイコンと同じ夜空の窓に、ネオンの色の絵
                            ZStack {
                                RoundedRectangle(cornerRadius: 32, style: .continuous)
                                    .fill(LinearGradient(colors: [Color(hex: 0x060A24), Color(hex: 0x140F3A), Color(hex: 0x3A1530)],
                                                         startPoint: .top, endPoint: .bottom))
                                Image(systemName: symbol)
                                    .font(.system(size: 58, weight: .regular))
                                    .foregroundStyle(LinearGradient(colors: Brand.neon.reversed(), startPoint: .top, endPoint: .bottom))
                                    .shadow(color: Color(hex: 0xFF3D7F).opacity(0.6), radius: 14)
                            }
                            .frame(width: 140, height: 140)
                            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                        } else {
                            GateMark(size: 140)
                        }
                        VStack(spacing: 14) {
                            if index == 0 { Wordmark(size: 26) }
                            Text(item.title)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Theme.text)
                                .multilineTextAlignment(.center)
                            Text(item.body)
                                .font(.body)
                                .foregroundStyle(Theme.textSecondary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                            if index == pages.count - 1 {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("友達に見える名前").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                                    TextField("例：そうた", text: $name)
                                        .focused($nameFocused)
                                        .submitLabel(.done)
                                        .padding(12)
                                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
                                        .onChange(of: name) { _, value in
                                            if value.count > 30 { name = String(value.prefix(30)) }
                                        }
                                    Text("あとで「わたし」で変えられます。").font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                                .padding(.top, 6)
                            }
                        }
                        .padding(.horizontal, 28)
                        Spacer()
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 10) {
                if page < pages.count - 1 {
                    Button("次へ") { withAnimation { page += 1 } }
                        .buttonStyle(PrimaryButtonStyle())
                    // とばしても、さいごの同意の画面は見てもらう
                    Button("とばす") { withAnimation { page = pages.count - 1 } }
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    TermsCheckbox(agreed: $agreed)
                        .padding(.bottom, 4)
                    Button("はじめる") { finish() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!agreed)
                    Text("このあと、近くの GATE を見つけるために位置情報の許可をたずねます。カメラは、扉を開けるときにたずねます。")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func finish() {
        nameFocused = false
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Trace.log("はじめの案内を終えました（\(page + 1)/\(pages.count) 枚目で）")
        onFinish()
    }
}
