// SuperResApp/Features/PhotoSuperRes/ZoomableImageView.swift
// 可缩放图片视图：UIScrollView 封装，支持双指缩放、双击缩放、平移

import SwiftUI
import UIKit

/// 可缩放图片视图（UIViewRepresentable 封装 UIScrollView）
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomScale: CGFloat
    let minZoom: CGFloat
    let maxZoom: CGFloat
    let doubleTapZoom: CGFloat

    init(
        image: UIImage,
        zoomScale: Binding<CGFloat>,
        minZoom: CGFloat = DesignTokens.previewMinZoom,
        maxZoom: CGFloat = DesignTokens.previewMaxZoom,
        doubleTapZoom: CGFloat = DesignTokens.previewDoubleTapZoom
    ) {
        self.image = image
        self._zoomScale = zoomScale
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.doubleTapZoom = doubleTapZoom
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = minZoom
        scrollView.maximumZoomScale = maxZoom
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .black

        // 图片视图
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.tag = 100
        scrollView.addSubview(imageView)

        // 双击手势
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        guard let imageView = scrollView.viewWithTag(100) as? UIImageView else { return }
        if imageView.image != image {
            imageView.image = image
        }
        context.coordinator.updateLayout()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableImageView
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?

        init(_ parent: ZoomableImageView) {
            self.parent = parent
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            parent.zoomScale = scrollView.zoomScale
            updateLayout()
        }

        func updateLayout() {
            guard let scrollView = scrollView, let imageView = imageView else { return }
            let imageSize = imageView.image?.size ?? .zero
            guard imageSize.width > 0 && imageSize.height > 0 else { return }

            // 计算 aspectFit 的尺寸
            let scrollSize = scrollView.bounds.size
            let scale = min(scrollSize.width / imageSize.width, scrollSize.height / imageSize.height)
            let baseWidth = imageSize.width * scale
            let baseHeight = imageSize.height * scale

            imageView.frame = CGRect(x: 0, y: 0, width: baseWidth, height: baseHeight)
            scrollView.contentSize = CGSize(width: baseWidth * scrollView.zoomScale,
                                             height: baseHeight * scrollView.zoomScale)

            // 居中
            let offsetX = max((scrollSize.width - scrollView.contentSize.width) / 2, 0)
            let offsetY = max((scrollSize.height - scrollView.contentSize.height) / 2, 0)
            imageView.center = CGPoint(x: scrollView.contentSize.width / 2 + offsetX,
                                       y: scrollView.contentSize.height / 2 + offsetY)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = scrollView else { return }
            if scrollView.zoomScale > parent.minZoom {
                // 缩放到 1x
                UIView.animate(withDuration: DesignTokens.animationDoubleTapZoom) {
                    scrollView.zoomScale = self.parent.minZoom
                }
            } else {
                // 缩放到 doubleTapZoom，以点击点为中心
                let point = gesture.location(in: gesture.view)
                let zoomRect = zoomRectForScale(scale: parent.doubleTapZoom, center: point)
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }

        private func zoomRectForScale(scale: CGFloat, center: CGPoint) -> CGRect {
            guard let scrollView = scrollView else { return .zero }
            var zoomRect = CGRect.zero
            zoomRect.size.height = scrollView.frame.size.height / scale
            zoomRect.size.width = scrollView.frame.size.width / scale
            zoomRect.origin.x = center.x - zoomRect.size.width / 2
            zoomRect.origin.y = center.y - zoomRect.size.height / 2
            return zoomRect
        }
    }
}
