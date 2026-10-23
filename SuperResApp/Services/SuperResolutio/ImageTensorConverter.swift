// SuperResApp/Services/SuperResolutio/ImageTensorConverter.swift

import Foundation
import CoreML
import CoreImage
import UIKit

enum ImageTensorConverter {
    
    // MARK: - CGImage -> MLMultiArray (安全寻址版)
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

        // ⭐️ 彻底废弃 bindMemory，改用绝对安全的 NSNumber 下标
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
        return array
    }

    // MARK: - MLMultiArray -> CGImage (安全寻址版，告别撕裂)
    static func multiArrayToImage(_ array: MLMultiArray, isNCHW: Bool) throws -> CGImage {
        let shape = array.shape.map { $0.intValue }
        let height = isNCHW ? shape[2] : shape[1]
        let width = isNCHW ? shape[3] : shape[2]
        
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        // ⭐️ 绝对安全的读取，无论底层 Padding 怎么排，都不会读错位
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
        
        guard let context = CGContext(data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InferenceError.tileProcessingFailed("创建输出 CGContext 失败")
        }
        
        // 翻转回来（因为 CoreML 输出的数组有时会颠倒）
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