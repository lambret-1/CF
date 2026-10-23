// SuperResApp/Services/SuperResolutio/ImageTensorConverter.swift

import Foundation
import CoreML
import CoreImage
import UIKit

/// 负责 CGImage 和 MLMultiArray / CVPixelBuffer 的转换
enum ImageTensorConverter {
    
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
    
    // MARK: - CGImage -> MLMultiArray
    static func imageToMultiArray(_ image: CGImage, constraint: MLMultiArrayConstraint, isNCHW: Bool) throws -> MLMultiArray {
        let shape = constraint.shape.map { $0.intValue }
        guard shape.count >= 3 else { throw InferenceError.tileProcessingFailed("张量维度不支持") }
        
        let height = isNCHW ? shape[shape.count - 2] : shape[shape.count - 3]
        let width = isNCHW ? shape[shape.count - 1] : shape[shape.count - 2]
        
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: constraint.dataType)
        
        let bytesPerPixel = 4
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
        
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        let realBytesPerRow = context.bytesPerRow
        
        // ⭐️ 输入部分的处理：保持你原本安全的 NSNumber 逻辑（防止极个别模型输入不支持 Float）
        // 如果你的输入模型极多，这里也可以加指针优化，但我们先保输出不崩
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * realBytesPerRow + x * bytesPerPixel
                let r = Float(pixelData[pixelIndex]) / 255.0
                let g = Float(pixelData[pixelIndex + 1]) / 255.0
                let b = Float(pixelData[pixelIndex + 2]) / 255.0
                
                if isNCHW {
                    array[[0, 0, y, x] as [NSNumber]] = NSNumber(value: r)
                    array[[0, 1, y, x] as [NSNumber]] = NSNumber(value: g)
                    array[[0, 2, y, x] as [NSNumber]] = NSNumber(value: b)
                } else {
                    array[[0, y, x, 0] as [NSNumber]] = NSNumber(value: r)
                    array[[0, y, x, 1] as [NSNumber]] = NSNumber(value: g)
                    array[[0, y, x, 2] as [NSNumber]] = NSNumber(value: b)
                }
            }
        }
        return array
    }

    // MARK: - MLMultiArray -> CGImage
    static func multiArrayToImage(_ array: MLMultiArray, isNCHW: Bool) throws -> CGImage {
        let shape = array.shape.map { $0.intValue }
        
        // ⭐️ 安全校验：ESRGAN 某些版本可能是 5 维，或者是奇怪的 3 维
        guard shape.count >= 3 else { throw InferenceError.tileProcessingFailed("张量维度不支持: \(shape)") }
        
        let height = isNCHW ? shape[shape.count - 2] : shape[shape.count - 3]
        let width = isNCHW ? shape[shape.count - 1] : shape[shape.count - 2]
        let channels = isNCHW ? shape[shape.count - 3] : shape[shape.count - 1]
        
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        
        // ⭐️ 核心修复：判断数据类型。如果是不认识的类型，走最安全的 NSNumber 通道！
        let isFloat32 = array.dataType == .float32
        let isDouble = array.dataType == .double
        
        // 只有是 Float32 或者 Double 时，才走极速指针
        let arrayPointer = array.dataPointer
        
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                
                var r: Float = 0
                var g: Float = 0
                var b: Float = 0
                
                if isNCHW {
                    let channelStride = height * width
                    let baseIdx = y * width + x
                    
                    if isFloat32 {
                        let ptr = arrayPointer.assumingMemoryBound(to: Float.self)
                        r = ptr[baseIdx]
                        g = channels > 1 ? ptr[channelStride + baseIdx] : r
                        b = channels > 2 ? ptr[channelStride * 2 + baseIdx] : r
                    } else if isDouble {
                        let ptr = arrayPointer.assumingMemoryBound(to: Double.self)
                        r = Float(ptr[baseIdx])
                        g = channels > 1 ? Float(ptr[channelStride + baseIdx]) : r
                        b = channels > 2 ? Float(ptr[channelStride * 2 + baseIdx]) : r
                    } else {
                        // ⭐️ 兜底逻辑：针对 Float16 或未知类型
                        r = array[[0, 0, y, x] as [NSNumber]].floatValue
                        g = channels > 1 ? array[[0, 1, y, x] as [NSNumber]].floatValue : r
                        b = channels > 2 ? array[[0, 2, y, x] as [NSNumber]].floatValue : r
                    }
                } else {
                    let baseIdx = (y * width + x) * channels
                    if isFloat32 {
                        let ptr = arrayPointer.assumingMemoryBound(to: Float.self)
                        r = ptr[baseIdx]
                        g = channels > 1 ? ptr[baseIdx + 1] : r
                        b = channels > 2 ? ptr[baseIdx + 2] : r
                    } else if isDouble {
                        let ptr = arrayPointer.assumingMemoryBound(to: Double.self)
                        r = Float(ptr[baseIdx])
                        g = channels > 1 ? Float(ptr[baseIdx + 1]) : r
                        b = channels > 2 ? Float(ptr[baseIdx + 2]) : r
                    } else {
                        // ⭐️ 兜底逻辑：针对 Float16 或未知类型
                        r = array[[0, y, x, 0] as [NSNumber]].floatValue
                        g = channels > 1 ? array[[0, y, x, 1] as [NSNumber]].floatValue : r
                        b = channels > 2 ? array[[0, y, x, 2] as [NSNumber]].floatValue : r
                    }
                }
                
                // ⭐️ 修复 ESRGAN 范围可能超出 0~1 的问题（如 0~255 或 -1~1）
                // 这里假设如果是负数说明是 -1~1，如果是大于 2 说明是 0~255
                let clampR = r < 0 ? (r + 1.0) / 2.0 : (r > 2.0 ? r / 255.0 : r)
                let clampG = g < 0 ? (g + 1.0) / 2.0 : (g > 2.0 ? g / 255.0 : g)
                let clampB = b < 0 ? (b + 1.0) / 2.0 : (b > 2.0 ? b / 255.0 : b)
                
                pixelData[pixelIndex]     = UInt8(clamping: Int((min(max(clampR, 0.0), 1.0) * 255.0).rounded()))
                pixelData[pixelIndex + 1] = UInt8(clamping: Int((min(max(clampG, 0.0), 1.0) * 255.0).rounded()))
                pixelData[pixelIndex + 2] = UInt8(clamping: Int((min(max(clampB, 0.0), 1.0) * 255.0).rounded()))
                pixelData[pixelIndex + 3] = 255
            }
        }
        
        guard let context = CGContext(data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InferenceError.tileProcessingFailed("创建输出 CGContext 失败")
        }
        
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        
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
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
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
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw InferenceError.tileProcessingFailed("PixelBuffer 转 CGImage 失败")
        }
        return cgImage
    }
}