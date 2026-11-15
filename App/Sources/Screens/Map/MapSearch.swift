import CoreLocation
import MapKit
import SwiftUI

/// 地図の「探す」：GATE を名前で（見てよい GATE の名前・表紙・おおよその場所だけ。中身は現地だけ）と、場所を名前で。
/// 場所を選ぶと地図をそこへ動かし、歩いて行く道を開ける。GATE を見つけられるのは、いまいる所の 100m 以内のまま。
struct MapSearchSheet: View {
    let onPickPlace: (MKMapItem) -> Void

    @EnvironmentObject private var session: SessionModel
    @EnvironmentObject private var location: LocationModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var gates: [GateSearchHit] = []
    @State private var places: [PlaceHit] = []
    @State private var searched = false
    @State private var searching = false
    @State private var message: String?
    @FocusState private var focused: Bool

    struct PlaceHit: Identifiable {
        let id = UUID()
        let item: MKMapItem
    }

    private var here: CLLocationCoordinate2D? { location.location?.coordinate }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                        TextField("GATE の名前・場所（駅・公園など）", text: $query)
                            .focused($focused)
                            .submitLabel(.search)
                            .onSubmit { Task { await search() } }
                        if !query.isEmpty {
                            Button {
                                query = ""
                                searched = false
                                gates = []
                                places = []
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                            }
                            .accessibilityLabel("消す")
                        }
                    }
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))

                    if searching {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 12)
                    }
                    if let message { NoticeText(text: message) }

                    if searched && !searching {
                        section("GATE", empty: "この名前の GATE は見つかりませんでした。") {
                            ForEach(gates) { hit in
                                NavigationLink {
                                    GateDetailView(gateID: hit.id)
                                } label: {
                                    gateRow(hit)
                                }
                                .buttonStyle(.plain)
                            }
                        } isEmpty: { gates.isEmpty }
                        section("場所", empty: "この名前の場所は見つかりませんでした。") {
                            ForEach(places) { hit in
                                Button {
                                    onPickPlace(hit.item)
                                    dismiss()
                                } label: {
                                    placeRow(hit.item)
                                }
                                .buttonStyle(.plain)
                            }
                        } isEmpty: { places.isEmpty }
                    } else if !searching {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("GATE は、見てよいものだけが出ます（自分・友達・全員に公開）。",
                                  systemImage: "door.left.hand.open")
                            Label("場所はおおよそだけ。中の記憶は、現地で扉を開けた人だけが見られます。",
                                  systemImage: "mappin.and.ellipse")
                        }
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("探す")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
            .onAppear { focused = true }
        }
    }

    // MARK: 部品

    @ViewBuilder
    private func section<Rows: View>(_ title: String, empty: String, @ViewBuilder rows: () -> Rows,
                                     isEmpty: () -> Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(Theme.text)
            if isEmpty() {
                Text(empty).font(.subheadline).foregroundStyle(Theme.textSecondary)
            } else {
                rows()
            }
        }
    }

    private func gateRow(_ hit: GateSearchHit) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Theme.surfaceElevated
                if let cover = hit.cover_path {
                    RemotePhoto(path: cover)
                } else {
                    Image(systemName: hit.gateKind.symbol).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 6) {
                    Text(hit.mine ? "あなた" : hit.owner_name)
                        .foregroundStyle(hit.mine ? Theme.warm : (hit.friend ? Theme.accent : Theme.textSecondary))
                    if hit.friend && !hit.mine {
                        Text("友達").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                    if let d = hit.distance_m {
                        Text("・\(TrailGuide.distanceText(d))")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                PlaceNameText(lat: hit.approx_lat, lon: hit.approx_lon, font: .caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }

    private func placeRow(_ item: MKMapItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name ?? "場所").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if let address = Self.address(of: item) {
                    Text(address).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let here {
                Text(TrailGuide.distanceText(CLLocation(latitude: here.latitude, longitude: here.longitude)
                    .distance(from: CLLocation(latitude: Self.coordinate(of: item).latitude,
                                               longitude: Self.coordinate(of: item).longitude))))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }

    static func coordinate(of item: MKMapItem) -> CLLocationCoordinate2D {
        item.placemark.coordinate
    }

    private static func address(of item: MKMapItem) -> String? {
        let p = item.placemark
        let parts = [p.administrativeArea, p.locality, p.subLocality, p.thoroughfare].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined()
    }

    // MARK: 探す

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !searching else { return }
        searching = true
        message = nil
        defer {
            searching = false
            searched = true
        }
        let near = here.map { (lat: $0.latitude, lon: $0.longitude) }
        async let gateResult: [GateSearchHit]? = searchGates(q, near: near)
        async let placeResult: [PlaceHit] = searchPlaces(q)
        gates = await gateResult ?? []
        places = await placeResult
        Trace.log("地図：名前で探した（GATE \(gates.count)・場所 \(places.count)）")
    }

    private func searchGates(_ q: String, near: (lat: Double, lon: Double)?) async -> [GateSearchHit]? {
        guard let api = session.api else { return nil }
        do {
            return try await api.searchGates(String(q.prefix(40)), near: near)
        } catch {
            message = ErrorText.isMissingFunction(error)
                ? "GATE を名前で探すのは、サーバーの準備（setup_all.sql の貼り直し）のあとで使えます。"
                : ErrorText.of(error)
            return nil
        }
    }

    private func searchPlaces(_ q: String) async -> [PlaceHit] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let here {
            request.region = MKCoordinateRegion(center: here, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.prefix(12).map { PlaceHit(item: $0) }
        } catch {
            return []
        }
    }
}
