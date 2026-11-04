import Photos
import PhotosUI
import SwiftUI
import UIKit

struct AppleLivePhotoPreview: UIViewRepresentable {
    let asset: PHAsset

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PHLivePhotoView {
        let view = PHLivePhotoView()
        view.contentMode = .scaleAspectFit
        requestLivePhoto(for: asset, in: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: PHLivePhotoView, context: Context) {
        guard context.coordinator.assetIdentifier != asset.localIdentifier else { return }
        requestLivePhoto(for: asset, in: view, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ view: PHLivePhotoView, coordinator: Coordinator) {
        if coordinator.requestID != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(coordinator.requestID)
        }
        view.stopPlayback()
    }

    private func requestLivePhoto(
        for asset: PHAsset,
        in view: PHLivePhotoView,
        coordinator: Coordinator
    ) {
        if coordinator.requestID != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(coordinator.requestID)
        }
        coordinator.assetIdentifier = asset.localIdentifier
        let options = PHLivePhotoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        coordinator.requestID = PHImageManager.default().requestLivePhoto(
            for: asset,
            targetSize: CGSize(width: 1600, height: 1600),
            contentMode: .aspectFit,
            options: options
        ) { [weak view] livePhoto, info in
            guard (info?[PHImageCancelledKey] as? Bool) != true,
                  (info?[PHImageErrorKey] as? Error) == nil,
                  let livePhoto else { return }
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.livePhoto = livePhoto
                view.startPlayback(with: .hint)
            }
        }
    }

    final class Coordinator {
        var assetIdentifier: String?
        var requestID: PHImageRequestID = PHInvalidImageRequestID
    }
}
