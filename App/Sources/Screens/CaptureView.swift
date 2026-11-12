import SwiftUI

/// 撮る：AR のカメラ。目の前の場所・物に向けて、近くの GATE を開く／新しく GATE を作る。
struct CaptureView: View {
    var body: some View {
        ARExperienceView(mode: .explore)
    }
}
