import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
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
    var rgb: IlluminantRGB
    var confidence: Double
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
    var enableWhitePatch = true
    var enableGrayWorld = true
    var enableShadesOfGray = true
    var enableGrayEdge = true
    var enableNeutralFilter = true
    var enableDarkChannelWeighting = true
    var enableRetinex = true
    var enableLocalPartition = true
    var enableGamutConstraint = true
    var enableDualTemperature = true
    var enableBayesianPrior = false
    var enableMLIlluminant = false
    var catMethod: CATMethod? = nil
    var enableExposureDecoupling = true
    var enableHighlightRecovery = true
    var enableShadowLift = false
    var enableBlackLevel = true
    var enableToneMapping = false

    var enableMemoryColor = false
    var enableHueTwistCorrection = false
    var enableSaturationHighlightCompress = false
    var enablePerChannelCurve = false

    var enableNoiseAwareWeighting = true
    var enableVignettingCorrection = false
    var enableChromaticAberration = false
    var enableIterativeRefinement = true
    var maxIterations = 3
    var analysisScale: CGFloat = 0.05
}

// MARK: - 外部依赖协议

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

    // MARK: Init
    init?(options: RestorerOptions = RestorerOptions()) {
        Task { @MainActor in
            AppLogger.shared.log("[PhotoColorRestorer] init 开始，analysisScale=\(options.analysisScale)，cat=\(options.catMethod?.rawValue ?? "auto")", isError: false)
        }

        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            Task { @MainActor in
                AppLogger.shared.log("[PhotoColorRestorer] ❌ init 失败：extendedLinearSRGB 不可用", isError: true)
            }
            return nil
        }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            Task { @MainActor in
                AppLogger.shared.log("[PhotoColorRestorer] ❌ init 失败：sRGB 不可用", isError: true)
            }
            return nil
        }

        self.linearSRGB = linear
        self.sRGB = srgb
        self.options = options
        self.ciContext = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: linear
        ])

        log("init 成功：workingSpace=extendedLinearSRGB，outputSpace=sRGB")
    }

    // MARK: 便捷入口
    func autoRestoreColor(image: UIImage) -> UIImage? {
        log("autoRestoreColor(image:) 调用（便捷入口）")
        return autoRestoreColor(image: image, previewScale: nil)?.0
    }

    // MARK: 主入口
    func autoRestoreColor(image: UIImage, previewScale: CGFloat? = nil) -> (UIImage?, Diagnostics)? {
        log("========== 开始真实色彩还原 ==========")
        log("原图：size=\(Int(image.size.width))x\(Int(image.size.height))，scale=\(image.scale)，orientation=\(image.imageOrientation.rawValue)")

        var diag = Diagnostics()

        // 0. 输入方向归一化
        let normalized = image.normalizedOrientation()
        guard let ciImage = CIImage(image: normalized) else {
            logError("CIImage 转换失败，返回原图")
            return (image, diag)
        }
        log("CIImage extent=\(ciImage.extent)")

        // 1. 预处理
        log("--- 阶段 1：预处理（CCM/暗角/色差）---")
        let preprocessed = preprocess(ciImage, diag: &diag)

        // 2. 下采样
        let scale = previewScale ?? options.analysisScale
        log("--- 阶段 2：下采样 scale=\(scale) ---")
        guard let small = downsample(preprocessed, scale: scale) else {
            logError("下采样失败")
            return (image, diag)
        }
        let extent = small.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0 else {
            logError("下采样尺寸无效 \(w)x\(h)")
            return (image, diag)
        }
        log("分析采样尺寸=\(w)x\(h)（线性空间）")

        let renderRect = small.extent.integral
        let safeSmall = small.clampedToExtent().cropped(to: renderRect)

        var bitmap = [Float](repeating: 0, count: w * h * 4)
        ciContext.render(safeSmall, toBitmap: &bitmap,
                         rowBytes: w * 4 * MemoryLayout<Float>.size,
                         bounds: renderRect, format: .RGBAf, colorSpace: nil)
        log("render 到 bitmap 完成，共 \(w*h) 像素")

        // 3. 场景分析
        log("--- 阶段 3：场景理解 ---")
        let scene = analyzeScene(bitmap: bitmap, w: w, h: h, cgImage: normalized.cgImage)
        diag.sceneType = scene.type
        log("场景类型=\(scene.type.rawValue)，face=\(scene.faceMask != nil)，sky=\(scene.skyMask != nil)，veg=\(scene.vegMask != nil)，doc=\(scene.docRect != nil)")

        // 4. 像素提取 + 修剪
        log("--- 阶段 4：像素提取 + 直方图修剪 ---")
        let pixels = extractPixels(bitmap: bitmap, w: w, h: h, diag: &diag)
        log("有效像素=\(pixels.count)，跳过 alpha<0.5 像素=\(diag.skippedPixels)")
        guard pixels.count > 200 else {
            logError("有效像素过少（\(pixels.count)），放弃还原")
            return (image, diag)
        }
        let valid = trimHistogram(pixels)
        log("修剪后像素=\(valid.count)（仅剔除暗部 2% 极值，保留亮部给 WhitePatch）")

        let estimatePixels = sceneExcludedPixels(valid, scene: scene)
        log("光源估计像素：\(estimatePixels.count) / \(valid.count)（已排除语义色）")

        // 5. 多光源估计 + 迭代残差补偿
        log("--- 阶段 5：多光源估计 + 融合 ---")
        var fused = IlluminantRGB(r: 1, g: 1, b: 1)
        let iterationLimit = options.enableIterativeRefinement ? options.maxIterations : 1
        var iterations = iterationLimit

        for it in 0..<iterationLimit {
            log("  迭代第 \(it + 1)/\(iterationLimit) 轮")

            let gr = fused.g / max(fused.r, 1e-6)
            let gb = fused.g / max(fused.b, 1e-6)

            let fgr = Float(gr)
            let fgb = Float(gb)
            let corrected: [(r: Float, g: Float, b: Float, luma: Float)] = estimatePixels.map { p in
                let newR: Float = p.r * fgr
                let newB: Float = p.b * fgb
                // 修复：luma 必须重算
                let newLuma: Float = 0.2126 * newR + 0.7152 * p.g + 0.0722 * newB
                return (r: newR, g: p.g, b: newB, luma: newLuma)
            }

            // 修复：几何类估计器只在第 0 轮跑，避免与 pixels 语义过滤不一致
            let allowGeometry = (it == 0)
            let ests = runEstimators(pixels: corrected, scene: scene,
                                     bitmap: bitmap, w: w, h: h, ciImage: small,
                                     allowGeometry: allowGeometry)
            if it == 0 { diag.estimates = ests }
            logEstimates(ests)

            guard let residual = fuse(ests: ests, pixels: corrected) else {
                logError("融合失败：无有效估计，放弃还原")
                return (image, diag)
            }

            let next = normalizeGM(IlluminantRGB(
                r: fused.r * residual.r,
                g: fused.g * residual.g,
                b: fused.b * residual.b))

            let delta = abs(next.r - fused.r) + abs(next.g - fused.g) + abs(next.b - fused.b)
            log(String(format: "  残差补偿 R=%.4f G=%.4f B=%.4f（Δ=%.5f）",
                       next.r, next.g, next.b, delta))
            fused = next

            if delta < 0.005 {
                iterations = it + 1
                log("  迭代收敛于第 \(iterations) 轮")
                break
            }
        }
        diag.iterations = iterations
        diag.fused = fused
        log(String(format: "最终光源估计 R=%.4f G=%.4f B=%.4f（迭代 %d 轮）",
                   fused.r, fused.g, fused.b, iterations))

        if let ts = temporalConsistency {
            let smoothed = ts.smooth(fused)
            log(String(format: "时域一致性平滑：R %.4f→%.4f G %.4f→%.4f B %.4f→%.4f",
                       fused.r, smoothed.r, fused.g, smoothed.g, fused.b, smoothed.b))
            fused = smoothed
        }

        // 6. CAT
        log("--- 阶段 6：色适应变换（CAT）---")
        let cat = options.catMethod ?? catForScene(scene.type)
        diag.catMethod = cat
        log("CAT 方法=\(cat.rawValue)（\(options.catMethod != nil ? "手动指定" : "按场景自动")）")

        guard let gains = computeCATGains(fused: fused, method: cat) else {
            logError("CAT 增益计算失败（LMS 异常），放弃还原")
            return (image, diag)
        }
        diag.gainsLMS = gains
        log(String(format: "LMS 增益 L=%.4f M=%.4f S=%.4f", gains.0, gains.1, gains.2))

        let M_final = buildFinalMatrix(fused: fused, gains: gains, method: cat)
        log("最终 3×3 矩阵构建完成")

        // 7. 应用 WB 矩阵
        log("--- 阶段 7：应用白平衡矩阵 ---")
        guard let wbImage = applyMatrix(M_final, to: preprocessed) else {
            logError("矩阵应用失败")
            return (image, diag)
        }
        log("白平衡矩阵已应用")

        // 8. 曝光解耦（修复：改为用 fused 增益修正后估计，避免色温污染 luma）
        log("--- 阶段 8：曝光解耦 ---")
        let expComp = estimateExposureCompensation(bitmap: bitmap, w: w, h: h, gains: fused)
        diag.exposureComp = expComp
        log(String(format: "曝光补偿系数=%.4f（EV=%.3f）", expComp, log2(expComp)))
        let exposed: CIImage = options.enableExposureDecoupling
            ? applyExposure(wbImage, factor: expComp)
            : wbImage
        if !options.enableExposureDecoupling {
            log("曝光解耦已禁用，跳过")
        }

        // 9. 后处理链
        log("--- 阶段 9：后处理链 ---")
        var processed = exposed

        if options.enableHighlightRecovery {
            processed = recoverHighlights(processed)
            log("  高光恢复: 已应用")
        }
        if options.enableShadowLift {
            processed = liftShadows(processed)
            log("  阴影提亮: 已应用")
        }
        if options.enableBlackLevel {
            processed = correctBlackLevel(processed)
            log("  黑电平校正: 已应用")
        }
        if options.enableHueTwistCorrection {
            processed = correctHueTwist(processed, M: M_final)
            log("  HueTwist 修正: 已应用（矩阵 85% + identity 15% 混合）")
        }
        if options.enableSaturationHighlightCompress {
            processed = compressSatHighlights(processed)
            log("  饱和度高光压缩: 已应用（luminance mask 局部降饱和）")
        }
        if options.enableMemoryColor {
            processed = applyMemoryColor(processed, scene: scene)
            log("  记忆色校正: 已应用（sky/veg mask，±0.01 rad 微调）")
        }
        if options.enablePerChannelCurve {
            processed = applyPerChannelCurve(processed)
            log("  PerChannel 曲线: 已应用（仅饱和 +5%，不做对比）")
        }
        if options.enableToneMapping {
            processed = toneMap(processed)
            log("  ToneMapping: 已应用")
        }
        if let lut = lutProvider?.lut(for: scene.type) {
            // 修复：3D LUT 在 sRGB gamma 空间应用（LUT 通常为 sRGB 设计）
            let inSRGB = processed.applyingFilter("CILinearToSRGBToneCurve")
            let lutted = applyLUT3D(inSRGB, lut: lut)
            processed = lutted.applyingFilter("CISRGBToneCurveToLinear")
            log("  3D LUT: 已应用 size=\(lut.size)（sRGB gamma 空间）")
        }

        // 10. 输出
        log("--- 阶段 10：输出 CGImage ---")
        let clamped = processed.clampedToExtent().cropped(to: preprocessed.extent)
        guard let cg = ciContext.createCGImage(clamped, from: clamped.extent,
                                               format: .RGBA8, colorSpace: sRGB) else {
            logError("CGImage 渲染失败")
            return (image, diag)
        }
        let out = UIImage(cgImage: cg, scale: normalized.scale, orientation: .up)
        log("输出图尺寸 \(Int(out.size.width))x\(Int(out.size.height))")

        // 11. 评估
        log("--- 阶段 11：ΔE2000 评估 ---")
        diag.deltaEBefore = meanDeltaEOfNeutrals(pixels: valid, matrix: matrix_identity_double3x3)
        diag.deltaEAfter  = meanDeltaEOfNeutrals(pixels: valid, matrix: M_final)
        log(String(format: "ΔE2000 中性区（色度）：before=%.3f after=%.3f（降低 %.1f%%）",
                   diag.deltaEBefore, diag.deltaEAfter,
                   diag.deltaEBefore > 0 ? (1 - diag.deltaEAfter / diag.deltaEBefore) * 100 : 0))
        log("========== 真实色彩还原完成 ==========")

        return (out, diag)
    }

    // MARK: - 预处理
    private func preprocess(_ img: CIImage, diag: inout Diagnostics) -> CIImage {
        var out = img

        if let ccm = cameraMatrixProvider?.matrix(for: nil) {
            log("CCM：已获取相机色彩矩阵，开始应用")
            let f = CIFilter.colorMatrix()
            f.inputImage = out
            f.rVector = CIVector(x: ccm[0][0], y: ccm[1][0], z: ccm[2][0], w: 0)
            f.gVector = CIVector(x: ccm[0][1], y: ccm[1][1], z: ccm[2][1], w: 0)
            f.bVector = CIVector(x: ccm[0][2], y: ccm[1][2], z: ccm[2][2], w: 0)
            if let o = f.outputImage { out = o; log("CCM：应用完成") }
            else { logError("CCM：矩阵应用失败，跳过") }
        } else {
            log("CCM：未提供 CameraColorMatrixProvider，跳过")
        }

        if options.enableVignettingCorrection {
            if let vp = lensProfileProvider?.vignetting(for: nil) {
                log(String(format: "暗角校正：k1=%.4f k2=%.4f", vp.k1, vp.k2))
                let f = CIFilter.vignetteEffect()
                f.inputImage = out
                f.center = CGPoint(x: out.extent.midX, y: out.extent.midY)
                f.radius = Float(max(out.extent.width, out.extent.height) / 2)
                f.intensity = Float(-vp.k1 * 2)
                if let o = f.outputImage { out = o; log("暗角校正：应用完成") }
            } else {
                log("暗角校正：已启用但无 lens profile，跳过")
            }
        }

        if options.enableChromaticAberration {
            if let ca = lensProfileProvider?.chromaticAberration(for: nil) {
                log(String(format: "色差校正：scaleR=%.4f scaleB=%.4f", ca.scaleR, ca.scaleB))
                let f = CIFilter.lanczosScaleTransform()
                f.inputImage = out
                f.scale = Float(ca.scaleR)
                if let o = f.outputImage { out = o }
            } else {
                log("色差校正：已启用但无 lens profile，跳过")
            }
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

    // MARK: - 像素提取
    private func extractPixels(bitmap: [Float], w: Int, h: Int, diag: inout Diagnostics)
        -> [(r: Float, g: Float, b: Float, luma: Float)] {
        var out: [(Float, Float, Float, Float)] = []
        out.reserveCapacity(w * h)
        var skipped = 0
        for i in 0..<(w * h) {
            let o = i * 4
            let a = bitmap[o + 3]
            guard a >= 0.5 else { skipped += 1; continue }
            let r = bitmap[o], g = bitmap[o + 1], b = bitmap[o + 2]
            out.append((r, g, b, 0.2126 * r + 0.7152 * g + 0.0722 * b))
        }
        diag.skippedPixels = skipped
        return out
    }

    /// 修复：只剔除暗部 2%，保留亮部给 WhitePatch 作为白点候选
    private func trimHistogram(_ px: [(r: Float, g: Float, b: Float, luma: Float)])
        -> [(r: Float, g: Float, b: Float, luma: Float)] {
        let sorted = px.sorted { $0.3 < $1.3 }
        let n = Int(Float(sorted.count) * 0.02)
        guard sorted.count > n + 100 else { return sorted }
        return Array(sorted[n..<sorted.count])
    }

    // MARK: - 场景分析
    struct Scene {
        var type: SceneType
        var faceMask: CIImage?
        var skyMask: CIImage?
        var vegMask: CIImage?
        var docRect: CGRect?
    }

    private func analyzeScene(bitmap: [Float], w: Int, h: Int, cgImage: CGImage?) -> Scene {
        var meanY = 0.0
        var blueRatio = 0.0, greenRatio = 0.0, skinRatio = 0.0
        for i in 0..<(w * h) {
            let o = i * 4
            let r = bitmap[o], g = bitmap[o + 1], b = bitmap[o + 2]
            meanY += Double(0.2126 * r + 0.7152 * g + 0.0722 * b)
            if b > r && b > g { blueRatio += 1 }
            if g > r && g > b { greenRatio += 1 }
            // 修复：线性空间中 r>0.15 约等于 sRGB 0.43，更贴近真实肤色
            if r > 0.15 && r > g && g > b && (r - b) > 0.08 { skinRatio += 1 }
        }
        let n = Double(w * h)
        meanY /= n; blueRatio /= n; greenRatio /= n; skinRatio /= n
        log(String(format: "场景统计：meanY=%.3f blue=%.2f green=%.2f skin=%.2f",
                   meanY, blueRatio, greenRatio, skinRatio))

        var faceMask: CIImage? = nil
        var hasFace = false
        var docRect: CGRect? = nil

        // 修复：合并两个 Vision request 到一次 perform，减少开销
        if let cg = cgImage {
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            let faceReq = VNDetectFaceRectanglesRequest()
            let rectReq = VNDetectRectanglesRequest()
            rectReq.minimumSize = 0.3
            do {
                try handler.perform([faceReq, rectReq])
                if let results = faceReq.results, !results.isEmpty {
                    hasFace = true
                    faceMask = buildMaskRect(results.map { $0.boundingBox }, w: w, h: h)
                    log("Vision：检测到 \(results.count) 张人脸")
                } else {
                    log("Vision：未检测到人脸")
                }
                if let r = rectReq.results?.first {
                    docRect = r.boundingBox
                    log("Vision：检测到文档矩形 \(r.boundingBox)")
                }
            } catch {
                logError("Vision 检测异常：\(error.localizedDescription)")
            }
        }

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
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: cs, bitmapInfo: 0) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        for r in rects {
            ctx.fill(CGRect(x: r.minX * CGFloat(w), y: r.minY * CGFloat(h),
                            width: r.width * CGFloat(w), height: r.height * CGFloat(h)))
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }

    enum HueBand { case blue, green }
    private func buildColorMask(bitmap: [Float], w: Int, h: Int, hue: HueBand) -> CIImage? {
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: cs, bitmapInfo: 0) else { return nil }
        guard let data = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h) else { return nil }
        for i in 0..<(w * h) {
            let o = i * 4
            let r = Double(bitmap[o]), g = Double(bitmap[o + 1]), b = Double(bitmap[o + 2])
            let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
            let sat = maxC > 1e-6 ? (maxC - minC) / maxC : 0
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            var val: UInt8 = 0
            // 修复：暗部不做色彩 mask，避免线性空间小值噪声误判
            if sat > 0.2 && luma > 0.02 {
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

    private func sceneExcludedPixels(
        _ pixels: [(r: Float, g: Float, b: Float, luma: Float)],
        scene: Scene
    ) -> [(r: Float, g: Float, b: Float, luma: Float)] {
        guard scene.skyMask != nil || scene.vegMask != nil || scene.faceMask != nil else {
            return pixels
        }

        let before = pixels.count
        let filtered = pixels.filter { p in
            let r = Double(p.0), g = Double(p.1), b = Double(p.2)
            let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
            let sat = maxC > 1e-6 ? (maxC - minC) / maxC : 0
            guard sat > 0.2 else { return true }

            switch scene.type {
            case .landscape:
                if b > r && b > g { return false }
                if g > r && g > b { return false }
            case .portrait:
                if r > g && g > b && (r - b) > 0.15 { return false }
            case .document:
                if sat > 0.35 { return false }
            default:
                break
            }
            return true
        }

        // 修复：排除过猛时回退到「中性像素」而非「全部像素」，避免语义色污染估计器
        if filtered.count < max(200, before / 4) {
            let neutral = pixels.filter { p in
                let maxC = Double(max(p.0, max(p.1, p.2)))
                let minC = Double(min(p.0, min(p.1, p.2)))
                let sat = maxC > 1e-6 ? (maxC - minC) / maxC : 0
                return sat < 0.2
            }
            if neutral.count >= 200 {
                log("场景排除过猛（\(before)→\(filtered.count)），回退到中性像素（\(neutral.count)）")
                return neutral
            }
            log("场景排除过猛（\(before)→\(filtered.count)），中性像素也不足，回退到全部像素")
            return pixels
        }
        return filtered
    }

    // MARK: - 光源估计器池
    private func runEstimators(pixels: [(r: Float, g: Float, b: Float, luma: Float)],
                               scene: Scene, bitmap: [Float], w: Int, h: Int,
                               ciImage: CIImage,
                               allowGeometry: Bool) -> [IlluminantEstimate] {
        var results: [IlluminantEstimate] = []
        guard !pixels.isEmpty else {
            logError("runEstimators：输入像素为空")
            return results
        }

        // 修复：夜景中 WhitePatch 取霓虹灯，不可靠，直接跳过
        if options.enableWhitePatch && scene.type != .night {
            let sorted = pixels.sorted { $0.luma > $1.luma }
            let topN = max(1, Int(Double(sorted.count) * 0.05))
            let top = Array(sorted.prefix(topN))
            let mr = top.map { Double($0.0) }.sorted()[topN / 2]
            let mg = top.map { Double($0.1) }.sorted()[topN / 2]
            let mb = top.map { Double($0.2) }.sorted()[topN / 2]
            results.append(IlluminantEstimate(method: "WhitePatch",
                rgb: normalizeGM(IlluminantRGB(r: mr, g: mg, b: mb)), confidence: 0.4))
        }

        if options.enableGrayWorld {
            let n = Double(pixels.count)
            let mr = pixels.reduce(0.0) { $0 + Double($1.0) } / n
            let mg = pixels.reduce(0.0) { $0 + Double($1.1) } / n
            let mb = pixels.reduce(0.0) { $0 + Double($1.2) } / n
            results.append(IlluminantEstimate(method: "GrayWorld",
                rgb: normalizeGM(IlluminantRGB(r: mr, g: mg, b: mb)), confidence: 0.5))
        }

        if options.enableShadesOfGray {
            let p = 6.0; let n = Double(pixels.count)
            let sr = pixels.reduce(0.0) { $0 + pow(Double($1.0), p) }
            let sg = pixels.reduce(0.0) { $0 + pow(Double($1.1), p) }
            let sb = pixels.reduce(0.0) { $0 + pow(Double($1.2), p) }
            let er = pow(sr / n, 1 / p), eg = pow(sg / n, 1 / p), eb = pow(sb / n, 1 / p)
            results.append(IlluminantEstimate(method: "ShadesOfGray(p=6)",
                rgb: normalizeGM(IlluminantRGB(r: er, g: eg, b: eb)), confidence: 0.65))
        }

        // GrayEdge / LocalPartition / RetinexSSR 只在第 0 轮跑（数据源一致性）
        // document 场景边缘是黑字白纸，几何类估计器无效，跳过
        if options.enableGrayEdge && allowGeometry && scene.type != .document {
            var sr = 0.0, sg = 0.0, sb = 0.0; var cnt = 0.0
            if w > 2, h > 2 {
                for y in 1..<(h - 1) {
                    for x in 1..<(w - 1) {
                        let i0 = (y * w + x) * 4
                        let iR = (y * w + x + 1) * 4
                        let iD = ((y + 1) * w + x) * 4
                        let dr = abs(Double(bitmap[iR] - bitmap[i0])) + abs(Double(bitmap[iD] - bitmap[i0]))
                        let dg = abs(Double(bitmap[iR + 1] - bitmap[i0 + 1])) + abs(Double(bitmap[iD + 1] - bitmap[i0 + 1]))
                        let db = abs(Double(bitmap[iR + 2] - bitmap[i0 + 2])) + abs(Double(bitmap[iD + 2] - bitmap[i0 + 2]))
                        let m = max(dr, max(dg, db)); guard m > 0.02 else { continue }
                        sr += dr; sg += dg; sb += db; cnt += 1
                    }
                }
            }
            if cnt > 10 {
                results.append(IlluminantEstimate(method: "GrayEdge",
                    rgb: normalizeGM(IlluminantRGB(r: sr, g: sg, b: sb)), confidence: 0.55))
            }
        }

        if options.enableNeutralFilter {
            var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0
            for p in pixels {
                let maxC = Double(max(p.0, max(p.1, p.2)))
                let minC = Double(min(p.0, min(p.1, p.2)))
                let sat = maxC > 1e-6 ? (maxC - minC) / maxC : 0
                let wgt = exp(-(sat * sat) / (2 * 0.25 * 0.25))
                sr += Double(p.0) * wgt; sg += Double(p.1) * wgt; sb += Double(p.2) * wgt; sw += wgt
            }
            if sw > 0 {
                results.append(IlluminantEstimate(method: "NeutralFilter",
                    rgb: normalizeGM(IlluminantRGB(r: sr / sw, g: sg / sw, b: sb / sw)), confidence: 0.7))
            }
        }

        // 修复：夜景中暗通道被阴影主导，跳过
        if options.enableDarkChannelWeighting && scene.type != .night {
            var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0
            for p in pixels {
                let dark = Double(min(p.0, min(p.1, p.2)))
                let wgt = 1.0 - min(1.0, dark * 4)
                sr += Double(p.0) * wgt; sg += Double(p.1) * wgt; sb += Double(p.2) * wgt; sw += wgt
            }
            if sw > 1 {
                results.append(IlluminantEstimate(method: "DarkChannelWeighted",
                    rgb: normalizeGM(IlluminantRGB(r: sr / sw, g: sg / sw, b: sb / sw)), confidence: 0.45))
            }
        }

        // 修复：窗口加大到 13×13（win=6），提升尺度，减少与 GrayWorld 共线
        // document/night 中 Retinex 会放大噪声或误抓文字边缘，跳过
        if options.enableRetinex && allowGeometry
            && scene.type != .night && scene.type != .document {
            var sr = 0.0, sg = 0.0, sb = 0.0, cnt = 0.0
            let win = 6
            if w > 2 * win, h > 2 * win {
                for y in win..<(h - win) {
                    for x in win..<(w - win) {
                        var lr = 0.0, lg = 0.0, lb = 0.0
                        for dy in -win...win { for dx in -win...win {
                            let o = ((y + dy) * w + (x + dx)) * 4
                            lr += Double(bitmap[o]); lg += Double(bitmap[o + 1]); lb += Double(bitmap[o + 2])
                        }}
                        let n = Double((2 * win + 1) * (2 * win + 1))
                        let o = (y * w + x) * 4
                        sr += Foundation.log(max(Double(bitmap[o]), 1e-4) + 1e-4) - Foundation.log(lr / n + 1e-4)
                        sg += Foundation.log(max(Double(bitmap[o + 1]), 1e-4) + 1e-4) - Foundation.log(lg / n + 1e-4)
                        sb += Foundation.log(max(Double(bitmap[o + 2]), 1e-4) + 1e-4) - Foundation.log(lb / n + 1e-4)
                        cnt += 1
                    }
                }
            }
            if cnt > 10 {
                let er = exp(-sr / cnt), eg = exp(-sg / cnt), eb = exp(-sb / cnt)
                results.append(IlluminantEstimate(method: "RetinexSSR",
                    rgb: normalizeGM(IlluminantRGB(r: er, g: eg, b: eb)), confidence: 0.5))
            }
        }

        if options.enableLocalPartition && allowGeometry && scene.type != .document {
            let gridW = 4, gridH = 4
            var local: [IlluminantRGB] = []
            for gy in 0..<gridH {
                for gx in 0..<gridW {
                    var sr = 0.0, sg = 0.0, sb = 0.0, sw = 0.0
                    let x0 = gx * w / gridW, x1 = (gx + 1) * w / gridW
                    let y0 = gy * h / gridH, y1 = (gy + 1) * h / gridH
                    if x1 <= x0 || y1 <= y0 { continue }
                    for y in y0..<y1 { for x in x0..<x1 {
                        let o = (y * w + x) * 4
                        let maxC = Double(max(bitmap[o], max(bitmap[o + 1], bitmap[o + 2])))
                        let minC = Double(min(bitmap[o], min(bitmap[o + 1], bitmap[o + 2])))
                        let sat = maxC > 1e-6 ? (maxC - minC) / maxC : 0
                        let wgt = exp(-(sat * sat) / (2 * 0.25 * 0.25))
                        sr += Double(bitmap[o]) * wgt; sg += Double(bitmap[o + 1]) * wgt; sb += Double(bitmap[o + 2]) * wgt; sw += wgt
                    }}
                    if sw > 1 { local.append(normalizeGM(IlluminantRGB(r: sr / sw, g: sg / sw, b: sb / sw))) }
                }
            }
            if local.count >= 4 {
                let r = local.map { $0.r }.sorted()
                let g = local.map { $0.g }.sorted()
                let b = local.map { $0.b }.sorted()
                let m = local.count / 2
                results.append(IlluminantEstimate(method: "LocalPartition",
                    rgb: IlluminantRGB(r: r[m], g: g[m], b: b[m]), confidence: 0.6))
            }
        }

        if options.enableDualTemperature,
           let base = results.max(by: { $0.confidence < $1.confidence })?.rgb {
            let xy = rgbToXY(base)
            let cct = cctFromXY(xy)
            log(String(format: "DualTemperature：base CCT≈%.0fK", cct))
            if cct < 1800 || cct > 20000 {
                // 修复：方向反转
                // CCT < 1800（光源极暖，图偏橙红）→ 压低 R、抬高 B
                // CCT > 20000（光源极冷，图偏蓝）→ 抬高 R、压低 B
                let target = cct < 1800
                    ? IlluminantRGB(r: 0.7, g: 0.9, b: 1.2)
                    : IlluminantRGB(r: 1.2, g: 0.9, b: 0.6)
                let mixed = IlluminantRGB(
                    r: (base.r + target.r) / 2,
                    g: (base.g + target.g) / 2,
                    b: (base.b + target.b) / 2)
                results.append(IlluminantEstimate(method: "DualTemperature",
                    rgb: normalizeGM(mixed), confidence: 0.55))
                log("DualTemperature：CCT 越界，已拉回中性")
            } else {
                log("DualTemperature：CCT 在合理范围，不修正")
            }
        }

        if options.enableBayesianPrior, let prior = priorProvider?.prior(for: scene.type) {
            results.append(IlluminantEstimate(method: "BayesianPrior",
                rgb: prior.mean, confidence: 0.6))
        }
        if options.enableMLIlluminant, let ml = mlProvider?.estimate(ciImage: ciImage) {
            var e = ml
            e.rgb = normalizeGM(e.rgb)
            e.confidence = min(1.0, max(0.0, e.confidence))
            results.append(e)
        }

        for i in results.indices {
            switch scene.type {
            case .portrait:
                if results[i].method == "NeutralFilter" { results[i].confidence *= 1.2 }
                if results[i].method == "DarkChannelWeighted" { results[i].confidence *= 0.8 }
            case .landscape:
                if results[i].method == "ShadesOfGray(p=6)" { results[i].confidence *= 1.1 }
                if results[i].method == "GrayWorld" { results[i].confidence *= 0.9 }
            case .night:
                if results[i].method == "WhitePatch" { results[i].confidence *= 0.7 }
                if results[i].method == "DarkChannelWeighted" { results[i].confidence *= 0.7 }
            case .document:
                if results[i].method == "NeutralFilter" { results[i].confidence *= 1.3 }
                if results[i].method == "WhitePatch" { results[i].confidence *= 1.1 }
            case .generic:
                break
            }
            results[i].confidence = clamp(results[i].confidence, 0, 1)
        }

        return results
    }

    private func logEstimates(_ ests: [IlluminantEstimate]) {
        for e in ests {
            log(String(format: "  %@ R=%.4f G=%.4f B=%.4f conf=%.2f",
                       e.method, e.rgb.r, e.rgb.g, e.rgb.b, e.confidence))
        }
    }

    // MARK: - 光源融合
    private func fuse(ests: [IlluminantEstimate],
                      pixels: [(r: Float, g: Float, b: Float, luma: Float)]) -> IlluminantRGB? {
        var valid = ests.filter { $0.rgb.g.isFinite && $0.rgb.g > 1e-6 }
        guard !valid.isEmpty else {
            logError("融合：无有效估计")
            return nil
        }
        for i in valid.indices {
            valid[i].confidence = clamp(valid[i].confidence, 0, 1)
        }
        log("融合：\(valid.count)/\(ests.count) 个有效估计")

        func toLog(_ e: IlluminantEstimate) -> (u: Double, v: Double) {
            let g = max(e.rgb.g, 1e-6)
            return (Foundation.log(max(e.rgb.r, 1e-6) / g),
                    Foundation.log(max(e.rgb.b, 1e-6) / g))
        }

        let logPts = valid.map { toLog($0) }
        let weights = valid.map { max($0.confidence, 1e-6) }

        func weightedMedian(_ values: [Double], _ w: [Double]) -> Double {
            let order = values.indices.sorted { values[$0] < values[$1] }
            let total = w.reduce(0, +)
            var acc = 0.0
            for i in order {
                acc += w[i]
                if acc >= total / 2 { return values[i] }
            }
            return values[order.last!]
        }

        let mu = weightedMedian(logPts.map { $0.u }, weights)
        let mv = weightedMedian(logPts.map { $0.v }, weights)

        let du = logPts.map { abs($0.u - mu) }
        let dv = logPts.map { abs($0.v - mv) }
        let madU = weightedMedian(du, weights)
        let madV = weightedMedian(dv, weights)
        let thresholdU = max(2.5 * 1.4826 * madU, 0.03)
        let thresholdV = max(2.5 * 1.4826 * madV, 0.03)

        let filtered = valid.enumerated().filter {
            du[$0.offset] <= thresholdU && dv[$0.offset] <= thresholdV
        }.map { $0.element }

        // 修复：只剩 1 个估计时方差爆炸，回退到全量
        let useSet = (filtered.count >= 2) ? filtered : valid
        log("融合：MAD 剔除 \(valid.count - useSet.count) 个")

        let wSum = useSet.reduce(0.0) { $0 + $1.confidence }
        var r = 0.0, g = 0.0, b = 0.0
        for e in useSet {
            let w = e.confidence / max(wSum, 1e-9)
            let lg = Foundation.log(max(e.rgb.g, 1e-6))
            let l = toLog(e)
            r += exp(lg + l.u) * w
            g += exp(lg) * w
            b += exp(lg + l.v) * w
        }

        var center = normalizeGM(IlluminantRGB(r: r, g: g, b: b))

        if options.enableGamutConstraint {
            let score = gamutScore(illuminant: center, pixels: pixels)
            log(String(format: "融合：Gamut score=%.2f", score))
            if score < 0.7 {
                // 修复：兜底不再无条件用全图 GrayWorld（会被大色块带偏），
                // 改用中性像素（sat<0.15）的 GrayWorld
                var nr = 0.0, ng = 0.0, nb = 0.0; var nc = 0
                for p in pixels {
                    let maxC = Double(max(p.0, max(p.1, p.2)))
                    let minC = Double(min(p.0, min(p.1, p.2)))
                    let sat = maxC > 1e-6 ? (maxC - minC) / maxC : 0
                    if sat < 0.15 {
                        nr += Double(p.0); ng += Double(p.1); nb += Double(p.2); nc += 1
                    }
                }
                if nc > 100 {
                    let neutralGW = normalizeGM(IlluminantRGB(
                        r: nr / Double(nc), g: ng / Double(nc), b: nb / Double(nc)))
                    center = normalizeGM(IlluminantRGB(
                        r: (center.r + neutralGW.r) / 2,
                        g: (center.g + neutralGW.g) / 2,
                        b: (center.b + neutralGW.b) / 2))
                    log("融合：Gamut 分数过低，向中性像素 GrayWorld 拉回一半")
                } else {
                    log("融合：Gamut 分数过低，但中性像素不足，保持原值")
                }
            }
        }
        return center
    }

    private func gamutScore(illuminant: IlluminantRGB,
                             pixels: [(r: Float, g: Float, b: Float, luma: Float)]) -> Double {
        let gr = illuminant.g / max(illuminant.r, 1e-6)
        let gb = illuminant.g / max(illuminant.b, 1e-6)
        var inCount = 0, total = 0
        let step = max(1, pixels.count / 500)
        for i in stride(from: 0, to: pixels.count, by: step) {
            let p = pixels[i]
            let r = Double(p.0) * gr
            let g = Double(p.1)
            let b = Double(p.2) * gb
            // 同时检查三个通道
            if r >= 0 && r <= 1.5 && g >= 0 && g <= 1.5 && b >= 0 && b <= 1.5 {
                inCount += 1
            }
            total += 1
        }
        return total > 0 ? Double(inCount) / Double(total) : 1.0
    }

    private func normalizeGM(_ c: IlluminantRGB) -> IlluminantRGB {
        let g = max(c.g, 1e-6)
        return IlluminantRGB(r: c.r / g, g: 1.0, b: c.b / g)
    }

    // MARK: - CAT
    private func catForScene(_ s: SceneType) -> CATMethod {
        switch s {
        case .portrait: return .bradford   // 修复：vonKries 极端色温下数值稳定性差
        case .landscape: return .bradford
        case .night: return .bradford
        case .document: return .vonKries
        case .generic: return .bradford
        }
    }

    private func catMatrices(_ m: CATMethod) -> (toLMS: simd_double3x3, fromLMS: simd_double3x3) {
        switch m {
        case .vonKries:
            let to = simd_double3x3(columns: (
                SIMD3(0.4002, 0.7075, -0.0807),
                SIMD3(-0.2280, 1.1500, 0.0612),
                SIMD3(0.0, 0.0, 0.9184)))
            return (to, to.inverse)
        case .bradford:
            let to = simd_double3x3(columns: (
                SIMD3( 0.8951, -0.7502,  0.0389),
                SIMD3( 0.2664,  1.7135, -0.0685),
                SIMD3(-0.1614,  0.0367,  1.0296)))
            return (to, to.inverse)
        case .cat02:
            let to = simd_double3x3(columns: (
                SIMD3( 0.7328, -0.7036,  0.0030),
                SIMD3( 0.4296,  1.6975,  0.0136),
                SIMD3(-0.1624,  0.0061,  0.9834)))
            return (to, to.inverse)
        case .cmccat2000:
            let to = simd_double3x3(columns: (
                SIMD3( 0.7982, -0.6169,  0.0209),
                SIMD3( 0.3389,  1.5552,  0.0924),
                SIMD3(-0.1371,  0.0617,  0.8868)))
            return (to, to.inverse)
        case .xyzScaling:
            return (matrix_identity_double3x3, matrix_identity_double3x3)
        }
    }

    private func computeCATGains(fused: IlluminantRGB, method: CATMethod) -> (Double, Double, Double)? {
        let M_sRGB2XYZ = simd_double3x3(columns: (
            SIMD3(0.4124564, 0.2126729, 0.0193339),
            SIMD3(0.3575761, 0.7151522, 0.1191920),
            SIMD3(0.1804375, 0.0721750, 0.9503041)))

        let srcXYZ = M_sRGB2XYZ * SIMD3(fused.r, fused.g, fused.b)
        guard srcXYZ.y.isFinite, srcXYZ.y > 1e-6 else {
            logError("CAT：srcXYZ.Y=\(srcXYZ.y) 异常")
            return nil
        }
        let srcXYZN = srcXYZ / srcXYZ.y

        let dstXYZ = SIMD3(0.95047, 1.0, 1.08883)

        let (toLMS, _) = catMatrices(method)
        let srcLMS = toLMS * srcXYZN
        let dstLMS = toLMS * dstXYZ

        guard srcLMS.x > 1e-6, srcLMS.y > 1e-6, srcLMS.z > 1e-6,
              dstLMS.x > 1e-6, dstLMS.y > 1e-6, dstLMS.z > 1e-6 else {
            logError(String(format: "CAT：LMS 异常 src=(%.6f,%.6f,%.6f) dst=(%.6f,%.6f,%.6f)",
                            srcLMS.x, srcLMS.y, srcLMS.z,
                            dstLMS.x, dstLMS.y, dstLMS.z))
            return nil
        }

        let gL = clamp(dstLMS.x / srcLMS.x, 0.25, 4.0)
        let gM = clamp(dstLMS.y / srcLMS.y, 0.25, 4.0)
        let gS = clamp(dstLMS.z / srcLMS.z, 0.25, 4.0)
        return (gL, gM, gS)
    }

    private func buildFinalMatrix(fused: IlluminantRGB, gains: (Double, Double, Double),
                                  method: CATMethod) -> simd_double3x3 {
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
        f.rVector = CIVector(x: m[0][0], y: m[1][0], z: m[2][0], w: 0)
        f.gVector = CIVector(x: m[0][1], y: m[1][1], z: m[2][1], w: 0)
        f.bVector = CIVector(x: m[0][2], y: m[1][2], z: m[2][2], w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let out = f.outputImage else {
            logError("CIColorMatrix 输出为空")
            return nil
        }
        return out
    }

    // MARK: - 曝光/动态

    /// 修复：用 fused 增益预修正 bitmap 的 R/B，避免暖/冷光污染中位 luma
    /// 中灰参考值 0.18 保持不变（extendedLinearSRGB 中 18% 反射率 = 0.18）
    private func estimateExposureCompensation(bitmap: [Float], w: Int, h: Int,
                                              gains: IlluminantRGB) -> Double {
        var lumas: [Float] = []; lumas.reserveCapacity(w * h)
        let gr = Float(gains.r)
        let gb = Float(gains.b)
        for i in 0..<(w * h) {
            let o = i * 4
            let r = bitmap[o] * gr
            let g = bitmap[o + 1]
            let b = bitmap[o + 2] * gb
            lumas.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        lumas.sort()
        guard !lumas.isEmpty else { return 1.0 }
        let median = Double(lumas[lumas.count / 2])
        guard median > 1e-4 else {
            log("曝光：中位 luma 过低（\(median)），跳过补偿")
            return 1.0
        }
        return clamp(0.18 / median, 0.5, 2.5)
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

    /// 修复：HueTwist 的合理近似是「把最终矩阵与 identity 混合」——
    /// 这既保留 WB 增益，又把矩阵引入的色相扭转按比例衰减。
    private func correctHueTwist(_ img: CIImage, M: simd_double3x3) -> CIImage {
        let blend = 0.85
        let invBlend = 1.0 - blend
        var col0 = SIMD3<Double>(0, 0, 0)
        var col1 = SIMD3<Double>(0, 0, 0)
        var col2 = SIMD3<Double>(0, 0, 0)
        for r in 0..<3 {
            col0[r] = M[0][r] * blend + (r == 0 ? invBlend : 0)
            col1[r] = M[1][r] * blend + (r == 1 ? invBlend : 0)
            col2[r] = M[2][r] * blend + (r == 2 ? invBlend : 0)
        }
        let m2 = simd_double3x3(columns: (col0, col1, col2))
        return applyMatrix(m2, to: img) ?? img
    }

    /// 修复：真正的高光饱和压缩 —— luminance mask 局部降饱和
    private func compressSatHighlights(_ img: CIImage) -> CIImage {
        // 1) 全局降饱和版本
        let desat = img.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.6
        ])

        // 2) 计算 luma（R=G=B=luma）
        let luma = img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])

        // 3) 高光 mask：luma 在 [0.6, 0.9] 区间映射到 [0, 1]
        //    3.333 * luma - 2.0
        let mask = luma.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 3.333, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 3.333, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 3.333, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: -2.0, y: -2.0, z: -2.0, w: 0)
        ]).applyingFilter("CIColorClamp")

        // 4) mask 区域用降饱和，其余保持
        return desat.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: img,
            kCIInputMaskImageKey: mask
        ])
    }

    private func scaledMask(_ mask: CIImage, to extent: CGRect) -> CIImage {
        let sx = extent.width / max(mask.extent.width, 1)
        let sy = extent.height / max(mask.extent.height, 1)
        return mask
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: extent)
    }

    private func applyMemoryColor(_ img: CIImage, scene: Scene) -> CIImage {
        var out = img
        if let sky = scene.skyMask {
            let hue = CIFilter.hueAdjust()
            hue.inputImage = out
            // 修复：角度从 0.02 降到 0.01，降低与 CAT 色相扭转的冲突
            hue.angle = 0.01
            if let o = hue.outputImage {
                let fullSky = scaledMask(sky, to: img.extent)
                let blend = CIFilter.blendWithMask()
                blend.inputImage = o
                blend.backgroundImage = out
                blend.maskImage = fullSky
                    .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 4])
                    .cropped(to: img.extent)
                if let b = blend.outputImage {
                    out = b.cropped(to: img.extent)
                    log("  记忆色：天空色相已微调 +0.01")
                }
            }
        }
        if let veg = scene.vegMask {
            let hue = CIFilter.hueAdjust()
            hue.inputImage = out
            hue.angle = -0.01
            if let o = hue.outputImage {
                let fullVeg = scaledMask(veg, to: img.extent)
                let blend = CIFilter.blendWithMask()
                blend.inputImage = o
                blend.backgroundImage = out
                blend.maskImage = fullVeg
                    .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 4])
                    .cropped(to: img.extent)
                if let b = blend.outputImage {
                    out = b.cropped(to: img.extent)
                    log("  记忆色：植被色相已微调 -0.01")
                }
            }
        }
        return out
    }

    /// 修复：去掉对比拉伸，避免和 ToneMap 叠加，只保留饱和微调
    private func applyPerChannelCurve(_ img: CIImage) -> CIImage {
        let f = CIFilter.colorControls()
        f.inputImage = img
        f.saturation = 1.05
        f.contrast = 1.0
        f.brightness = 0.0
        return f.outputImage ?? img
    }

    private func toneMap(_ img: CIImage) -> CIImage {
        let f = CIFilter.toneCurve()
        f.inputImage = img
        f.point0 = CGPoint(x: 0.0, y: 0.0)
        f.point1 = CGPoint(x: 0.25, y: 0.22)
        f.point2 = CGPoint(x: 0.5, y: 0.5)
        f.point3 = CGPoint(x: 0.75, y: 0.78)
        f.point4 = CGPoint(x: 1.0, y: 1.0)
        return f.outputImage ?? img
    }

    /// 调用方需保证 data 为 RGBA Float32（4 通道）
    private func applyLUT3D(_ img: CIImage, lut: (size: Int, data: [Float])) -> CIImage {
        let expected = lut.size * lut.size * lut.size * 4
        guard lut.data.count == expected else {
            logError("3D LUT 数据长度不匹配：期望 \(expected)，实际 \(lut.data.count)")
            return img
        }
        let colorCube = CIFilter.colorCube()
        colorCube.inputImage = img
        colorCube.cubeDimension = Float(lut.size)
        colorCube.cubeData = Data(bytes: lut.data, count: lut.data.count * MemoryLayout<Float>.size)
        guard let out = colorCube.outputImage else {
            logError("3D LUT 应用失败")
            return img
        }
        return out
    }

    // MARK: - ΔE2000 评估
    private func meanDeltaEOfNeutrals(
        pixels: [(r: Float, g: Float, b: Float, luma: Float)],
        matrix: simd_double3x3
    ) -> Double {
        var sum = 0.0
        var cnt = 0
        for p in pixels {
            let maxC = Double(max(p.0, max(p.1, p.2)))
            let minC = Double(min(p.0, min(p.1, p.2)))
            guard maxC > 1e-6, (maxC - minC) / maxC < 0.15 else { continue }

            let src = SIMD3(Double(p.0), Double(p.1), Double(p.2))
            let out = matrix * src
            let Y = 0.2126 * out.x + 0.7152 * out.y + 0.0722 * out.z
            guard Y > 1e-6 else { continue }

            sum += deltaE2000Chroma(lab(out.x, out.y, out.z), lab(Y, Y, Y))
            cnt += 1
        }
        return cnt > 0 ? sum / Double(cnt) : 0
    }

    private func lab(_ r: Double, _ g: Double, _ b: Double) -> (L: Double, a: Double, b: Double) {
        let M = simd_double3x3(columns: (
            SIMD3(0.4124564, 0.2126729, 0.0193339),
            SIMD3(0.3575761, 0.7151522, 0.1191920),
            SIMD3(0.1804375, 0.0721750, 0.9503041)))
        let xyz = M * SIMD3(r, g, b)
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t + 16.0 / 116.0) }
        let fx = f(xyz.x / 0.95047), fy = f(xyz.y / 1.0), fz = f(xyz.z / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    private func deltaE2000Chroma(_ a: (L: Double, a: Double, b: Double),
                                   _ b: (L: Double, a: Double, b: Double)) -> Double {
        let dA = b.a - a.a, dB = b.b - a.b
        let c1 = sqrt(a.a * a.a + a.b * a.b), c2 = sqrt(b.a * b.a + b.b * b.b)
        let cBar = (c1 + c2) / 2
        let g = 0.5 * (1 - sqrt(pow(cBar, 7) / (pow(cBar, 7) + pow(25.0, 7))))
        let a1 = a.a * (1 + g), a2 = b.a * (1 + g)
        let c1p = sqrt(a1 * a1 + a.b * a.b), c2p = sqrt(a2 * a2 + b.b * b.b)
        let h1 = atan2(a.b, a1) * 180 / .pi
        let h2 = atan2(b.b, a2) * 180 / .pi
        let dHp: Double
        if c1p * c2p == 0 { dHp = 0 }
        else if abs(h2 - h1) <= 180 { dHp = h2 - h1 }
        else if (h2 - h1) > 180 { dHp = h2 - h1 - 360 }
        else { dHp = h2 - h1 + 360 }
        let dH = 2 * sqrt(c1p * c2p) * sin(dHp * .pi / 180 / 2)
        let dCp = c2p - c1p
        let cBarP = (c1p + c2p) / 2
        var hBarP = (h1 + h2) / 2
        if c1p * c2p == 0 { hBarP = h1 + h2 }
        else if abs(h1 - h2) > 180 { hBarP = (h1 + h2 + 360) / 2 }
        if hBarP >= 360 { hBarP -= 360 }
        let T = 1 - 0.17 * cos((hBarP - 30) * .pi / 180) + 0.24 * cos(2 * hBarP * .pi / 180)
                + 0.32 * cos((3 * hBarP + 6) * .pi / 180) - 0.20 * cos((4 * hBarP - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hBarP - 275) / 25, 2))
        let RC = 2 * sqrt(pow(cBarP, 7) / (pow(cBarP, 7) + pow(25.0, 7)))
        let SC = 1 + 0.045 * cBarP
        let SH = 1 + 0.015 * cBarP * T
        let RT = -sin(2 * dTheta * .pi / 180) * RC
        let cTerm = dCp / SC, hTerm = dH / SH
        return sqrt(cTerm * cTerm + hTerm * hTerm + RT * cTerm * hTerm)
    }

    private func rgbToXY(_ c: IlluminantRGB) -> (x: Double, y: Double) {
        let M = simd_double3x3(columns: (
            SIMD3(0.4124564, 0.2126729, 0.0193339),
            SIMD3(0.3575761, 0.7151522, 0.1191920),
            SIMD3(0.1804375, 0.0721750, 0.9503041)))
        let xyz = M * SIMD3(c.r, c.g, c.b)
        let s = xyz.x + xyz.y + xyz.z
        guard s > 1e-9 else { return (0.3127, 0.3290) }
        return (xyz.x / s, xyz.y / s)
    }

    private func cctFromXY(_ xy: (x: Double, y: Double)) -> Double {
        let n = (xy.x - 0.3320) / max(xy.y - 0.1858, 1e-6)
        return 449.0 * n * n * n + 3525.0 * n * n + 6823.3 * n + 5520.33
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    // MARK: - Logging
    private func log(_ message: String) {
        Task { @MainActor in
            AppLogger.shared.log("[PhotoColorRestorer] \(message)", isError: false)
        }
    }

    private func logError(_ message: String) {
        Task { @MainActor in
            AppLogger.shared.log("[PhotoColorRestorer] ❌ \(message)", isError: true)
        }
    }
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
