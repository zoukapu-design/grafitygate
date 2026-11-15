import CoreLocation
import MapKit
import SwiftUI

// MARK: - 読み込み（地図の画面と、カードのタブで同じものを使う）

/// 近くにある友達のカード：いまいる所から 300m 以内の GATE に、お互いにフォローの友達が残したカード。
/// 判定はサーバー（gf_nearby_cards）。見せたカードには 30 分の「近くの券」が出て、そのあいだ写真・お気に入りが使える。
@MainActor
final class NearbyCardsModel: ObservableObject {
    enum Problem: Equatable {
        case noLocation
        case inaccurate
        case unsupported
        case failed(String)
    }

    @Published private(set) var cards: [NearbyCard] = []
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published private(set) var problem: Problem?
    /// 今日スワイプしたカード（見ない／くわしく見た）。日付が変わると、また出る
    @Published private(set) var done: Set<UUID> = NearbyCardMemory.doneToday()
    /// 今日くわしく見たカード（上の帯から開き直せる）
    @Published private(set) var viewed: [UUID] = NearbyCardMemory.viewedToday()

    private var lastLocation: CLLocation?
    private var lastLoadedAt = Date.distantPast

    /// まだ今日スワイプしていないカード
    var deck: [NearbyCard] { cards.filter { !done.contains($0.id) } }
    var viewedCards: [NearbyCard] { viewed.compactMap { id in cards.first { $0.id == id } } }

    /// 50m 以上動いたか、2 分たったら探し直す（サーバーの回数の上限に当たらないように）
    func refresh(api: GateAPI?, location: CLLocation?, force: Bool = false) async {
        guard let api else { return }
        guard let here = location, here.horizontalAccuracy >= 0 else {
            problem = .noLocation
            return
        }
        if !force, let last = lastLocation, here.distance(from: last) < 50, Date().timeIntervalSince(lastLoadedAt) < 120 {
            return
        }
        guard here.horizontalAccuracy <= 80 else {
            problem = .inaccurate
            return
        }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            cards = try await api.nearbyCards(at: here)
            lastLocation = here
            lastLoadedAt = Date()
            problem = nil
            Trace.log("近くの友達のカード：\(cards.count) 枚（まだ見ていない \(deck.count) 枚）")
        } catch {
            if ErrorText.isMissingFunction(error) {
                problem = .unsupported
            } else if ErrorText.hasCode(error, "gf_inaccurate") {
                problem = .inaccurate
            } else if !ErrorText.isCancellation(error) {
                problem = .failed(ErrorText.of(error))
            }
        }
        loaded = true
    }

    func pass(_ card: NearbyCard) {
        NearbyCardMemory.markDone(card.id)
        done.insert(card.id)
        Trace.log("近くの友達のカード：見ない")
    }

    func open(_ card: NearbyCard) {
        NearbyCardMemory.markDone(card.id)
        NearbyCardMemory.markViewed(card.id)
        done.insert(card.id)
        viewed.removeAll { $0 == card.id }
        viewed.insert(card.id, at: 0)
        Trace.log("近くの友達のカード：くわしく見る")
    }

    /// 今日「見ない」にしたカードを、もう一度出す
    func showPassedAgain() {
        NearbyCardMemory.resetToday()
        done = []
        viewed = []
    }
}

/// 今日スワイプしたカードを iPhone の中だけに覚える（何を見なかったかはサーバーに送らない）
enum NearbyCardMemory {
    private static let doneKey = "nearbyCards.done"
    private static let viewedKey = "nearbyCards.viewed"
    private static let dayKey = "nearbyCards.day"

    private static var today: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// 日付が変わっていたら、覚えていたものを消す
    private static func rollOver() {
        let d = UserDefaults.standard
        if d.string(forKey: dayKey) != today {
            d.set(today, forKey: dayKey)
            d.removeObject(forKey: doneKey)
            d.removeObject(forKey: viewedKey)
        }
    }

    static func doneToday() -> Set<UUID> {
        rollOver()
        return Set((UserDefaults.standard.stringArray(forKey: doneKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    static func viewedToday() -> [UUID] {
        rollOver()
        return (UserDefaults.standard.stringArray(forKey: viewedKey) ?? []).compactMap(UUID.init(uuidString:))
    }

    static func markDone(_ id: UUID) {
        rollOver()
        var list = UserDefaults.standard.stringArray(forKey: doneKey) ?? []
        if !list.contains(id.uuidString) { list.append(id.uuidString) }
        UserDefaults.standard.set(Array(list.suffix(300)), forKey: doneKey)
    }

    static func markViewed(_ id: UUID) {
        rollOver()
        var list = UserDefaults.standard.stringArray(forKey: viewedKey) ?? []
        list.removeAll { $0 == id.uuidString }
        list.insert(id.uuidString, at: 0)
        UserDefaults.standard.set(Array(list.prefix(50)), forKey: viewedKey)
    }

    static func resetToday() {
        UserDefaults.standard.removeObject(forKey: doneKey)
        UserDefaults.standard.removeObject(forKey: viewedKey)
    }
}

// MARK: - カードのタブ

/// 地図の別タブ「近くの友達のカード」：1 枚ずつ画面いっぱいに出して、右へ＝くわしく見る、左へ＝見ない。
struct NearbyCardsView: View {
    @ObservedObject var model: NearbyCardsModel

    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var location: LocationModel
    @State private var drag: CGSize = .zero
    @State private var flying = false
    @State private var detail: NearbyCard?

    private static let threshold: CGFloat = 110

    var body: some View {
        VStack(spacing: 12) {
            header
            if !model.viewedCards.isEmpty {
                viewedStrip
            }
            ZStack {
                if let card = model.deck.first {
                    stack(top: card)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.deck.first != nil {
                buttons
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(Theme.background)
        .task(id: location.location?.timestamp) {
            await model.refresh(api: session.api, location: location.location)
        }
        .sheet(item: $detail) { card in
            NearbyCardDetail(card: card)
                .environmentObject(session)
                .environmentObject(location)
        }
    }

    // MARK: 部品

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("今日、近くにある友達のカード").font(.headline).foregroundStyle(Theme.text)
                Text("いまいる所から 300m 以内の GATE に、友達が残したカードです")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if !model.deck.isEmpty {
                Text("あと \(model.deck.count) 枚")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.warm)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.warm.opacity(0.12), in: Capsule())
            }
        }
        .padding(.top, 8)
    }

    private var viewedStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("今日見た")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                ForEach(model.viewedCards) { card in
                    Button {
                        detail = card
                    } label: {
                        ZStack {
                            Theme.surfaceElevated
                            if let path = card.photo_path {
                                RemotePhoto(path: path)
                            } else {
                                Image(systemName: "text.quote").foregroundStyle(Theme.accent)
                            }
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Theme.accent, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(card.author_name)さんのカードをもう一度見る")
                }
            }
        }
    }

    private func stack(top: NearbyCard) -> some View {
        let rest = Array(model.deck.dropFirst().prefix(2))
        return ZStack {
            ForEach(Array(rest.enumerated().reversed()), id: \.element.id) { index, card in
                NearbyCardFace(card: card)
                    .scaleEffect(1 - CGFloat(index + 1) * 0.04)
                    .offset(y: CGFloat(index + 1) * 12)
                    .allowsHitTesting(false)
            }
            NearbyCardFace(card: top)
                .overlay(alignment: .topLeading) { stamp("見ない", color: Theme.textSecondary, show: drag.width < -30) }
                .overlay(alignment: .topTrailing) { stamp("くわしく", color: Theme.accent, show: drag.width > 30) }
                .offset(drag)
                .rotationEffect(.degrees(Double(drag.width / 20)), anchor: .bottom)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            guard !flying else { return }
                            drag = value.translation
                        }
                        .onEnded { value in
                            if value.translation.width > Self.threshold {
                                finish(top, liked: true)
                            } else if value.translation.width < -Self.threshold {
                                finish(top, liked: false)
                            } else {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { drag = .zero }
                            }
                        }
                )
                .onTapGesture { finish(top, liked: true) }
                .accessibilityElement(children: .combine)
                .accessibilityHint("右へはらうとくわしく見る、左へはらうと見ない")
                .accessibilityAction(named: "くわしく見る") { finish(top, liked: true) }
                .accessibilityAction(named: "見ない") { finish(top, liked: false) }
        }
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func stamp(_ text: String, color: Color, show: Bool) -> some View {
        Text(text)
            .font(.title3.weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color, lineWidth: 3))
            .rotationEffect(.degrees(text == "見ない" ? -12 : 12))
            .padding(24)
            .opacity(show ? min(1, Double(abs(drag.width) - 30) / 80) : 0)
    }

    private var buttons: some View {
        HStack(spacing: 36) {
            Button {
                if let top = model.deck.first { finish(top, liked: false) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 62, height: 62)
                    .background(Theme.surface, in: Circle())
                    .overlay(Circle().stroke(Theme.line))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            }
            .accessibilityLabel("見ない")
            Button {
                if let top = model.deck.first { finish(top, liked: true) }
            } label: {
                Image(systemName: "eye.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 70, height: 70)
                    .background(Theme.neonBand, in: Circle())
                    .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 4)
            }
            .accessibilityLabel("くわしく見る")
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 14) {
            GateMark(size: 72, glowing: model.cards.isEmpty == false)
            switch model.problem {
            case .noLocation:
                if location.fixProblem != nil, location.location == nil || location.needsSettings {
                    LocationProblemView()
                } else {
                    Text("いまの場所を調べています…").font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
            case .inaccurate:
                note("位置がまだ確かではありません", "空の見える所で、少し待ってください。")
            case .unsupported:
                note("まだ使えません", "サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。")
            case .failed(let text):
                note("読み込めませんでした", text)
            case nil:
                if !model.loaded || model.loading {
                    ProgressView()
                } else if model.cards.isEmpty {
                    note("近くに友達のカードはありません", "300m 以内の GATE に友達がカードを残すと、ここに出ます。")
                } else {
                    note("今日のカードは全部見ました", "また歩いて、別の場所で開いてみてください。")
                    Button("見なかったカードをもう一度") { model.showPassedAgain() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            if model.problem != nil || (model.loaded && model.deck.isEmpty) {
                Button {
                    Task { await model.refresh(api: session.api, location: location.location, force: true) }
                } label: {
                    Label("探し直す", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(model.loading)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func note(_ title: String, _ message: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline).foregroundStyle(Theme.text)
            Text(message).font(.subheadline).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
        }
    }

    // MARK: 動き

    private func finish(_ card: NearbyCard, liked: Bool) {
        guard !flying else { return }
        flying = true
        Haptics.soft()
        withAnimation(.easeIn(duration: 0.22)) {
            drag = CGSize(width: liked ? 620 : -620, height: drag.height + 40)
        }
        Task {
            try? await Task.sleep(nanoseconds: 230_000_000)
            if liked {
                model.open(card)
                detail = card
            } else {
                model.pass(card)
            }
            drag = .zero
            flying = false
        }
    }
}

// MARK: - カードの見た目（画面いっぱい）

struct NearbyCardFace: View {
    let card: NearbyCard

    private var walkMinutes: Int { max(1, Int((card.distance_m / 75).rounded())) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let path = card.photo_path {
                RemotePhoto(path: path)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x140F3A), Color(hex: 0x3A1530), Color(hex: 0xF0702A).opacity(0.8)],
                                   startPoint: .top, endPoint: .bottom)
                    Text(card.body)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(6)
                        .padding(32)
                }
            }
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    NeonAvatar(name: card.author_name, size: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(card.author_name).font(.headline).foregroundStyle(.white)
                        Text(ServerDate.relative(card.created_at)).font(.caption).foregroundStyle(.white.opacity(0.8))
                    }
                }
                Label(card.gate_title, systemImage: (GateKind(rawValue: card.gate_kind) ?? .place).symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Label("\(TrailGuide.distanceText(card.distance_m))・歩いて約 \(walkMinutes) 分", systemImage: "figure.walk")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(20)
        }
        .overlay(alignment: .topLeading) {
            Label("友達のカード", systemImage: "person.2.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.black.opacity(0.35), in: Capsule())
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }
}

// MARK: - くわしく見る

/// カードのくわしいこと（ひとこと・書いた人・日時）と、そのカードがある GATE の場所・そこまでの道案内。
/// GATE の場所はおおよそ（100m ほど）。近づくと、地図に GATE が出る。
struct NearbyCardDetail: View {
    let card: NearbyCard

    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var location: LocationModel
    @Environment(\.dismiss) private var dismiss
    @State private var route: MKRoute?
    @State private var saved = false
    @State private var saving = false
    @State private var message: String?
    @State private var report: ReportItem?
    @State private var viewer: PhotoViewerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let path = card.photo_path {
                        Button {
                            viewer = PhotoViewerItem(path: path, caption: card.body)
                        } label: {
                            RemotePhoto(path: path)
                                .frame(height: 320)
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("写真を大きく見る")
                    }
                    authorRow
                    if !card.body.isEmpty {
                        Text(card.body)
                            .font(.title3)
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions
                    if let message { NoticeText(text: message) }
                    Divider()
                    gateSection
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("\(card.author_name)さんのカード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            report = ReportItem(id: card.id, target: .nearby_card, userID: card.author,
                                                userName: card.author_name, label: "友達のカード")
                        } label: {
                            Label("通報する", systemImage: "exclamationmark.bubble")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("そのほか")
                }
            }
            .sheet(item: $report) { item in ReportSheet(item: item) }
            .fullScreenCover(item: $viewer) { item in
                PhotoViewer(path: item.path, caption: item.caption)
                    .environmentObject(session)
            }
            .task { await loadRoute() }
        }
    }

    private var authorRow: some View {
        NavigationLink {
            ProfileView(userID: card.author)
        } label: {
            HStack(spacing: 10) {
                NeonAvatar(name: card.author_name, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.author_name).font(.headline).foregroundStyle(Theme.text)
                    Text(GateDates.fullText(card.created_at)).font(.caption).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await toggleSave() }
            } label: {
                Label(saved ? "保存しました" : "お気に入りに保存", systemImage: saved ? "bookmark.fill" : "bookmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(saved ? Theme.warm : Theme.accent)
            .disabled(saving)
            NavigationLink {
                GateDetailView(gateID: card.gate_id)
            } label: {
                Label("GATE を見る", systemImage: "door.left.hand.open")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
    }

    private var gateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("このカードがある GATE").font(.headline).foregroundStyle(Theme.text)
            HStack(spacing: 8) {
                Image(systemName: (GateKind(rawValue: card.gate_kind) ?? .place).symbol).foregroundStyle(Theme.accent)
                Text(card.gate_title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
            }
            PlaceNameText(lat: card.approx_lat, lon: card.approx_lon, font: .caption)
                .foregroundStyle(Theme.textSecondary)
            Map(initialPosition: .automatic) {
                UserAnnotation()
                Marker(card.gate_title, systemImage: "door.left.hand.open", coordinate: card.gateCoordinate)
                    .tint(Theme.accent)
                MapCircle(center: card.gateCoordinate, radius: 60)
                    .foregroundStyle(Theme.accent.opacity(0.1))
                    .stroke(Theme.accent.opacity(0.4), lineWidth: 1)
                if let route {
                    MapPolyline(route.polyline)
                        .stroke(Theme.warm, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            if let route {
                Label("歩いて約 \(max(1, Int((route.expectedTravelTime / 60).rounded()))) 分・\(TrailGuide.distanceText(route.distance))",
                      systemImage: "figure.walk")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.warm)
            } else {
                Label(TrailGuide.distanceText(card.distance_m), systemImage: "figure.walk")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.warm)
            }
            Text("場所はおおよそです。100m 以内に近づくと、地図に GATE が出ます。中の記憶は、現地で扉を開けると見られます。")
                .font(.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                let item = MKMapItem(placemark: MKPlacemark(coordinate: card.gateCoordinate))
                item.name = card.gate_title
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                Trace.log("近くの友達のカード：GATE への道案内を開いた")
            } label: {
                Label("道案内を始める", systemImage: "location.north.line.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func loadRoute() async {
        guard let here = location.location?.coordinate else { return }
        route = await TrailGuide.walkingRoute(from: here, to: card.gateCoordinate)
    }

    private func toggleSave() async {
        guard let api = session.api else { return }
        saving = true
        defer { saving = false }
        do {
            saved = try await api.saveCard(card.id, on: !saved)
            Haptics.tap()
            message = nil
        } catch {
            message = ErrorText.isMissingFunction(error)
                ? "保存は、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。"
                : (saved ? ErrorText.of(error) : "近くで見てから 30 分を過ぎたので保存できません。もう一度近くで開いてください。")
        }
    }
}
