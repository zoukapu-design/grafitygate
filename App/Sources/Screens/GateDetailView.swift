import CoreLocation
import MapKit
import PhotosUI
import SwiftUI

/// GATE の中のどこを見ているか
enum GateTab: String, CaseIterable, Identifiable {
    case graffiti, memories, board, letters, thenNow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .graffiti: return "カード"
        case .memories: return "アルバム"
        case .board: return "掲示板"
        case .letters: return "手紙"
        case .thenNow: return "今と昔"
        }
    }
}

/// GATE の中の画面に渡す、いまの状態
struct GateContext: Equatable {
    let gateID: UUID
    let title: String
    let ownerID: UUID
    let ownerName: String
    let coverPath: String?
    let createdAt: String
    /// いま有効な入場券（現地で扉を開けているあいだだけ）
    let visit: UUID?
    let visitExpires: Date?

    /// 作った人か、一緒に管理する人（掲示板のピン留め・消す・解決しました）
    var canManage = false
    /// 一度でも扉を開けたことがある（遠くからもグラフィティカードと掲示板を読める。0024）
    var opened = false
    /// まだ開けたことのない人に見せるもの（新しいカード 3 枚・掲示板の題名）
    var peek: GatePeek?

    var isInside: Bool { visit != nil && (visitExpires ?? .distantPast) > Date() }
    /// 読めるか（扉の中か、一度開けたことがある）。書く・保存・返信・いいねは isInside だけ
    var canRead: Bool { isInside || opened }
}

/// GATE の画面。上に表紙、まん中に「カード／アルバム／掲示板／手紙」の切り替え。
/// 中身の多くは、現地で扉を開けているあいだ（20 分）だけ読める・書ける。
struct GateDetailView: View {
    let gateID: UUID

    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var location: LocationModel
    @State private var summary: GateSummary?
    @State private var loadError: String?
    @State private var loaded = false
    @State private var showAR = false
    /// 作った本人が、別の時間の見え方を足す
    @State private var showAddLooks = false
    /// はじめに開く機能（お知らせ・わたしから来たとき。カード以外なら、その機能の画面を開く）
    private let initialTab: GateTab
    /// いま開いている機能の画面（アルバム・掲示板・手紙・今と昔）
    @State private var openFeature: GateTab?
    @State private var featureCounts = GateFeatureCounts()
    /// 今日この GATE にカードを残したか（1 日 1 枚）
    @State private var cardToday: CardToday?
    /// カードを作る画面
    @State private var showMaker = false
    /// カードを残した直後の一言
    @State private var postedNote: String?
    @State private var saved = false
    /// 一緒に管理する人（作った人のほか）
    @State private var managers: [GateManager] = []
    @State private var editingGate = false
    /// 表紙の向きを直す（作った人・一緒に管理する人）
    @State private var rotatingCover = false
    /// 「再開する」を押しているあいだと、うまくいかなかったときの一言
    @State private var resuming = false
    @State private var resumeError: String?
    @ObservedObject private var keeper = VisitKeeper.shared
    @State private var showManagers = false
    @State private var confirmClose = false
    /// 「扉を出る」の確かめ
    @State private var confirmLeave = false
    /// AR カメラ（扉・みんなの AR と一緒にカードの写真を撮る）
    @State private var showARCardCamera = false
    @Environment(\.openARCardCamera) private var openARCardCamera
    @State private var report: ReportItem?
    @State private var refreshToken = 0
    @State private var actionMessage: String?
    @State private var trails: [TrailSummary] = []
    @State private var stats: GateStats?
    @State private var health: PlaceMapHealth?
    /// グラフィティボードに出すもの（鍵とチラ見せ。0024 の前のサーバーでは nil）
    @State private var peek: GatePeek?
    /// 作った本人には正確な位置
    @State private var exactPlace: CLLocationCoordinate2D?
    /// 自分がこの GATE に来た日
    @State private var showVisits = false
    @State private var openedInitial = false

    init(gateID: UUID, tab: GateTab = .graffiti) {
        self.gateID = gateID
        self.initialTab = tab
    }

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary {
                    if summary.status == "closed" && isOwner(summary) {
                        closedBanner(summary)
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        let context = makeContext(summary, now: timeline.date)
                        if context.isInside {
                            // 扉の中：夜空の画面。小さな見出し → みんなのカード → カードを作る → 中のもの
                            insidePage(summary, context: context, now: timeline.date, scroller: scroller)
                        } else {
                            // グラフィティボード：表紙・名前・作った人 → 紹介と数 → 扉 → いつ・どこで → 扉の向こう
                            VStack(alignment: .leading, spacing: 16) {
                                // 2026-11-18 オーナー「徹底的に見やすく」：上から 表紙 → みんなのカード → 紹介と数 →
                                // どこにあるか → 扉の向こう（読めるもの）。いちばん大事な「扉を開ける／ここへ行く」は、
                                // 画面の下にいつも出す（boardActionBar）
                                // 2026-11-19 オーナー「各機能の表示がわかりにくい」：表紙 → できること（札）→
                                // みんなのカード（2 列）→ 紹介と数 → どこにあるか。「扉を開ける／ここへ行く」は下にいつも出す
                                hero(summary)
                                GateFeatureTiles(context: context, counts: featureCounts) { openFeature = $0 }
                                GateCardWall(context: context, refreshToken: refreshToken)
                                    .id("inside")
                                statsBox(summary)
                                whereWhen(summary)
                                visitBanner(context, summary: summary, now: timeline.date, showActions: false)
                                    .id("door")
                                if !trails.isEmpty {
                                    trailStrip
                                }
                                if summary.owner == session.userID {
                                    addLooksButton(summary)
                                }
                            }
                        }
                    }
                } else if let loadError {
                    NoticeText(text: loadError)
                } else if loaded {
                    EmptyNote(title: "GATE が見つかりません",
                              message: "公開範囲が変わったか、閉じられた可能性があります。",
                              systemImage: "door.left.hand.closed")
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        // グラフィティボード（扉が閉じているとき）は、いちばん大事なボタンを画面の下にいつも出す
        .safeAreaInset(edge: .bottom) {
            if let summary, !insideNow, summary.status != "closed" || summary.owner == session.userID {
                boardActionBar(summary)
            }
        }
        // AR カメラで撮った写真が届いたら、カードを作る画面へ（AR カメラの画面が閉じてから開く）
        .onReceive(CardPhotoInbox.shared.$pending) { pending in
            guard pending?.gate == gateID, insideNow else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                if cardToday?.posted != true { showMaker = true }
            }
        }
        #if DEBUG
        // 画面の見本：下のほう（扉の札から）を撮る
        .onChange(of: summary?.id) { _, id in
            guard id != nil, let target = DemoMode.scroll else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { scroller.scrollTo(target, anchor: .top) }
        }
        #endif
        }
        .background {
            if insideNow { InsideBackground().ignoresSafeArea() } else { Theme.background.ignoresSafeArea() }
        }
        // 扉を開けずに見ているあいだは「グラフィティボード」、扉が開いているあいだは「扉の中」（夜空の画面）
        .navigationTitle(insideNow ? "扉の中" : "グラフィティボード")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(insideNow ? .dark : nil, for: .navigationBar)
        .confirmationDialog("扉を出ますか？", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("扉を出る", role: .destructive) { Task { await leaveDoor() } }
        } message: {
            Text("グラフィティカードを残す・いいね・返信などは、扉の中でできます。出たあとも、この GATE のものは遠くから読めます。もう一度入るには、現地で扉を開けます。")
        }
        .toolbar { toolbar }
        .task { await reload() }
        .refreshable {
            await reload()
            refreshToken += 1
        }
        .fullScreenCover(isPresented: $showAR) {
            ARExperienceView(mode: .enter(gateID)) {
                showAR = false
                Task {
                    await reload()
                    refreshToken += 1
                }
            }
        }
        .fullScreenCover(isPresented: $showARCardCamera) {
            ARExperienceView(mode: .cardCamera(gateID, visit: summary?.my_visit)) {
                showARCardCamera = false
            }
        }
        .fullScreenCover(isPresented: $showMaker) {
            if let summary {
                CardMakerView(context: makeContext(summary, now: Date()),
                              externalARCamera: makerARCamera) {
                    Task { await cardPosted() }
                }
                .environmentObject(session)
                .environmentObject(location)
            }
        }
        .navigationDestination(item: $openFeature) { feature in
            if let summary {
                GateFeaturePage(tab: feature, context: makeContext(summary, now: Date()), refreshToken: refreshToken)
                    .environmentObject(session)
            }
        }
        .fullScreenCover(isPresented: $showAddLooks) {
            ARExperienceView(mode: .addLooks(gateID)) {
                showAddLooks = false
            }
        }
        .sheet(item: $report) { item in
            ReportSheet(item: item)
        }
        .sheet(isPresented: $rotatingCover) {
            if let summary {
                CoverRotateSheet(summary: summary) { Task { await reload() } }
                    .environmentObject(session)
            }
        }
        .sheet(isPresented: $editingGate) {
            if let summary {
                GateEditSheet(summary: summary, isOwner: isOwner(summary)) { Task { await reload() } }
                    .environmentObject(session)
            }
        }
        .sheet(isPresented: $showManagers) {
            GateManagersSheet(gateID: gateID, title: summary?.title ?? "") { Task { await reload() } }
                .environmentObject(session)
        }
        .confirmationDialog("この GATE をお休みにしますか？", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("お休みにする", role: .destructive) { Task { await setOpen(false) } }
        } message: {
            Text("ほかの人は見つけられず、入れなくなります（自分が扉から出るだけなら「扉を出る」）。中のグラフィティカードや掲示板は消えず、あとで再開できます。")
        }
        .sheet(isPresented: $showVisits) {
            MyVisitsSheet(gateID: gateID, title: summary?.title ?? "")
                .environmentObject(session)
        }
    }

    private func makeContext(_ s: GateSummary, now: Date) -> GateContext {
        // その場にいるあいだ延びた時刻（VisitKeeper）があれば、そちらを使う
        let expires = keeper.expires(visit: s.my_visit) ?? s.visitExpiresAt
        let active = (expires ?? .distantPast) > now
        return GateContext(gateID: s.id, title: s.title, ownerID: s.owner, ownerName: s.owner_name,
                           coverPath: s.cover_path, createdAt: s.created_at,
                           visit: active ? s.my_visit : nil, visitExpires: active ? expires : nil,
                           canManage: canManage(s), opened: peek?.opened ?? false, peek: peek)
    }

    private func isOwner(_ s: GateSummary) -> Bool { s.owner == session.userID }

    /// 作った人か、一緒に管理する人
    private func canManage(_ s: GateSummary) -> Bool {
        isOwner(s) || managers.contains { $0.user_id == session.userID }
    }

    /// 閉じた GATE（作った人にだけ見えている）
    private func closedBanner(_ s: GateSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "door.left.hand.closed")
                .font(.title3)
                .foregroundStyle(Theme.warm)
            VStack(alignment: .leading, spacing: 6) {
                Text("この GATE はお休み中です").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text("いまは、あなたにだけ見えています。ほかの人は見つけられず、入れません。中のグラフィティカードや掲示板は消えていません。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await resume() }
                } label: {
                    if resuming {
                        ProgressView().tint(.white).frame(minWidth: 90)
                    } else {
                        Label("再開する", systemImage: "door.left.hand.open")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(resuming)
                if let resumeError {
                    NoticeText(text: resumeError)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warm.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.warm.opacity(0.35)))
    }

    /// お休みの GATE を再開する（押したことが分かるように、ここで待ち・うまくいかなければ、ここに理由を出す）
    private func resume() async {
        guard let api = session.api else {
            resumeError = "サーバーにつながっていません。少し待ってからもう一度押してください。"
            return
        }
        resuming = true
        resumeError = nil
        Haptics.tap()
        defer { resuming = false }
        do {
            try await api.setGateOpen(gateID, open: true)
            Trace.log("GATE を再開した")
            await reload()
            if summary?.status == "closed" {
                resumeError = "再開できませんでした（サーバーの答えが「お休み中」のままです）。もう一度押してください。"
                Trace.log("GATE の再開：サーバーの答えがお休み中のまま")
            } else {
                Haptics.success()
            }
        } catch {
            Trace.log("GATE を再開できませんでした：\(ErrorText.of(error))")
            resumeError = ErrorText.isMissingFunction(error)
                ? "お休み・再開は、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
    }

    private func setOpen(_ open: Bool) async {
        guard let api = session.api else { return }
        do {
            try await api.setGateOpen(gateID, open: open)
            Haptics.success()
            Trace.log("GATE を\(open ? "再開した" : "お休みにした")")
            await reload()
        } catch {
            actionMessage = ErrorText.isMissingFunction(error)
                ? "お休み・再開は、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
    }

    private func leaveManagers() async {
        guard let api = session.api, let me = session.userID else { return }
        do {
            try await api.removeGateManager(gateID, user: me)
            await reload()
        } catch {
            actionMessage = ErrorText.of(error)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let summary {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if summary.status == "open", summary.visibility != "private" {
                    ShareLink(item: AppNavigator.gateShareText(title: summary.title, id: summary.id)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("この GATE のリンクを送る")
                }
                Button {
                    Task { await toggleSaved() }
                } label: {
                    Image(systemName: saved ? "bookmark.fill" : "bookmark")
                }
                .accessibilityLabel(saved ? "保存をやめる" : "保存する")
                Menu {
                    if canManage(summary) {
                        Button {
                            editingGate = true
                        } label: {
                            Label("GATE を直す（名前・紹介・表紙）", systemImage: "pencil")
                        }
                    }
                    if isOwner(summary) {
                        Button {
                            showManagers = true
                        } label: {
                            Label("一緒に管理する人", systemImage: "person.2.badge.gearshape")
                        }
                        if summary.status == "open" {
                            Button(role: .destructive) {
                                confirmClose = true
                            } label: {
                                Label("GATE をお休みにする（ほかの人に見せない）", systemImage: "moon.zzz")
                            }
                        } else {
                            Button {
                                Task { await setOpen(true) }
                            } label: {
                                Label("GATE を再開する", systemImage: "door.left.hand.open")
                            }
                        }
                    } else {
                        if canManage(summary) {
                            Button(role: .destructive) {
                                Task { await leaveManagers() }
                            } label: {
                                Label("管理から抜ける", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        }
                        Button {
                            report = ReportItem(id: summary.id, target: .gate, userID: summary.owner,
                                                userName: summary.owner_name, label: summary.title)
                        } label: {
                            Label("この GATE を通報する", systemImage: "exclamationmark.bubble")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("そのほか")
            }
        }
    }

    // MARK: 表紙

    /// いま扉の中か（画面の色・題を変える）
    private var insideNow: Bool {
        summary.map { makeContext($0, now: Date()).isInside } ?? false
    }

    /// 扉の中の画面（2026-11-19 オーナー「初めての人でも迷わず使える画面に」）：夜空の画面に、上から
    /// ① どこにいるか・扉を出る ② 今日の 1 枚（AR カメラでカードを作る／今日は残しました）③ 扉の中でできること（札）
    /// ④ みんなのグラフィティカード（2 列・友達が上）⑤ この GATE について
    private func insidePage(_ s: GateSummary, context: GateContext, now: Date, scroller: ScrollViewProxy) -> some View {
        let minutes = context.visitExpires.map { max(1, Int($0.timeIntervalSince(now) / 60 + 0.5)) } ?? 0
        let near = keeper.entries[context.visit ?? UUID()]?.near
        return VStack(alignment: .leading, spacing: 24) {
            InsideHeader(title: s.title, coverPath: s.cover_path,
                         ownerLine: s.owner == session.userID ? "あなたの GATE" : "\(s.owner_name) さんの GATE",
                         status: near == false ? "離れたので、あと約 \(minutes) 分で扉が閉じます" : "扉が開いています",
                         warning: near == false) {
                confirmLeave = true
            }

            VStack(alignment: .leading, spacing: 8) {
                TodayCardPanel(today: cardToday, onARCamera: { openARCamera() }, onMaker: {
                    Haptics.tap()
                    showMaker = true
                })
                if let postedNote {
                    Label(postedNote, systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }

            GateFeatureTiles(context: context, counts: featureCounts, onDark: true) { openFeature = $0 }

            GateCardWall(context: context, refreshToken: refreshToken, onDark: true)
                .id("inside")

            // この GATE について（グラフィティボードの中身は下に）
            VStack(alignment: .leading, spacing: 12) {
                Text("この GATE について")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 16) {
                    header(s)
                    whereWhen(s)
                    if !trails.isEmpty {
                        trailStrip
                    }
                    if s.owner == session.userID {
                        addLooksButton(s)
                    }
                }
                .padding(16)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .padding(.top, 8)
        }
    }

    /// AR カメラを開く（AR の画面から開いた扉の中なら、シートを閉じていまの扉のまま）
    private func openARCamera() {
        Trace.log("扉の中：AR カメラを開く")
        if let open = openARCardCamera, open(gateID) { return }
        showARCardCamera = true
    }

    /// カードを作る画面の「AR カメラ」：AR の画面から開いた扉の中なら、シートを閉じていまの扉のまま撮る
    private var makerARCamera: (() -> Bool)? {
        guard let open = openARCardCamera else { return nil }
        let gate = gateID
        return { open(gate) }
    }

    /// カードを残したあと：今日の 1 枚を「残しました」にし、みんなのカードを読み直す
    private func cardPosted() async {
        postedNote = "グラフィティカードを残しました。下の「あなた」で見られます。"
        refreshToken += 1
        if let api = session.api { cardToday = (try? await api.myCardToday(gateID)) ?? CardToday(posted: true, card_id: nil, next_at: nil) }
        if cardToday == nil { cardToday = CardToday(posted: true, card_id: nil, next_at: nil) }
        await reload()
    }

    /// 扉を出る（自分の入場をその場で終わらせる。GATE をお休みにするのとは別）
    private func leaveDoor() async {
        guard let api = session.api, let visit = summary?.my_visit else { return }
        do {
            try await api.leaveVisit(visit)
            VisitKeeper.shared.forget(visit: visit)
            Haptics.success()
            Trace.log("扉を出た")
            await reload()
            refreshToken += 1
        } catch {
            actionMessage = ErrorText.isMissingFunction(error)
                ? "「扉を出る」は、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
    }

    private func header(_ s: GateSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            hero(s)
            statsBox(s)
        }
    }

    /// 表紙と名前（グラフィティボードのいちばん上）
    private func hero(_ s: GateSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GraffitiBoardHero(title: s.title, coverPath: s.cover_path, kind: GateKind(raw: s.kind)) {
                if s.owner == session.userID {
                    Label("あなたの GATE", systemImage: "person.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                } else {
                    NavigationLink {
                        ProfileView(userID: s.owner)
                    } label: {
                        HStack(spacing: 6) {
                            NeonAvatar(name: s.owner_name, size: 22)
                            Text(s.owner_name).font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.white.opacity(0.92))
                    }
                }
                if !managers.isEmpty {
                    Label("一緒に管理：" + managers.map { $0.user_id == session.userID ? "あなた" : $0.display_name }
                        .joined(separator: "・"), systemImage: "person.2.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // 表紙が横倒しのとき、すぐ直せるように（作った人・一緒に管理する人）
                if s.cover_path != nil, canManage(s) {
                    Button {
                        rotatingCover = true
                    } label: {
                        Label("向きを直す", systemImage: "rotate.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.black.opacity(0.5), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                    .padding(.bottom, 6)
                    .accessibilityLabel("表紙の写真の向きを直す")
                }
            }
        }
    }

    /// 紹介と数
    private func statsBox(_ s: GateSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // 紹介と数
            VStack(alignment: .leading, spacing: 14) {
                if !s.note.isEmpty {
                    Text(s.note).font(.body).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 0) {
                    BoardStat(value: "\(s.graffiti_count)", label: "グラフィティカード")
                    statDivider
                    BoardStat(value: stats.map { "\($0.visitor_count)" } ?? "–", label: "訪れた人")
                    statDivider
                    if let stats, stats.my_visits > 0 {
                        Button {
                            showVisits = true
                        } label: {
                            BoardStat(value: "\(stats.my_visits)", label: "あなたが来た回数", warm: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("あなたが来た日を見る")
                    } else {
                        BoardStat(value: stats == nil ? "–" : "0", label: "あなたが来た回数")
                    }
                }
                // 入りきらなければ次の行へ
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    Group {
                        if let last = stats?.last_activity_at { chip("最後の記録 \(ServerDate.relative(last))", "clock") }
                        chip("見える人：" + Visibility.label(of: s.visibility), "eye")
                    }
                }
                if let actionMessage {
                    NoticeText(text: actionMessage, isError: false)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.line))
        }
    }

    private var statDivider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 34)
    }

    /// いつ・どこで（地図）と、GATE の位置の記録の様子（作った本人だけ）
    private func whereWhen(_ s: GateSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GateWhereWhen(title: s.title, createdAt: s.created_at,
                          coordinate: exactPlace ?? CLLocationCoordinate2D(latitude: s.approx_lat, longitude: s.approx_lon),
                          exact: exactPlace != nil, coverPath: s.cover_path,
                          mine: s.owner == session.userID, ownerName: s.owner_name)
            if let health {
                placeMemoryNote(health)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.line))
    }

    private func chip(_ text: String, _ symbol: String, warm: Bool = false) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(warm ? Theme.warm : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(warm ? Theme.warm.opacity(0.12) : Theme.surfaceElevated, in: Capsule())
    }

    /// 作った本人だけ：GATE の位置の記録が友達の iPhone で見つかっているか
    private func placeMemoryNote(_ h: PlaceMapHealth) -> some View {
        let text: String
        if !h.has_map {
            text = "GATE の位置の記録がありません。友達の iPhone では扉が仮の位置に出ます。現地で扉を開け、「扉の位置を合わせる」→「この位置で GATE の位置の記録を撮り直す」で保存できます。"
        } else if h.recent_attempts == 0 {
            text = "GATE の位置の記録：まだ友達が探していません。"
        } else {
            text = "GATE の位置の記録：最近 \(h.recent_attempts) 回のうち \(h.recent_found) 回、友達の iPhone で見つかりました。"
                + (h.looksStale ? "見つかりにくくなっています。現地で扉を開けて「GATE の位置の記録を撮り直す」を押してください。" : "")
        }
        return Label(text, systemImage: h.looksStale ? "exclamationmark.triangle" : "checkmark.seal")
            .font(.caption)
            .foregroundStyle(h.looksStale ? Theme.warm : Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// この GATE をふくむ TRAIL
    private var trailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(trails) { trail in
                    NavigationLink {
                        TrailDetailView(trailID: trail.id, title: trail.title)
                    } label: {
                        Label(trail.inProgress ? "\(trail.title)（\(trail.reached)/\(trail.stop_count)）" : trail.title,
                              systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.accentLight, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 扉の札：開いているあいだは「扉が開いています」、開ける前は「扉を開ける」（遠いときは、まず現地へ）
    @ViewBuilder private func visitBanner(_ context: GateContext, summary: GateSummary, now: Date,
                                          showActions: Bool = true) -> some View {
        if let expires = context.visitExpires, context.isInside {
            let minutes = max(1, Int(expires.timeIntervalSince(now) / 60 + 0.5))
            let near = keeper.entries[context.visit ?? UUID()]?.near
            BoardDoorPanel(isOpen: true,
                           title: near == false ? "まもなく扉が閉じます" : "扉が開いています",
                           detail: near == false ? "GATE から離れたので、あと約 \(minutes) 分で閉じます。"
                                                 : "その場にいるあいだ開いたまま。下の「扉の中」で読んだり残したりできます。") {
                EmptyView()
            }
        } else {
            let distance = location.location?.distance(from: CLLocation(latitude: summary.approx_lat,
                                                                         longitude: summary.approx_lon))
            let far = (distance ?? 0) > 150
            BoardDoorPanel(isOpen: false,
                           title: "扉は閉じています",
                           detail: far && distance != nil
                               ? "ここから \(TrailGuide.distanceText(distance!))。GATE の近く（120m 以内）まで行くと開けられます。"
                               : "作った人が写した場所・物にカメラを向けて、位置と景色が合うと扉が開きます。") {
                if showActions {
                VStack(spacing: 10) {
                    if far, distance != nil {
                        // 遠いとき：まず現地へ（地図アプリで歩く道）
                        Button {
                            openWalking(summary)
                        } label: {
                            Label("ここへ行く", systemImage: "figure.walk")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        Button {
                            showAR = true
                        } label: {
                            Label("着いたら、扉を開ける", systemImage: "door.left.hand.open")
                        }
                        .buttonStyle(NightSecondaryButtonStyle())
                        .disabled(session.api == nil)
                    } else {
                        Button {
                            showAR = true
                        } label: {
                            Label("扉を開ける", systemImage: "door.left.hand.open")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(session.api == nil)
                    }
                }
                }
            }
        }
    }

    /// グラフィティボードの下にいつも出す、いちばん大事なこと（遠ければ「ここへ行く」、近ければ「扉を開ける」）
    private func boardActionBar(_ summary: GateSummary) -> some View {
        let distance = location.location?.distance(from: CLLocation(latitude: summary.approx_lat,
                                                                     longitude: summary.approx_lon))
        let far = (distance ?? 0) > 150 && distance != nil
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(far ? "ここから \(TrailGuide.distanceText(distance ?? 0))" : (distance == nil ? "扉は閉じています" : "近くにいます"))
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(far ? "120m 以内まで行くと扉を開けられます" : "カメラを向けて、扉を開けましょう")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if far {
                Button {
                    showAR = true
                } label: {
                    Image(systemName: "door.left.hand.open")
                        .font(.headline)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 46, height: 46)
                        .background(Theme.accentLight, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("着いたら、扉を開ける")
                Button {
                    openWalking(summary)
                } label: {
                    Label("ここへ行く", systemImage: "figure.walk")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 46)
                        .background(Theme.neonBand, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    showAR = true
                } label: {
                    Label("扉を開ける", systemImage: "door.left.hand.open")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 46)
                        .background(Theme.neonBand, in: Capsule())
                        .shadow(color: Color(hex: 0xFF3D7F).opacity(0.35), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(session.api == nil)
            }
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    /// 作った本人だけ：別の時間の見え方を足す（夕方・夜・別の季節。景色の GATE で特に大事）
    private func addLooksButton(_ summary: GateSummary) -> some View {
        let isView = GateKind(raw: summary.kind) == .view
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                showAddLooks = true
            } label: {
                Label("別の時間の見え方を足す", systemImage: "sun.horizon")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.warm)
            }
            .disabled(session.api == nil)
            Text(isView
                 ? "景色は時間・天気・季節で見え方が変わります。夕方や夜にも現地で足しておくと、その時間に来た友達も入れます。"
                 : "夜や別の季節に現地で足しておくと、その時間に来た友達も入りやすくなります。")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: 動き

    /// 地図アプリで、GATE のおおよその場所までの歩く道を出す
    private func openWalking(_ summary: GateSummary) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: summary.approx_lat,
                                                                                    longitude: summary.approx_lon)))
        item.name = summary.title
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
        Trace.log("GATE へ行く道を地図アプリで開きました")
    }

    private func reload() async {
        guard let api = session.api else { return }
        do {
            summary = try await api.summary(gateID)
            if let s = summary, let visit = s.my_visit {
                VisitKeeper.shared.track(visit: visit, gate: s.id, expires: s.visitExpiresAt, session: session, location: location)
            }
            loadError = nil
            if let saved = try? await api.collection("saved") {
                self.saved = saved.contains { $0.gate_id == gateID }
            }
            trails = (try? await api.trails(including: gateID)) ?? []
            stats = try? await api.gateStats(gateID)
            if let loaded = try? await api.gatePeek(gateID) {
                peek = loaded
                Trace.log("グラフィティボード：鍵\(loaded.opened ? "あり" : "なし")・チラ見せ \(loaded.cards.count) 枚・題名 \(loaded.threads.count)")
            }
            managers = (try? await api.gateManagers(gateID)) ?? []
            await loadFeatureCounts(api)
            if let today = try? await api.myCardToday(gateID) { cardToday = today }
            // お知らせ・わたしから来たとき：その機能の画面を開く（はじめの 1 回だけ）
            if !openedInitial, initialTab != .graffiti {
                openedInitial = true
                openFeature = initialTab
            }
            health = summary?.owner == session.userID ? (try? await api.placeMapHealth(gateID)) ?? nil : nil
            if summary?.owner == session.userID {
                exactPlace = (try? await api.myGate(gateID))?.coordinate
            }
        } catch {
            loadError = ErrorText.of(error)
        }
        loaded = true
    }

    /// 札に出す数（アルバム・掲示板の話題・まだ開けていない自分あての手紙・今と昔）
    private func loadFeatureCounts(_ api: GateAPI) async {
        var counts = GateFeatureCounts()
        counts.threads = peek?.thread_count
        if let memories = try? await api.memories(in: gateID) { counts.albums = memories.count }
        if let letters = try? await api.letters(at: gateID) {
            counts.lettersForMe = letters.filter { !$0.sent && !$0.isOpened }.count
        }
        if let snapshots = try? await api.snapshots(in: gateID) { counts.snapshots = snapshots.count }
        featureCounts = counts
    }

    private func toggleSaved() async {
        guard let api = session.api else { return }
        let next = !saved
        do {
            try await api.setBookmark(gateID, on: next)
            saved = next
            actionMessage = next ? "保存しました。「わたし」→「保存」から開けます。" : "保存をやめました。"
            Haptics.tap()
        } catch {
            actionMessage = ErrorText.of(error)
        }
    }
}

/// グラフィティのカード（写真が主役。文字は写真の下に）
struct GraffitiCard: View {
    let item: Graffiti
    let author: String
    let isMine: Bool
    let likeCount: Int
    let liked: Bool
    let onLike: () -> Void
    let onDelete: () -> Void
    let onReport: () -> Void
    /// 自分のカードを絵にして送る（自分のカードだけ）
    let onShare: (() -> Void)?
    /// この GATE の自分のカードと並べる（友達のカードで、自分のカードがあるときだけ）
    let onCompare: (() -> Void)?
    /// 友達のカードに「来たよ」を送る（GATE の中・友達・自分のカードがあるとき）
    let onCardLink: (() -> Void)?
    /// 「来たよ」の札（送った・届いた）
    let linkNote: String?
    /// 友達のカード図鑑に載せているか（自分の写真つきカードだけ。nil なら出さない）
    let inAtlas: Bool?
    let onToggleAtlas: () -> Void
    /// 返信の数と、返信を開く（nil なら出さない＝サーバーが 0018 の前）
    let commentCount: Int
    let onComments: (() -> Void)?
    /// お気に入りか（nil なら出さない）
    let saved: Bool?
    let onToggleSave: () -> Void
    /// 自分のカードを直す（自分のカードだけ）
    let onEdit: (() -> Void)?
    /// 自分のカードを友達に送る（自分のカードだけ）
    let onSendToFriend: (() -> Void)?

    @State private var confirmDelete = false
    @State private var viewer: PhotoViewerItem?
    /// トレーディングカードの形で大きく見る
    @State private var showBig = false
    /// カードの帯に出す GATE の名前
    let gateTitle: String
    /// 裏返しているか（裏はくわしいこと：書いた人・日時・公開範囲など）
    @State private var flipped = false
    /// 表と裏の高さ（いま見えている面の高さにする。高いほうに合わせると、低い面の上下に空きができる）
    @State private var frontHeight: CGFloat = 0
    @State private var backHeight: CGFloat = 0
    @EnvironmentObject private var session: SessionModel

    init(item: Graffiti, author: String, isMine: Bool, likeCount: Int, liked: Bool,
         onLike: @escaping () -> Void, onDelete: @escaping () -> Void, onReport: @escaping () -> Void,
         onShare: (() -> Void)? = nil, onCompare: (() -> Void)? = nil, onCardLink: (() -> Void)? = nil,
         linkNote: String? = nil, inAtlas: Bool? = nil, onToggleAtlas: @escaping () -> Void = {},
         commentCount: Int = 0, onComments: (() -> Void)? = nil,
         saved: Bool? = nil, onToggleSave: @escaping () -> Void = {}, onEdit: (() -> Void)? = nil,
         onSendToFriend: (() -> Void)? = nil, startFlipped: Bool = false, gateTitle: String = "") {
        _flipped = State(initialValue: startFlipped)
        self.gateTitle = gateTitle
        self.item = item
        self.author = author
        self.isMine = isMine
        self.likeCount = likeCount
        self.liked = liked
        self.onLike = onLike
        self.onDelete = onDelete
        self.onReport = onReport
        self.onShare = onShare
        self.onCompare = onCompare
        self.onCardLink = onCardLink
        self.linkNote = linkNote
        self.inAtlas = inAtlas
        self.onToggleAtlas = onToggleAtlas
        self.commentCount = commentCount
        self.onComments = onComments
        self.saved = saved
        self.onToggleSave = onToggleSave
        self.onEdit = onEdit
        self.onSendToFriend = onSendToFriend
    }

    var body: some View {
        ZStack(alignment: .top) {
            front
                .fixedSize(horizontal: false, vertical: true)
                .background(HeightReader(height: $frontHeight))
                .opacity(flipped ? 0 : 1)
                .accessibilityHidden(flipped)
            back
                .fixedSize(horizontal: false, vertical: true)
                .background(HeightReader(height: $backHeight))
                .opacity(flipped ? 1 : 0)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .accessibilityHidden(!flipped)
        }
        .frame(height: shownHeight, alignment: .top)
        .clipped()
        .rotation3DEffect(.degrees(flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCard).stroke(Theme.line))
        .fullScreenCover(item: $viewer) { item in
            PhotoViewer(path: item.path, caption: item.caption)
                .environmentObject(session)
        }
        .fullScreenCover(isPresented: $showBig) {
            TradingCardViewer(content: tradingContent, isMine: isMine, onReport: onReport)
        }
        .confirmationDialog("このグラフィティカードを消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("消す", role: .destructive, action: onDelete)
        } message: {
            Text("友達の新着や GATE からも見えなくなります。")
        }
    }

    /// いま見えている面の高さ（測る前は、決めずに置く）
    private var shownHeight: CGFloat? {
        let h = flipped ? backHeight : frontHeight
        return h > 0 ? h : nil
    }

    private func flip() {
        Haptics.soft()
        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) { flipped.toggle() }
    }

    // MARK: 表（写真とひとこと）

    /// トレーディングカードの形にする中身
    private var tradingContent: TradingCardContent {
        TradingCardContent(id: item.id, photoPath: item.photo_path, body: item.body,
                           author: isMine ? (session.profile?.display_name ?? "あなた") : author, title: item.title,
                           gateTitle: gateTitle, createdAt: item.created_at, likes: likeCount,
                           finish: CardFinish(raw: item.finish), badge: isMine ? .mine : nil)
    }

    private var front: some View {
        VStack(alignment: .leading, spacing: 10) {
            // カードそのもの（押すと大きく見て、指で傾けられる）
            Button {
                showBig = true
            } label: {
                TradingCard(content: tradingContent)
                    .frame(maxWidth: 290)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("押すと大きく見られます")
            HStack(spacing: 8) {
                authorLabel
                Spacer()
                Text(ServerDate.relative(item.created_at)).font(.caption).foregroundStyle(Theme.textSecondary)
                Button(action: flip) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("カードの裏を見る")
            }
            if item.edited_at != nil {
                Text("直しました").font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            if let linkNote {
                Label(linkNote, systemImage: "hand.wave.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.warm)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.warm.opacity(0.12), in: Capsule())
            }
            actionRow
        }
        .padding(14)
    }

    @ViewBuilder private var authorLabel: some View {
        if isMine {
            PersonBadge(name: "あなた", size: 28)
            Text("あなた").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
        } else {
            NavigationLink {
                ProfileView(userID: item.author)
            } label: {
                HStack(spacing: 8) {
                    PersonBadge(name: author.isEmpty ? "?" : author, size: 28)
                    Text(author.isEmpty ? "だれか" : author)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                }
            }
        }
    }

    /// 幅が足りないとき（小さい iPhone で友達のカード）は「来たよ」「見比べる」をしるしだけにする
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            actionRow(compact: false)
            actionRow(compact: true)
        }
    }

    private func actionRow(compact: Bool) -> some View {
        HStack(spacing: 14) {
            Button(action: onLike) {
                Label("\(likeCount)", systemImage: liked ? "heart.fill" : "heart")
                    .foregroundStyle(liked ? Theme.alert : Theme.textSecondary)
                    .symbolEffect(.bounce, value: liked)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: likeCount)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(liked ? "いいねをやめる" : "いいね")
            if let onComments {
                Button(action: onComments) {
                    Label("\(commentCount)", systemImage: commentCount > 0 ? "bubble.left.fill" : "bubble.left")
                        .foregroundStyle(commentCount > 0 ? Theme.accent : Theme.textSecondary)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: commentCount)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返信 \(commentCount) 件")
            }
            Spacer()
            if let onCardLink {
                Button(action: onCardLink) {
                    Label("来たよ", systemImage: "hand.wave")
                        .labelStyle(CompactLabelStyle(compact: compact))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.warm)
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("自分のカードを添えて来たよを送る")
            }
            if let onCompare {
                Button(action: onCompare) {
                    Label("見比べる", systemImage: "rectangle.split.2x1")
                        .labelStyle(CompactLabelStyle(compact: compact))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("自分のカードと見比べる")
            }
            if let saved {
                Button(action: onToggleSave) {
                    Image(systemName: saved ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(saved ? Theme.warm : Theme.textSecondary)
                        .symbolEffect(.bounce, value: saved)
                        .frame(width: 28, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(saved ? "保存をやめる" : "保存する")
            }
            Menu {
                if isMine {
                    if let onSendToFriend {
                        Button(action: onSendToFriend) { Label("友達に送る", systemImage: "paperplane") }
                    }
                    if let onEdit {
                        Button(action: onEdit) { Label("直す（ひとこと・見せる範囲）", systemImage: "pencil") }
                    }
                    if let onShare {
                        Button(action: onShare) { Label("カードを共有", systemImage: "square.and.arrow.up") }
                    }
                    if let inAtlas {
                        Button(action: onToggleAtlas) {
                            Label(inAtlas ? "友達のカード図鑑から外す" : "友達のカード図鑑に載せる",
                                  systemImage: inAtlas ? "books.vertical" : "books.vertical.fill")
                        }
                    }
                    Button { flip() } label: { Label("カードの裏を見る", systemImage: "arrow.triangle.2.circlepath") }
                    Button("消す", role: .destructive) { confirmDelete = true }
                } else {
                    if let onCardLink {
                        Button(action: onCardLink) {
                            Label("自分のカードを添えて来たよを送る", systemImage: "hand.wave")
                        }
                    }
                    if let onCompare {
                        Button(action: onCompare) {
                            Label("自分のカードと見比べる", systemImage: "rectangle.split.2x1")
                        }
                    }
                    Button { flip() } label: { Label("カードの裏を見る", systemImage: "arrow.triangle.2.circlepath") }
                    Button(action: onReport) {
                        Label("通報する", systemImage: "exclamationmark.bubble")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 24)
            }
            .accessibilityLabel("そのほか")
        }
        .font(.caption)
        .foregroundStyle(Theme.textSecondary)
    }

    // MARK: 裏（くわしいこと）

    private var back: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("カードの裏")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button(action: flip) {
                    Label("表にもどす", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            backRow("person.fill", "書いた人", isMine ? "あなた" : (author.isEmpty ? "だれか" : author))
            backRow("calendar", "残した日", GateDates.fullText(item.created_at))
            if let edited = item.edited_at {
                backRow("pencil", "直した日", GateDates.fullText(edited))
            }
            backRow("eye", "見える人", Visibility.label(of: item.visibility))
            backRow(item.local_only ? "mappin.and.ellipse" : "sparkles", "どこで見られるか",
                    item.local_only ? "この GATE の中だけ" : "GATE の中と、友達の新着（24 時間）")
            if let inAtlas {
                backRow("books.vertical", "友達のカード図鑑", inAtlas ? "載せています（写真・場所・日付だけ）" : "載せていません")
            }
            HStack(spacing: 14) {
                Label("いいね \(likeCount)", systemImage: "heart")
                if onComments != nil { Label("返信 \(commentCount)", systemImage: "bubble.left") }
                if saved == true { Label("保存しています", systemImage: "bookmark.fill").foregroundStyle(Theme.warm) }
            }
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(colors: [Theme.accentLight.opacity(0.55), Theme.surface], startPoint: .top, endPoint: .bottom)
        )
    }

    private func backRow(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}


/// 幅が足りないときは、しるしだけにするラベル
struct CompactLabelStyle: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.icon
                .frame(minWidth: 28, minHeight: 24)
        } else {
            HStack(spacing: 4) {
                configuration.icon
                configuration.title
            }
        }
    }
}


/// 置かれた面の高さを測る（カードの表と裏で、見えている面の高さにするため）
struct HeightReader: View {
    @Binding var height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { height = proxy.size.height }
                .onChange(of: proxy.size.height) { _, value in height = value }
        }
    }
}
