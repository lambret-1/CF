import Metal
import CoreVideo
import OSLog

/// Metal 计算辅助工具：封装纹理创建、缓冲区管理等通用操作
/// 单例模式，Metal 初始化失败时 shared 为 nil，调用方需降级处理
final class RIFEMetalComputeHelper {
    private let logger = Logger(subsystem: "com.superres.app", category: "RIFEMetalComputeHelper")

    static let shared: RIFEMetalComputeHelper? = RIFEMetalComputeHelper()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    // 保护 textureCache 访问，CVMetalTextureCache 非线程安全
    private let cacheLock = NSLock()

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue

        // 创建 CVMetalTextureCache，用于 IOSurface 零拷贝纹理
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
            &cache
        )
        if status == kCVReturnSuccess {
            self.textureCache = cache
        }
        logger.info("RIFEMetalComputeHelper 初始化成功，设备: \(device.name, privacy: .public)")
    }

    /// 从 CVPixelBuffer 的 IOSurface 创建 MTLTexture（零拷贝，推荐用于输入/输出帧）
    /// 比 makeTexture(from:) 的 lock+replace 路径快得多，无 CPU/GPU 来回拷贝
    /// 若 IOSurface 零拷贝失败，自动回退到 makeTexture（CPU→GPU拷贝路径），保证GPU可用
    func makeIOSurfaceTexture(from pixelBuffer: CVPixelBuffer, usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard let cache = textureCache else {
            // cache 不可用，回退到 CPU→GPU 拷贝路径
            return makeTextureLocked(from: pixelBuffer, usage: usage)
        }

        var image: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &image
        )

        guard status == kCVReturnSuccess, let cvImage = image else {
            // IOSurface 零拷贝失败，回退到 CPU→GPU 拷贝路径
            return makeTextureLocked(from: pixelBuffer, usage: usage)
        }
        return CVMetalTextureGetTexture(cvImage)
    }

    /// 把 CVPixelBuffer(BGRA) 包装为 MTLTexture（CPU→GPU 拷贝路径，用于非 IOSurface buffer）
    /// 注意：有性能开销，优先使用 makeIOSurfaceTexture
    func makeTexture(from pixelBuffer: CVPixelBuffer, usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) -> MTLTexture? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return makeTextureLocked(from: pixelBuffer, usage: usage)
    }

    /// 内部方法：调用方必须已持有 cacheLock
    private func makeTextureLocked(from pixelBuffer: CVPixelBuffer, usage: MTLTextureUsage) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var texture: MTLTexture?
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = .shared

        texture = device.makeTexture(descriptor: descriptor)
        texture?.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: baseAddress,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    /// 创建一个空的纹理，用作 Metal 的中间缓冲
    /// - Parameters:
    ///   - storageMode: 存储模式，中间缓冲用 .private（GPU-only，性能好），
    ///                  需要 CPU 读取（如 getBytes）时必须用 .shared
    func makeEmptyTexture(
        width: Int,
        height: Int,
        format: MTLPixelFormat = .rgba16Float,
        storageMode: MTLStorageMode = .private
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = storageMode
        return device.makeTexture(descriptor: descriptor)
    }

    /// 把 MTLTexture 内容拷回 CVPixelBuffer
    func copy(texture: MTLTexture, to pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        texture.getBytes(
            baseAddress,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
    }
}
