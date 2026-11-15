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

    var isInside: Bool { visit != nil && (visitExpires ?? .distantPast) > Date() }
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
    @State private var report: ReportItem?
    @State private var refreshToken = 0
    @State private var actionMessage: String?
    @State private var trails: [TrailSummary] = []
    @State private var stats: GateStats?
    @State private var health: PlaceMapHealth?
    /// 作った本人には正確な位置
    @State private var exactPlace: CLLocationCoordinate2D?
    /// 自分がこの GATE に来た日
    @State private var showVisits = false

    init(gateID: UUID, tab: GateTab = .graffiti) {
        self.gateID = gateID
        _tab = State(initialValue: tab)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary {
                    if summary.status == "closed" && isOwner(summary) {
                        closedBanner(summary)
                    }
                    header(summary)
                    if !trails.isEmpty {
                        trailStrip
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        let context = makeContext(summary, now: timeline.date)
                        VStack(alignment: .leading, spacing: 16) {
                            visitBanner(context, summary: summary, now: timeline.date)
                            if summary.owner == session.userID {
                                addLooksButton(summary)
                            }
                            Picker("GATE の中", selection: $tab) {
                                ForEach(GateTab.allCases) { t in Text(t.label).tag(t) }
                            }
                            .pickerStyle(.segmented)
                            section(context)
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
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(summary?.title ?? "GATE")
        .navigationBarTitleDisplayMode(.inline)
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
        .confirmationDialog("この GATE を閉じますか？", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("閉じる", role: .destructive) { Task { await setOpen(false) } }
        } message: {
            Text("ほかの人は見つけられず、入れなくなります。中のグラフィティカードや掲示板は消えず、あとで開け直せます。")
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
                           canManage: canManage(s))
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
                Text("この GATE は閉じています").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text("いまは、あなたにだけ見えています。ほかの人は見つけられず、入れません。中のグラフィティカードや掲示板は消えていません。")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await setOpen(true) }
                } label: {
                    Label("開け直す", systemImage: "door.left.hand.open")
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
            Trace.log("GATE を\(open ? "開け直した" : "閉じた")")
            await reload()
        } catch {
            actionMessage = ErrorText.isMissingFunction(error)
                ? "閉じる・開け直すは、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
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
                                Label("GATE を閉じる", systemImage: "door.left.hand.closed")
                            }
                        } else {
                            Button {
                                Task { await setOpen(true) }
                            } label: {
                                Label("GATE を開け直す", systemImage: "door.left.hand.open")
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

    private func header(_ s: GateSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 表紙（無いときは、アイコンと同じ夜空にしるし）。下に題と作った人を重ねる
            ZStack(alignment: .bottomLeading) {
                if let cover = s.cover_path {
                    RemotePhoto(path: cover)
                } else {
                    LinearGradient(colors: [Color(hex: 0x060A24), Color(hex: 0x140F3A), Color(hex: 0x3A1530)],
                                   startPoint: .top, endPoint: .bottom)
                    GateMark(size: 84, glowing: false)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, 40)
                }
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.62)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                    if s.owner == session.userID {
                        Label("あなたの GATE", systemImage: "person.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.9))
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
                .padding(16)
            }
            .frame(height: 230)
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(alignment: .leading, spacing: 12) {
                if !s.note.isEmpty {
                    Text(s.note).font(.body).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 数の札（横に流す）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(GateKind(raw: s.kind).label, GateKind(raw: s.kind).symbol, warm: GateKind(raw: s.kind) == .view)
                        chip("グラフィティカード \(s.graffiti_count) 枚", "square.stack")
                        if let stats {
                            chip("\(stats.visitor_count) 人が訪れた", "figure.walk")
                            if stats.my_visits > 0 {
                                Button {
                                    showVisits = true
                                } label: {
                                    chip("あなたは \(stats.my_visits) 回", "door.left.hand.open", warm: true)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("あなたが来た日を見る")
                            }
                            if let last = stats.last_activity_at { chip("最後の記録 \(ServerDate.relative(last))", "clock") }
                        }
                        chip(Visibility.label(of: s.visibility), "eye")
                    }
                }
                // いつ・どこで
                GateWhereWhen(title: s.title, createdAt: s.created_at,
                              coordinate: exactPlace ?? CLLocationCoordinate2D(latitude: s.approx_lat, longitude: s.approx_lon),
                              exact: exactPlace != nil, coverPath: s.cover_path,
                              mine: s.owner == session.userID, ownerName: s.owner_name)
                if let health {
                    placeMemoryNote(health)
                }
                if let actionMessage {
                    NoticeText(text: actionMessage, isError: false)
                }
            }
            .padding(16)
        }
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

    /// 入場中は残り時間、入る前は「現地で扉を開ける」
    @ViewBuilder private func visitBanner(_ context: GateContext, summary: GateSummary, now: Date) -> some View {
        if let expires = context.visitExpires, context.isInside {
            let minutes = max(1, Int(expires.timeIntervalSince(now) / 60 + 0.5))
            let near = keeper.entries[context.visit ?? UUID()]?.near
            Label(near == false ? "GATE から離れたので、まもなく扉が閉じます（あと約 \(minutes) 分）"
                                : "扉が開いています（その場にいるあいだ開いたまま）",
                  systemImage: near == false ? "door.left.hand.closed" : "door.left.hand.open")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.accentLight, in: RoundedRectangle(cornerRadius: 14))
        } else {
            let distance = location.location?.distance(from: CLLocation(latitude: summary.approx_lat,
                                                                         longitude: summary.approx_lon))
            let far = (distance ?? 0) > 150
            VStack(alignment: .leading, spacing: 8) {
                if far, let distance {
                    // 遠いとき：まず現地へ（地図アプリで歩く道）
                    Button {
                        openWalking(summary)
                    } label: {
                        Label("ここへ行く（\(TrailGuide.distanceText(distance))）", systemImage: "figure.walk")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button {
                        showAR = true
                    } label: {
                        Label("着いたら、扉を開ける", systemImage: "door.left.hand.open")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(session.api == nil)
                    Text("扉は GATE の近く（120m 以内）で開けます。地図アプリで、おおよその場所までの歩く道を出します。")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Button {
                        showAR = true
                    } label: {
                        Label("現地で扉を開ける", systemImage: "door.left.hand.open")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(session.api == nil)
                    Text("作った人が写した場所・物にカメラを向けます。位置（120m 以内）と景色の両方が合うと扉が現れ、その場にいるあいだ、中のグラフィティカードや掲示板を読んだり残したりできます。")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
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
            if context.isInside && graffiti.count > 2 {
                orderBar
            }
            if context.isInside && graffiti.count > 5 {
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
            let shown = context.isInside ? searched(arranged(graffiti)) : graffiti.filter { $0.author == session.userID }
            if !context.isInside && !shown.isEmpty {
                Text("ここに残した自分のグラフィティカード").font(.headline).foregroundStyle(Theme.text)
            }
            if context.isInside && shown.isEmpty {
                Text(graffiti.isEmpty ? "まだグラフィティカードはありません。最初の 1 枚を残せます。" : "この並べ方に合うグラフィティカードはありません。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            if !context.isInside && shown.isEmpty {
                Text("みんなのグラフィティカードは、現地で扉を開けると読めます。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            if let error { NoticeText(text: error) }
            ForEach(shown) { item in
                let isMine = item.author == session.userID
                GraffitiCard(item: item, author: names[item.author] ?? "",
                             isMine: isMine,
                             likeCount: likes[item.id]?.count ?? 0, liked: likes[item.id]?.mine ?? false,
                             onLike: { Task { await toggleLike(item) } },
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
                             onToggleSave: { Task { await toggleSave(item) } },
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
        ZStack {
            front
                .opacity(flipped ? 0 : 1)
                .accessibilityHidden(flipped)
            back
                .opacity(flipped ? 1 : 0)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                .accessibilityHidden(!flipped)
        }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
