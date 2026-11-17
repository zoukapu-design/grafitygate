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
    @State private var tab: GateTab = .graffiti
    @State private var saved = false
    /// 一緒に管理する人（作った人のほか）
    @State private var managers: [GateManager] = []
    @State private var editingGate = false
    @ObservedObject private var keeper = VisitKeeper.shared
    @State private var showManagers = false
    @State private var confirmClose = false
    /// 「扉を出る」の確かめ
    @State private var confirmLeave = false
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

    init(gateID: UUID, tab: GateTab = .graffiti) {
        self.gateID = gateID
        _tab = State(initialValue: tab)
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
                            // 扉の中：夜空の画面。ようこそ → ここでできること → 扉を出る → 中のもの
                            insidePage(summary, context: context, now: timeline.date, scroller: scroller)
                        } else {
                            // グラフィティボード：表紙・名前・作った人 → 紹介と数 → 扉 → いつ・どこで → 扉の向こう
                            VStack(alignment: .leading, spacing: 16) {
                                header(summary)
                                visitBanner(context, summary: summary, now: timeline.date)
                                    .id("door")
                                whereWhen(summary)
                                if !trails.isEmpty {
                                    trailStrip
                                }
                                if summary.owner == session.userID {
                                    addLooksButton(summary)
                                }
                                insideHeading(context)
                                    .id("inside")
                                tabPicker
                                section(context)
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
        .fullScreenCover(isPresented: $showAddLooks) {
            ARExperienceView(mode: .addLooks(gateID)) {
                showAddLooks = false
            }
        }
        .sheet(item: $report) { item in
            ReportSheet(item: item)
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
                    Task { await setOpen(true) }
                } label: {
                    Label("再開する", systemImage: "door.left.hand.open")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warm.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.warm.opacity(0.35)))
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

    private var tabPicker: some View {
        Picker("扉の向こう", selection: $tab) {
            ForEach(GateTab.allCases) { t in Text(t.label).tag(t) }
        }
        .pickerStyle(.segmented)
    }

    /// 扉の中の画面：グラフィティボードとはっきり違う夜空の画面にし、ここでできることを大きく見せる
    private func insidePage(_ s: GateSummary, context: GateContext, now: Date, scroller: ScrollViewProxy) -> some View {
        let minutes = context.visitExpires.map { max(1, Int($0.timeIntervalSince(now) / 60 + 0.5)) } ?? 0
        let near = keeper.entries[context.visit ?? UUID()]?.near
        return VStack(alignment: .leading, spacing: 22) {
            InsideWelcome(title: s.title, coverPath: s.cover_path,
                          ownerLine: s.owner == session.userID ? "あなたの GATE" : "\(s.owner_name) さんの GATE",
                          status: near == false ? "GATE から離れたので、あと約 \(minutes) 分で扉が閉じます"
                                                : "その場にいるあいだ、扉は開いたまま",
                          warning: near == false)

            // ここでできること（押すと、下の「扉の中」のその場所へ）
            VStack(alignment: .leading, spacing: 12) {
                Text("扉の中でできること")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(.white)
                InsideActionTile(symbol: "square.and.pencil", title: "グラフィティカードを残す",
                                 detail: "この扉の中でだけ残せる 1 枚。写真とひとことを、ここに。", primary: true) {
                    jump(to: .graffiti, scroller: scroller)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    InsideActionTile(symbol: "square.stack.fill", title: "みんなのカード",
                                     detail: "\(s.graffiti_count) 枚・いいね・返信・保存") { jump(to: .graffiti, scroller: scroller) }
                    InsideActionTile(symbol: "text.bubble.fill", title: "掲示板",
                                     detail: "話題を立てる・返す") { jump(to: .board, scroller: scroller) }
                    InsideActionTile(symbol: "photo.on.rectangle.angled", title: "アルバム",
                                     detail: "みんなで写真・動画・声を") { jump(to: .memories, scroller: scroller) }
                    InsideActionTile(symbol: "envelope.fill", title: "手紙",
                                     detail: "未来のだれかへ・届いた手紙") { jump(to: .letters, scroller: scroller) }
                    InsideActionTile(symbol: "clock.arrow.circlepath", title: "今と昔",
                                     detail: "同じ場所の写真を重ねる") { jump(to: .thenNow, scroller: scroller) }
                    InsideActionTile(symbol: "person.2.fill", title: "来たよ",
                                     detail: "友達のカードに自分のカードを") { jump(to: .graffiti, scroller: scroller) }
                }
            }

            Button {
                confirmLeave = true
            } label: {
                Label("扉を出る", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.headline)
            }
            .buttonStyle(NightSecondaryButtonStyle())
            .accessibilityHint("扉の中から出て、グラフィティボードに戻ります")

            // 扉の中のもの（白い紙の上に）
            VStack(alignment: .leading, spacing: 16) {
                insideHeading(context)
                    .id("inside")
                tabPicker
                section(context)
            }
            .padding(16)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

            // この GATE について（グラフィティボードの中身は下に小さく）
            VStack(alignment: .leading, spacing: 16) {
                Text("この GATE について")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(.white)
                header(s)
                whereWhen(s)
                if !trails.isEmpty {
                    trailStrip
                }
                if s.owner == session.userID {
                    addLooksButton(s)
                }
            }
            .padding(.top, 8)
        }
    }

    private func jump(to target: GateTab, scroller: ScrollViewProxy) {
        tab = target
        Haptics.tap()
        withAnimation(.easeInOut(duration: 0.35)) { scroller.scrollTo("inside", anchor: .top) }
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

    /// 扉の向こう（カード・アルバム・掲示板・手紙・今と昔）の見出し
    private func insideHeading(_ context: GateContext) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: context.isInside ? "door.left.hand.open" : "lock.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(context.isInside ? Theme.accent : Theme.textSecondary)
            Text(context.isInside ? "扉の中" : "扉の向こう")
                .font(.title3.weight(.heavy))
                .foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            if !context.isInside {
                Text(context.opened ? "読めます・残すのは扉の中で" : "扉を開けると読めます・残せます")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.top, 6)
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
    @ViewBuilder private func visitBanner(_ context: GateContext, summary: GateSummary, now: Date) -> some View {
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

    @ViewBuilder private func section(_ context: GateContext) -> some View {
        switch tab {
        case .graffiti:
            GraffitiSection(context: context, refreshToken: refreshToken) { item in report = item }
        case .memories:
            MemorySection(context: context, refreshToken: refreshToken) { item in report = item }
        case .board:
            BoardSection(context: context, refreshToken: refreshToken)
        case .letters:
            LetterSection(context: context, refreshToken: refreshToken)
        case .thenNow:
            SnapshotSection(context: context, refreshToken: refreshToken) { item in report = item }
        }
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
            health = summary?.owner == session.userID ? (try? await api.placeMapHealth(gateID)) ?? nil : nil
            if summary?.owner == session.userID {
                exactPlace = (try? await api.myGate(gateID))?.coordinate
            }
        } catch {
            loadError = ErrorText.of(error)
        }
        loaded = true
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

// MARK: - 記憶（グラフィティ）

/// みんなのグラフィティカード：入場中は 1 枚残せて、みんなのカードが読める。入る前は自分のカードだけ。
struct GraffitiSection: View {
    let context: GateContext
    let refreshToken: Int
    let onReport: (ReportItem) -> Void

    @EnvironmentObject private var session: SessionModel
    @State private var graffiti: [Graffiti] = []
    @State private var names: [UUID: String] = [:]
    @State private var likes: [UUID: (count: Int, mine: Bool)] = [:]
    @State private var error: String?

    @State private var draft = ""
    @State private var draftVisibility: Visibility = .friends
    @State private var draftLocalOnly = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var posting = false
    @State private var postMessage: (text: String, isError: Bool)?
    @State private var order: GraffitiOrder = .newest
    @State private var season: Season = .current
    @State private var friendIDs: Set<UUID> = []
    @State private var sharing: CardSnapshot?
    @State private var comparing: CardCompareRequest?
    @State private var linking: CardSnapshot?
    /// この GATE で、自分が関わる「来たよ」
    @State private var links: [CardLinkMark] = []
    @State private var draftInAtlas = true
    /// カードごとの返信の数・お気に入り（nil＝サーバーがまだ 0018 の前なので出さない）
    @State private var extras: [UUID: CardExtra]?
    @State private var commenting: Graffiti?
    @State private var editingCard: Graffiti?
    @State private var sendingCard: Graffiti?
    @State private var cardQuery = ""

    init(context: GateContext, refreshToken: Int, onReport: @escaping (ReportItem) -> Void) {
        self.context = context
        self.refreshToken = refreshToken
        self.onReport = onReport
    }

    /// ほかの人のカード（友達を先に、新しい順）
    private var otherCards: [Graffiti] {
        graffiti.filter { $0.author != session.userID }.sorted {
            let fa = friendIDs.contains($0.author), fb = friendIDs.contains($1.author)
            return fa != fb ? fa : $0.created_at > $1.created_at
        }
    }

    private func compare(start: UUID?) {
        comparing = CardCompareRequest(others: otherCards.map(snapshot), mine: myCards.map(snapshot), start: start)
    }

    /// 「来たよ」を送れるか：GATE の中で、友達のカードに、自分のカードがあって、まだ送っていない
    private func canLink(to item: Graffiti) -> Bool {
        guard context.isInside, item.author != session.userID, friendIDs.contains(item.author), !myCards.isEmpty else { return false }
        return !links.contains { $0.to_card == item.id && $0.sender == session.userID }
    }

    private func linkNote(for item: Graffiti) -> String? {
        if item.author == session.userID {
            let from = links.filter { $0.to_card == item.id && $0.recipient == session.userID }
            guard let first = from.first else { return nil }
            let who = names[first.sender] ?? "友達"
            return from.count > 1 ? "\(who) さんたちが「来たよ」" : "\(who) さんが「来たよ」"
        }
        return links.contains { $0.to_card == item.id && $0.sender == session.userID } ? "「来たよ」を送りました" : nil
    }

    private func loadLinks() async {
        links = (try? await session.api?.cardLinks(in: context.gateID)) ?? []
    }

    private func toggleAtlas(_ item: Graffiti) async {
        guard let api = session.api else { return }
        let next = !(item.in_atlas ?? false)
        do {
            try await api.setGraffitiAtlas(item.id, on: next)
            if let i = graffiti.firstIndex(where: { $0.id == item.id }) { graffiti[i].in_atlas = next }
            postMessage = (next ? "友達のカード図鑑に載せました（写真・場所・日付。ひとことは現地だけ）。" : "カード図鑑から外しました。", false)
        } catch {
            postMessage = (ErrorText.isMissingFunction(error) ? "サーバーの準備がまだです（SQL を貼り直すと使えます）。" : ErrorText.of(error), true)
        }
    }

    /// この GATE の自分のカード（新しい順）
    private var myCards: [Graffiti] {
        graffiti.filter { $0.author == session.userID }.sorted { $0.created_at > $1.created_at }
    }

    private func snapshot(_ item: Graffiti) -> CardSnapshot {
        let mine = item.author == session.userID
        let name = mine ? (session.profile?.display_name ?? "") : (names[item.author] ?? "")
        return CardSnapshot(item, gateTitle: context.title, authorName: name)
    }

    /// 並べ方：新しい順・古い順・友達だけ・季節
    enum GraffitiOrder: String, CaseIterable, Identifiable {
        case newest = "新しい順"
        case oldest = "古い順"
        case friends = "友達だけ"
        case mine = "自分の"
        case season = "季節で"
        var id: String { rawValue }
    }

    enum Season: Int, CaseIterable, Identifiable {
        case spring, summer, autumn, winter
        var id: Int { rawValue }
        var label: String { ["春", "夏", "秋", "冬"][rawValue] }
        static func of(_ date: Date) -> Season {
            switch Calendar.current.component(.month, from: date) {
            case 3...5: return .spring
            case 6...8: return .summer
            case 9...11: return .autumn
            default: return .winter
            }
        }
        static var current: Season { of(Date()) }
    }

    private func arranged(_ list: [Graffiti]) -> [Graffiti] {
        switch order {
        case .newest: return list.sorted { $0.created_at > $1.created_at }
        case .oldest: return list.sorted { $0.created_at < $1.created_at }
        case .friends:
            return list.filter { friendIDs.contains($0.author) || $0.author == session.userID }
                .sorted { $0.created_at > $1.created_at }
        case .mine:
            return list.filter { $0.author == session.userID }.sorted { $0.created_at > $1.created_at }
        case .season:
            return list.filter { ServerDate.parse($0.created_at).map(Season.of) == season }
                .sorted { $0.created_at > $1.created_at }
        }
    }

    /// ことば・書いた人の名前で探す（GATE の中の一覧から）
    private func searched(_ list: [Graffiti]) -> [Graffiti] {
        let q = cardQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.body.localizedCaseInsensitiveContains(q) || (names[$0.author] ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    private var orderBar: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("並べ方", selection: $order) {
                    ForEach(GraffitiOrder.allCases) { o in Text(o.rawValue).tag(o) }
                }
            } label: {
                Label(order.rawValue, systemImage: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            if order == .season {
                Picker("季節", selection: $season) {
                    ForEach(Season.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.segmented)
            }
            Spacer(minLength: 0)
            // 自分のカードを置いたまま、みんなのカードを横にめくって見比べる
            if !myCards.isEmpty && !otherCards.isEmpty && order != .season {
                Button {
                    compare(start: nil)
                } label: {
                    Label("見比べる", systemImage: "rectangle.split.2x1")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.warm)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if context.isInside {
                composer
            }
            if !context.isInside {
                outsideNote
            }
            if context.canRead && graffiti.count > 2 {
                orderBar
            }
            if context.canRead && graffiti.count > 5 {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                    TextField("ことば・名前で探す", text: $cardQuery)
                    if !cardQuery.isEmpty {
                        Button { cardQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                        }
                        .accessibilityLabel("消す")
                    }
                }
                .padding(10)
                .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
            }
            let shown = context.canRead ? searched(arranged(graffiti)) : graffiti.filter { $0.author == session.userID }
            if !context.canRead && !shown.isEmpty {
                Text("ここに残した自分のグラフィティカード").font(.headline).foregroundStyle(Theme.text)
            }
            if context.canRead && shown.isEmpty {
                Text(graffiti.isEmpty
                     ? (context.isInside ? "まだグラフィティカードはありません。最初の 1 枚を残せます。" : "まだグラフィティカードはありません。")
                     : "この並べ方に合うグラフィティカードはありません。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            if !context.canRead {
                peekCards
            }
            if let error { NoticeText(text: error) }
            ForEach(shown) { item in
                let isMine = item.author == session.userID
                GraffitiCard(item: item, author: names[item.author] ?? "",
                             isMine: isMine,
                             likeCount: likes[item.id]?.count ?? 0, liked: likes[item.id]?.mine ?? false,
                             onLike: {
                                 // いいねは扉の中だけ（遠くから読んでいるときは、そう伝える）
                                 if context.isInside { Task { await toggleLike(item) } } else { insideOnlyHint("いいね") }
                             },
                             onDelete: { Task { await delete(item) } },
                             onReport: {
                                 onReport(ReportItem(id: item.id, target: .graffiti, userID: item.author,
                                                     userName: names[item.author], label: "グラフィティカード"))
                             },
                             onShare: isMine ? { sharing = snapshot(item) } : nil,
                             onCompare: (!isMine && !myCards.isEmpty) ? { compare(start: item.id) } : nil,
                             onCardLink: canLink(to: item) ? { linking = snapshot(item) } : nil,
                             linkNote: linkNote(for: item),
                             inAtlas: isMine && item.photo_path != nil && !item.local_only ? item.in_atlas : nil,
                             onToggleAtlas: { Task { await toggleAtlas(item) } },
                             commentCount: extras?[item.id]?.comments ?? 0,
                             onComments: extras == nil ? nil : { commenting = item },
                             saved: extras == nil ? nil : (extras?[item.id]?.saved ?? false),
                             onToggleSave: {
                                 // 保存を付けるのは扉の中だけ（外すのはいつでも）
                                 if context.isInside || extras?[item.id]?.saved == true {
                                     Task { await toggleSave(item) }
                                 } else {
                                     insideOnlyHint("保存")
                                 }
                             },
                             onEdit: isMine ? { editingCard = item } : nil,
                             onSendToFriend: isMine ? { sendingCard = item } : nil)
            }
        }
        .sheet(item: $sendingCard) { card in
            SendCardSheet(card: card, gateTitle: context.title) { text in postMessage = (text, false) }
                .environmentObject(session)
        }
        .sheet(item: $editingCard) { card in
            GraffitiEditSheet(item: card) { Task { await load() } }
                .environmentObject(session)
        }
        .sheet(item: $commenting) { card in
            CardCommentsSheet(card: card, authorName: names[card.author] ?? "",
                              canWrite: context.isInside || card.author == session.userID) { count in
                extras?[card.id, default: CardExtra(graffiti_id: card.id, comments: 0, saved: false)].comments = count
            }
            .environmentObject(session)
        }
        .sheet(item: $linking) { card in
            CardLinkComposer(friendCard: card, myCards: myCards.map(snapshot)) {
                Task { await loadLinks() }
            }
            .environmentObject(session)
        }
        .sheet(item: $sharing) { card in
            CardShareSheet(card: card).environmentObject(session)
        }
        .sheet(item: $comparing) { request in
            CardCompareView(request: request).environmentObject(session)
        }
        .task(id: "\(context.isInside)-\(refreshToken)") { await load() }
        .onChange(of: photoItem) { _, item in
            Task { await loadPhoto(item) }
        }
    }

    /// 扉の外で見ているときの一言（一度開けた GATE は、遠くからも読める）
    @ViewBuilder private var outsideNote: some View {
        if context.opened {
            Label("一度扉を開けた GATE なので、遠くからも読めます。いいね・保存・返信は、扉を開けているあいだにできます。",
                  systemImage: "key.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentLight, in: RoundedRectangle(cornerRadius: 14))
        }
        if let postMessage {
            NoticeText(text: postMessage.text, isError: postMessage.isError)
        }
    }

    private func insideOnlyHint(_ what: String) {
        postMessage = ("\(what)は、現地で扉を開けているあいだにできます。", false)
        Haptics.tap()
    }

    /// まだ扉を開けたことのない人へのチラ見せ（新しいグラフィティカード 3 枚）
    @ViewBuilder private var peekCards: some View {
        if let peek = context.peek, !peek.cards.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                PeekHeading(title: "新しいグラフィティカード")
                ForEach(peek.cards) { card in
                    PeekCardView(card: card, isMine: card.author == session.userID) {
                        onReport(ReportItem(id: card.id, target: .graffiti, userID: card.author,
                                            userName: card.author_name, label: "グラフィティカード"))
                    }
                }
                LockNote(text: "ほかのグラフィティカードと返信は、扉を開けると読めます。一度開ければ、そのあとは遠くからでも読めます。")
            }
        } else {
            LockNote(text: graffiti.isEmpty && context.peek != nil
                     ? "まだグラフィティカードはありません。扉を開けて、最初の 1 枚を残せます。"
                     : "みんなのグラフィティカードは、現地で扉を開けると読めます。一度開ければ、そのあとは遠くからでも読めます。")
        }
    }

    private var composer: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("ここに 1 枚残す").font(.headline).foregroundStyle(Theme.text)
                if let photo {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 200)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        Button {
                            self.photo = nil
                            photoItem = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white, .black.opacity(0.45))
                        }
                        .padding(8)
                        .accessibilityLabel("写真を外す")
                    }
                }
                TextField("この場所の思い出・ひとこと", text: $draft, axis: .vertical)
                    .lineLimit(2...5)
                    .padding(12)
                    .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                // 写真と、見せる人（細かい決まりはメニューの中に。詰め込まない）
                HStack(spacing: 10) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(photo == nil ? "写真" : "選び直す", systemImage: "photo")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(Theme.accentLight, in: Capsule())
                    }
                    Menu {
                        Picker("見せる人", selection: $draftVisibility) {
                            ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
                        }
                        Toggle("現地だけで見せる（友達の新着に出さない）", isOn: $draftLocalOnly)
                        Toggle("友達のカード図鑑に写真を載せる", isOn: $draftInAtlas)
                            .disabled(draftLocalOnly)
                    } label: {
                        Label(draftVisibility.label + (draftLocalOnly ? "・現地だけ" : ""), systemImage: "eye")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(Theme.surfaceElevated, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                Button {
                    Task { await post() }
                } label: {
                    if posting { ProgressView().tint(.white) } else { Text("残す") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(posting || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photo == nil))
                Text("扉を開けるたびに 1 枚。同じ GATE には 12 時間あけると、また残せます。写真の位置情報などは消して送ります。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                if let postMessage {
                    NoticeText(text: postMessage.text, isError: postMessage.isError)
                }
            }
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            graffiti = try await api.graffiti(in: context.gateID)
            names = try await api.names(of: Array(Set(graffiti.map(\.author))))
            if let me = session.userID, let r = try? await api.relations(me: me) {
                friendIDs = r.following.intersection(r.followers)
            }
            if let me = session.userID {
                likes = (try? await api.likes(for: graffiti.map(\.id), me: me)) ?? [:]
            }
            if let loaded = try? await api.cardExtras(in: context.gateID) {
                extras = loaded
            }
            await loadLinks()
            error = nil
        } catch {
            self.error = ErrorText.of(error)
        }
    }

    /// 保存する・外す（先に見た目を変え、だめなら戻す）
    private func toggleSave(_ item: Graffiti) async {
        guard let api = session.api, extras != nil else { return }
        let was = extras?[item.id]?.saved ?? false
        extras?[item.id, default: CardExtra(graffiti_id: item.id, comments: 0, saved: false)].saved = !was
        Haptics.tap()
        do {
            try await api.saveCard(item.id, on: !was)
            Trace.log("カード：保存を\(was ? "外した" : "付けた")")
        } catch {
            extras?[item.id]?.saved = was
            self.error = ErrorText.of(error)
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
            photo = image.downscaled(maxSide: 1600)
        } else {
            postMessage = ("写真を読み込めませんでした。", true)
        }
    }

    private func post() async {
        guard let api = session.api, let visit = context.visit else { return }
        posting = true
        defer { posting = false }
        var photoPath: String?
        do {
            if let photo, let media = session.media, let me = session.userID {
                photoPath = try await media.uploadPhoto(photo, owner: me)
            }
            let newID = try await api.postGraffiti(visit: visit, body: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   photoPath: photoPath, visibility: draftVisibility, localOnly: draftLocalOnly)
            // 写真つきで「現地だけ」でなければ、選んだとおり友達のカード図鑑に載せる（前のサーバーでは何もしない）
            if photoPath != nil, !draftLocalOnly, draftInAtlas, draftVisibility != .private {
                try? await api.setGraffitiAtlas(newID, on: true)
            }
            draft = ""
            photo = nil
            photoItem = nil
            postMessage = ("残しました。", false)
            Haptics.success()
            await load()
        } catch {
            if let photoPath { await session.media?.removePhoto(path: photoPath) }
            postMessage = (ErrorText.of(error), true)
        }
    }

    private func delete(_ item: Graffiti) async {
        guard let api = session.api else { return }
        do {
            try await api.deleteGraffiti(item.id)
            if let path = item.photo_path { await session.media?.removePhoto(path: path) }
            await load()
        } catch {
            postMessage = (ErrorText.of(error), true)
        }
    }

    private func toggleLike(_ item: Graffiti) async {
        guard let api = session.api, let me = session.userID else { return }
        let current = likes[item.id] ?? (0, false)
        let next = !current.mine
        likes[item.id] = (max(0, current.count + (next ? 1 : -1)), next)
        do {
            try await api.setLike(item.id, me: me, on: next)
            if next { Haptics.tap() }
        } catch {
            likes[item.id] = current
            postMessage = (ErrorText.of(error), true)
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
         onSendToFriend: (() -> Void)? = nil, startFlipped: Bool = false) {
        _flipped = State(initialValue: startFlipped)
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

    private var front: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let path = item.photo_path {
                Button {
                    viewer = PhotoViewerItem(path: path, caption: item.body)
                } label: {
                    RemotePhoto(path: path)
                        .frame(height: 240)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("写真を大きく見る")
            }
            VStack(alignment: .leading, spacing: 8) {
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
                if !item.body.isEmpty {
                    Text(item.body).font(.body).foregroundStyle(Theme.text)
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
            .padding(16)
        }
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
