import CoreML
import CoreVideo
import Metal
import Accelerate
import OSLog

/// 帧插值器：Metal 预处理 → Core ML 光流估计 → Metal 后处理（Warp + Blend）
/// RIFE 4.22 Lite 模型输出光流与掩码，warp 和 blend 由 Metal Compute 完成
/// 模型文件缺失时 init 返回 nil，VideoPipeline 自动降级为空转
final class FrameInterpolator {
    private let logger = Logger(subsystem: "com.superres.app", category: "FrameInterpolator")

    // MARK: - Metal 资源
    private let helper: RIFEMetalComputeHelper
    private let commandQueue: MTLCommandQueue
    private let preprocessPipeline: MTLComputePipelineState
    private let sigmoidPipeline: MTLComputePipelineState
    private let warpPipeline: MTLComputePipelineState
    private let blendPipeline: MTLComputePipelineState
    private let rgbaToBgraPipeline: MTLComputePipelineState
    private let upsampleFlowMaskPipeline: MTLComputePipelineState

    // MARK: - Core ML 模型
    private let model: MLModel

    // MARK: - 配置
    /// 模型固定输入宽度
    let modelInputWidth = 512
    /// 模型固定输入高度
    let modelInputHeight = 512

    // MARK: - 调试开关（定位偏暗问题）
    /// true 时跳过模型推理，强制 flow=0 + mask=0，输出 (frame0+frame1)/2 简单平均
    /// 用于区分偏暗是模型输出问题还是 Metal 管线问题
    static let forceSimpleAverage = false

    // MARK: - 预分配 MTLBuffer
    private let frame0Buffer: MTLBuffer
    private let frame1Buffer: MTLBuffer
    private let flowBuffer: MTLBuffer
    private let maskBuffer: MTLBuffer

    // MARK: - PixelBuffer 复用池
    private let pool = RIFEFramePixelBufferPool()

    // MARK: - 调试标志
    private var hasLoggedDataType = false
    private var didReportDebug = false
    // 调试统计暂存
    private var debugDataTypeFlow: Int = 0
    private var debugDataTypeMask: Int = 0
    private var debugFlowMin: Float = 0
    private var debugFlowMax: Float = 0
    private var debugFlowAbsMean: Float = 0
    private var debugMaskLogitMin: Float = 0
    private var debugMaskLogitMax: Float = 0
    private var debugMaskLogitMean: Float = 0

    // MARK: - 初始化
    init?(model: MLModel) {
        // 模型由 CF 的 ModelStore 负责加载和缓存；此处只注入已加载模型。
        guard let metalHelper = RIFEMetalComputeHelper.shared else {
            logger.error("Metal 初始化失败，无法创建帧插值器")
            return nil
        }
        self.helper = metalHelper
        self.model = model

        // 2. 初始化 Metal 计算管线
        guard let queue = helper.device.makeCommandQueue(),
              let library = helper.device.makeDefaultLibrary(),
              let pre = library.makeFunction(name: "bgra_to_nchw"),
              let sig = library.makeFunction(name: "sigmoid_mask"),
              let warp = library.makeFunction(name: "warp_frame"),
              let blend = library.makeFunction(name: "blend_frames"),
              let rgb2bgra = library.makeFunction(name: "rgba_to_bgra"),
              let upsample = library.makeFunction(name: "upsample_flow_mask") else {
            logger.error("Metal 函数加载失败")
            return nil
        }
        self.commandQueue = queue

        do {
            self.preprocessPipeline = try helper.device.makeComputePipelineState(function: pre)
            self.sigmoidPipeline = try helper.device.makeComputePipelineState(function: sig)
            self.warpPipeline = try helper.device.makeComputePipelineState(function: warp)
            self.blendPipeline = try helper.device.makeComputePipelineState(function: blend)
            self.rgbaToBgraPipeline = try helper.device.makeComputePipelineState(function: rgb2bgra)
            self.upsampleFlowMaskPipeline = try helper.device.makeComputePipelineState(function: upsample)
        } catch {
            logger.error("Metal 管线创建失败: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // 3. 预分配 MTLBuffer
        let plane = modelInputWidth * modelInputHeight
        let frameBytes = plane * 3 * MemoryLayout<Float16>.size
        let flowBytes = plane * 4 * MemoryLayout<Float16>.size
        let maskBytes = plane * 1 * MemoryLayout<Float16>.size

        guard let f0 = helper.device.makeBuffer(length: frameBytes, options: .storageModeShared),
              let f1 = helper.device.makeBuffer(length: frameBytes, options: .storageModeShared),
              let fl = helper.device.makeBuffer(length: flowBytes, options: .storageModeShared),
              let mk = helper.device.makeBuffer(length: maskBytes, options: .storageModeShared) else {
            logger.error("MTLBuffer 分配失败")
            return nil
        }
        self.frame0Buffer = f0
        self.frame1Buffer = f1
        self.flowBuffer = fl
        self.maskBuffer = mk

        // 4. 配置输出 RIFEFramePixelBufferPool
        pool.configure(width: modelInputWidth, height: modelInputHeight, format: kCVPixelFormatType_32BGRA)

        logger.info("FrameInterpolator 初始化成功，模型输入: \(self.modelInputWidth, privacy: .public)x\(self.modelInputHeight, privacy: .public)，Metal 后处理已启用")
    }

    // MARK: - 公开方法
    /// 输入前后两帧，输出中间帧
    /// - Parameters:
    ///   - frame0: 前一帧（CVPixelBuffer，32BGRA）
    ///   - frame1: 后一帧（CVPixelBuffer，32BGRA）
    /// - Returns: 中间帧（CVPixelBuffer，32BGRA，尺寸与输入一致），失败返回 nil
    func interpolate(frame0: CVPixelBuffer, frame1: CVPixelBuffer) -> CVPixelBuffer? {
        let originalWidth = CVPixelBufferGetWidth(frame0)
        let originalHeight = CVPixelBufferGetHeight(frame0)
        guard CVPixelBufferGetWidth(frame1) == originalWidth,
              CVPixelBufferGetHeight(frame1) == originalHeight else {
            logger.error("输入帧尺寸不一致")
            return nil
        }

        // 1. 缩放到模型输入尺寸 512x512
        guard let resized0 = resize(pixelBuffer: frame0, width: modelInputWidth, height: modelInputHeight),
              let resized1 = resize(pixelBuffer: frame1, width: modelInputWidth, height: modelInputHeight) else {
            logger.error("输入帧缩放失败")
            return nil
        }

        // 2. 创建 Metal 纹理（全部走 IOSurface 零拷贝）
        // 512 纹理用于模型预处理
        guard let tex0 = helper.makeIOSurfaceTexture(from: resized0, usage: .shaderRead),
              let tex1 = helper.makeIOSurfaceTexture(from: resized1, usage: .shaderRead) else {
            logger.error("创建输入纹理失败")
            return nil
        }
        // 原分辨率纹理用于 warp/blend（避免二次缩放损失）
        guard let origTex0 = helper.makeIOSurfaceTexture(from: frame0, usage: .shaderRead),
              let origTex1 = helper.makeIOSurfaceTexture(from: frame1, usage: .shaderRead) else {
            logger.error("创建原分辨率纹理失败")
            return nil
        }

        // 3. Metal 预处理：BGRA → NCHW Float16
        guard let preprocessBuffer = commandQueue.makeCommandBuffer() else { return nil }
        encodePreprocess(commandBuffer: preprocessBuffer, source: tex0, dstBuffer: frame0Buffer)
        encodePreprocess(commandBuffer: preprocessBuffer, source: tex1, dstBuffer: frame1Buffer)
        preprocessBuffer.commit()
        preprocessBuffer.waitUntilCompleted()

        // 4. Core ML 推理（光流估计）或调试模式
        if Self.forceSimpleAverage {
            // 调试模式：flow=0（warp后等于原帧），mask=0（sigmoid后=0.5，blend后等于两帧平均）
            let flowCount = flowBuffer.length / MemoryLayout<Float16>.size
            flowBuffer.contents().initializeMemory(as: Float16.self, repeating: 0, count: flowCount)
            let maskCount = maskBuffer.length / MemoryLayout<Float16>.size
            maskBuffer.contents().initializeMemory(as: Float16.self, repeating: 0, count: maskCount)
            logger.info("调试模式：已跳过模型推理，强制简单平均")
        } else {
            guard let input0 = makeMultiArray(from: frame0Buffer, shape: [1, 3, NSNumber(value: modelInputHeight), NSNumber(value: modelInputWidth)]),
                  let input1 = makeMultiArray(from: frame1Buffer, shape: [1, 3, NSNumber(value: modelInputHeight), NSNumber(value: modelInputWidth)]),
                  let featureProvider = try? MLDictionaryFeatureProvider(dictionary: [
                      "frame0": input0,
                      "frame1": input1
                  ]),
                  let output = try? model.prediction(from: featureProvider) else {
                logger.error("Core ML 推理失败")
                return nil
            }

            guard let flowArray = output.featureValue(for: "flow")?.multiArrayValue,
                  let maskArray = output.featureValue(for: "mask")?.multiArrayValue else {
                logger.error("模型输出缺少 flow 或 mask")
                return nil
            }

            // 首次推理时收集模型输出统计
            if !hasLoggedDataType {
                hasLoggedDataType = true
                debugDataTypeFlow = flowArray.dataType.rawValue
                debugDataTypeMask = maskArray.dataType.rawValue
            }

            // 5. 将 MLMultiArray 拷贝到 MTLBuffer（含 Float32→Float16 转换）
            copyToBuffer(multiArray: flowArray, buffer: flowBuffer)
            copyToBuffer(multiArray: maskArray, buffer: maskBuffer)

            // 首次推理时收集 flow/mask 统计（sigmoid 前）
            if !didReportDebug {
                let flowStats = statsOfFloat16Buffer(flowBuffer, count: modelInputWidth * modelInputHeight * 4)
                let maskStats = statsOfFloat16Buffer(maskBuffer, count: modelInputWidth * modelInputHeight)
                debugFlowMin = flowStats.min
                debugFlowMax = flowStats.max
                debugFlowAbsMean = flowStats.absMean
                debugMaskLogitMin = maskStats.min
                debugMaskLogitMax = maskStats.max
                debugMaskLogitMean = maskStats.mean
            }
        }

        // 6. Metal 后处理：Sigmoid(512) → 上采样flow/mask到原分辨率 → Warp(原分辨率) → Blend(原分辨率) → RGBA→BGRA
        guard let postprocessBuffer = commandQueue.makeCommandBuffer() else { return nil }

        // 创建原分辨率的 flow/mask buffer（上采样目标）
        let origPlane = originalWidth * originalHeight
        let origFlowBytes = origPlane * 4 * MemoryLayout<Float16>.size
        let origMaskBytes = origPlane * 1 * MemoryLayout<Float16>.size
        guard let origFlowBuffer = helper.device.makeBuffer(length: origFlowBytes, options: .storageModeShared),
              let origMaskBuffer = helper.device.makeBuffer(length: origMaskBytes, options: .storageModeShared) else {
            logger.error("创建原分辨率flow/mask buffer失败")
            return nil
        }

        // 创建原分辨率后处理纹理
        guard let warped0 = helper.makeEmptyTexture(width: originalWidth, height: originalHeight),
              let warped1 = helper.makeEmptyTexture(width: originalWidth, height: originalHeight),
              let blended = helper.makeEmptyTexture(width: originalWidth, height: originalHeight),
              let outputBGRA = helper.makeEmptyTexture(width: originalWidth, height: originalHeight, format: .bgra8Unorm, storageMode: .shared) else {
            logger.error("创建后处理纹理失败")
            return nil
        }

        // Sigmoid mask（512空间）
        encodeSigmoid(commandBuffer: postprocessBuffer)

        // 上采样 flow/mask 到原分辨率，光流值按宽度比缩放
        let flowScaleX = Float(originalWidth) / Float(modelInputWidth)
        let flowScaleY = Float(originalHeight) / Float(modelInputHeight)
        encodeUpsampleFlowMask(
            commandBuffer: postprocessBuffer,
            srcFlow: flowBuffer, srcMask: maskBuffer,
            dstFlow: origFlowBuffer, dstMask: origMaskBuffer,
            srcW: modelInputWidth, srcH: modelInputHeight,
            dstW: originalWidth, dstH: originalHeight,
            flowScaleX: flowScaleX, flowScaleY: flowScaleY
        )

        // Warp：在原分辨率空间用原帧做warp，光流已上采样
        // frame0 用正向光流（前2通道），frame1 用反向光流（后2通道）
        encodeWarp(commandBuffer: postprocessBuffer, source: origTex0, destination: warped0,
                   flowBuffer: origFlowBuffer, width: originalWidth, height: originalHeight,
                   scale: 1.0, channelOffset: 0)
        encodeWarp(commandBuffer: postprocessBuffer, source: origTex1, destination: warped1,
                   flowBuffer: origFlowBuffer, width: originalWidth, height: originalHeight,
                   scale: 1.0, channelOffset: 2)

        // Blend（原分辨率空间）
        encodeBlend(commandBuffer: postprocessBuffer, warped0: warped0, warped1: warped1,
                    output: blended, maskBuffer: origMaskBuffer,
                    width: originalWidth, height: originalHeight)

        // RGBA → BGRA
        encodeRgbaToBgra(commandBuffer: postprocessBuffer, source: blended, destination: outputBGRA)

        postprocessBuffer.commit()
        postprocessBuffer.waitUntilCompleted()

        // 7. 从纹理拷贝到 PixelBuffer（原分辨率，无需再缩放）
        var outputBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: originalWidth,
            kCVPixelBufferHeightKey: originalHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, originalWidth, originalHeight,
                                  kCVPixelFormatType_32BGRA, attrs, &outputBuffer) == kCVReturnSuccess,
              let output = outputBuffer else {
            logger.error("创建输出PixelBuffer失败")
            return nil
        }
        helper.copy(texture: outputBGRA, to: output)

        // 首次推理完成后收集完整调试信息并通知 UI
        if !didReportDebug {
            didReportDebug = true
            let maskAfterSigmoid = statsOfFloat16Buffer(maskBuffer, count: modelInputWidth * modelInputHeight)
            let inLum = averageLuminance(of: resized0)
            let outLum = averageLuminance(of: output)
            let info = """
            输出类型: flow=\(debugDataTypeFlow) mask=\(debugDataTypeMask) (65535=Float16, 65536=Float32)
            光流: [\(String(format: "%.2f", debugFlowMin)), \(String(format: "%.2f", debugFlowMax))] absMean=\(String(format: "%.3f", debugFlowAbsMean))
            掩码logits: [\(String(format: "%.2f", debugMaskLogitMin)), \(String(format: "%.2f", debugMaskLogitMax))] mean=\(String(format: "%.3f", debugMaskLogitMean))
            掩码sigmoid后: mean=\(String(format: "%.3f", maskAfterSigmoid.mean))
            输入亮度: \(String(format: "%.1f", inLum))  输出亮度: \(String(format: "%.1f", outLum))  比例: \(String(format: "%.3f", outLum / max(inLum, 1)))
            """
            NotificationCenter.default.post(name: NSNotification.Name("BzDebugInfoUpdated"), object: info)
            logger.info("调试信息: \(info, privacy: .public)")
        }

        // 8. 直接返回原分辨率输出（光流已上采样，warp/blend在原分辨率完成，无需二次缩放）
        return output
    }

    // MARK: - Metal 编码：预处理
    private func encodePreprocess(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        dstBuffer: MTLBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(preprocessPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(dstBuffer, offset: 0, index: 0)

        var width = UInt32(modelInputWidth)
        var height = UInt32(modelInputHeight)
        encoder.setBytes(&width, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&height, length: MemoryLayout<UInt32>.size, index: 2)

        dispatch2D(encoder: encoder, width: modelInputWidth, height: modelInputHeight)
        encoder.endEncoding()
    }

    // MARK: - Metal 编码：Sigmoid
    private func encodeSigmoid(commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(sigmoidPipeline)
        encoder.setBuffer(maskBuffer, offset: 0, index: 0)

        var count = UInt32(modelInputWidth * modelInputHeight)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)

        let threadGroup = MTLSize(width: 256, height: 1, depth: 1)
        let threadGrid = MTLSize(width: (modelInputWidth * modelInputHeight + 255) / 256, height: 1, depth: 1)
        encoder.dispatchThreadgroups(threadGrid, threadsPerThreadgroup: threadGroup)
        encoder.endEncoding()
    }

    // MARK: - Metal 编码：光流+掩码上采样（512→原分辨率）
    private func encodeUpsampleFlowMask(
        commandBuffer: MTLCommandBuffer,
        srcFlow: MTLBuffer,
        srcMask: MTLBuffer,
        dstFlow: MTLBuffer,
        dstMask: MTLBuffer,
        srcW: Int,
        srcH: Int,
        dstW: Int,
        dstH: Int,
        flowScaleX: Float,
        flowScaleY: Float
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(upsampleFlowMaskPipeline)
        encoder.setBuffer(srcFlow, offset: 0, index: 0)
        encoder.setBuffer(srcMask, offset: 0, index: 1)
        encoder.setBuffer(dstFlow, offset: 0, index: 2)
        encoder.setBuffer(dstMask, offset: 0, index: 3)

        var sw = UInt32(srcW), sh = UInt32(srcH)
        var dw = UInt32(dstW), dh = UInt32(dstH)
        var fsx = flowScaleX
        var fsy = flowScaleY
        encoder.setBytes(&sw, length: MemoryLayout<UInt32>.size, index: 4)
        encoder.setBytes(&sh, length: MemoryLayout<UInt32>.size, index: 5)
        encoder.setBytes(&dw, length: MemoryLayout<UInt32>.size, index: 6)
        encoder.setBytes(&dh, length: MemoryLayout<UInt32>.size, index: 7)
        encoder.setBytes(&fsx, length: MemoryLayout<Float>.size, index: 8)
        encoder.setBytes(&fsy, length: MemoryLayout<Float>.size, index: 9)

        dispatch2D(encoder: encoder, width: dstW, height: dstH)
        encoder.endEncoding()
    }

    // MARK: - Metal 编码：Warp
    private func encodeWarp(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture,
        flowBuffer: MTLBuffer,
        width: Int,
        height: Int,
        scale: Float,
        channelOffset: UInt32
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(warpPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBuffer(flowBuffer, offset: 0, index: 0)

        var w = UInt32(width)
        var h = UInt32(height)
        var s = scale
        var offset = channelOffset
        encoder.setBytes(&w, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&h, length: MemoryLayout<UInt32>.size, index: 2)
        encoder.setBytes(&s, length: MemoryLayout<Float>.size, index: 3)
        encoder.setBytes(&offset, length: MemoryLayout<UInt32>.size, index: 4)

        dispatch2D(encoder: encoder, width: width, height: height)
        encoder.endEncoding()
    }

    // MARK: - Metal 编码：Blend
    private func encodeBlend(
        commandBuffer: MTLCommandBuffer,
        warped0: MTLTexture,
        warped1: MTLTexture,
        output: MTLTexture,
        maskBuffer: MTLBuffer,
        width: Int,
        height: Int
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(blendPipeline)
        encoder.setTexture(warped0, index: 0)
        encoder.setTexture(warped1, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBuffer(maskBuffer, offset: 0, index: 0)

        var w = UInt32(width)
        var h = UInt32(height)
        encoder.setBytes(&w, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&h, length: MemoryLayout<UInt32>.size, index: 2)

        dispatch2D(encoder: encoder, width: width, height: height)
        encoder.endEncoding()
    }

    // MARK: - Metal 编码：RGBA → BGRA
    private func encodeRgbaToBgra(
        commandBuffer: MTLCommandBuffer,
        source: MTLTexture,
        destination: MTLTexture
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(rgbaToBgraPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)

        dispatch2D(encoder: encoder, width: source.width, height: source.height)
        encoder.endEncoding()
    }

    // MARK: - 通用 2D 线程组分发
    private func dispatch2D(encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        let threadGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadGrid = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGrid, threadsPerThreadgroup: threadGroup)
    }

    // MARK: - MLMultiArray <-> MTLBuffer
    private func makeMultiArray(from buffer: MTLBuffer, shape: [NSNumber]) -> MLMultiArray? {
        guard let array = try? MLMultiArray(shape: shape, dataType: .float16) else { return nil }
        memcpy(array.dataPointer, buffer.contents(), min(buffer.length, array.count * MemoryLayout<Float16>.size))
        return array
    }

    private func copyToBuffer(multiArray: MLMultiArray, buffer: MTLBuffer) {
        let count = multiArray.count
        // 关键修复：coremltools TensorType 默认输出 Float32，而 MTLBuffer 是 Float16
        // 直接 memcpy 会将 Float32 字节错误解析为 Float16，导致光流/掩码值完全错误
        if multiArray.dataType == .float16 {
            let byteCount = count * MemoryLayout<Float16>.size
            memcpy(buffer.contents(), multiArray.dataPointer, min(byteCount, buffer.length))
        } else if multiArray.dataType == .float32 {
            let src = multiArray.dataPointer.assumingMemoryBound(to: Float32.self)
            let dst = buffer.contents().assumingMemoryBound(to: Float16.self)
            for i in 0..<count {
                dst[i] = Float16(src[i])
            }
        } else {
            logger.error("不支持的 MLMultiArray 数据类型: \(multiArray.dataType.rawValue, privacy: .public)")
        }
    }

    // MARK: - 调试统计辅助
    /// 统计 Float16 MTLBuffer 的 min/max/mean/absMean
    private func statsOfFloat16Buffer(_ buffer: MTLBuffer, count: Int) -> (min: Float, max: Float, mean: Float, absMean: Float) {
        let ptr = buffer.contents().assumingMemoryBound(to: Float16.self)
        var minVal = Float.greatestFiniteMagnitude
        var maxVal = -Float.greatestFiniteMagnitude
        var sum: Float = 0
        var absSum: Float = 0
        for i in 0..<count {
            let v = Float(ptr[i])
            if v < minVal { minVal = v }
            if v > maxVal { maxVal = v }
            sum += v
            absSum += abs(v)
        }
        let fCount = Float(count)
        return (minVal, maxVal, sum / fCount, absSum / fCount)
    }

    /// 计算 CVPixelBuffer（32BGRA）的平均亮度（RGB 三通道平均，0-255）
    private func averageLuminance(of pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var sum: Int64 = 0
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                // 32BGRA: 字节0=B, 1=G, 2=R, 3=A
                sum += Int64(row[x * 4 + 0]) + Int64(row[x * 4 + 1]) + Int64(row[x * 4 + 2])
            }
        }
        return Double(sum) / Double(width * height * 3)
    }

    // MARK: - vImage 缩放
    private func resize(pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(pixelBuffer) == width &&
           CVPixelBufferGetHeight(pixelBuffer) == height {
            return pixelBuffer
        }

        var outputBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputBuffer)
        guard status == kCVReturnSuccess, let output = outputBuffer else {
            logger.error("创建缩放缓冲区失败")
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let dstBase = CVPixelBufferGetBaseAddress(output) else {
            return nil
        }

        var srcBuffer = vImage_Buffer(
            data: srcBase,
            height: vImagePixelCount(CVPixelBufferGetHeight(pixelBuffer)),
            width: vImagePixelCount(CVPixelBufferGetWidth(pixelBuffer)),
            rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
        )
        var dstBuffer = vImage_Buffer(
            data: dstBase,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: CVPixelBufferGetBytesPerRow(output)
        )

        let scaleError = vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil, vImage_Flags(kvImageHighQualityResampling))
        if scaleError != kvImageNoError {
            logger.error("vImage 缩放失败，错误码: \(scaleError, privacy: .public)")
            return nil
        }

        return output
    }
}
