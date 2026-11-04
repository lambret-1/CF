import SwiftUI
import UIKit

struct AppleFreeCropEditor: View {
    let image: UIImage
    let onCancel: () -> Void
    let onApply: (CGRect) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cropRect = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let scale = min(
                    geometry.size.width / max(image.size.width, 1),
                    geometry.size.height / max(image.size.height, 1)
                )
                let fittedSize = CGSize(
                    width: image.size.width * scale,
                    height: image.size.height * scale
                )
                ZStack {
                    Color.black
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                        CropSelectionOverlay(rect: $cropRect)
                    }
                    .frame(width: fittedSize.width, height: fittedSize.height)
                }
            }
            .navigationTitle("自由裁剪")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        onApply(cropRect)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct CropSelectionOverlay: View {
    @Binding var rect: CGRect
    @State private var moveStart: CGRect?
    @State private var resizeStart: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let selection = CGRect(
                x: rect.minX * bounds.width,
                y: rect.minY * bounds.height,
                width: rect.width * bounds.width,
                height: rect.height * bounds.height
            )

            ZStack(alignment: .topLeading) {
                Path { path in
                    path.addRect(bounds)
                    path.addRect(selection)
                }
                .fill(Color.black.opacity(0.48), style: FillStyle(eoFill: true))

                Rectangle()
                    .stroke(Color.white, lineWidth: 1.5)
                    .frame(width: selection.width, height: selection.height)
                    .position(x: selection.midX, y: selection.midY)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if moveStart == nil { moveStart = rect }
                                guard let start = moveStart else { return }
                                let dx = value.translation.width / max(bounds.width, 1)
                                let dy = value.translation.height / max(bounds.height, 1)
                                rect.origin.x = min(max(0, start.minX + dx), 1 - start.width)
                                rect.origin.y = min(max(0, start.minY + dy), 1 - start.height)
                            }
                            .onEnded { _ in moveStart = nil }
                    )

                corner(.topLeft, at: CGPoint(x: selection.minX, y: selection.minY), in: bounds)
                corner(.topRight, at: CGPoint(x: selection.maxX, y: selection.minY), in: bounds)
                corner(.bottomLeft, at: CGPoint(x: selection.minX, y: selection.maxY), in: bounds)
                corner(.bottomRight, at: CGPoint(x: selection.maxX, y: selection.maxY), in: bounds)
            }
        }
    }

    private func corner(_ corner: CropCorner, at point: CGPoint, in bounds: CGRect) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
            .frame(width: 16, height: 16)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if resizeStart == nil { resizeStart = rect }
                        guard let start = resizeStart else { return }
                        let dx = value.translation.width / max(bounds.width, 1)
                        let dy = value.translation.height / max(bounds.height, 1)
                        let minimum = 0.12
                        var next = start
                        switch corner {
                        case .topLeft:
                            let x = min(start.minX + dx, start.maxX - minimum)
                            let y = min(start.minY + dy, start.maxY - minimum)
                            next = CGRect(x: max(0, x), y: max(0, y), width: start.maxX - max(0, x), height: start.maxY - max(0, y))
                        case .topRight:
                            let x = max(start.minX + minimum, start.maxX + dx)
                            let y = min(start.minY + dy, start.maxY - minimum)
                            next = CGRect(x: start.minX, y: max(0, y), width: min(1, x) - start.minX, height: start.maxY - max(0, y))
                        case .bottomLeft:
                            let x = min(start.minX + dx, start.maxX - minimum)
                            let y = max(start.minY + minimum, start.maxY + dy)
                            next = CGRect(x: max(0, x), y: start.minY, width: start.maxX - max(0, x), height: min(1, y) - start.minY)
                        case .bottomRight:
                            next.size.width = min(1 - start.minX, max(minimum, start.width + dx))
                            next.size.height = min(1 - start.minY, max(minimum, start.height + dy))
                        }
                        rect = next
                    }
                    .onEnded { _ in resizeStart = nil }
            )
    }

    private enum CropCorner {
        case topLeft, topRight, bottomLeft, bottomRight
    }
}
