// SuperResApp/Services/SuperResolutio/ImageTensorConverter.swift

import Foundation
import CoreML
import CoreImage
import UIKit

/// 负责 CGImage 和 MLMultiArray / CVPixelBuffer 的转换
enum ImageTensorConverter {
    
    // MARK: - CGImage -> MLMultiArray (极速底层指针版)
    static func imageToMultiArray(_ image: CGImage, constraint: MLMultiArrayConstraint, isNCHW: Bool) throws -> MLMultiArray {
        let shape = constraint.shape.map { $0.intValue }
        let height = isNCHW ? shape[2] : shape[1]
        let width = isNCHW ? shape[3] : shape[2]
        
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: constraint.dataType)
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        
        guard let context = CGContext(data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InferenceError.tileProcessingFailed("创建 CGContext 失败")
        }
        
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // ⭐️ 核心优化：如果数据类型是 float32，直接操作底层内存指针，彻底抛弃 NSNumber 的创建
        if constraint.dataType == .float32 {
            let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: height * width * 3)
            
            for y in 0..<height {
                for x in 0..<width {
                    let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                    let r = Float32(pixelData[pixelIndex]) / 255.0
                    let g = Float32(pixelData[pixelIndex + 1]) / 255.0
                    let b = Float32(pixelData[pixelIndex + 2]) / 255.0
                    
                    if isNCHW {
                        let offset = y * width + x
                        ptr[offset] = r
                        ptr[height * width + offset] = g
                        ptr[2 * height * width + offset] = b
                    } else {
                        let offset = (y * width + x) * 3
                        ptr[offset] = r
                        ptr[offset + 1] = g
                        ptr[offset + 2] = b
                    }
                }
            }
        } else {
            // 兜底方案：针对罕见的非 float32 模型使用原有的 NSNumber 逻辑
            for y in 0..<height {
                for x in 0..<width {
                    let pixelIndex = y * bytesPerRow + x * bytesPerPixel
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
        }
        
        return array
    }

    // MARK: - MLMultiArray -> CGImage (极速底层指针版)
    static func multiArrayToImage(_ array: MLMultiArray, isNCHW: Bool) throws -> CGImage {
        let shape = array.shape.map { $0.intValue }
        let height = isNCHW ? shape[2] : shape[1]
        let width = isNCHW ? shape[3] : shape[2]
        
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        // ⭐️ 核心优化：直接读取内存指针
        if array.dataType == .float32 {
            let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: height * width * 3)
            
            for y in 0..<height {
                for x in 0..<width {
                    let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                    
                    let r: Float32
                    let g: Float32
                    let b: Float32
                    
                    if isNCHW {
                        let offset = y * width + x
                        r = ptr[offset]
                        g = ptr[height * width + offset]
                        b = ptr[2 * height * width + offset]
                    } else {
                        let offset = (y * width + x) * 3
                        r = ptr[offset]
                        g = ptr[offset + 1]
                        b = ptr[offset + 2]
                    }
                    
                    pixelData[pixelIndex] = UInt8(clamping: Int((r * 255.0).rounded()))
                    pixelData[pixelIndex + 1] = UInt8(clamping: Int((g * 255.0).rounded()))
                    pixelData[pixelIndex + 2] = UInt8(clamping: Int((b * 255.0).rounded()))
                    pixelData[pixelIndex + 3] = 255
                }
            }
        } else {
            // 兜底方案
            for y in 0..<height {
                for x in 0..<width {
                    let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                    
                    let r: Float
                    let g: Float
                    let b: Float
                    
                    if isNCHW {
                        r = array[[0, 0, y, x] as [NSNumber]].floatValue
                        g = array[[0, 1, y, x] as [NSNumber]].floatValue
                        b = array[[0, 2, y, x] as [NSNumber]].floatValue
                    } else {
                        r = array[[0, y, x, 0] as [NSNumber]].floatValue
                        g = array[[0, y, x, 1] as [NSNumber]].floatValue
                        b = array[[0, y, x, 2] as [NSNumber]].floatValue
                    }
                    
                    pixelData[pixelIndex] = UInt8(clamping: Int((r * 255.0).rounded()))
                    pixelData[pixelIndex + 1] = UInt8(clamping: Int((g * 255.0).rounded()))
                    pixelData[pixelIndex + 2] = UInt8(clamping: Int((b * 255.0).rounded()))
                    pixelData[pixelIndex + 3] = 255
                }
            }
        }
        
        guard let context = CGContext(data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InferenceError.tileProcessingFailed("创建输出 CGContext 失败")
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        
        return context.makeImage()!
    }

    // MARK: - CGImage -> CVPixelBuffer
    static func createPixelBuffer(from image: CGImage, width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { throw InferenceError.tileProcessingFailed("创建 PixelBuffer 失败") }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        
        context?.translateBy(x: 0, y: CGFloat(height))
        context?.scaleBy(x: 1.0, y: -1.0)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - CVPixelBuffer -> CGImage
    static func createCGImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw InferenceError.tileProcessingFailed("创建 CGContext 失败")
        }
        context.translateBy(x: 0, y: CGFloat(CVPixelBufferGetHeight(pixelBuffer)))
        context.scaleBy(x: 1.0, y: -1.0)
        
        return context.makeImage()!
    }
}