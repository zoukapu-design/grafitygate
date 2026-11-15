import MapKit
import SwiftUI

/// GATE の「いつ・どこで」：小さな地図（押すと地図アプリ）・作った日時・場所の名前。
/// 作った本人には正確な位置、ほかの人にはおおよその位置（約 100m）を出す。
struct GateWhereWhen: View {
    let title: String
    let createdAt: String
    let coordinate: CLLocationCoordinate2D
    /// 正確な位置か（作った本人）
    let exact: Bool
    var coverPath: String? = nil
    var mine = false
    var ownerName: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: openInMaps) {
                Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                                                                latitudinalMeters: exact ? 350 : 700,
                                                                longitudinalMeters: exact ? 350 : 700)),
                    interactionModes: []) {
                    if exact {
                        Annotation(title, coordinate: coordinate, anchor: .bottom) {
                            GatePin(mine: mine, coverPath: coverPath, ownerName: ownerName, showsName: false)
                        }
                        .annotationTitles(.hidden)
                    } else {
                        MapCircle(center: coordinate, radius: 90)
                            .stroke(Theme.accent.opacity(0.5), lineWidth: 1.5)
                            .foregroundStyle(Theme.accent.opacity(0.12))
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .including([.publicTransport, .park, .museum])))
                // 正確な位置があとから届いたら、地図を作り直してそこを真ん中にする
                .id(PlaceNames.key(coordinate.latitude, coordinate.longitude) + (exact ? "e" : "a"))
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    Label("地図アプリ", systemImage: "arrow.up.right.square")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
                .allowsHitTesting(false)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("地図アプリで場所を開く")

            VStack(alignment: .leading, spacing: 4) {
                Label(GateDates.fullText(createdAt) + " に作成", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                HStack(spacing: 6) {
                    PlaceNameText(lat: coordinate.latitude, lon: coordinate.longitude, font: .subheadline)
                    if !exact {
                        Text("（おおよそ）").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    private func openInMaps() {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = title
        item.openInMaps(launchOptions: [MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: coordinate)])
    }
}
