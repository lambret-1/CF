import Photos
import PhotosUI
import UIKit
import SwiftUI
import CoreImage
import UniformTypeIdentifiers

final class PhotoEditingViewController: UIViewController, PHContentEditingController {
    private let formatIdentifier = "com.superres.app.photo-editor"
    private var editingInput: PHContentEditingInput?
    private var sourceImage: UIImage?
    private var settings = DemoAdjustmentSettings()
    private var selectedPreset: DemoPhotoPreset = .original
    private var autoEnhanceEnabled = false
    private var transform = DemoImageTransform()

    private let imageView = UIImageView()
    private let scrollView = UIScrollView()
    private let controlsStack = UIStackView()
    private var presetControl: UISegmentedControl?
    private var sliders: [Int: UISlider] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureEditorUI()
    }

    func canHandle(_ adjustmentData: PHAdjustmentData) -> Bool {
        guard adjustmentData.formatIdentifier == formatIdentifier,
              let root = try? JSONSerialization.jsonObject(with: adjustmentData.data) as? [String: Any] else {
            return false
        }
        let markup = root["markupData"] as? String ?? ""
        return markup.isEmpty
    }

    func startContentEditing(
        with contentEditingInput: PHContentEditingInput,
        placeholderImage: UIImage
    ) {
        editingInput = contentEditingInput
        sourceImage = contentEditingInput.displaySizeImage ?? placeholderImage
        restoreAdjustmentData(contentEditingInput.adjustmentData?.data)
        updatePreview()
    }

    func finishContentEditing(completionHandler: @escaping (PHContentEditingOutput?) -> Void) {
        guard let editingInput,
              let sourceImage,
              let sourceURL = editingInput.fullSizeImageURL else {
            completionHandler(nil)
            return
        }

        let currentSettings = settings
        let currentPreset = selectedPreset
        let currentTransform = transform
        let useAutoEnhance = autoEnhanceEnabled
        let output = PHContentEditingOutput(contentEditingInput: editingInput)
        guard let adjustmentData = makeAdjustmentData() else {
            completionHandler(nil)
            return
        }
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: formatIdentifier,
            formatVersion: "2.0",
            data: adjustmentData
        )

        DispatchQueue.global(qos: .userInitiated).async {
            guard let rendered = DemoImageProcessor.renderCIImage(
                sourceImage,
                settings: currentSettings,
                autoEnhance: useAutoEnhance,
                filterName: currentPreset.filterName,
                transform: currentTransform,
                sourceURL: sourceURL
            ),
            let pqColorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ),
            let outputURL = try? output.renderedContentURL(for: .heic) else {
                DispatchQueue.main.async { completionHandler(nil) }
                return
            }

            do {
                try CIContext().writeHEIF10Representation(
                    of: rendered,
                    to: outputURL,
                    colorSpace: pqColorSpace,
                    options: [:]
                )
                DispatchQueue.main.async { completionHandler(output) }
            } catch {
                DispatchQueue.main.async { completionHandler(nil) }
            }
        }
    }

    var shouldShowCancelConfirmation: Bool { true }

    func cancelContentEditing() {
        editingInput = nil
        sourceImage = nil
    }

    private func configureEditorUI() {
        imageView.contentMode = .scaleAspectFit
        imageView.preferredImageDynamicRange = .high
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        controlsStack.axis = .vertical
        controlsStack.spacing = 10
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        let autoButton = UIButton(type: .system)
        autoButton.setTitle("自动增强", for: .normal)
        autoButton.addTarget(self, action: #selector(toggleAutoEnhance), for: .touchUpInside)
        controlsStack.addArrangedSubview(autoButton)

        let presets = DemoPhotoPreset.allCases.filter { $0 != .custom }
        let preset = UISegmentedControl(items: presets.map(\.title))
        preset.selectedSegmentIndex = 0
        preset.addTarget(self, action: #selector(presetChanged(_:)), for: .valueChanged)
        presetControl = preset
        controlsStack.addArrangedSubview(preset)

        addSlider("曝光", tag: 0, range: -4...4, value: Float(settings.exposure))
        addSlider("亮度", tag: 1, range: -0.5...0.5, value: Float(settings.brightness))
        addSlider("对比度", tag: 2, range: 0...2, value: Float(settings.contrast))
        addSlider("饱和度", tag: 3, range: 0...2, value: Float(settings.saturation))
        addSlider("自然饱和度", tag: 4, range: -1...1, value: Float(settings.vibrance))
        addSlider("高光", tag: 5, range: -1...1, value: Float(settings.highlights))
        addSlider("阴影", tag: 6, range: -1...1, value: Float(settings.shadows))
        addSlider("色温", tag: 7, range: 2500...10000, value: Float(settings.temperature))
        addSlider("色调", tag: 8, range: -150...150, value: Float(settings.tint))
        addSlider("锐度", tag: 9, range: 0...2, value: Float(settings.sharpness))
        addSlider("降噪", tag: 10, range: 0...0.1, value: Float(settings.noiseReduction))
        addSlider("暗角", tag: 11, range: -2...2, value: Float(settings.vignette))

        view.addSubview(imageView)
        view.addSubview(scrollView)
        scrollView.addSubview(controlsStack)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            imageView.bottomAnchor.constraint(equalTo: scrollView.topAnchor, constant: -8),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            scrollView.heightAnchor.constraint(equalToConstant: 250),
            controlsStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            controlsStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            controlsStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            controlsStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            controlsStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
    }

    private func addSlider(_ title: String, tag: Int, range: ClosedRange<Float>, value: Float) {
        let row = UIStackView()
        row.axis = .vertical
        row.spacing = 2
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.text = title
        let slider = UISlider()
        slider.minimumValue = range.lowerBound
        slider.maximumValue = range.upperBound
        slider.value = value
        slider.tag = tag
        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        row.addArrangedSubview(label)
        row.addArrangedSubview(slider)
        controlsStack.addArrangedSubview(row)
        sliders[tag] = slider
    }

    @objc private func toggleAutoEnhance() {
        autoEnhanceEnabled.toggle()
        if autoEnhanceEnabled {
            selectedPreset = .original
            presetControl?.selectedSegmentIndex = 0
        }
        updatePreview()
    }

    @objc private func presetChanged(_ sender: UISegmentedControl) {
        let presets = DemoPhotoPreset.allCases.filter { $0 != .custom }
        guard presets.indices.contains(sender.selectedSegmentIndex) else { return }
        selectedPreset = presets[sender.selectedSegmentIndex]
        autoEnhanceEnabled = false
        updatePreview()
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        let value = Double(sender.value)
        switch sender.tag {
        case 0: settings.exposure = value
        case 1: settings.brightness = value
        case 2: settings.contrast = value
        case 3: settings.saturation = value
        case 4: settings.vibrance = value
        case 5: settings.highlights = value
        case 6: settings.shadows = value
        case 7: settings.temperature = value
        case 8: settings.tint = value
        case 9: settings.sharpness = value
        case 10: settings.noiseReduction = value
        case 11: settings.vignette = value
        default: break
        }
        selectedPreset = .custom
        autoEnhanceEnabled = false
        updatePreview()
    }

    private func updatePreview() {
        guard let sourceImage,
              let rendered = DemoImageProcessor.renderCIImage(
                sourceImage,
                settings: settings,
                autoEnhance: autoEnhanceEnabled,
                filterName: selectedPreset.filterName,
                transform: transform,
                sourceURL: editingInput?.fullSizeImageURL
              ),
              let preview = DemoImageProcessor.makePreviewImage(from: rendered) else {
            imageView.image = sourceImage
            return
        }
        imageView.image = preview
    }

    private func makeAdjustmentData() -> Data? {
        let values: [String: Any] = [
            "settings": [
                "exposure": settings.exposure,
                "brightness": settings.brightness,
                "contrast": settings.contrast,
                "saturation": settings.saturation,
                "vibrance": settings.vibrance,
                "highlights": settings.highlights,
                "shadows": settings.shadows,
                "temperature": settings.temperature,
                "tint": settings.tint,
                "sharpness": settings.sharpness,
                "noiseReduction": settings.noiseReduction,
                "vignette": settings.vignette
            ],
            "preset": selectedPreset.rawValue,
            "autoEnhance": autoEnhanceEnabled,
            "rotation": transform.quarterTurnsClockwise,
            "horizontalFlip": transform.isHorizontallyFlipped,
            "squareCrop": transform.usesSquareCrop,
            "straightenAngle": transform.straightenAngle,
            "perspectiveCorrection": transform.usesPerspectiveCorrection,
            "depthBlur": transform.usesDepthBlur,
            "cropAspectRatio": transform.cropAspectRatio ?? 0,
            "cropRect": transform.cropRect.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] } ?? []
        ]
        return try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    }

    private func refreshSliders() {
        sliders[0]?.value = Float(settings.exposure)
        sliders[1]?.value = Float(settings.brightness)
        sliders[2]?.value = Float(settings.contrast)
        sliders[3]?.value = Float(settings.saturation)
        sliders[4]?.value = Float(settings.vibrance)
        sliders[5]?.value = Float(settings.highlights)
        sliders[6]?.value = Float(settings.shadows)
        sliders[7]?.value = Float(settings.temperature)
        sliders[8]?.value = Float(settings.tint)
        sliders[9]?.value = Float(settings.sharpness)
        sliders[10]?.value = Float(settings.noiseReduction)
        sliders[11]?.value = Float(settings.vignette)
    }

    private func restoreAdjustmentData(_ data: Data?) {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let values = root["settings"] as? [String: Double] {
            settings.exposure = values["exposure"] ?? 0
            settings.brightness = values["brightness"] ?? 0
            settings.contrast = values["contrast"] ?? 1
            settings.saturation = values["saturation"] ?? 1
            settings.vibrance = values["vibrance"] ?? 0
            settings.highlights = values["highlights"] ?? 0
            settings.shadows = values["shadows"] ?? 0
            settings.temperature = values["temperature"] ?? 6500
            settings.tint = values["tint"] ?? 0
            settings.sharpness = values["sharpness"] ?? 0
            settings.noiseReduction = values["noiseReduction"] ?? 0
            settings.vignette = values["vignette"] ?? 0
        }
        if let rawPreset = root["preset"] as? String,
           let preset = DemoPhotoPreset(rawValue: rawPreset) {
            selectedPreset = preset
            let presets = DemoPhotoPreset.allCases.filter { $0 != .custom }
            presetControl?.selectedSegmentIndex = presets.firstIndex(of: preset) ?? 0
        }
        autoEnhanceEnabled = root["autoEnhance"] as? Bool ?? false
        refreshSliders()
        transform.quarterTurnsClockwise = root["rotation"] as? Int ?? 0
        transform.isHorizontallyFlipped = root["horizontalFlip"] as? Bool ?? false
        transform.usesSquareCrop = root["squareCrop"] as? Bool ?? false
        transform.straightenAngle = root["straightenAngle"] as? Double ?? 0
        transform.usesPerspectiveCorrection = root["perspectiveCorrection"] as? Bool ?? false
        transform.usesDepthBlur = root["depthBlur"] as? Bool ?? false
        let ratio = root["cropAspectRatio"] as? Double ?? 0
        transform.cropAspectRatio = ratio > 0 ? ratio : nil
        if let crop = root["cropRect"] as? [Double], crop.count == 4 {
            transform.cropRect = CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3])
        }
    }
}
