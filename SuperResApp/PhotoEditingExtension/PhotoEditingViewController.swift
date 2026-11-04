import Photos
import PhotosUI
import UIKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

final class PhotoEditingViewController: UIViewController, PHContentEditingController {
    private let formatIdentifier = "com.superres.app.photo-editor"
    private var editingInput: PHContentEditingInput?
    private var sourceImage: UIImage?
    private var exposure: Float = 0

    private let imageView = UIImageView()
    private let exposureSlider = UISlider()
    private let valueLabel = UILabel()
    private let context = CIContext()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureEditorUI()
    }

    func canHandle(_ adjustmentData: PHAdjustmentData) -> Bool {
        adjustmentData.formatIdentifier == formatIdentifier
    }

    func startContentEditing(
        with contentEditingInput: PHContentEditingInput,
        placeholderImage: UIImage
    ) {
        editingInput = contentEditingInput
        sourceImage = contentEditingInput.displaySizeImage ?? placeholderImage
        imageView.image = sourceImage
        if let data = contentEditingInput.adjustmentData?.data,
           let values = try? JSONSerialization.jsonObject(with: data) as? [String: NSNumber] {
            exposure = values["exposure"]?.floatValue ?? 0
            exposureSlider.value = exposure
            updatePreview()
        }
    }

    func finishContentEditing(completionHandler: @escaping (PHContentEditingOutput?) -> Void) {
        guard let editingInput,
              let sourceURL = editingInput.fullSizeImageURL,
              let inputImage = CIImage(contentsOf: sourceURL) else {
            completionHandler(nil)
            return
        }

        let currentExposure = exposure
        let output = PHContentEditingOutput(contentEditingInput: editingInput)
        let adjustment = try? JSONSerialization.data(
            withJSONObject: ["exposure": currentExposure],
            options: [.sortedKeys]
        )
        guard let adjustment else {
            completionHandler(nil)
            return
        }
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: formatIdentifier,
            formatVersion: "1.0",
            data: adjustment
        )

        DispatchQueue.global(qos: .userInitiated).async {
            let filter = CIFilter(name: "CIExposureAdjust")
            filter?.setValue(inputImage, forKey: kCIInputImageKey)
            filter?.setValue(currentExposure, forKey: kCIInputEVKey)
            guard let rendered = filter?.outputImage,
                  let cgImage = self.context.createCGImage(rendered, from: rendered.extent.integral),
                  let destination = CGImageDestinationCreateWithURL(
                    output.renderedContentURL as CFURL,
                    UTType.jpeg.identifier as CFString,
                    1,
                    nil
                  ) else {
                DispatchQueue.main.async { completionHandler(nil) }
                return
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else {
                DispatchQueue.main.async { completionHandler(nil) }
                return
            }
            DispatchQueue.main.async { completionHandler(output) }
        }
    }

    var shouldShowCancelConfirmation: Bool { true }

    func cancelContentEditing() {
        editingInput = nil
        sourceImage = nil
    }

    private func configureEditorUI() {
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        exposureSlider.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.textAlignment = .center
        valueLabel.text = "曝光"
        exposureSlider.minimumValue = -2
        exposureSlider.maximumValue = 2
        exposureSlider.addTarget(self, action: #selector(exposureChanged), for: .valueChanged)

        let controls = UIStackView(arrangedSubviews: [valueLabel, exposureSlider])
        controls.axis = .vertical
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        view.addSubview(controls)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            imageView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12),
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
    }

    @objc private func exposureChanged() {
        exposure = exposureSlider.value
        updatePreview()
    }

    private func updatePreview() {
        guard let sourceImage, let cgImage = sourceImage.cgImage else { return }
        let input = CIImage(cgImage: cgImage)
        let filter = CIFilter(name: "CIExposureAdjust")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(exposure, forKey: kCIInputEVKey)
        guard let output = filter?.outputImage,
              let rendered = context.createCGImage(output, from: output.extent.integral) else { return }
        imageView.image = UIImage(cgImage: rendered)
        valueLabel.text = String(format: "曝光 %+.2f EV", exposure)
    }
}
