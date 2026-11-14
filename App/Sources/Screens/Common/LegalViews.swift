import SwiftUI

/// 利用規約・プライバシーポリシー（アプリに入れた文。版はサーバーの gf_settings の terms_version と合わせる）
enum LegalDocument: String, Identifiable, CaseIterable {
    case terms, privacy

    var id: String { rawValue }

    /// アプリに入れた文の版。文を変えて同意し直してもらうときは、こことサーバーの terms_version を一緒に上げる
    static let version = 1
    static let updated = "2026年11月14日"

    var title: String {
        switch self {
        case .terms: return "利用規約"
        case .privacy: return "プライバシーポリシー"
        }
    }

    var lead: String {
        switch self {
        case .terms:
            return "Grafity Gate（以下「このアプリ」）を使う前に、この規約を読んでください。このアプリを使うと、この規約に同意したことになります。"
        case .privacy:
            return "このアプリが、どんな情報を、何のために使い、どこに置くかをまとめました。"
        }
    }

    var sections: [(heading: String, body: String)] {
        switch self {
        case .terms:
            return [
                ("1. このアプリでできること",
                 "場所や物に「GATE」（記憶の扉）を作り、写真・言葉・手紙・AR の作品などを残せます。GATE の中は、現地で扉を開けたときにだけ読んだり残したりできます。"),
                ("2. 好ましくない内容は許しません",
                 "次のものを残す・送ることは、どの場所・どの公開範囲でも禁止です。見つけたときは、予告なく消し、使えなくすることがあります。\n・人を傷つける・おどす・いやがらせをする内容\n・差別・暴力・性的な内容、法律に反する内容\n・ほかの人の顔・家・車のナンバー・個人の情報を、その人の許しなく写したもの\n・ほかの人の作品（写真・音楽・絵など）を、権利を持つ人の許しなく使ったもの\n・広告・勧誘・同じ内容のくり返し\n・危険な場所・立ち入ってはいけない場所へ人を誘う内容"),
                ("3. 迷惑な人への対応",
                 "どの記録・作品・メッセージにも「通報する」があります。通報は 24 時間以内に確かめ、規約に反するものは消し、書いた人を使えなくします。気になる人は「ブロック」で、おたがいに見えなくできます。"),
                ("4. 現地での安全",
                 "AR を使っているあいだは、周りが見えにくくなります。歩きながら画面を見続けない、道路・線路・私有地・立ち入り禁止の所に入らない、夜や天気の悪い日は無理をしない、を守ってください。けが・事故・ほかの人とのもめごとについて、このアプリは責任を負えません。"),
                ("5. 残したものの扱い",
                 "残したものの権利は、残した人にあります。このアプリは、選んだ公開範囲の人に見せるため・サービスを動かすためにだけ、それを置き、見せます。"),
                ("6. アカウント",
                 "アカウントは、このアプリを入れた iPhone ごとに自動で作られます。「わたし」→「アカウントを削除」で、いつでも消せます。消すと、残したものも一緒に消え、元に戻せません。"),
                ("7. 変更・終了",
                 "この規約は変えることがあります。大事な変更のときは、アプリでもう一度同意をお願いします。このアプリは、予告して終えることがあります。"),
            ]
        case .privacy:
            return [
                ("1. 集める情報",
                 "・アカウントの番号（自動で作るもの。メールアドレスや電話番号は使いません）、名前、ID\n・位置：近くの GATE を探す・扉を開ける・GATE を作るときの、そのときの位置と精度\n・景色の特徴：カメラの絵から iPhone の中で作った数字（写真そのものではありません）\n・場所の記憶：GATE を作った所の周りの形（AR で扉を同じ位置に出すため）\n・残したもの：写真・動画・声・言葉・手紙・作品・掲示板・メッセージ・TRAIL\n・通報・ブロック・フォローの記録\n・扉を開けたときの結果（距離・精度・景色の近さ。仕組みを良くするため）"),
                ("2. 集めない・送らない情報",
                 "・カメラの映像そのもの（扉を開けるとき）と、手の動き（作品に触れるとき）は、iPhone の中だけで使い、送りません\n・写真や動画に入っている位置などの付加情報は、送る前に消します\n・広告のための情報は集めません。広告もありません"),
                ("3. 使い道",
                 "GATE を見せる・扉を開けてよいか確かめる・友達に新着やお知らせを届ける・規約に反する使い方を防ぐ・仕組みを良くする、のためだけに使います。"),
                ("4. ほかの人に見えるもの",
                 "ほかの人に見える GATE の位置は、おおよその位置（約 100m）だけです。残したものは、あなたが選んだ公開範囲（自分だけ・友達・全員）の人にだけ見えます。場所の記憶は、GATE を作った人と、その場で扉を開けている人だけが受け取れます。"),
                ("5. 置き場所",
                 "情報は、クラウドのデータベース Supabase に置きます。見てよいかどうかは、サーバーが一つずつ確かめます。"),
                ("6. 消す",
                 "残したものは、いつでも消せます。「わたし」→「アカウントを削除」で、アカウントと、残したものすべてを消せます。「わたし」→「自分のデータを書き出す」で、残したものの一覧を受け取れます。"),
                ("7. 調べものの記録",
                 "うまく動かないときのための記録は、iPhone の中にだけ残ります。あなたが「調べものの記録を送る」を選んだときだけ、あなたが選んだ相手に渡ります。"),
                ("8. お問い合わせ・変更",
                 "お問い合わせは、App Store のこのアプリのページにある連絡先へお願いします。このポリシーを変えたときは、アプリでお知らせします。"),
            ]
        }
    }
}

/// 規約・ポリシーを読む画面
struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(document.lead)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(document.sections, id: \.heading) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.heading).font(.headline).foregroundStyle(Theme.text)
                        Text(section.body)
                            .font(.subheadline)
                            .foregroundStyle(Theme.text)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("\(LegalDocument.updated) 版")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 同意のしるし（はじめの案内と、規約が変わったときの画面で使う）
struct TermsCheckbox: View {
    @Binding var agreed: Bool
    @State private var reading: LegalDocument?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                agreed.toggle()
                Haptics.tap()
            } label: {
                Image(systemName: agreed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 22))
                    .foregroundStyle(agreed ? Theme.accent : Theme.textSecondary)
            }
            .accessibilityLabel("利用規約とプライバシーポリシーに同意する")
            .accessibilityValue(agreed ? "同意した" : "まだ")
            VStack(alignment: .leading, spacing: 4) {
                Text("利用規約とプライバシーポリシーに同意します。好ましくない内容や迷惑な行いは許されません。")
                    .font(.footnote)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { agreed.toggle() }
                HStack(spacing: 16) {
                    ForEach(LegalDocument.allCases) { doc in
                        Button(doc.title) { reading = doc }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .sheet(item: $reading) { doc in
            NavigationStack {
                LegalDocumentView(document: doc)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("閉じる") { reading = nil }
                        }
                    }
            }
        }
    }
}

/// 規約が新しくなった・まだ同意していないときに出す画面（同意するまで閉じない）
struct TermsAgreementSheet: View {
    let version: Int
    @EnvironmentObject private var session: SessionModel
    @State private var agreed = false
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GateMark(size: 64)
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            Text("利用規約への同意のお願い")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.text)
            Text("Grafity Gate を安心して使えるように、利用規約とプライバシーポリシーをまとめました。GATE を作る・記憶や作品を残す・メッセージを送るには、同意が必要です。")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TermsCheckbox(agreed: $agreed)
            if let error { NoticeText(text: error) }
            Spacer()
            Button {
                Task { await agree() }
            } label: {
                if sending { ProgressView().tint(.white) } else { Text("同意して続ける") }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!agreed || sending)
        }
        .padding(24)
        .background(Theme.background.ignoresSafeArea())
        .interactiveDismissDisabled()
    }

    private func agree() async {
        sending = true
        defer { sending = false }
        do {
            try await session.acceptTerms(version)
            Haptics.success()
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}
