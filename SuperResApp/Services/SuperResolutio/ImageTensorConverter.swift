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
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw InferenceError.tileProcessingFailed("创建 CGContext 失败")
        }
        
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        let realBytesPerRow = context.bytesPerRow
        let arrayPointer = array.dataPointer
        
        // 统一处理输入类型 (输入模型通常兼容 Float32)
        let isDouble = constraint.dataType == .double
        
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * realBytesPerRow + x * bytesPerPixel
                let r = Float(pixelData[pixelIndex]) / 255.0
                let g = Float(pixelData[pixelIndex + 1]) / 255.0
                let b = Float(pixelData[pixelIndex + 2]) / 255.0
                
                if isNCHW {
                    let channelStride = height * width
                    let baseIdx = y * width + x
                    if isDouble {
                        let ptr = arrayPointer.assumingMemoryBound(to: Double.self)
                        ptr[baseIdx] = Double(r)
                        ptr[channelStride + baseIdx] = Double(g)
                        ptr[channelStride * 2 + baseIdx] = Double(b)
                    } else {
                        let ptr = arrayPointer.assumingMemoryBound(to: Float.self)
                        ptr[baseIdx] = r
                        ptr[channelStride + baseIdx] = g
                        ptr[channelStride * 2 + baseIdx] = b
                    }
                } else {
                    let baseIdx = (y * width + x) * 3
                    if isDouble {
                        let ptr = arrayPointer.assumingMemoryBound(to: Double.self)
                        ptr[baseIdx] = Double(r)
                        ptr[baseIdx + 1] = Double(g)
                        ptr[baseIdx + 2] = Double(b)
                    } else {
                        let ptr = arrayPointer.assumingMemoryBound(to: Float.self)
                        ptr[baseIdx] = r
                        ptr[baseIdx + 1] = g
                        ptr[baseIdx + 2] = b
                    }
                }
            }
        }
        return array
    }

    // MARK: - MLMultiArray -> CGImage (核心修复区)
    static func multiArrayToImage(_ array: MLMultiArray, isNCHW: Bool) throws -> CGImage {
        let shape = array.shape.map { $0.intValue }
        guard shape.count >= 3 else { throw InferenceError.tileProcessingFailed("张量维度不支持") }
        
        let height = isNCHW ? shape[shape.count - 2] : shape[shape.count - 3]
        let width = isNCHW ? shape[shape.count - 1] : shape[shape.count - 2]
        let channels = isNCHW ? shape[shape.count - 3] : shape[shape.count - 1]
        
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        
        let dataType = array.dataType
        let arrayPointer = array.dataPointer
        
        // ⭐️ 核心修复 1：判断是否支持指针高速读取。如果是 Float16，为了防崩溃，退回安全读取
        let canUsePointer = (dataType == .float32 || dataType == .double)
        let isDouble = (dataType == .double)
        
        // ⭐️ 核心修复 2：判断值域。如果模型输出可能是 0-255，通过采样动态判断
        // 采样中心点的像素值，大于 1.5 就认为是 0-255 的域
        var scaleFactor: Float = 1.0
        let midIdx = (height / 2) * width + (width / 2)
        let sampleVal: Float
        if canUsePointer {
            if isDouble {
                sampleVal = Float(arrayPointer.assumingMemoryBound(to: Double.self)[midIdx])
            } else {
                sampleVal = arrayPointer.assumingMemoryBound(to: Float.self)[midIdx]
            }
        } else {
            let idx: [NSNumber] = isNCHW ? [0, 0, height/2, width/2] : [0, height/2, width/2, 0]
            sampleVal = array[idx].floatValue
        }
        if sampleVal > 1.5 { scaleFactor = 255.0 }
        
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                
                let r: Float
                let g: Float
                let b: Float
                
                if canUsePointer {
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
                } else {
                    // ⭐️ 修复 3：如果是 Float16 等不支持直接内存映射的类型，使用绝对的 NSNumber 读取防崩溃
                    if isNCHW {
                        r = array[[0, 0, y, x] as [NSNumber]].floatValue
                        g = channels > 1 ? array[[0, 1, y, x] as [NSNumber]].floatValue : r
                        b = channels > 2 ? array[[0, 2, y, x] as [NSNumber]].floatValue : r
                    } else {
                        r = array[[0, y, x, 0] as [NSNumber]].floatValue
                        g = channels > 1 ? array[[0, y, x, 1] as [NSNumber]].floatValue : r
                        b = channels > 2 ? array[[0, y, x, 2] as [NSNumber]].floatValue : r
                    }
                }
                
                // 根据动态判断的 scaleFactor 转换并限制在 0-255
                let finalR = min(max(r * scaleFactor, 0.0), 255.0)
                let finalG = min(max(g * scaleFactor, 0.0), 255.0)
                let finalB = min(max(b * scaleFactor, 0.0), 255.0)
                
                pixelData[pixelIndex]     = UInt8(finalR.rounded())
                pixelData[pixelIndex + 1] = UInt8(finalG.rounded())
                pixelData[pixelIndex + 2] = UInt8(finalB.rounded())
                pixelData[pixelIndex + 3] = 255 // Alpha
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