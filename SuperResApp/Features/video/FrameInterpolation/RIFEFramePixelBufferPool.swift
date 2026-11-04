import CoreVideo
import OSLog

/// CVPixelBuffer 复用池：避免重复分配像素缓冲区，降低内存峰值和 GC 压力
final class RIFEFramePixelBufferPool {
    private let logger = Logger(subsystem: "com.superres.app", category: "RIFEFramePixelBufferPool")
    private var pool: CVPixelBufferPool?
    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private(set) var pixelFormat: OSType = 0

    /// 配置缓冲区池
    /// - Parameters:
    ///   - width: 缓冲区宽度
    ///   - height: 缓冲区高度
    ///   - format: 像素格式，默认 32BGRA
    ///   - minBufferCount: 最小缓冲区数量，默认 6
    func configure(
        width: Int,
        height: Int,
        format: OSType = kCVPixelFormatType_32BGRA,
        minBufferCount: Int = 6
    ) {
        self.width = width
        self.height = height
        self.pixelFormat = format

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: minBufferCount
        ]
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            nil,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &newPool
        )

        if status == kCVReturnSuccess, let newPool = newPool {
            self.pool = newPool
            logger.info("RIFEFramePixelBufferPool 创建成功: \(width, privacy: .public)x\(height, privacy: .public), 最小\(minBufferCount, privacy: .public)个缓冲区")
        } else {
            logger.error("RIFEFramePixelBufferPool 创建失败，状态码: \(status, privacy: .public)")
        }
    }

    /// 从池中获取一个像素缓冲区
    /// - Returns: 像素缓冲区，池未配置或获取失败返回 nil
    func makeBuffer() -> CVPixelBuffer? {
        guard let pool = pool else {
            logger.error("RIFEFramePixelBufferPool 未配置")
            return nil
        }

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)

        if status != kCVReturnSuccess {
            logger.error("从池中获取缓冲区失败，状态码: \(status, privacy: .public)")
            return nil
        }

        return buffer
    }

    /// 释放池
    func invalidate() {
        pool = nil
        logger.info("RIFEFramePixelBufferPool 已释放")
    }
}
