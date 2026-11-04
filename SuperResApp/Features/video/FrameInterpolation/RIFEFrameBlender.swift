import Metal
import CoreVideo

/// BZ 原版 MetalFrameBlender 的 CF 移植：GPU 50/50 混合，失败时回退 CPU。
final class RIFEFrameBlender {
    static let shared: RIFEFrameBlender? = RIFEFrameBlender()
    private let helper: RIFEMetalComputeHelper
    private let pipeline: MTLComputePipelineState
    private let outputPool = RIFEFramePixelBufferPool()
    private let lock = NSLock()
    private var configuredWidth = 0
    private var configuredHeight = 0

    private init?() {
        guard let helper = RIFEMetalComputeHelper.shared,
              let library = helper.device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "simple_blend"),
              let pipeline = try? helper.device.makeComputePipelineState(function: function) else { return nil }
        self.helper = helper
        self.pipeline = pipeline
    }

    func blend(frame0: CVPixelBuffer, frame1: CVPixelBuffer, alpha: Float = 0.5) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let width = CVPixelBufferGetWidth(frame0)
        let height = CVPixelBufferGetHeight(frame0)
        guard width > 0, height > 0,
              width == CVPixelBufferGetWidth(frame1),
              height == CVPixelBufferGetHeight(frame1) else { return nil }

        if width != configuredWidth || height != configuredHeight {
            outputPool.configure(width: width, height: height, minBufferCount: 8)
            configuredWidth = width
            configuredHeight = height
        }
        guard let output = outputPool.makeBuffer(),
              let texture0 = helper.makeIOSurfaceTexture(from: frame0, usage: .shaderRead),
              let texture1 = helper.makeIOSurfaceTexture(from: frame1, usage: .shaderRead),
              let textureOut = helper.makeIOSurfaceTexture(from: output, usage: [.shaderRead, .shaderWrite]),
              let commandBuffer = helper.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture0, index: 0)
        encoder.setTexture(texture1, index: 1)
        encoder.setTexture(textureOut, index: 2)
        var blendAlpha = alpha
        encoder.setBytes(&blendAlpha, length: MemoryLayout<Float>.size, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(
            width: (width + group.width - 1) / group.width,
            height: (height + group.height - 1) / group.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed, commandBuffer.error == nil else { return nil }
        return output
    }
}
