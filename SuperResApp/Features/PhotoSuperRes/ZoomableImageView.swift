// SuperResApp/Features/PhotoSuperRes/ZoomableImageView.swift
// 可缩放图片视图：UIScrollView 封装，支持双指缩放、双击缩放、平移

import SwiftUI
import UIKit

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
        // ⭐️ 初始先不设置 minZoom，等尺寸计算出来后在 updateLayout 里设置
        scrollView.maximumZoomScale = maxZoom
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .black

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.tag = 100
        scrollView.addSubview(imageView)

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
            centerImage()
        }

        func updateLayout() {
            guard let scrollView = scrollView, let imageView = imageView else { return }
            let imageSize = imageView.image?.size ?? .zero
            guard imageSize.width > 0 && imageSize.height > 0 else { return }

            let scrollSize = scrollView.bounds.size

            // 如果 bounds 还没计算出来(为0)，推迟到下一帧执行
            if scrollSize.width == 0 || scrollSize.height == 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.updateLayout()
                }
                return
            }

            // 计算 aspectFit 的尺寸
            let scale = min(scrollSize.width / imageSize.width, scrollSize.height / imageSize.height)
            let baseWidth = imageSize.width * scale
            let baseHeight = imageSize.height * scale

            // ⭐️ 强制设置 ImageView 的大小，保证大图不会撑爆
            imageView.frame = CGRect(x: 0, y: 0, width: baseWidth, height: baseHeight)
            scrollView.contentSize = CGSize(width: baseWidth, height: baseHeight)

            // ⭐️ 关键修复：将 UIScrollView 的 1.0 缩放定义为 "恰好适应屏幕的大小"
            scrollView.minimumZoomScale = 1.0
            
            // ⭐️ 关键修复：每次换图或重新布局时，强制重置缩放为适应屏幕状态
            scrollView.setZoomScale(1.0, animated: false)

            centerImage()
        }

        private func centerImage() {
            guard let scrollView = scrollView else { return }
            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) * 0.5, 0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) * 0.5, 0)
            scrollView.contentInset = UIEdgeInsets(top: offsetY, left: offsetX, bottom: offsetY, right: offsetX)
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = scrollView else { return }
            // 判断条件改为 1.0
            if scrollView.zoomScale > 1.0 {
                // 缩放到 1x (恢复适应屏幕)
                scrollView.setZoomScale(1.0, animated: true)
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
            zoomRect.size.height = scrollView.bounds.size.height / scale
            zoomRect.size.width = scrollView.bounds.size.width / scale
            zoomRect.origin.x = center.x - zoomRect.size.width / 2
            zoomRect.origin.y = center.y - zoomRect.size.height / 2
            return zoomRect
        }
    }
}