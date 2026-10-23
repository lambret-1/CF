// SuperResApp/Services/SuperResolution/ImageTensorConverter.swift

import Foundation
import CoreML
import CoreImage
import UIKit
import Accelerate

// MARK: - Tensor 元素抽象
//
// 统一处理 MLMultiArray 支持的所有数据类型，避免"用 Float 写 Float16 缓冲"
// 这类越界写导致的堆破坏。

protocol TensorElement {
    static func toFloat(_ value: Self) -> Float
    static func fromFloat(_ value: Float) -> Self
}

extension Float: TensorElement {
    @inline(__always) static func toFloat(_ v: Float) -> Float { v }
    @inline(__always) static func fromFloat(_ v: Float) -> Float { v }
}

extension Double: TensorElement {
    @inline(__always) static func toFloat(_ v: Double) -> Float { Float(v) }
    @inline(__always) static func fromFloat(_ v: Float) -> Double { Double(v) }
}

extension Float16: TensorElement {
    @inline(__always) static func toFloat(_ v: Float16) -> Float { Float(v) }
    @inline(__always) static func fromFloat(_ v: Float) -> Float16 { Float16(v) }
}

extension Int32: TensorElement {
    @inline(__always) static func toFloat(_ v: Int32) -> Float { Float(v) }
    @inline(__always) static func fromFloat(_ v: Float) -> Int32 {
        if v.isNaN { return 0 }
        let r = v.rounded()
        // 避免 Float 精度导致 2^31 溢出 trap
        if r >= 2147483648.0 { return Int32.max }
        if r <= -2147483648.0 { return Int32.min }
        return Int32(r)
    }
}

// MARK: - ImageTensorConverter

/// 负责 CGImage ↔ MLMultiArray / CVPixelBuffer 的转换。
///
/// 设计要点：
/// - 使用 `MLMultiArray.strides` 计算内存偏移，不假设紧密连续布局；
/// - 支持 3D/4D shape 与 NCHW/NHWC 两种排布；
/// - 支持 float32 / float16 / double / int32 四种数据类型；
/// - 所有 CGContext 缓冲区都在 `withUnsafeMutableBytes` 作用域内使用；
/// - 默认串行，`parallel: true` 时使用 `DispatchQueue.concurrentPerform`。
enum ImageTensorConverter {

    private static let ciContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
    ])

    /// 默认背景色（白色）。用于 `imageToMultiArray` 绘制图像时填充透明区域。
    private static let defaultBackground = CGColor(gray: 1.0, alpha: 1.0)

    // MARK: - 数据类型分派

    private enum ElementKind {
        case float32, float16, double, int32
    }

    private static func elementKind(_ type: MLMultiArrayDataType) throws -> ElementKind {
        switch type {
        case .float32: return .float32
        case .float16: return .float16
        case .double:  return .double
        case .int32:   return .int32
        @unknown default:
            throw InferenceError.tileProcessingFailed(
                "不支持的 MLMultiArray 数据类型: \(type.rawValue)"
            )
        }
    }

    // MARK: - 张量布局解析

    /// 从 `MLMultiArray.shape` / `strides` 中解析出通道/行/列的内存步长。
    /// 这样无论模型输出是紧密还是带 padding，都能按 strides 正确寻址。
    private struct TensorLayout {
        let isNCHW: Bool
        let hasBatch: Bool
        let channels: Int
        let height: Int
        let width: Int

        /// 相邻通道之间的元素偏移
        let channelStride: Int
        /// 相邻行之间的元素偏移
        let rowStride: Int
        /// 相邻列之间的元素偏移
        let columnStride: Int

        init(array: MLMultiArray, isNCHW: Bool) throws {
            let shape = array.shape.map { $0.intValue }
            let strides = array.strides.map { $0.intValue }

            guard shape.count == 3 || shape.count == 4 else {
                throw InferenceError.tileProcessingFailed(
                    "仅支持 3D/4D 张量，实际 shape=\(shape), strides=\(strides), dataType=\(array.dataType.rawValue)"
                )
            }
            guard strides.count == shape.count else {
                throw InferenceError.tileProcessingFailed(
                    "shape/strides 维度不一致 shape=\(shape), strides=\(strides)"
                )
            }
            if shape.count == 4 && shape[0] != 1 {
                throw InferenceError.tileProcessingFailed(
                    "仅支持 batch=1，实际 shape=\(shape)"
                )
            }

            self.isNCHW = isNCHW
            self.hasBatch = shape.count == 4

            if isNCHW {
                self.channels = shape[shape.count - 3]
                self.height   = shape[shape.count - 2]
                self.width    = shape[shape.count - 1]
            } else {
                self.height   = shape[shape.count - 3]
                self.width    = shape[shape.count - 2]
                self.channels = shape[shape.count - 1]
            }

            guard channels >= 1 && channels <= 4 else {
                throw InferenceError.tileProcessingFailed(
                    "通道数不支持: \(channels), shape=\(shape)"
                )
            }

            let base = hasBatch ? 1 : 0
            if isNCHW {
                // 4D [N,C,H,W] -> strides[1],[2],[3]
                // 3D [C,H,W]   -> strides[0],[1],[2]
                self.channelStride = strides[base]
                self.rowStride     = strides[base + 1]
                self.columnStride  = strides[base + 2]
            } else {
                // 4D [N,H,W,C] -> strides[1],[2],[3]
                // 3D [H,W,C]   -> strides[0],[1],[2]
                self.rowStride     = strides[base]
                self.columnStride  = strides[base + 1]
                self.channelStride = strides[base + 2]
            }
        }
    }

    // MARK: - CGImage -> MLMultiArray

    /// 将图像写入约束指定的 `MLMultiArray`。
    ///
    /// - Parameters:
    ///   - image: 源图像
    ///   - constraint: 输入张量约束（决定 shape 与 dataType）
    ///   - isNCHW: 模型期望的布局
    ///   - valueRange: 像素归一化目标范围，默认 `0...1`；若模型需要 0-255 则传 `0...255`
    ///   - backgroundColor: 透明区域填充色；`nil` 表示不填充（透明→黑），默认白色
    ///   - parallel: 是否并行按行处理；默认关闭以避免与外部 `concurrentPerform` 嵌套
    static func imageToMultiArray(
        _ image: CGImage,
        constraint: MLMultiArrayConstraint,
        isNCHW: Bool,
        valueRange: ClosedRange<Float> = 0...1,
        backgroundColor: CGColor? = nil,
        parallel: Bool = false
    ) throws -> MLMultiArray {
        let shape = constraint.shape.map { $0.intValue }
        guard shape.count == 3 || shape.count == 4 else {
            throw InferenceError.tileProcessingFailed("约束 shape 不支持: \(shape)")
        }
        if shape.count == 4 && shape[0] != 1 {
            throw InferenceError.tileProcessingFailed("仅支持 batch=1，实际 shape=\(shape)")
        }

        let array = try MLMultiArray(
            shape: shape.map { NSNumber(value: $0) },
            dataType: constraint.dataType
        )
        let layout = try TensorLayout(array: array, isNCHW: isNCHW)

        // 1) 把图像绘制为 RGBA8888 缓冲区（可控 bytesPerRow）
        let (rgba, bytesPerRow) = try drawToRGBA(
            image,
            width: layout.width,
            height: layout.height,
            backgroundColor: backgroundColor ?? defaultBackground
        )

        // 2) 按 dataType 分派到泛型填充函数
        let kind = try elementKind(array.dataType)
        rgba.withUnsafeBytes { raw in
            let src = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            switch kind {
            case .float32:
                fillTensor(array: array, layout: layout, rgba: src,
                           bytesPerRow: bytesPerRow, valueRange: valueRange,
                           parallel: parallel, as: Float.self)
            case .float16:
                fillTensor(array: array, layout: layout, rgba: src,
                           bytesPerRow: bytesPerRow, valueRange: valueRange,
                           parallel: parallel, as: Float16.self)
            case .double:
                fillTensor(array: array, layout: layout, rgba: src,
                           bytesPerRow: bytesPerRow, valueRange: valueRange,
                           parallel: parallel, as: Double.self)
            case .int32:
                fillTensor(array: array, layout: layout, rgba: src,
                           bytesPerRow: bytesPerRow, valueRange: valueRange,
                           parallel: parallel, as: Int32.self)
            }
        }
        return array
    }

    /// 把 CGImage 绘制为 RGBA 缓冲区，返回 (buffer, bytesPerRow)。
    /// 使用 `withUnsafeMutableBytes` 保证指针生命周期；bytesPerRow 做 64 字节对齐。
    private static func drawToRGBA(
        _ image: CGImage,
        width: Int,
        height: Int,
        backgroundColor: CGColor?
    ) throws -> ([UInt8], Int) {
        let bytesPerRow = (width * 4 + 63) & ~63
        var rgba = [UInt8](repeating: 0, count: height * bytesPerRow)

        try rgba.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue   // 明确 RGBA 字节序
            ) else {
                throw InferenceError.tileProcessingFailed(
                    "创建 CGContext 失败 (\(width)x\(height))"
                )
            }

            if let bg = backgroundColor {
                ctx.setFillColor(bg)
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }

            ctx.interpolationQuality = .high
            // CoreGraphics 原点在左下，翻转以匹配图像左上
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (rgba, bytesPerRow)
    }

    private static func fillTensor<T: TensorElement>(
        array: MLMultiArray,
        layout: TensorLayout,
        rgba: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        valueRange: ClosedRange<Float>,
        parallel: Bool,
        as: T.Type
    ) {
        let out = array.dataPointer.assumingMemoryBound(to: T.self)
        let lo = valueRange.lowerBound
        let span = valueRange.upperBound - lo

        let channels   = layout.channels
        let rowStride  = layout.rowStride
        let colStride  = layout.columnStride
        let chStride   = layout.channelStride
        let h = layout.height
        let w = layout.width

        let body: (Int) -> Void = { y in
            let rowBase = y * rowStride
            let srcRow = rgba + y * bytesPerRow
            for x in 0..<w {
                let px = srcRow + x * 4
                let a = px[3]
                let r255: Float
                let g255: Float
                let b255: Float
                if a == 0 {
                    r255 = 0; g255 = 0; b255 = 0
                } else if a == 255 {
                    r255 = Float(px[0]); g255 = Float(px[1]); b255 = Float(px[2])
                } else {
                    // 反预乘，避免半透明边缘偏暗
                    let af = Float(a) / 255.0
                    r255 = Swift.min(Float(px[0]) / af, 255)
                    g255 = Swift.min(Float(px[1]) / af, 255)
                    b255 = Swift.min(Float(px[2]) / af, 255)
                }
                let r = lo + (r255 / 255.0) * span
                let g = lo + (g255 / 255.0) * span
                let b = lo + (b255 / 255.0) * span

                let base = rowBase + x * colStride
                out[base] = T.fromFloat(r)
                if channels > 1 { out[base + chStride]     = T.fromFloat(g) }
                if channels > 2 { out[base + 2 * chStride] = T.fromFloat(b) }
                if channels > 3 { out[base + 3 * chStride] = T.fromFloat(1.0) }
            }
        }

        if parallel {
            DispatchQueue.concurrentPerform(iterations: h, execute: body)
        } else {
            for y in 0..<h { body(y) }
        }
    }

    // MARK: - MLMultiArray -> CGImage

    /// 将 `MLMultiArray` 转为 `CGImage`。
    ///
    /// - Parameters:
    ///   - array: 模型输出
    ///   - isNCHW: 布局
    ///   - valueRange: 数据值域；`nil` 时自动采样检测
    ///   - parallel: 是否并行；默认关闭
    static func multiArrayToImage(
        _ array: MLMultiArray,
        isNCHW: Bool,
        valueRange: ClosedRange<Float>? = nil,
        parallel: Bool = false
    ) throws -> CGImage {
        let layout = try TensorLayout(array: array, isNCHW: isNCHW)
        let kind = try elementKind(array.dataType)

        // 值域：优先用调用方传入，否则按数据类型采样
        let range: ClosedRange<Float>
        if let r = valueRange {
            range = r
        } else {
            switch kind {
            case .float32: range = detectValueRange(array: array, layout: layout, as: Float.self)
            case .float16: range = detectValueRange(array: array, layout: layout, as: Float16.self)
            case .double:  range = detectValueRange(array: array, layout: layout, as: Double.self)
            case .int32:   range = detectValueRange(array: array, layout: layout, as: Int32.self)
            }
        }

        // 1) 渲染为 RGBA 缓冲区
        var rgba: [UInt8]
        switch kind {
        case .float32:
            rgba = renderRGBA(array: array, layout: layout, range: range,
                              parallel: parallel, as: Float.self)
        case .float16:
            rgba = renderRGBA(array: array, layout: layout, range: range,
                              parallel: parallel, as: Float16.self)
        case .double:
            rgba = renderRGBA(array: array, layout: layout, range: range,
                              parallel: parallel, as: Double.self)
        case .int32:
            rgba = renderRGBA(array: array, layout: layout, range: range,
                              parallel: parallel, as: Int32.self)
        }

        // 2) 在缓冲区生命周期内生成 CGImage（makeImage 会拷贝数据）
        let w = layout.width
        let h = layout.height
        let bytesPerRow = w * 4
        return try rgba.withUnsafeMutableBytes { raw -> CGImage in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                throw InferenceError.tileProcessingFailed(
                    "创建输出 CGContext 失败 (\(w)x\(h))"
                )
            }
            guard let img = ctx.makeImage() else {
                throw InferenceError.tileProcessingFailed(
                    "生成 CGImage 失败 (\(w)x\(h))"
                )
            }
            return img
        }
    }

    private static func renderRGBA<T: TensorElement>(
        array: MLMultiArray,
        layout: TensorLayout,
        range: ClosedRange<Float>,
        parallel: Bool,
        as: T.Type
    ) -> [UInt8] {
        let src = array.dataPointer.assumingMemoryBound(to: T.self)
        let lo = range.lowerBound
        let span = range.upperBound - lo
        let scale: Float = span > 0 ? 255.0 / span : 0

        let channels  = layout.channels
        let rowStride = layout.rowStride
        let colStride = layout.columnStride
        let chStride  = layout.channelStride
        let h = layout.height
        let w = layout.width
        let bytesPerRow = w * 4

        var rgba = [UInt8](repeating: 255, count: h * bytesPerRow)

        rgba.withUnsafeMutableBufferPointer { buf in
            let out = buf.baseAddress!
            let body: (Int) -> Void = { y in
                let rowBase = y * rowStride
                let outRow  = out + y * bytesPerRow
                for x in 0..<w {
                    let base = rowBase + x * colStride
                    let r = T.toFloat(src[base])
                    let g = channels > 1 ? T.toFloat(src[base + chStride])     : r
                    let b = channels > 2 ? T.toFloat(src[base + 2 * chStride]) : r

                    let fr = Swift.min(Swift.max((r - lo) * scale, 0), 255)
                    let fg = Swift.min(Swift.max((g - lo) * scale, 0), 255)
                    let fb = Swift.min(Swift.max((b - lo) * scale, 0), 255)

                    outRow[x * 4]     = UInt8(fr.rounded())
                    outRow[x * 4 + 1] = UInt8(fg.rounded())
                    outRow[x * 4 + 2] = UInt8(fb.rounded())
                    outRow[x * 4 + 3] = 255
                }
            }
            if parallel {
                DispatchQueue.concurrentPerform(iterations: h, execute: body)
            } else {
                for y in 0..<h { body(y) }
            }
        }
        return rgba
    }

    // MARK: - 值域自动检测

    /// 采样 64 个跨通道、跨位置的点，根据经验规则推断值域。
    /// 规则：`max ∈ [0,1.5] && min ≥ -0.5` → 0...1；`max ∈ [0,255.5]` → 0...255；否则用 [min,max]。
    private static func detectValueRange<T: TensorElement>(
        array: MLMultiArray,
        layout: TensorLayout,
        as: T.Type
    ) -> ClosedRange<Float> {
        let ptr = array.dataPointer.assumingMemoryBound(to: T.self)
        let channels  = layout.channels
        let chStride  = layout.channelStride
        let rowStride = layout.rowStride
        let colStride = layout.columnStride
        let h = layout.height
        let w = layout.width

        var minVal: Float = .greatestFiniteMagnitude
        var maxVal: Float = -.greatestFiniteMagnitude

        let samples = Swift.min(64, h * w)
        for i in 0..<samples {
            let y = (i &* 7)  % h
            let x = (i &* 13) % w
            let c = channels > 1 ? (i % channels) : 0
            let off = c * chStride + y * rowStride + x * colStride
            let v = T.toFloat(ptr[off])
            if v.isFinite {
                minVal = Swift.min(minVal, v)
                maxVal = Swift.max(maxVal, v)
            }
        }

        guard minVal.isFinite, maxVal.isFinite, maxVal > minVal else {
            return 0...1
        }
        if maxVal <= 1.5 && minVal >= -0.5 { return 0...1 }
        if maxVal <= 255.5 && minVal >= -0.5 { return 0...255 }
        return minVal...maxVal
    }

    // MARK: - CGImage <-> CVPixelBuffer

    static func createPixelBuffer(
        from image: CGImage,
        width: Int,
        height: Int,
        pixelFormat: OSType,
        backgroundColor: CGColor? = nil
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, pixelFormat,
            attributes as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw InferenceError.tileProcessingFailed(
                "创建 PixelBuffer 失败 status=\(status), format=\(pixelFormat)"
            )
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw InferenceError.tileProcessingFailed("PixelBuffer 基址为空")
        }

        // 明确字节序，避免依赖默认行为
        let bitmapInfo: UInt32
        switch pixelFormat {
        case kCVPixelFormatType_32BGRA:
            bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        case kCVPixelFormatType_32RGBA:
            bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        default:
            throw InferenceError.tileProcessingFailed(
                "不支持的 pixelFormat: \(pixelFormat)"
            )
        }

        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            throw InferenceError.tileProcessingFailed("创建 PixelBuffer CGContext 失败")
        }

        if let bg = backgroundColor ?? defaultBackground as CGColor? {
            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    static func createCGImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        guard let cgImage = ciContext.createCGImage(
            ciImage,
            from: ciImage.extent,
            format: .RGBA8,
            colorSpace: colorSpace
        ) else {
            throw InferenceError.tileProcessingFailed("PixelBuffer 转 CGImage 失败")
        }
        return cgImage
    }
}