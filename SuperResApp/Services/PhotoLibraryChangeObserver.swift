import Combine
import Photos
import Foundation

@MainActor
final class PhotoLibraryChangeObserver: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    static let shared = PhotoLibraryChangeObserver()

    @Published private(set) var changeCount = 0
    private var isRegistered = false

    private override init() {
        super.init()
    }

    func start() {
        guard !isRegistered else { return }
        PHPhotoLibrary.shared().register(self)
        isRegistered = true
    }

    func stop() {
        guard isRegistered else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        isRegistered = false
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.changeCount += 1
        }
    }
}
