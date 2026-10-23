// SuperResApp/Services/SuperResolutio/ImageTensorConverter.swift

import Foundation
import CoreML
import CoreImage
import UIKit

/// 负责 CGImage 和 MLMultiArray / CVPixelBuffer 的转换
enum ImageTensorConverter {
    
    // 静态复用 CIContext，处理 PixelBuffer 深拷贝更快更稳
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
    
    // MARK: - CGImage -> MLMultiArray
    static func imageToMultiArray(_ image: CGImage, constraint: MLMultiArrayConstraint, isNCHW: Bool) throws -> MLMultiArray {
        let shape = constraint.shape.map { $0.intValue }
        // 兼容可能的 3 维输入 (如 1xHxW)
        guard shape.count >= 3 else { throw InferenceError.tileProcessingFailed("张量维度不支持") }
        
        let height = isNCHW ? shape[shape.count - 2] : shape[shape.count - 3]
        let width = isNCHW ? shape[shape.count - 1] : shape[shape.count - 2]
        
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: constraint.dataType)
        
        // 绘制到 CGContext
        let bytesPerPixel = 4
        // ⭐️ 修复 3：使用系统自动对齐的 bytesPerRow
        var pixelData = [UInt8](repeating: 0, count: height * width * bytesPerPixel)
        
        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue // RGBA
        ) else {
            throw InferenceError.tileProcessingFailed("创建 CGContext 失败")
        }
        
        // CoreGraphics 默认原点在左下角，做翻转以匹配左上角坐标系
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        let realBytesPerRow = context.bytesPerRow
        
        // ⭐️ 修复 2：使用 dataPointer 直接内存操作（性能提升数十倍）
        let arrayPointer = array.dataPointer
        let isFloat16 = constraint.dataType == .float16
        let isDouble = constraint.dataType == .double
        
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * realBytesPerRow + x * bytesPerPixel
                
                // 将 UInt8 (0-255) 归一化为 0.0-1.0
                let r = Float(pixelData[pixelIndex]) / 255.0
                let g = Float(pixelData[pixelIndex + 1]) / 255.0
                let b = Float(pixelData[pixelIndex + 2]) / 255.0
                
                // 计算 Tensor 的内存偏移量
                // 假设 batch size 为 1
                let offsetR: Int
                let offsetG: Int
                let offsetB: Int
                
                if isNCHW {
                    let channelStride = height * width
                    let baseIdx = y * width + x
                    offsetR = baseIdx
                    offsetG = channelStride + baseIdx
                    offsetB = channelStride * 2 + baseIdx
                } else {
                    let baseIdx = (y * width + x) * 3 // NHWC 通常只有 3 通道输出
                    offsetR = baseIdx
                    offsetG = baseIdx + 1
                    offsetB = baseIdx + 2
                }
                
                // 直接指针赋值
                if isDouble {
                    let ptr = arrayPointer.assumingMemoryBound(to: Double.self)
                    ptr[offsetR] = Double(r)
                    ptr[offsetG] = Double(g)
                    ptr[offsetB] = Double(b)
                } else if isFloat16 {
                    // 注意：Swift 原生不支持直接写 Float16，如果模型是 Float16，建议先用 Float32 中转
                    // 这里为了保证绝对安全，退回 NSNumber 赋值（极少模型输入用 float16）
                    if isNCHW {
                        array[[0, 0, y, x] as [NSNumber]] = NSNumber(value: r)
                        array[[0, 1, y, x] as [NSNumber]] = NSNumber(value: g)
                        array[[0, 2, y, x] as [NSNumber]] = NSNumber(value: b)
                    } else {
                        array[[0, y, x, 0] as [NSNumber]] = NSNumber(value: r)
                        array[[0, y, x, 1] as [NSNumber]] = NSNumber(value: g)
                        array[[0, y, x, 2] as [NSNumber]] = NSNumber(value: b)
                    }
                } else {
                    // 默认按 Float32 处理（最常见）
                    let ptr = arrayPointer.assumingMemoryBound(to: Float.self)
                    ptr[offsetR] = r
                    ptr[offsetG] = g
                    ptr[offsetB] = b
                }
            }
        }
        return array
    }

    // MARK: - MLMultiArray -> CGImage
    static func multiArrayToImage(_ array: MLMultiArray, isNCHW: Bool) throws -> CGImage {
        let shape = array.shape.map { $0.intValue }
        guard shape.count >= 3 else { throw InferenceError.tileProcessingFailed("张量维度不支持") }
        
        let height = isNCHW ? shape[shape.count - 2] : shape[shape.count - 3]
        let width = isNCHW ? shape[shape.count - 1] : shape[shape.count - 2]
        let channels = isNCHW ? shape[shape.count - 3] : shape[shape.count - 1]
        
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        
        let arrayPointer = array.dataPointer
        let isDouble = array.dataType == .double
        
        // ⭐️ 修复 2：使用指针直接读取
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                
                let r: Float
                let g: Float
                let b: Float
                
                if isNCHW {
                    let channelStride = height * width
                    let baseIdx = y * width + x
                    
                    if isDouble {
                        let ptr = arrayPointer.assumingMemoryBound(to: Double.self)
                        r = Float(ptr[baseIdx])
                        g = channels > 1 ? Float(ptr[channelStride + baseIdx]) : r
                        b = channels > 2 ? Float(ptr[channelStride * 2 + baseIdx]) : r
                    } else {
                        let ptr = arrayPointer.assumingMemoryBound(to: Float.self)
                        r = ptr[baseIdx]
                        g = channels > 1 ? ptr[channelStride + baseIdx] : r
                        b = channels > 2 ? ptr[channelStride * 2 + baseIdx] : r
                    }
                } else {
                    let baseIdx = (y * width + x) * channels
                    if isDouble {
                        let ptr = arrayPointer.assumingMemoryBound(to: Double.self)
                        r = Float(ptr[baseIdx])
                        g = channels > 1 ? Float(ptr[baseIdx + 1]) : r
                        b = channels > 2 ? Float(ptr[baseIdx + 2]) : r
                    } else {
                        let ptr = arrayPointer.assumingMemoryBound(to: Float.self)
                        r = ptr[baseIdx]
                        g = channels > 1 ? ptr[baseIdx + 1] : r
                        b = channels > 2 ? ptr[baseIdx + 2] : r
                    }
                }
                
                // 确保浮点值在 0-1 之间，防止模型输出异常导致越界崩溃
                pixelData[pixelIndex]     = UInt8(clamping: Int((min(max(r, 0.0), 1.0) * 255.0).rounded()))
                pixelData[pixelIndex + 1] = UInt8(clamping: Int((min(max(g, 0.0), 1.0) * 255.0).rounded()))
                pixelData[pixelIndex + 2] = UInt8(clamping: Int((min(max(b, 0.0), 1.0) * 255.0).rounded()))
                pixelData[pixelIndex + 3] = 255 // Alpha
            }
        }
        
        guard let context = CGContext(data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InferenceError.tileProcessingFailed("创建输出 CGContext 失败")
        }
        
        // 保持原有的垂直翻转逻辑，因为 RGBA 的 Buffer 画进 CGContext 坐标系需要翻转
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        
        // ⭐️ 修复 4：移除强制解包
        guard let cgImage = context.makeImage() else {
            throw InferenceError.tileProcessingFailed("生成 CGImage 失败")
        }
        return cgImage
    }

    // MARK: - CGImage -> CVPixelBuffer
    static func createPixelBuffer(from image: CGImage, width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { throw InferenceError.tileProcessingFailed("创建 PixelBuffer 失败") }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        // ⭐️ 修复 4：防止 CGContext 创建失败
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            // 注意：如果你的模型需要 BGR，这里用 kCVPixelFormatType_32BGRA 时，对应的是 premultipliedFirst | byteOrder32Little
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw InferenceError.tileProcessingFailed("创建 Buffer CGContext 失败")
        }
        
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - CVPixelBuffer -> CGImage
    static func createCGImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        // ⭐️ 修复 1：绝对不能用 context.makeImage() 直接返回，否则解锁后会野指针崩溃。
        // 使用 CIContext 进行深拷贝转换，既安全又能自动处理颜色空间。
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // CoreML 输出的 Buffer 本身就是正方向（但在 CGImage 里是倒的）
        // 一般不需要在这里做翻转，因为上层引擎（如 TilingEngine）已经有统一的翻转逻辑了
        
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw InferenceError.tileProcessingFailed("PixelBuffer 转 CGImage 失败")
        }
        return cgImage
    }
}