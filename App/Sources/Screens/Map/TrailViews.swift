import CoreLocation
import MapKit
import SwiftUI

/// TRAIL の一覧：歩いているもの・自分の・友達の。右上から新しく作れる。
struct TrailListView: View {
    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var location: LocationModel
    @State private var trails: [TrailSummary] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var showComposer = false
    /// 名前で探す・近くの TRAIL（0018 のサーバーだけ）
    @State private var query = ""
    @State private var found: [TrailSummary]?
    @State private var nearby: [TrailSummary] = []
    @State private var searching = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("TRAIL は、いくつかの GATE をつないだ「思い出を歩く道」です。順番に現地で扉を開けると進みます。")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                if let error { NoticeText(text: error) }
                if loaded && trails.isEmpty && error == nil {
                    EmptyNote(title: "まだ TRAIL はありません",
                              message: "扉を開けた GATE が 2 つ以上あれば、右上から作れます。友達の TRAIL もここに出ます。",
                              systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                if let found {
                    Text(found.isEmpty ? "「\(query)」の TRAIL は見つかりませんでした" : "見つかった TRAIL")
                        .font(.headline).foregroundStyle(Theme.text)
                    ForEach(found) { trail in trailLink(trail) }
                }
                let walking = trails.filter(\.inProgress)
                let others = trails.filter { !$0.inProgress }
                let near = nearby.filter { n in !trails.contains { $0.id == n.id } }
                if found == nil && !near.isEmpty {
                    Text("近くの TRAIL").font(.headline).foregroundStyle(Theme.text)
                    Text("いまいる所の 5km 以内に地点がある、だれでも・友達が歩ける TRAIL です。")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                    ForEach(near) { trail in trailLink(trail) }
                }
                if !walking.isEmpty {
                    Text("歩いている TRAIL").font(.headline).foregroundStyle(Theme.text)
                    ForEach(walking) { trail in trailLink(trail) }
                }
                if !others.isEmpty {
                    Text(walking.isEmpty ? "TRAIL" : "ほかの TRAIL").font(.headline).foregroundStyle(Theme.text).padding(.top, 4)
                    ForEach(others) { trail in trailLink(trail) }
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("TRAIL")
        .searchable(text: $query, prompt: "TRAIL を名前で探す")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { _, value in
            if value.trimmingCharacters(in: .whitespaces).isEmpty { found = nil }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showComposer = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("TRAIL を作る")
            }
        }
        .sheet(isPresented: $showComposer) {
            TrailComposer { Task { await load() } }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func trailLink(_ trail: TrailSummary) -> some View {
        NavigationLink {
            TrailDetailView(trailID: trail.id, title: trail.title)
        } label: {
            TrailCard(trail: trail)
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            trails = try await api.trails()
            error = nil
        } catch {
            self.error = ErrorText.of(error)
        }
        loaded = true
        if let here = location.location?.coordinate {
            nearby = (try? await api.searchTrails("", near: (here.latitude, here.longitude))) ?? []
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api = session.api, !q.isEmpty, !searching else { return }
        searching = true
        defer { searching = false }
        do {
            let here = location.location?.coordinate
            found = try await api.searchTrails(q, near: here.map { ($0.latitude, $0.longitude) })
            error = nil
        } catch {
            self.error = ErrorText.isMissingFunction(error) ? "名前で探すのは、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
    }
}

/// TRAIL の名前・説明・見せる範囲を直す（作った本人だけ。地点の並びは、歩いている人のために変えない）
struct TrailEditSheet: View {
    let trail: TrailSummary
    let onSaved: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String
    @State private var visibility: Visibility
    @State private var saving = false
    @State private var message: String?

    init(trail: TrailSummary, onSaved: @escaping () -> Void) {
        self.trail = trail
        self.onSaved = onSaved
        _title = State(initialValue: trail.title)
        _note = State(initialValue: trail.note)
        _visibility = State(initialValue: Visibility(rawValue: trail.visibility) ?? .friends)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名前") {
                    TextField("TRAIL の名前", text: $title)
                        .onChange(of: title) { _, v in if v.count > 60 { title = String(v.prefix(60)) } }
                }
                Section("説明") {
                    TextField("どんな道か（なくてもよい）", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .onChange(of: note) { _, v in if v.count > 500 { note = String(v.prefix(500)) } }
                }
                Section {
                    Picker("見せる範囲", selection: $visibility) {
                        ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
                    }
                } footer: {
                    Text("地点の並びは、歩いている人の進み具合が崩れないよう、あとから変えられません。")
                }
                if let message {
                    Section { NoticeText(text: message) }
                }
            }
            .navigationTitle("TRAIL を直す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() async {
        guard let api = session.api else { return }
        saving = true
        defer { saving = false }
        do {
            try await api.updateTrail(trail.id, title: title, note: note, visibility: visibility)
            Haptics.success()
            onSaved()
            dismiss()
        } catch {
            message = ErrorText.isMissingFunction(error) ? "直すのは、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。" : ErrorText.of(error)
        }
    }
}

struct TrailCard: View {
    let trail: TrailSummary

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Theme.surfaceElevated
                if let cover = trail.cover_path {
                    RemotePhoto(path: cover)
                } else {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(trail.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(trail.owner_name)・\(trail.stop_count) か所").font(.caption).foregroundStyle(Theme.textSecondary)
                if trail.started {
                    ProgressView(value: Double(trail.reached), total: Double(max(trail.stop_count, 1)))
                        .tint(trail.completed ? Theme.warm : Theme.accent)
                    Text(trail.completed ? "歩き終わりました" : "\(trail.reached)/\(trail.stop_count) か所")
                        .font(.caption2).foregroundStyle(trail.completed ? Theme.warm : Theme.accent)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }
}

/// TRAIL の中：地図に番号の印、地点の順の一覧、進み具合、次の地点への行き方
struct TrailDetailView: View {
    let trailID: UUID
    let title: String

    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var location: LocationModel
    @Environment(\.dismiss) private var dismiss
    @State private var summary: TrailSummary?
    @State private var stops: [TrailStop] = []
    @State private var error: String?
    @State private var report: ReportItem?
    @State private var confirmDelete = false
    @State private var editing = false
    /// 見られない（消された・公開範囲が変わった）
    @State private var unavailable = false

    init(trailID: UUID, title: String) {
        self.trailID = trailID
        self.title = title
    }

    private var nextStop: TrailStop? { stops.first { !$0.reached } }

    /// 地点を順につないだ線（見られない地点は飛ばす）
    private var routeLine: [CLLocationCoordinate2D] {
        stops.compactMap { s -> CLLocationCoordinate2D? in
            guard let lat = s.approx_lat, let lon = s.approx_lon else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                map
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard))
                if let summary {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.title).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                        if !summary.note.isEmpty {
                            Text(summary.note).font(.body).foregroundStyle(Theme.text)
                        }
                        Text("\(summary.owner_name)・\(summary.stop_count) か所・\(Visibility.label(of: summary.visibility))")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    progressCard(summary)
                }
                if unavailable {
                    EmptyNote(title: "この TRAIL は見られません",
                              message: "消されたか、作った人が見せる範囲を変えました。",
                              systemImage: "eye.slash")
                }
                if let error { NoticeText(text: error) }
                Text("地点").font(.headline).foregroundStyle(Theme.text)
                ForEach(stops) { stop in
                    stopRow(stop)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(summary?.title ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let summary {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if summary.visibility != Visibility.private.rawValue || summary.owner == session.userID {
                            ShareLink(item: AppNavigator.trailURL(summary.id),
                                      message: Text(AppNavigator.trailShareText(title: summary.title,
                                                                                stops: summary.stop_count,
                                                                                id: summary.id))) {
                                Label("TRAIL を送る", systemImage: "square.and.arrow.up")
                            }
                        }
                        if summary.owner == session.userID {
                            Button {
                                editing = true
                            } label: {
                                Label("名前・説明・見せる範囲を直す", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                confirmDelete = true
                            } label: {
                                Label("TRAIL を消す", systemImage: "trash")
                            }
                        } else {
                            Button {
                                report = ReportItem(id: summary.id, target: .trail, userID: summary.owner,
                                                    userName: summary.owner_name, label: summary.title)
                            } label: {
                                Label("通報する", systemImage: "exclamationmark.bubble")
                            }
                        }
                        if summary.started {
                            Button {
                                Task { await quit() }
                            } label: {
                                Label("歩くのをやめる（進み具合を消す）", systemImage: "xmark.circle")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .confirmationDialog("この TRAIL を消しますか？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("消す", role: .destructive) { Task { await delete() } }
        } message: {
            Text("歩いている人の進み具合も消えます。GATE そのものは消えません。")
        }
        .sheet(item: $report) { item in ReportSheet(item: item) }
        .sheet(isPresented: $editing) {
            if let summary {
                TrailEditSheet(trail: summary) { Task { await load() } }
                    .environmentObject(session)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private var map: some View {
        Map(initialPosition: .automatic) {
            UserAnnotation()
            ForEach(stops.filter { $0.approx_lat != nil }) { stop in
                Annotation(stop.title, coordinate: CLLocationCoordinate2D(latitude: stop.approx_lat ?? 0,
                                                                           longitude: stop.approx_lon ?? 0)) {
                    Text("\(stop.seq)")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(stop.reached ? Theme.warm : (stop.seq == nextStop?.seq ? Theme.accent : Theme.textSecondary),
                                    in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            MapPolyline(coordinates: routeLine)
                .stroke(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
        }
        .mapControls { MapUserLocationButton() }
    }

    @ViewBuilder private func progressCard(_ summary: TrailSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                if summary.completed {
                    Label("歩き終わりました", systemImage: "checkmark.seal.fill")
                        .font(.headline).foregroundStyle(Theme.warm)
                } else if summary.started {
                    ProgressView(value: Double(summary.reached), total: Double(max(summary.stop_count, 1)))
                        .tint(Theme.accent)
                    if let next = nextStop {
                        Text("次は \(next.seq). \(next.title)\(distanceText(next))")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Text("着いたら「撮る」で扉を開けると、ここが 1 つ進みます。")
                            .font(.caption).foregroundStyle(Theme.textSecondary)
                        if let lat = next.approx_lat, let lon = next.approx_lon {
                            Button {
                                openDirections(lat: lat, lon: lon, name: next.title)
                            } label: {
                                Label("地図アプリで行き方を見る", systemImage: "figure.walk")
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                } else {
                    Text("歩き始めると、順番に現地で扉を開けるたびに進みます。")
                        .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    Button("この TRAIL を歩き始める") { Task { await start() } }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    private func stopRow(_ stop: TrailStop) -> some View {
        let content = HStack(spacing: 12) {
            Text("\(stop.seq)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(stop.reached ? .white : Theme.text)
                .frame(width: 30, height: 30)
                .background(stop.reached ? Theme.warm : Theme.surfaceElevated, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(stop.visible ? Theme.text : Theme.textSecondary)
                if stop.reached {
                    Text("着きました").font(.caption).foregroundStyle(Theme.warm)
                } else if stop.visible, !distanceText(stop).isEmpty {
                    Text(distanceText(stop).trimmingCharacters(in: CharacterSet(charactersIn: "（）")))
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            if stop.visible { Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary) }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
        return Group {
            if let gate = stop.gate_id {
                NavigationLink {
                    GateDetailView(gateID: gate)
                } label: {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private func distanceText(_ stop: TrailStop) -> String {
        guard let here = location.location, let lat = stop.approx_lat, let lon = stop.approx_lon else { return "" }
        let d = here.distance(from: CLLocation(latitude: lat, longitude: lon))
        return d >= 1000 ? String(format: "（約 %.1fkm）", d / 1000) : "（約 \(Int(d.rounded() / 10) * 10)m）"
    }

    private func openDirections(lat: Double, lon: Double, name: String) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            stops = try await api.trailStops(trailID)
            var found: TrailSummary?
            do {
                // 0018：リンク・友達のプロフィール・探した結果から開いても、見てよい TRAIL なら出る
                found = try await api.trail(trailID)
            } catch let error where ErrorText.isMissingFunction(error) {
                found = try await api.trails().first { $0.id == trailID }
                if found == nil, let gate = stops.compactMap(\.gate_id).first {
                    // ふだんの一覧に出ない公開の TRAIL（GATE の画面から開いたもの）
                    found = try await api.trails(including: gate).first { $0.id == trailID }
                }
            }
            summary = found
            unavailable = found == nil
            error = nil
        } catch {
            self.error = ErrorText.of(error)
        }
    }

    private func start() async {
        guard let api = session.api else { return }
        do {
            try await api.startTrail(trailID)
            Haptics.success()
            Trace.log("TRAIL を歩き始めました")
            await load()
        } catch {
            self.error = ErrorText.of(error)
        }
    }

    private func quit() async {
        guard let api = session.api else { return }
        do {
            try await api.quitTrail(trailID)
            await load()
        } catch {
            self.error = ErrorText.of(error)
        }
    }

    private func delete() async {
        guard let api = session.api else { return }
        do {
            try await api.deleteTrail(trailID)
            dismiss()
        } catch {
            self.error = ErrorText.of(error)
        }
    }
}

/// TRAIL を作る：扉を開けたことのある GATE から選んで、歩く順に並べる
struct TrailComposer: View {
    let onCreated: () -> Void

    @EnvironmentObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var visited: [CollectionGate] = []
    @State private var chosen: [CollectionGate] = []
    @State private var title = ""
    @State private var note = ""
    @State private var visibility: Visibility = .friends
    @State private var saving = false
    @State private var message: String?
    @State private var loaded = false

    init(onCreated: @escaping () -> Void) {
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("題（例：春の川沿い）", text: $title)
                    TextField("ひとこと（なくても大丈夫）", text: $note, axis: .vertical).lineLimit(2...4)
                    Picker("見せる人", selection: $visibility) {
                        ForEach(Visibility.allCases) { v in Text(v.label).tag(v) }
                    }
                }
                Section {
                    if chosen.isEmpty {
                        Text("下の一覧から、歩く順に押してください。").foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(Array(chosen.enumerated()), id: \.element.gate_id) { index, gate in
                        HStack {
                            Text("\(index + 1)").font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent).frame(width: 24)
                            Text(gate.title)
                        }
                    }
                    .onMove { from, to in chosen.move(fromOffsets: from, toOffset: to) }
                    .onDelete { offsets in chosen.remove(atOffsets: offsets) }
                } header: {
                    Text("歩く順（\(chosen.count)/20）")
                } footer: {
                    Text("並べ替えは右上の「編集」から。")
                }
                Section("扉を開けたことのある GATE") {
                    if loaded && visited.isEmpty {
                        Text("まだありません。GATE の扉を開けると、ここに出ます。").foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(visited.filter { g in !chosen.contains { $0.gate_id == g.gate_id } }) { gate in
                        Button {
                            if chosen.count < 20 { chosen.append(gate) }
                        } label: {
                            HStack {
                                Text(gate.title).foregroundStyle(Theme.text)
                                Spacer()
                                Image(systemName: "plus.circle").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
                if let message {
                    Section { NoticeText(text: message) }
                }
            }
            .navigationTitle("TRAIL を作る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving { ProgressView() } else { Text("この順で作る").bold() }
                    }
                    .disabled(saving || chosen.count < 2 || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                guard let api = session.api else { return }
                visited = (try? await api.collection("visited")) ?? []
                loaded = true
            }
        }
    }

    private func save() async {
        guard let api = session.api else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await api.createTrail(title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)),
                                          note: String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)),
                                          visibility: visibility, gates: chosen.map(\.gate_id))
            Haptics.success()
            Trace.log("TRAIL を作りました（\(chosen.count) か所）")
            onCreated()
            dismiss()
        } catch {
            message = ErrorText.of(error)
        }
    }
}
