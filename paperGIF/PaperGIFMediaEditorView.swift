import CoreGraphics
import SwiftUI

struct PaperGIFMediaEditorView: View {
    private enum Step {
        case crop
        case adjustment
    }

    let name: String
    let sourcePreview: CGImage
    let isAnimated: Bool
    let onSave: (PaperGIFConversionRecipe) -> Void
    let onCancel: () -> Void

    @State private var recipe: PaperGIFConversionRecipe
    @State private var step: Step
    @State private var cropFramingIsCrop: Bool

    init(
        name: String,
        sourcePreview: CGImage,
        isAnimated: Bool,
        initialRecipe: PaperGIFConversionRecipe,
        isNew: Bool,
        startsAtAdjustment: Bool = false,
        onSave: @escaping (PaperGIFConversionRecipe) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.name = name
        self.sourcePreview = sourcePreview
        self.isAnimated = isAnimated
        self.onSave = onSave
        self.onCancel = onCancel
        _recipe = State(initialValue: initialRecipe)
        _step = State(initialValue: startsAtAdjustment ? .adjustment : .crop)
        _cropFramingIsCrop = State(initialValue: initialRecipe.cropRect != nil || isNew)
    }

    var body: some View {
        Group {
            switch step {
            case .crop:
                PaperGIFCropView(
                    image: sourcePreview,
                    initialCropRect: recipe.cropRect,
                    initialRotationQuarterTurns: recipe.rotationQuarterTurns,
                    initialFramingIsCrop: cropFramingIsCrop
                ) { cropRect, rotationQuarterTurns in
                    recipe.cropRect = cropRect
                    recipe.rotationQuarterTurns = rotationQuarterTurns
                    cropFramingIsCrop = cropRect != nil
                    step = .adjustment
                } onCancel: {
                    onCancel()
                }
            case .adjustment:
                PaperGIFAdjustmentView(
                    name: name,
                    sourcePreview: sourcePreview,
                    isAnimated: isAnimated,
                    recipe: $recipe
                ) {
                    step = .crop
                } onSave: {
                    onSave(recipe)
                }
            }
        }
    }
}
