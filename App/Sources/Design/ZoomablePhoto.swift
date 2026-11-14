import SwiftUI
import UIKit

/// 写真を大きく見る：2 本指で広げる・2 回たたくと寄る／戻る（写真アプリと同じ動き）
struct ZoomableRemotePhoto: View {
    let path: String

    @EnvironmentObject private var session: SessionModel
    @State private var image: UIImage?
    @State private var failed = false

    init(path: String) {
        self.path = path
        _image = State(initialValue: MediaStore.cachedPhoto(path: path))
    }

    var body: some View {
        ZStack {
            if let image {
                ZoomableImageView(image: image)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "photo").font(.title)
                    Text("写真を読み込めませんでした").font(.footnote)
                }
                .foregroundStyle(.white.opacity(0.7))
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: path) {
            guard image == nil else { return }
            let loaded = await session.media?.photo(path: path)
            image = loaded
            failed = loaded == nil
        }
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear
        scroll.imageView.image = image
        scroll.imageView.contentMode = .scaleAspectFit
        scroll.addSubview(scroll.imageView)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: ZoomScrollView, context: Context) {
        if scroll.imageView.image !== image {
            scroll.setZoomScale(1, animated: false)
            scroll.imageView.image = image
        }
    }

    final class ZoomScrollView: UIScrollView {
        let imageView = UIImageView()

        override func layoutSubviews() {
            super.layoutSubviews()
            // 寄っていないときだけ、画面いっぱいに合わせ直す（回したとき・はじめて出たとき）
            if zoomScale <= minimumZoomScale + 0.001, imageView.frame.size != bounds.size {
                imageView.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
            }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomScrollView)?.imageView
        }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? ZoomScrollView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale + 0.01 {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: scroll.imageView)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}

/// 写真 1 枚を画面いっぱいに見る（黒い地・閉じるボタン・下にひとこと）
struct PhotoViewer: View {
    let path: String
    var caption: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            ZoomableRemotePhoto(path: path)
                .ignoresSafeArea()
            if !caption.isEmpty {
                VStack {
                    Spacer()
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .padding(16)
            .accessibilityLabel("閉じる")
        }
    }
}

/// fullScreenCover で写真を開くための札
struct PhotoViewerItem: Identifiable {
    let path: String
    let caption: String
    var id: String { path }
}
