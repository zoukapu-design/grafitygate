import MapKit
import SwiftUI

// 地図で重なる GATE の印をまとめる（2026-11-18 オーナー「同じ・近い場所に GATE を作ると、地図の印が重なって変」）。
// いまの地図の縮尺で、印の大きさより近いものを 1 つの「重ねた印」にし、数を出す。
// 押すと：散らばっていれば寄って分け、同じ所（おおよその位置が同じ）なら一覧を出して選ぶ。

/// 地図に出す GATE の印 1 つ分（どの地図でも同じ形にそろえる）
struct MapPinItem: Identifiable {
    let id: UUID
    let title: String
    let cover: String?
    let coordinate: CLLocationCoordinate2D
    var mine = false
    var ownerName: String? = nil
}

/// 近いものをまとめた印
struct PinCluster: Identifiable {
    let items: [MapPinItem]
    let coordinate: CLLocationCoordinate2D
    /// まん中から、いちばん遠い印まで（m）
    let spread: Double

    var id: UUID { items[0].id }
    var isSingle: Bool { items.count == 1 }
    func contains(_ id: UUID?) -> Bool { id.map { id in items.contains { $0.id == id } } ?? false }
}

/// 一覧で選ぶときの GATE たち
struct PinStack: Identifiable {
    let id = UUID()
    let items: [MapPinItem]
}

enum MapClusters {
    /// 印の大きさ（pt）。名前の札まで入れて、これより近いと重なって見える
    static let pinPoints: Double = 80

    /// 1pt が何 m か（地図の縦の広さと、地図の高さから）
    static func metersPerPoint(_ region: MKCoordinateRegion, height: CGFloat) -> Double {
        region.span.latitudeDelta * 111_000 / max(Double(height), 100)
    }

    /// 1pt が何 m か（地図の上の 2 点を実際に緯度経度へ直して測る。地図の余白・縦横の比に左右されない）
    static func metersPerPoint(_ proxy: MapProxy, region: MKCoordinateRegion, height: CGFloat) -> Double {
        if let a = proxy.convert(CGPoint(x: 20, y: 20), from: .local),
           let b = proxy.convert(CGPoint(x: 20, y: 120), from: .local) {
            let d = CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            if d > 0 { return d / 100 }
        }
        return metersPerPoint(region, height: height)
    }

    /// 近いものをまとめる（並びの順に、いちばん先に近いまとまりへ入れる。まとまりのまん中は平均）
    static func group(_ items: [MapPinItem], metersPerPoint: Double) -> [PinCluster] {
        let threshold = max(metersPerPoint * pinPoints, 0.5)
        var groups: [(lat: Double, lon: Double, members: [MapPinItem])] = []
        for item in items {
            let here = CLLocation(latitude: item.coordinate.latitude, longitude: item.coordinate.longitude)
            if let i = groups.firstIndex(where: {
                CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: here) < threshold
            }) {
                groups[i].members.append(item)
                let n = Double(groups[i].members.count)
                groups[i].lat += (item.coordinate.latitude - groups[i].lat) / n
                groups[i].lon += (item.coordinate.longitude - groups[i].lon) / n
            } else {
                groups.append((item.coordinate.latitude, item.coordinate.longitude, [item]))
            }
        }
        return groups.map { g in
            let center = CLLocation(latitude: g.lat, longitude: g.lon)
            let spread = g.members.map {
                CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude).distance(from: center)
            }.max() ?? 0
            return PinCluster(items: g.members, coordinate: center.coordinate, spread: spread)
        }
    }

    /// 重ねた印を押したとき、寄れば分かれるならその範囲（同じ所に重なっているなら nil＝一覧を出す）
    static func zoomRegion(for cluster: PinCluster) -> MKCoordinateRegion? {
        guard cluster.spread >= 15 else { return nil }
        return MapFraming.region(cluster.items.map(\.coordinate), minMeters: max(60, cluster.spread * 2.2))
    }
}

/// 重ねた印：表紙を 2〜3 枚ずらして重ね、右上に数
struct GateStackPin: View {
    let cluster: PinCluster
    var selected = false

    private var size: CGFloat { selected ? 50 : 42 }
    private var mine: Bool { cluster.items.contains { $0.mine } }

    var body: some View {
        VStack(spacing: 2) {
            VStack(spacing: 0) {
                ZStack {
                    let shown = Array(cluster.items.prefix(3))
                    ForEach(Array(shown.enumerated().reversed()), id: \.element.id) { index, item in
                        cover(item)
                            .rotationEffect(.degrees(index == 0 ? 0 : (index == 1 ? -11 : 11)))
                            .offset(x: index == 0 ? 0 : (index == 1 ? -7 : 7), y: index == 0 ? 0 : -2)
                    }
                }
                .frame(width: size + 16, height: size + 4)
                .overlay(alignment: .topTrailing) {
                    Text("\(cluster.items.count)")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 22, minHeight: 22)
                        .padding(.horizontal, 3)
                        .background(Theme.neonBand, in: Capsule())
                        .overlay(Capsule().stroke(.white, lineWidth: 2))
                        .offset(x: 4, y: -8)
                }
                StackTail()
                    .fill(mine ? Theme.warm : .white)
                    .frame(width: 10, height: 6)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
            Text("\(cluster.items.count) 個の GATE")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.white.opacity(0.94), in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("この近くに \(cluster.items.count) 個の GATE")
        .accessibilityHint("押すと、分けて見せるか一覧を出します")
    }

    private func cover(_ item: MapPinItem) -> some View {
        Group {
            if let path = item.cover {
                RemotePhoto(path: path)
            } else {
                Image("BrandMark").resizable().interpolation(.high)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(item.mine ? Theme.warm : .white, lineWidth: item.mine ? 3 : 2.5))
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
    }
}

private struct StackTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// 同じ所にある GATE の一覧（押すとその GATE の画面へ）
struct GateStackSheet: View {
    let stack: PinStack
    let onPick: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    Text("おおよその位置が同じなので、地図では 1 つにまとめています。")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(stack.items) { item in
                        Button {
                            onPick(item.id)
                        } label: {
                            HStack(spacing: 12) {
                                GateCoverImage(path: item.cover, markSize: 24)
                                    .frame(width: 60, height: 60)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(item.mine ? Theme.warm : Theme.line, lineWidth: item.mine ? 2.5 : 1))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.headline)
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if item.mine {
                                        Text("あなたの GATE").font(.caption.weight(.semibold)).foregroundStyle(Theme.warm)
                                    } else if let name = item.ownerName, !name.isEmpty {
                                        HStack(spacing: 6) {
                                            NeonAvatar(name: name, size: 18)
                                            Text(name).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("ここにある GATE \(stack.items.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension View {
    /// 重ねた印の一覧を出し、選んだ GATE を open に入れる（一覧が閉じてから開く。閉じる前に開くと、開かないことがある）
    func gateStackSheet(_ stack: Binding<PinStack?>, open: Binding<UUID?>) -> some View {
        modifier(GateStackPresenter(stack: stack, open: open))
    }
}

private struct GateStackPresenter: ViewModifier {
    @Binding var stack: PinStack?
    @Binding var open: UUID?
    @State private var picked: UUID?

    func body(content: Content) -> some View {
        content.sheet(item: $stack, onDismiss: {
            if let id = picked {
                picked = nil
                open = id
            }
        }) { s in
            GateStackSheet(stack: s) { id in
                picked = id
                stack = nil
            }
        }
    }
}
