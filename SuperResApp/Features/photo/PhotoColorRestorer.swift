import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import ImageIO
import simd

// MARK: - 公共类型

struct IlluminantRGB {
    var r: Double, g: Double, b: Double
    static let d65 = IlluminantRGB(r: 0.95047, g: 1.0, b: 1.08883)
}

enum CATMethod: String, CaseIterable {
    case vonKries, bradford, cat02, cmccat2000, xyzScaling
}

enum SceneType: String { case portrait, landscape, night, document, generic }

struct IlluminantEstimate {
    let method: String
    var rgb: IlluminantRGB          // 已 g=1 归一化
    var confidence: Double          // 0…1
}

struct Diagnostics {
    var estimates: [IlluminantEstimate] = []
    var fused: IlluminantRGB = IlluminantRGB(r: 1, g: 1, b: 1)
    var catMethod: CATMethod = .bradford
    var gainsLMS: (Double, Double, Double) = (1, 1, 1)
    var exposureComp: Double = 1.0
    var iterations: Int = 0
    var deltaEBefore: Double = 0
    var deltaEAfter: Double = 0
    var sceneType: SceneType = .generic
    var skippedPixels: Int = 0
}

struct RestorerOptions {
    // 光源估计
    var enableWhitePatch = true
    var enableGrayWorld = true
    var enableShadesOfGray = true           // p=6
    var enableGrayEdge = true
    var enableNeutralFilter = true
    var enableDarkChannelWeighting = true
    var enableRetinex = true
    var enableLocalPartition = true
    var enableGamutConstraint = true
    var enableDualTemperature = true
    var enableBayesianPrior = false         // 需 prior provider
    var enableMLIlluminant = false          // 需 ML provider
    // CAT
    var catMethod: CATMethod? = nil         // nil → 按场景自动
    // 曝光/动态范围
    var enableExposureDecoupling = true
    var enableHighlightRecovery = true
    var enableShadowLift = false
    var enableBlackLevel = true
    var enableToneMapping = false
    // 记忆色 / 后处理
    var enableMemoryColor = true
    var enableHueTwistCorrection = true
    var enableSaturationHighlightCompress = true
    var enablePerChannelCurve = true
    // 预处理
    var enableNoiseAwareWeighting = true
    var enableVignettingCorrection = false  // 需 lens profile
    var enableChromaticAberration = false   // 需 lens profile
    // 迭代 & 性能
    var enableIterativeRefinement = true
    var maxIterations = 3
    var analysisScale: CGFloat = 0.05
}

// MARK: - 外部依赖协议（默认 no-op）

protocol CameraColorMatrixProvider { func matrix(for model: String?) -> simd_double3x3? }
protocol LensProfileProvider {
    func vignetting(for lens: String?) -> (k1: Double, k2: Double)?
    func chromaticAberration(for lens: String?) -> (scaleR: Double, scaleB: Double)?
}
protocol LUT3DProvider { func lut(for scene: SceneType) -> (size: Int, data: [Float])? }
protocol MLIlluminantProvider { func estimate(ciImage: CIImage) -> IlluminantEstimate? }
protocol BayesianPriorProvider { func prior(for scene: SceneType) -> (mean: IlluminantRGB, cov: simd_double3x3)? }
protocol ReferenceComparator { func psnr(_ a: UIImage, _ b: UIImage) -> Double?; func ssim(_ a: UIImage, _ b: UIImage) -> Double? }
protocol TemporalConsistency { func smooth(_ current: IlluminantRGB) -> IlluminantRGB }

// MARK: - 主类

final class PhotoColorRestorer {
    private let ciContext: CIContext
    private let linearSRGB: CGColorSpace
    private let sRGB: CGColorSpace
    private let options: RestorerOptions

    var cameraMatrixProvider: CameraColorMatrixProvider?
    var lensProfileProvider: LensProfileProvider?
    var lutProvider: LUT3DProvider?
    var mlProvider: MLIlluminantProvider?
    var priorProvider: BayesianPriorProvider?
    var referenceComparator: ReferenceComparator?
    var temporalConsistency: TemporalConsistency?

    init?(options: RestorerOptions = RestorerOptions()) {
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        self.linearSRGB = linear; self.sRGB = srgb
        self.options = options
        self.ciContext = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: linear
        ])
    }

    // MARK: 主入口
    func autoRestoreColor(image: UIImage, previewScale: CGFloat? = nil) -> (UIImage?, Diagnostics)? {
        var diag = Diagnostics()

        // [修复] 输入方向归一化 —— CIImage 不应用 UIImage.orientation
        let normalized = image.normalizedOrientation()
        guard let ciImage = CIImage(image: normalized) else { return (image, diag) }

        // 1. 预处理：暗角 / 色差（[接口]）
        let preprocessed = preprocess(ciImage, diag: &diag)

        // 2. 缩小分析
        let scale = previewScale ?? options.analysisScale
        guard let small = downsample(preprocessed, scale: scale) else { return (image, diag) }
        let extent = small.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0 else { return (image, diag) }

        var bitmap = [Float](repeating: 0, count: w*h*4)
        ciContext.render(small, toBitmap: &bitmap,
                         rowBytes: w*4*MemoryLayout<Float>.size,
                         bounds: extent, format: .RGBAf, colorSpace: nil)

        // 3. 场景理解
        let scene = analyzeScene(bitmap: bitmap, w: w, h: h, cgImage: normalized.cgImage)
        diag.sceneType = scene.type

        // 4. 像素提取（alpha 过滤 + 修剪）
        let pixels = extractPixels(bitmap: bitmap, w: w, h: h, diag: &diag)
        guard pixels.count > 200 else { return (image, diag) }
        let valid = trimHistogram(pixels)

        // 5. 多光源估计 + 融合（迭代）
        var fused = IlluminantRGB(r: 1, g: 1, b: 1)
        var iterationCount = options.enableIterativeRefinement ? options.maxIterations : 1
        for it in 0..<iterationCount {
            let ests = runEstimators(pixels: valid, scene: scene,
                                     bitmap: bitmap, w: w, h: h, ciImage: small)
            if it == 0 { diag.estimates = ests }
            guard let f = fuse(ests: ests, pixels: valid) else {
                return (image, diag)
            }
            let delta = abs(f.r - fused.r) + abs(f.g - fused.g) + abs(f.b - fused.b)
            fused = f
            if delta < 0.01 { iterationCount = it + 1; break }
        }
        diag.iterations = iterationCount
        diag.fused = fused

        // [接口] 时域一致性
        if let ts = temporalConsistency { fused = ts.smooth(fused) }

        // 6. CAT
        let cat = options.catMethod ?? catForScene(scene.type)
        diag.catMethod = cat
        guard let gains = computeCATGains(fused: fused, method: cat) else { return (image, diag) }
        diag.gainsLMS = gains
        let M_final = buildFinalMatrix(fused: fused, gains: gains, method: cat)

        // 7. 应用 WB 矩阵
        guard let wbImage = applyMatrix(M_final, to: preprocessed) else { return (image, diag) }

        // 8. 曝光解耦（保持 Y，不做 #1 的过曝）
        let expComp = estimateExposureCompensation(bitmap: bitmap, w: w, h: h)
        diag.exposureComp = expComp
        let exposed = options.enableExposureDecoupling
            ? applyExposure(wbImage, factor: expComp) : wbImage

        // 9. 后处理链
        var processed = exposed
        if options.enableHighlightRecovery { processed = recoverHighlights(processed) }
        if options.enableShadowLift { processed = liftShadows(processed) }
        if options.enableBlackLevel { processed = correctBlackLevel(processed) }
        if options.enableHueTwistCorrection { processed = correctHueTwist(processed, M: M_final) }
        if options.enableSaturationHighlightCompress { processed = compressSatHighlights(processed) }
        if options.enableMemoryColor { processed = applyMemoryColor(processed, scene: scene) }
        if options.enablePerChannelCurve { processed = applyPerChannelCurve(processed) }
        if options.enableToneMapping { processed = toneMap(processed) }
        if let lut = lutProvider?.lut(for: scene.type) { processed = applyLUT3D(processed, lut: lut) }

        // 10. 输出
        let clamped = processed.clampedToExtent().cropped(to: preprocessed.extent)
        guard let cg = ciContext.createCGImage(clamped, from: clamped.extent,
                                               format: .RGBA8, colorSpace: sRGB) else {
            return (image, diag)
        }
        let out = UIImage(cgImage: cg, scale: normalized.scale, orientation: .up)

        // 11. 评估
        diag.deltaEBefore = meanDeltaEOfNeutrals(pixels: valid, fused: IlluminantRGB(r: 1, g: 1, b: 1))
        diag.deltaEAfter = meanDeltaEOfNeutrals(pixels: valid, fused: fused)
        return (out, diag)
    }

    // MARK: - 预处理（暗角 + 色差 + CCM）

    private func preprocess(_ img: CIImage, diag: inout Diagnostics) -> CIImage {
        var out = img
        // [接口] CCM
        if let ccm = cameraMatrixProvider?.matrix(for: nil) {
            let f = CIFilter.colorMatrix()
            f.inputImage = out
            f.rVector = CIVector(x: ccm[0][0], y: ccm[0][1], z: ccm[0][2], w: 0)
            f.gVector = CIVector(x: ccm[1][0], y: ccm[1][1], z: ccm[1][2], w: 0)
            f.bVector = CIVector(x: ccm[2][0], y: ccm[2][1], z: ccm[2][2], w: 0)
            if let o = f.outputImage { out = o }
        }
        // [接口] 暗角（径向衰减逆校正）
        if options.enableVignettingCorrection,
           let vp = lensProfileProvider?.vignetting(for: nil) {
            let center = CIVector(x: out.extent.midX, y: out.extent.midY)
            let f = CIFilter.vignetteEffect()
            f.inputImage = out
            f.center = CGPoint(x: out.extent.midX, y: out.extent.midY)
            f.radius = Float(max(out.extent.width, out.extent.height) / 2)
            f.intensity = Float(-vp.k1 * 2)
            if let o = f.outputImage { out = o }
        }
        // [接口] 色差（简化：R/B 微缩放）
        if options.enableChromaticAberration,
           let ca = lensProfileProvider?.chromaticAberration(for: nil) {
            let scaleR = CIFilter.lanczosScaleTransform()
            scaleR.inputImage = out
            scaleR.scale = Float(ca.scaleR)
            if let o = scaleR.outputImage { out = o }
            let scaleB = CIFilter.lanczosScaleTransform()
            scaleB.inputImage = out
            scaleB.scale = Float(ca.scaleB)
            if let o = scaleB.outputImage { out = o }
        }
        return out
    }

    private func downsample(_ img: CIImage, scale: CGFloat) -> CIImage? {
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = img
        f.scale = Float(max(scale, 0.001))
        f.aspectRatio = 1.0
        return f.outputImage
    }

    // MARK: - 像素提取（含 alpha 过滤）

    private func extractPixels(bitmap: [Float], w: Int, h: Int, diag: inout Diagnostics) -> [ (r: Float, g: Float, b: Float, luma: Float) ] {
        var out: [(Float, Float, Float, Float)] = []
        out.reserveCapacity(w*h)
        var skipped = 0
        for i in 0..<(w*h) {
            let o = i*4
            let a = bitmap[o+3]
            guard a >= 0.5 else { skipped += 1; continue }
            let r = bitmap[o], g = bitmap[o+1], b = bitmap[o+2]
            out.append((r, g, b, 0.2126*r + 0.7152*g + 0.0722*b))
        }
        diag.skippedPixels = skipped
        return out
    }

    private func trimHistogram(_ px: [ (r: Float, g: Float, b: Float, luma: Float) ]) -> [ (r: Float, g: Float, b: Float, luma: Float) ] {
        let sorted = px.sorted { $0.3 < $1.3 }
        let n = Int(Float(sorted.count) * 0.02)
        guard sorted.count > n*2 + 100 else { return sorted }
        return Array(sorted[n..<(sorted.count - n)])
    }

    // MARK: - 场景理解（分类 + 人脸 + 天空/植被 + 文档）

    struct Scene { var type: SceneType; var faceMask: CIImage?; var skyMask: CIImage?; var vegMask: CIImage?; var docRect: CGRect? }

    private func analyzeScene(bitmap: [Float], w: Int, h: Int, cgImage: CGImage?) -> Scene {
        // 场景分类（启发式；[接口] 可替换为 Core ML）
        var meanY = 0.0, varSum = 0.0
        var blueRatio = 0.0, greenRatio = 0.0, skinRatio = 0.0
        for i in 0..<(w*h) {
            let o = i*4
            let r = bitmap[o], g = bitmap[o+1], b = bitmap[o+2]
            let y = 0.2126*r + 0.7152*g + 0.0722*b
            meanY += Double(y)
            varSum += Double((y - 0.5) * (y - 0.5))
            if b > r && b > g { blueRatio += 1 }
            if g > r && g > b { greenRatio += 1 }
            // 肤色粗判
            if r > 0.3 && r > g && g > b && (r - b) > 0.15 { skinRatio += 1 }
        }
        let n = Double(w*h)
        meanY /= n; varSum /= n
        blueRatio /= n; greenRatio /= n; skinRatio /= n

        // 人脸
        var faceMask: CIImage? = nil
        var hasFace = false
        if let cg = cgImage {
            let req = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([req])
            if let results = req.results, !results.isEmpty {
                hasFace = true
                faceMask = buildMaskRect(results.map { $0.boundingBox }, w: w, h: h)
            }
        }
        // 文档
        var docRect: CGRect? = nil
        if let cg = cgImage {
            let req = VNDetectRectanglesRequest()
            req.minimumSize = 0.3
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            try? handler.perform([req])
            if let r = req.results?.first { docRect = r.boundingBox }
        }
        // 天空 / 植被 mask（HSV 启发式）
        let skyMask = (blueRatio > 0.25) ? buildColorMask(bitmap: bitmap, w: w, h: h, hue: .blue) : nil
        let vegMask = (greenRatio > 0.2) ? buildColorMask(bitmap: bitmap, w: w, h: h, hue: .green) : nil

        let type: SceneType
        if docRect != nil { type = .document }
        else if meanY < 0.08 { type = .night }
        else if hasFace || skinRatio > 0.08 { type = .portrait }
        else if blueRatio > 0.25 || greenRatio > 0.2 { type = .landscape }
        else { type = .generic }

        return Scene(type: type, faceMask: faceMask, skyMask: skyMask, vegMask: vegMask, docRect: docRect)
    }

    private func buildMaskRect(_ rects: [CGRect], w: Int, h: Int) -> CIImage? {
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: cs, bitmapInfo: 0) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        for r in rects {
            ctx.fill(CGRect(x: r.minX*CGFloat(w), y: r.minY*CGFloat(h), width: r.width*CGFloat(w), height: r.height*CGFloat(h)))
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    enum HueBand { case blue, green }
    private func buildColorMask(bitmap: [Float], w: Int, h: Int, hue: HueBand) -> CIImage? {
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: cs, bitmapInfo: 0) else { return nil }
        guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w*h) else { return nil }
        for i in 0..<(w*h) {
            let o = i*4
            let r = Double(bitmap[o]), g = Double(bitmap[o+1]), b = Double(bitmap[o+2])
            let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
            let sat = maxC > 1e-6 ? (maxC - minC) / maxC : 0
            var val: UInt8 = 0
            if sat > 0.2 {
                switch hue {
                case .blue:  if b > r && b > g { val = 255 }
                case .green: if g > r && g > b { val = 255 }
                }
            }
            data[i] = val
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
    // MARK: - 光源估计器（10 种 + 融合）

    private func runEstimators(pixels: [ (r: Float, g: Float, b: Float, luma: Float) ],
                               scene: Scene, bitmap: [Float], w: Int, h: Int, ciImage: CIImage) -> [IlluminantEstimate] {
        var results: [IlluminantEstimate] = []

        // [1] White Patch（Max-RGB）
        if options.enableWhitePatch {
            let mr = pixels.map { Double($0.0) }.max() ?? 1
            let mg = pixels.map { Double($0.1) }.max() ?? 1
            let mb = pixels.map { Double($0.2) }.max() ?? 1
            results.append(IlluminantEstimate(method: "WhitePatch",
                rgb: normalizeGM(IlluminantRGB(r: mr, g: mg, b: mb)), confidence: 0.4))
        }

        // [2] Gray World
        if options.enableGrayWorld {
            let n = Double(pixels.count)
            let mr = pixels.reduce(0.0) { $0 + Double($1.0) } / n
            let mg = pixels.reduce(0.0) { $0 + Double($1.1) } / n
            let mb = pixels.reduce(0.0) { $0 + Double($1.2) } / n
            results.append(IlluminantEstimate(method: "GrayWorld",
                rgb: normalizeGM(IlluminantRGB(r: mr, g: mg, b: mb)), confidence: 0.5))
        }

        // [3] Shades of Gray (Minkowski p=6)
        if options.enableShadesOfGray {
            let p = 6.0; let n = Double(pixels.count)
            let sr = pixels.reduce(0.0) { $0 + pow(Double($1.0), p) }
            let sg = pixels.reduce(0.0) { $0 + pow(Double($1.1), p) }
            let sb = pixels.reduce(0.0) { $0 + pow(Double($1.2), p) }
            let er = pow(sr/n, 1/p), eg = pow(sg/n, 1/p), eb = pow(sb/n, 1/p)
            results.append(IlluminantEstimate(method: "ShadesOfGray(p=6)",
                rgb: normalizeGM(IlluminantRGB(r: er, g: eg, b: eb)), confidence: 0.65))
        }

        // [4] Gray Edge（梯度域）
        if options.enableGrayEdge {
            var sr = 0.0, sg = 0.0, sb = 0.0; var cnt = 0.0
            for y in 1..<(h-1) {
                for x in 1..<(w-1) {
                    let i0 = (y*w + x)*4
                    let iR = (y*w + x+1)*4
                    let iD = ((y+1)*w + x)*4
                    let dr = abs(Double(bitmap[iR]   - bitmap[i0])) + abs(Double(bitmap[iD]   - bitmap[i0]))
                    let dg = abs(Double(bitmap[iR+1] - bitmap[i0+1])) + abs(Double(bitmap[iD+1] - bitmap[i0+1]))
                    let db = abs(Double(bitmap[iR+2] - bitmap[i0+2])) + abs(Double(bitmap[iD+2] - bitmap[i0+2]))
                    let m = max(dr, max(dg, db)); guard m > 0.02 else { continue }
                    sr += dr; sg += dg; sb += db; cnt += 1
                }
            }
            if cnt > 10 {
                results.append(IlluminantEstimate(method: "GrayEdge",
                    rgb: normalizeGM(IlluminantRGB(r: sr, g: sg, b: sb)), confidence: 0.55))
            }
        }

        // [5] 中性像素筛选（原方法）
        if options.enableNeutralFilter {
            var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0
            for p in pixels {
                let maxC = Double(max(p.0, max(p.1, p.2)))
                let minC = Double(min(p.0, min(p.1, p.2)))
                let sat = maxC > 1e-6 ? (maxC - minC) / maxC : 0
                let w = exp(-(sat*sat) / (2*0.25*0.25))
                sr += Double(p.0)*w; sg += Double(p.1)*w; sb += Double(p.2)*w; sw += w
            }
            if sw > 0 {
                results.append(IlluminantEstimate(method: "NeutralFilter",
                    rgb: normalizeGM(IlluminantRGB(r: sr/sw, g: sg/sw, b: sb/sw)), confidence: 0.7))
            }
        }

        // [6] 暗通道加权（用暗通道作为"阴影 mask"降权暗部）
        if options.enableDarkChannelWeighting {
            var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0
            for p in pixels {
                let dark = Double(min(p.0, min(p.1, p.2)))
                let w = 1.0 - min(1.0, dark * 4)  // 暗部权重低
                sr += Double(p.0)*w; sg += Double(p.1)*w; sb += Double(p.2)*w; sw += w
            }
            if sw > 1 {
                results.append(IlluminantEstimate(method: "DarkChannelWeighted",
                    rgb: normalizeGM(IlluminantRGB(r: sr/sw, g: sg/sw, b: sb/sw)), confidence: 0.45))
            }
        }

        // [7] Retinex SSR（简化）
        if options.enableRetinex {
            var sr = 0.0, sg = 0.0, sb = 0.0, cnt = 0.0
            let win = 3
            for y in win..<(h-win) {
                for x in win..<(w-win) {
                    var lr = 0.0, lg = 0.0, lb = 0.0
                    for dy in -win...win { for dx in -win...win {
                        let o = ((y+dy)*w + (x+dx))*4
                        lr += Double(bitmap[o]); lg += Double(bitmap[o+1]); lb += Double(bitmap[o+2])
                    }}
                    let n = Double((2*win+1)*(2*win+1))
                    let o = (y*w + x)*4
                    sr += log(max(Double(bitmap[o]), 1e-4) + 1e-4) - log(lr/n + 1e-4)
                    sg += log(max(Double(bitmap[o+1]), 1e-4) + 1e-4) - log(lg/n + 1e-4)
                    sb += log(max(Double(bitmap[o+2]), 1e-4) + 1e-4) - log(lb/n + 1e-4)
                    cnt += 1
                }
            }
            if cnt > 10 {
                let er = exp(-sr/cnt), eg = exp(-sg/cnt), eb = exp(-sb/cnt)
                results.append(IlluminantEstimate(method: "RetinexSSR",
                    rgb: normalizeGM(IlluminantRGB(r: er, g: eg, b: eb)), confidence: 0.5))
            }
        }

        // [8] 局部/分区估计（分区取中位数）
        if options.enableLocalPartition {
            let gridW = 4, gridH = 4
            var local: [IlluminantRGB] = []
            for gy in 0..<gridH {
                for gx in 0..<gridW {
                    var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0
                    let x0 = gx*w/gridW, x1 = (gx+1)*w/gridW
                    let y0 = gy*h/gridH, y1 = (gy+1)*h/gridH
                    for y in y0..<y1 { for x in x0..<x1 {
                        let o = (y*w + x)*4
                        let maxC = Double(max(bitmap[o], max(bitmap[o+1], bitmap[o+2])))
                        let minC = Double(min(bitmap[o], min(bitmap[o+1], bitmap[o+2])))
                        let sat = maxC > 1e-6 ? (maxC - minC)/maxC : 0
                        let wgt = exp(-(sat*sat)/(2*0.25*0.25))
                        sr += Double(bitmap[o])*wgt; sg += Double(bitmap[o+1])*wgt; sb += Double(bitmap[o+2])*wgt; sw += wgt
                    }}
                    if sw > 1 { local.append(normalizeGM(IlluminantRGB(r: sr/sw, g: sg/sw, b: sb/sw))) }
                }
            }
            if local.count >= 4 {
                let r = local.map{$0.r}.sorted(); let g = local.map{$0.g}.sorted(); let b = local.map{$0.b}.sorted()
                let m = local.count/2
                results.append(IlluminantEstimate(method: "LocalPartition",
                    rgb: IlluminantRGB(r: r[m], g: g[m], b: b[m]), confidence: 0.6))
            }
        }

        // [9] 双色温约束精修 —— 把已有估计投影到合理 CCT 范围
        if options.enableDualTemperature, let base = results.max(by: { $0.confidence < $1.confidence })?.rgb {
            let xy = rgbToXY(base)
            let cct = cctFromXY(xy)
            if cct < 1800 || cct > 20000 {
                // 超过合理范围 → 拉回最近端点（简化：按比例）
                let target: IlluminantRGB
                if cct < 1800 { target = IlluminantRGB(r: 1.2, g: 0.9, b: 0.6) }
                else          { target = IlluminantRGB(r: 0.7, g: 0.9, b: 1.2) }
                let mixed = IlluminantRGB(r: (base.r + target.r)/2, g: (base.g + target.g)/2, b: (base.b + target.b)/2)
                results.append(IlluminantEstimate(method: "DualTemperature",
                    rgb: normalizeGM(mixed), confidence: 0.55))
            }
        }

        // [10] 贝叶斯先验
        if options.enableBayesianPrior, let prior = priorProvider?.prior(for: scene.type) {
            results.append(IlluminantEstimate(method: "BayesianPrior",
                rgb: prior.mean, confidence: 0.6))
        }

        // [11] ML
        if options.enableMLIlluminant, let ml = mlProvider?.estimate(ciImage: ciImage) {
            var e = ml; e.rgb = normalizeGM(e.rgb); e.confidence = min(1.0, max(0.0, e.confidence))
            results.append(e)
        }

        // [12] 场景先验调权
        for i in results.indices {
            switch scene.type {
            case .portrait: if results[i].method == "NeutralFilter" { results[i].confidence *= 1.2 }
            case .landscape: if results[i].method == "ShadesOfGray(p=6)" { results[i].confidence *= 1.1 }
            case .night: if results[i].method == "WhitePatch" { results[i].confidence *= 0.7 }
            default: break
            }
        }
        return results
    }

    // MARK: - 融合（加权 + 离群剔除 + gamut 约束）

    private func fuse(ests: [IlluminantEstimate],
                      pixels: [ (r: Float, g: Float, b: Float, luma: Float) ]) -> IlluminantRGB? {
        let valid = ests.filter { $0.rgb.g.isFinite && $0.rgb.g > 1e-6 }
        guard !valid.isEmpty else { return nil }

        // 加权中心
        func weightedCenter(_ src: [IlluminantEstimate]) -> IlluminantRGB {
            var r = 0.0, g = 0.0, b = 0.0, w = 0.0
            for e in src {
                r += e.rgb.r * e.confidence; g += e.rgb.g * e.confidence; b += e.rgb.b * e.confidence
                w += e.confidence
            }
            return IlluminantRGB(r: r/w, g: g/w, b: b/w)
        }

        var center = weightedCenter(valid)
        // 离群剔除：与中心距离 > 2σ 的降权
        let dists = valid.map { sqrt(pow($0.rgb.r - center.r, 2) + pow($0.rgb.g - center.g, 2) + pow($0.rgb.b - center.b, 2)) }
        let meanD = dists.reduce(0, +) / Double(dists.count)
        let varD = dists.map { pow($0 - meanD, 2) }.reduce(0, +) / Double(dists.count)
        let sigma = sqrt(varD)
        if sigma > 1e-3 {
            let filtered = valid.enumerated().filter { dists[$0.offset] <= 2*sigma }.map { $0.element }
            if !filtered.isEmpty { center = weightedCenter(filtered) }
        }

        // Gamut 约束：用该白点校正，检查中性区像素落在 sRGB 内的比例
        if options.enableGamutConstraint {
            let inGamut = gamutScore(illuminant: center, pixels: pixels)
            if inGamut < 0.7 {
                // 投影回 Gray World（更保守）
                let n = Double(pixels.count)
                let gw = IlluminantRGB(
                    r: pixels.reduce(0.0) { $0 + Double($1.0) }/n,
                    g: pixels.reduce(0.0) { $0 + Double($1.1) }/n,
                    b: pixels.reduce(0.0) { $0 + Double($1.2) }/n)
                center = normalizeGM(IlluminantRGB(
                    r: (center.r + gw.r)/2, g: (center.g + gw.g)/2, b: (center.b + gw.b)/2))
            }
        }
        return normalizeGM(center)
    }

    private func gamutScore(illuminant: IlluminantRGB, pixels: [ (r: Float, g: Float, b: Float, luma: Float) ]) -> Double {
        // 归一化后 BW 增益 = illuminant.g / illuminant.(r|g|b)
        let gr = illuminant.g / max(illuminant.r, 1e-6)
        let gb = illuminant.g / max(illuminant.b, 1e-6)
        var inCount = 0, total = 0
        // 采样 500 个
        let step = max(1, pixels.count / 500)
        for i in stride(from: 0, to: pixels.count, by: step) {
            let p = pixels[i]
            let r = Double(p.0)*gr, b = Double(p.2)*gb
            if r >= 0 && r <= 1.5 && b >= 0 && b <= 1.5 { inCount += 1 }
            total += 1
        }
        return total > 0 ? Double(inCount)/Double(total) : 1.0
    }

    private func normalizeGM(_ c: IlluminantRGB) -> IlluminantRGB {
        let g = max(c.g, 1e-6)
        return IlluminantRGB(r: c.r/g, g: 1.0, b: c.b/g)
    }
    // MARK: - CAT（5 种）

    private func catForScene(_ s: SceneType) -> CATMethod {
        switch s {
        case .portrait:   return .vonKries   // 保守，避免肤色漂移
        case .landscape:  return .bradford
        case .night:      return .bradford
        case .document:   return .vonKries
        case .generic:    return .bradford
        }
    }

    private func catMatrices(_ m: CATMethod) -> (toLMS: simd_double3x3, fromLMS: simd_double3x3) {
        switch m {
        case .vonKries:
            let to = simd_double3x3(columns: (
                SIMD3(0.4002, 0.7075, -0.0807), SIMD3(-0.2280, 1.1500, 0.0612), SIMD3(0.0, 0.0, 0.9184)))
            return (to, to.inverse)
        case .bradford:
            let to = simd_double3x3(columns: (
                SIMD3( 0.8951, -0.7502,  0.0389), SIMD3( 0.2664,  1.7135, -0.0685), SIMD3(-0.1614,  0.0367,  1.0296)))
            return (to, to.inverse)
        case .cat02:
            let to = simd_double3x3(columns: (
                SIMD3( 0.7328, -0.7036,  0.0030), SIMD3( 0.4296,  1.6975,  0.0136), SIMD3(-0.1624,  0.0061,  0.9834)))
            return (to, to.inverse)
        case .cmccat2000:
            let to = simd_double3x3(columns: (
                SIMD3( 0.7982, -0.6169,  0.0209), SIMD3( 0.3389,  1.5552,  0.0924), SIMD3(-0.1371,  0.0617,  0.8868)))
            return (to, to.inverse)
        case .xyzScaling:
            return (matrix_identity_double3x3, matrix_identity_double3x3)
        }
    }

    private func computeCATGains(fused: IlluminantRGB, method: CATMethod) -> (Double, Double, Double)? {
        // 光源 RGB → XYZ → Y=1 归一化
        let M_sRGB2XYZ = simd_double3x3(columns: (
            SIMD3(0.4124564, 0.2126729, 0.0193339),
            SIMD3(0.3575761, 0.7151522, 0.1191920),
            SIMD3(0.1804375, 0.0721750, 0.9503041)))
        let rgb = SIMD3(fused.r, fused.g, fused.b)
        let xyz = M_sRGB2XYZ * rgb
        guard xyz.y.isFinite, xyz.y > 1e-6 else { return nil }
        let xyzN = xyz / xyz.y

        let (toLMS, _) = catMatrices(method)
        let srcLMS = toLMS * xyzN
        guard srcLMS.x.isFinite, srcLMS.y.isFinite, srcLMS.z.isFinite,
              srcLMS.x > 1e-6, srcLMS.y > 1e-6, srcLMS.z > 1e-6 else { return nil }

        let d65 = IlluminantRGB.d65
        let dstXYZ = M_sRGB2XYZ * SIMD3(d65.r, d65.g, d65.b)
        let dstLMS = toLMS * dstXYZ

        let gL = clamp(dstLMS.x / srcLMS.x, 0.25, 4.0)
        let gM = clamp(dstLMS.y / srcLMS.y, 0.25, 4.0)
        let gS = clamp(dstLMS.z / srcLMS.z, 0.25, 4.0)
        return (gL, gM, gS)
    }

    private func buildFinalMatrix(fused: IlluminantRGB, gains: (Double, Double, Double), method: CATMethod) -> simd_double3x3 {
        let M_sRGB2XYZ = simd_double3x3(columns: (
            SIMD3(0.4124564, 0.2126729, 0.0193339),
            SIMD3(0.3575761, 0.7151522, 0.1191920),
            SIMD3(0.1804375, 0.0721750, 0.9503041)))
        let M_XYZ2sRGB = M_sRGB2XYZ.inverse
        let (toLMS, fromLMS) = catMatrices(method)
        let gain = simd_double3x3(diagonal: SIMD3(gains.0, gains.1, gains.2))
        return M_XYZ2sRGB * fromLMS * gain * toLMS * M_sRGB2XYZ
    }

    private func applyMatrix(_ m: simd_double3x3, to img: CIImage) -> CIImage? {
        let f = CIFilter.colorMatrix()
        f.inputImage = img
        f.rVector = CIVector(x: m[0][0], y: m[0][1], z: m[0][2], w: 0)
        f.gVector = CIVector(x: m[1][0], y: m[1][1], z: m[1][2], w: 0)
        f.bVector = CIVector(x: m[2][0], y: m[2][1], z: m[2][2], w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return f.outputImage
    }
    // MARK: - 曝光解耦 & 动态范围

    private func estimateExposureCompensation(bitmap: [Float], w: Int, h: Int) -> Double {
        // 目标:中位 luma ~ 0.18（18% 灰）
        var lumas: [Float] = []; lumas.reserveCapacity(w*h)
        for i in 0..<(w*h) {
            let o = i*4
            lumas.append(0.2126*bitmap[o] + 0.7152*bitmap[o+1] + 0.0722*bitmap[o+2])
        }
        lumas.sort()
        guard !lumas.isEmpty else { return 1.0 }
        let median = Double(lumas[lumas.count / 2])
        guard median > 1e-4 else { return 1.0 }
        let factor = 0.18 / median
        return clamp(factor, 0.5, 2.5)
    }

    private func applyExposure(_ img: CIImage, factor: Double) -> CIImage {
        let f = CIFilter.exposureAdjust()
        f.inputImage = img
        f.ev = Float(log2(factor))
        return f.outputImage ?? img
    }

    private func recoverHighlights(_ img: CIImage) -> CIImage {
        let f = CIFilter.highlightShadowAdjust()
        f.inputImage = img
        f.highlightAmount = 0.7
        f.shadowAmount = 0.0
        return f.outputImage ?? img
    }

    private func liftShadows(_ img: CIImage) -> CIImage {
        let f = CIFilter.highlightShadowAdjust()
        f.inputImage = img
        f.shadowAmount = 0.3
        f.highlightAmount = 0.0
        return f.outputImage ?? img
    }

    private func correctBlackLevel(_ img: CIImage) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = img
        f.rVector = CIVector(x: 1.02, y: 0, z: 0, w: -0.02)
        f.gVector = CIVector(x: 0, y: 1.02, z: 0, w: -0.02)
        f.bVector = CIVector(x: 0, y: 0, z: 1.02, w: -0.02)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return f.outputImage ?? img
    }

    // MARK: - Hue Twist 修正 & 饱和度高光 & 记忆色 & 曲线

    private func correctHueTwist(_ img: CIImage, M: simd_double3x3) -> CIImage {
        // 简化：用 CIVibrance 抑制高饱和区色相偏移
        let f = CIFilter.vibrance()
        f.inputImage = img
        f.amount = 0.2
        return f.outputImage ?? img
    }

    private func compressSatHighlights(_ img: CIImage) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = img
        f.saturation = 0.95
        f.brightness = 0
        f.contrast = 1.02
        return f.outputImage ?? img
    }

    private func applyMemoryColor(_ img: CIImage, scene: Scene) -> CIImage {
        // 肤色：人脸区域 hue 微调
        // 天空/植被：色相收缩
        var out = img
        if let sky = scene.skyMask {
            let hue = CIFilter.hueAdjust()
            hue.inputImage = out
            hue.angle = 0.02
            if let o = hue.outputImage {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = o
                blend.backgroundImage = out
                blend.maskImage = sky.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 4])
                if let b = blend.outputImage { out = b.cropped(to: img.extent) }
            }
        }
        if let veg = scene.vegMask {
            let hue = CIFilter.hueAdjust()
            hue.inputImage = out
            hue.angle = -0.02
            if let o = hue.outputImage {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = o
                blend.backgroundImage = out
                blend.maskImage = veg.applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 4])
                if let b = blend.outputImage { out = b.cropped(to: img.extent) }
            }
        }
        return out
    }

    private func applyPerChannelCurve(_ img: CIImage) -> CIImage {
        // 简化 S 曲线：用 CIColorControls 近似
        let f = CIFilter.colorControls()
        f.inputImage = img
        f.saturation = 1.05
        f.contrast = 1.03
        f.brightness = 0.0
        return f.outputImage ?? img
    }

    private func toneMap(_ img: CIImage) -> CIImage {
        // 简化 Reinhard（用 CIExposureAdjust + 曲线近似）
        let f = CIFilter.toneCurve()
        f.inputImage = img
        f.point0 = CGPoint(x: 0.0,  y: 0.0)
        f.point1 = CGPoint(x: 0.25, y: 0.22)
        f.point2 = CGPoint(x: 0.5,  y: 0.5)
        f.point3 = CGPoint(x: 0.75, y: 0.78)
        f.point4 = CGPoint(x: 1.0,  y: 1.0)
        return f.outputImage ?? img
    }

    private func applyLUT3D(_ img: CIImage, lut: (size: Int, data: [Float])) -> CIImage {
        // [接口] 需要 CIColorCube 数据格式（RGBA float，size³）
        let colorCube = CIFilter.colorCube()
        colorCube.inputImage = img
        colorCube.cubeDimension = Float(lut.size)
        colorCube.cubeData = Data(bytes: lut.data, count: lut.data.count * MemoryLayout<Float>.size)
        return colorCube.outputImage ?? img
    }
    // MARK: - 评估（ΔE2000 / CCT / PSNR / SSIM）

    private func meanDeltaEOfNeutrals(pixels: [ (r: Float, g: Float, b: Float, luma: Float) ], fused: IlluminantRGB) -> Double {
        // 简化：把中性区像素做白平衡后,与理想灰 (0.18,0.18,0.18) 比 ΔE
        let gr = fused.g / max(fused.r, 1e-6)
        let gb = fused.g / max(fused.b, 1e-6)
        var sum = 0.0; var cnt = 0
        for p in pixels {
            let maxC = Double(max(p.0, max(p.1, p.2)))
            let minC = Double(min(p.0, min(p.1, p.2)))
            guard maxC > 1e-6, (maxC - minC)/maxC < 0.15 else { continue }
            let r = Double(p.0)*gr, g = Double(p.1), b = Double(p.2)*gb
            sum += deltaE2000(lab(r, g, b), lab(0.18, 0.18, 0.18))
            cnt += 1
        }
        return cnt > 0 ? sum/Double(cnt) : 0
    }

    private func lab(_ r: Double, _ g: Double, _ b: Double) -> (L: Double, a: Double, b: Double) {
        let M = simd_double3x3(columns: (
            SIMD3(0.4124564, 0.2126729, 0.0193339),
            SIMD3(0.3575761, 0.7151522, 0.1191920),
            SIMD3(0.1804375, 0.0721750, 0.9503041)))
        let xyz = M * SIMD3(r, g, b)
        func f(_ t: Double) -> Double { return t > 0.008856 ? pow(t, 1.0/3.0) : (7.787*t + 16.0/116.0) }
        let fx = f(xyz.x / 0.95047), fy = f(xyz.y / 1.0), fz = f(xyz.z / 1.08883)
        return (116*fy - 16, 500*(fx - fy), 200*(fy - fz))
    }

    private func deltaE2000(_ a: (L: Double, a: Double, b: Double), _ b: (L: Double, a: Double, b: Double)) -> Double {
        // 完整 CIEDE2000（简化 kL=kC=kH=1）
        let dL = b.L - a.L, dA = b.a - a.a, dB = b.b - a.b
        let c1 = sqrt(a.a*a.a + a.b*a.b), c2 = sqrt(b.a*b.a + b.b*b.b)
        let cBar = (c1 + c2)/2
        let g = 0.5 * (1 - sqrt(pow(cBar, 7)/(pow(cBar, 7) + pow(25.0, 7))))
        let a1 = a.a*(1+g), a2 = b.a*(1+g)
        let c1p = sqrt(a1*a1 + a.b*a.b), c2p = sqrt(a2*a2 + b.b*b.b)
        let h1 = atan2(a.b, a1) * 180 / .pi
        let h2 = atan2(b.b, a2) * 180 / .pi
        let dHp: Double
        if c1p * c2p == 0 { dHp = 0 }
        else if abs(h2 - h1) <= 180 { dHp = h2 - h1 }
        else if (h2 - h1) > 180 { dHp = h2 - h1 - 360 }
        else { dHp = h2 - h1 + 360 }
        let dH = 2 * sqrt(c1p * c2p) * sin(dHp * .pi / 180 / 2)
        let dCp = c2p - c1p
        let lBar = (a.L + b.L)/2, cBarP = (c1p + c2p)/2
        var hBarP = (h1 + h2)/2
        if c1p * c2p == 0 { hBarP = h1 + h2 }
        else if abs(h1 - h2) > 180 { hBarP = (h1 + h2 + 360)/2 }
        if hBarP >= 360 { hBarP -= 360 }
        let T = 1 - 0.17*cos((hBarP - 30) * .pi/180) + 0.24*cos(2*hBarP * .pi/180)
                + 0.32*cos((3*hBarP + 6) * .pi/180) - 0.20*cos((4*hBarP - 63) * .pi/180)
        let dTheta = 30 * exp(-pow((hBarP - 275)/25, 2))
        let RC = 2 * sqrt(pow(cBarP, 7)/(pow(cBarP, 7) + pow(25.0, 7)))
        let SL = 1 + 0.015*pow(lBar - 50, 2) / sqrt(20 + pow(lBar - 50, 2))
        let SC = 1 + 0.045*cBarP
        let SH = 1 + 0.015*cBarP*T
        let RT = -sin(2*dTheta * .pi/180) * RC
        let lTerm = dL/SL, cTerm = dCp/SC, hTerm = dH/SH
        return sqrt(lTerm*lTerm + cTerm*cTerm + hTerm*hTerm + RT*cTerm*hTerm)
    }

    private func rgbToXY(_ c: IlluminantRGB) -> (x: Double, y: Double) {
        let M = simd_double3x3(columns: (
            SIMD3(0.4124564, 0.2126729, 0.0193339),
            SIMD3(0.3575761, 0.7151522, 0.1191920),
            SIMD3(0.1804375, 0.0721750, 0.9503041)))
        let xyz = M * SIMD3(c.r, c.g, c.b)
        let s = xyz.x + xyz.y + xyz.z
        return (xyz.x/s, xyz.y/s)
    }

    private func cctFromXY(_ xy: (x: Double, y: Double)) -> Double {
        let n = (xy.x - 0.3320) / max(xy.y - 0.1858, 1e-6)
        return 449.0*n*n*n + 3525.0*n*n + 6823.3*n + 5520.33
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}

// MARK: - UIImage 方向归一化

extension UIImage {
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let out = UIGraphicsGetImageFromCurrentImageContext() ?? self
        UIGraphicsEndImageContext()
        return out
    }
}
