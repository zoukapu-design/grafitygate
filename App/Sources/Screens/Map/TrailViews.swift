import CoreLocation
import MapKit
import SwiftUI

/// TRAIL の一覧：歩いているもの・自分の・友達の。右上から新しく作れる。
struct TrailListView: View {
    @EnvironmentObject private var session: SessionModel
    @State private var trails: [TrailSummary] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var showComposer = false

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
                let walking = trails.filter(\.inProgress)
                let others = trails.filter { !$0.inProgress }
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
                if let error { NoticeText(text: error) }
                Text("地点").font(.headline).foregroundStyle(Theme.text)
                ForEach(stops) { stop in
                    stopRow(stop)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let summary {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if summary.owner == session.userID {
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
            var found = try await api.trails().first { $0.id == trailID }
            if found == nil, let gate = stops.compactMap(\.gate_id).first {
                // ふだんの一覧に出ない公開の TRAIL（GATE の画面から開いたもの）
                found = try await api.trails(including: gate).first { $0.id == trailID }
            }
            summary = found
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
