import MapKit
import SwiftUI

/// 自分の GATE を見返す：上に全部の GATE の地図（正確な位置）、下に月ごとの「いつ・どこで」の一覧。
/// 地図の印を押すと、その GATE のカードが出る。カードや一覧を押すと GATE の画面。
struct MyGatesView: View {
    let gates: [MyGate]

    @State private var selected: UUID?
    @State private var position: MapCameraPosition = .automatic

    private var placed: [MyGate] { gates.filter { $0.coordinate != nil } }

    /// 月ごと（新しい月から）
    private var months: [(title: String, gates: [MyGate])] {
        var order: [String] = []
        var groups: [String: [MyGate]] = [:]
        for gate in gates {
            let m = GateDates.monthText(gate.created_at)
            if groups[m] == nil { order.append(m) }
            groups[m, default: []].append(gate)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if gates.isEmpty {
                        EmptyNote(title: "まだ GATE がありません",
                                  message: "「撮る」→「ここに GATE を作る」から作れます。",
                                  systemImage: "door.left.hand.open")
                            .padding(.top, 40)
                    } else {
                        map
                        ForEach(months, id: \.title) { month in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(month.title).font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                                    Text("\(month.gates.count) 個").font(.subheadline).foregroundStyle(Theme.textSecondary)
                                }
                                ForEach(month.gates) { gate in
                                    NavigationLink {
                                        GateDetailView(gateID: gate.id)
                                    } label: {
                                        GateJournalRow(gate: gate, highlighted: selected == gate.id)
                                    }
                                    .buttonStyle(.plain)
                                    .id(gate.id)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .onChange(of: selected) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("わたしの GATE")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 全部の GATE の地図（印を押すと選ぶ）
    private var map: some View {
        Map(position: $position) {
            UserAnnotation()
            ForEach(placed) { gate in
                if let c = gate.coordinate {
                    Annotation(gate.title, coordinate: c, anchor: .bottom) {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                selected = selected == gate.id ? nil : gate.id
                            }
                        } label: {
                            GatePin(mine: true, selected: selected == gate.id, coverPath: gate.cover_path, showsName: false)
                        }
                        .buttonStyle(.plain)
                    }
                    .annotationTitles(selected == gate.id ? .visible : .hidden)
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .frame(height: 300)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line))
        .overlay(alignment: .topLeading) {
            Label("\(placed.count) 個の GATE", systemImage: "door.left.hand.open")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.warm, in: Capsule())
                .padding(10)
        }
    }
}

/// 一覧の 1 行：表紙・名前・種類・場所の名前・作った日時・公開範囲
struct GateJournalRow: View {
    let gate: MyGate
    var highlighted = false

    var body: some View {
        HStack(spacing: 12) {
            GateCoverImage(path: gate.cover_path, markSize: 30)
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(gate.title).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                    let kind = GateKind(raw: gate.kind)
                    Image(systemName: kind.symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(kind == .view ? Theme.warm : Theme.accent)
                        .accessibilityLabel(kind.label)
                }
                Label(GateDates.shortText(gate.created_at), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                if let lat = gate.lat, let lon = gate.lon {
                    PlaceNameText(lat: lat, lon: lon)
                }
                Text(Visibility.label(of: gate.visibility))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.accentLight, in: Capsule())
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(highlighted ? Theme.warm : Theme.line, lineWidth: highlighted ? 2 : 1))
    }
}

/// 「わたし」の上に置く、自分の GATE の地図（さわれない小さな地図。押すと見返す画面）
struct MyGatesMapCard: View {
    let gates: [MyGate]

    private var placed: [MyGate] { gates.filter { $0.coordinate != nil } }

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: []) {
            ForEach(placed.prefix(40)) { gate in
                if let c = gate.coordinate {
                    Annotation(gate.title, coordinate: c, anchor: .bottom) {
                        GatePin(mine: true, coverPath: gate.cover_path, showsName: false)
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
        // 印は場所の上に立つので、上に余白をとって地図に収める（下の札にも重ならないように）
        .safeAreaPadding(EdgeInsets(top: 64, leading: 28, bottom: 40, trailing: 28))
        .id(placed.map(\.id))
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line))
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 6) {
                Image(systemName: "map.fill")
                Text("地図といつ・どこでを見る")
                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(10)
        }
        .allowsHitTesting(false)
        .contentShape(Rectangle())
    }
}
