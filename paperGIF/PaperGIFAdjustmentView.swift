import CoreGraphics
import SwiftUI

struct PaperGIFAdjustmentView: View {
    private struct PreviewKey: Hashable {
        let cropX: Double?
        let cropY: Double?
        let cropWidth: Double?
        let cropHeight: Double?
        let rotationQuarterTurns: Int
        let monochromeMode: PaperGIFMonochromeMode
        let threshold: Int
        let monochromeLevels: Int
        let halftoneDotSpacing: Int
        let halftoneAngle: Int
        let halftoneDotGain: Int
    }

    let name: String
    let sourcePreview: CGImage
    let isAnimated: Bool
    @Binding var recipe: PaperGIFConversionRecipe
    let onBack: () -> Void
    let onSave: () -> Void

    @State private var previewImage: CGImage?
    @State private var previewFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    preview
                        .aspectRatio(
                            CGFloat(PaperGIFAnimation.width) / CGFloat(PaperGIFAnimation.height),
                            contentMode: .fit
                        )
                        .frame(maxHeight: 500)
                        .frame(maxWidth: .infinity)

                    VStack(spacing: 18) {
                        Picker("Rendering", selection: $recipe.monochromeMode) {
                            ForEach(PaperGIFMonochromeMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        if recipe.monochromeMode.usesThreshold {
                            LabeledContent("Black threshold") {
                                Text("\(Int(recipe.threshold))")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $recipe.threshold, in: 32...224, step: 1)
                        }

                        if recipe.monochromeMode.usesMonochromeLevels {
                            LabeledContent("Monochrome levels") {
                                Text(recipe.monochromeLevels == 0 ? "Off" : "\(recipe.monochromeLevels)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(recipe.monochromeLevels) },
                                    set: { recipe.monochromeLevels = Int($0.rounded()) }
                                ),
                                in: 0...16,
                                step: 1
                            )
                        }

                        if recipe.monochromeMode.usesHalftone {
                            Stepper(
                                "Dot spacing: \(recipe.halftoneDotSpacing) px",
                                value: $recipe.halftoneDotSpacing,
                                in: 3...24
                            )
                            Stepper(
                                "Screen angle: \(recipe.halftoneAngle)°",
                                value: $recipe.halftoneAngle,
                                in: 0...90,
                                step: 15
                            )
                            Stepper(
                                "Dot gain: \(recipe.halftoneDotGain)%",
                                value: $recipe.halftoneDotGain,
                                in: -50...50,
                                step: 5
                            )
                        }

                        if isAnimated {
                            LabeledContent("Maximum frame rate") {
                                Text("\(Int(recipe.maximumFramesPerSecond)) fps")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $recipe.maximumFramesPerSecond, in: 1...30, step: 1)
                        }

                        DisclosureGroup("Display tuning") {
                            VStack(spacing: 16) {
                                Picker("Panel scan rate", selection: $recipe.scanRateHz) {
                                    Text("30 Hz").tag(30)
                                    Text("40 Hz").tag(40)
                                    Text("50 Hz").tag(50)
                                    Text("60 Hz").tag(60)
                                }

                                Stepper(
                                    "Transition scans: \(recipe.transitionScans)",
                                    value: $recipe.transitionScans,
                                    in: 1...9
                                )

                                Toggle("Adaptive cleaning", isOn: $recipe.adaptiveCleaning)

                                if recipe.adaptiveCleaning {
                                    Stepper(
                                        "Clean after \(recipe.cleanRefreshInterval) updates",
                                        value: $recipe.cleanRefreshInterval,
                                        in: 30...600,
                                        step: 30
                                    )
                                }
                            }
                            .padding(.top, 14)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Button(action: onBack) {
                        Label("Crop", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(action: onSave) {
                        Label("Save", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(previewImage == nil)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: previewKey) {
                await updatePreview()
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let previewImage {
            Image(decorative: previewImage, scale: 1)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .background(.white)
                .overlay {
                    Rectangle().stroke(.secondary.opacity(0.4))
                }
        } else if previewFailed {
            ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle")
        } else {
            ProgressView()
        }
    }

    private func updatePreview() async {
        previewFailed = false
        let sourcePreview = sourcePreview
        let monochromeMode = recipe.monochromeMode
        let threshold = UInt8(clamping: Int(recipe.threshold.rounded()))
        let monochromeLevels = recipe.monochromeLevels
        let halftoneDotSpacing = recipe.halftoneDotSpacing
        let halftoneAngle = recipe.halftoneAngle
        let halftoneDotGain = recipe.halftoneDotGain
        let cropRect = recipe.cropRect
        let rotationQuarterTurns = recipe.rotationQuarterTurns
        do {
            let image = try await Task.detached(priority: .userInitiated) {
                try PaperGIFEncoder.monochromePreview(
                    image: sourcePreview,
                    monochromeMode: monochromeMode,
                    threshold: threshold,
                    monochromeLevels: monochromeLevels,
                    halftoneDotSpacing: halftoneDotSpacing,
                    halftoneAngle: halftoneAngle,
                    halftoneDotGain: halftoneDotGain,
                    cropRect: cropRect,
                    rotationQuarterTurns: rotationQuarterTurns
                )
            }.value
            guard !Task.isCancelled else { return }
            previewImage = image
        } catch {
            guard !Task.isCancelled else { return }
            previewImage = nil
            previewFailed = true
        }
    }

    private var previewKey: PreviewKey {
        PreviewKey(
            cropX: recipe.cropRect.map { Double($0.origin.x) },
            cropY: recipe.cropRect.map { Double($0.origin.y) },
            cropWidth: recipe.cropRect.map { Double($0.width) },
            cropHeight: recipe.cropRect.map { Double($0.height) },
            rotationQuarterTurns: recipe.rotationQuarterTurns,
            monochromeMode: recipe.monochromeMode,
            threshold: Int(recipe.threshold),
            monochromeLevels: recipe.monochromeLevels,
            halftoneDotSpacing: recipe.halftoneDotSpacing,
            halftoneAngle: recipe.halftoneAngle,
            halftoneDotGain: recipe.halftoneDotGain
        )
    }
}
