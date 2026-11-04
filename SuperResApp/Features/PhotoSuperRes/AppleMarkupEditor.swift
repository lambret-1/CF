import PencilKit
import SwiftUI
import UIKit

struct AppleMarkupEditor: View {
    let image: UIImage
    let onCancel: () -> Void
    let onSave: (PKDrawing) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var drawing = PKDrawing()

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let fitScale = min(
                    geometry.size.width / max(image.size.width, 1),
                    geometry.size.height / max(image.size.height, 1)
                )
                let fittedSize = CGSize(
                    width: image.size.width * fitScale,
                    height: image.size.height * fitScale
                )
                ZStack {
                    Color.black
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                        PencilCanvas(drawing: $drawing)
                    }
                    .frame(width: fittedSize.width, height: fittedSize.height)
                }
            }
            .navigationTitle("标注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onSave(drawing)
                        dismiss()
                    }
                    .disabled(drawing.strokes.isEmpty)
                }
            }
        }
    }

}

private struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 5)
        canvas.delegate = context.coordinator
        context.coordinator.canvasView = canvas
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        @Binding private var drawing: PKDrawing
        weak var canvasView: PKCanvasView?

        init(drawing: Binding<PKDrawing>) {
            _drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing = canvasView.drawing
        }
    }
}
