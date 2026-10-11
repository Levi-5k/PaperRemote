import PhotosUI
import SwiftUI

extension PaperGIFRemoteButtonBackground {
    var title: String {
        switch self {
        case .outline: "Outline"
        case .filled: "Filled"
        case .shaded: "Shaded"
        case .borderless: "Borderless"
        }
    }
}

extension PaperGIFRemoteButtonTextureKind {
    var title: String {
        switch self {
        case .none: "None"
        case .pattern: "Pattern"
        case .image: "Image"
        }
    }
}

extension PaperGIFRemoteButtonPattern {
    var title: String {
        switch self {
        case .hexagons: "Hexagons"
        case .triangles: "Triangles"
        case .grid: "Grid"
        case .dots: "Dots"
        case .diagonal: "Diagonal Lines"
        case .checker: "Checkerboard"
        case .waves: "Sine Waves"
        case .rings: "Rings"
        case .spiral: "Spiral"
        case .truchet: "Truchet Arcs"
        }
    }
}

/// Idle button fill as the M5Paper draws it, at `scale` points per device pixel.
struct PaperGIFButtonBackgroundPreview: View {
    let background: PaperGIFRemoteButtonBackground
    let texture: PaperGIFRemoteButtonTexture
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: CGFloat

    var body: some View {
        let radius = max(0, min(10, min(pixelWidth, pixelHeight) / 2))
        let shape = RoundedRectangle(cornerRadius: CGFloat(radius) * scale)
        ZStack {
            if let image = PaperGIFButtonTextureRenderer.image(
                texture: texture,
                background: background,
                width: pixelWidth,
                height: pixelHeight,
                radius: radius
            ) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(scale >= 1 ? .none : .medium)
            } else {
                shape.fill(Color(white: Double(background.idleFillLuminance) / 255))
            }
            if background.hasIdleBorder {
                shape.strokeBorder(Color.black, lineWidth: max(1, scale))
            }
        }
    }
}

/// Fill controls shared by the remote-wide default and per-button overrides.
struct PaperGIFButtonTextureEditor: View {
    @Binding var texture: PaperGIFRemoteButtonTexture
    let background: PaperGIFRemoteButtonBackground
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        Section {
            PaperGIFButtonBackgroundPreview(
                background: background,
                texture: texture,
                pixelWidth: 240,
                pixelHeight: 120,
                scale: 1
            )
            .frame(width: 240, height: 120)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            Picker("Fill", selection: $texture.kind) {
                ForEach(PaperGIFRemoteButtonTextureKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Fill")
        }

        if texture.kind == .pattern {
            Section("Pattern") {
                Picker("Pattern", selection: $texture.pattern) {
                    ForEach(PaperGIFRemoteButtonPattern.allCases) { pattern in
                        Text(pattern.title).tag(pattern)
                    }
                }
                Stepper("Size: \(texture.scale) px", value: $texture.scale, in: 6...64, step: 2)
                Stepper("Line width: \(texture.lineWidth) px", value: $texture.lineWidth, in: 1...8)
            }
        }

        if texture.kind == .image {
            imageSection
        }

        if texture.kind != .none {
            Section {
                LabeledContent("Fade") {
                    Text("\(texture.fade)%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(texture.fade) },
                        set: { texture.fade = Int($0.rounded()) }
                    ),
                    in: 0...90,
                    step: 5
                )
            } footer: {
                Text("Fade lightens the fill so labels stay readable. Pressed buttons show a solid fill.")
            }
        }
    }

    @ViewBuilder
    private var imageSection: some View {
        Section {
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label(texture.imageID == nil ? "Choose Image" : "Replace Image", systemImage: "photo")
            }
            .disabled(isImporting)
            if isImporting {
                ProgressView()
            }
            if let importError {
                Text(importError)
                    .foregroundStyle(.secondary)
            }

            Picker("Rendering", selection: $texture.mode) {
                ForEach(PaperGIFMonochromeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if texture.mode.usesThreshold {
                LabeledContent("Black threshold") {
                    Text("\(texture.threshold)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(texture.threshold) },
                        set: { texture.threshold = Int($0.rounded()) }
                    ),
                    in: 32...224,
                    step: 1
                )
            }

            if texture.mode.usesMonochromeLevels {
                LabeledContent("Monochrome levels") {
                    Text(texture.levels == 0 ? "Off" : "\(texture.levels)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(texture.levels) },
                        set: { texture.levels = Int($0.rounded()) }
                    ),
                    in: 0...16,
                    step: 1
                )
            }

            if texture.mode.usesHalftone {
                Stepper("Dot spacing: \(texture.dotSpacing) px", value: $texture.dotSpacing, in: 3...24)
                Stepper("Screen angle: \(texture.angle)°", value: $texture.angle, in: 0...90, step: 15)
                Stepper("Dot gain: \(texture.dotGain)%", value: $texture.dotGain, in: -50...50, step: 5)
            }
        } header: {
            Text("Image")
        } footer: {
            Text("Images are converted like your media and sent to the M5Paper over Bluetooth with the remote. Each button shows a centered crop.")
        }
        .onChange(of: selectedPhoto) {
            guard let selectedPhoto else { return }
            importPhoto(selectedPhoto)
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        isImporting = true
        importError = nil
        Task {
            defer {
                isImporting = false
                selectedPhoto = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw PaperGIFError.invalidMedia
                }
                let id = UUID()
                try await Task.detached(priority: .userInitiated) {
                    let file = try PaperGIFButtonImageStore.makeImageFile(from: data)
                    try PaperGIFButtonImageStore.save(file, id: id)
                }.value
                texture.imageID = id
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

/// Remote-wide default button background.
struct PaperGIFButtonBackgroundSettings: View {
    @Binding var background: PaperGIFRemoteButtonBackground
    @Binding var texture: PaperGIFRemoteButtonTexture

    var body: some View {
        Form {
            Section {
                Picker("Style", selection: $background) {
                    ForEach(PaperGIFRemoteButtonBackground.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } header: {
                Text("Style")
            } footer: {
                Text("The default for every button. Individual buttons can override it.")
            }
            PaperGIFButtonTextureEditor(texture: $texture, background: background)
        }
        .navigationTitle("Button Background")
    }
}

/// Per-button background override.
struct PaperGIFControlBackgroundEditor: View {
    @Binding var control: PaperGIFRemoteControl
    let defaultBackground: PaperGIFRemoteButtonBackground
    let defaultTexture: PaperGIFRemoteButtonTexture

    var body: some View {
        Form {
            Section("Style") {
                Picker("Style", selection: $control.buttonBackground) {
                    Text("Default (\(defaultBackground.title))")
                        .tag(PaperGIFRemoteButtonBackground?.none)
                    ForEach(PaperGIFRemoteButtonBackground.allCases) { style in
                        Text(style.title).tag(Optional(style))
                    }
                }
            }
            Section {
                Toggle("Use Default Fill", isOn: Binding(
                    get: { control.buttonTexture == nil },
                    set: { control.buttonTexture = $0 ? nil : defaultTexture }
                ))
            } footer: {
                Text("Default fill: \(defaultTexture.kind == .pattern ? defaultTexture.pattern.title : defaultTexture.kind.title).")
            }
            if control.buttonTexture == nil {
                Section {
                    PaperGIFButtonBackgroundPreview(
                        background: effectiveBackground,
                        texture: defaultTexture,
                        pixelWidth: 240,
                        pixelHeight: 120,
                        scale: 1
                    )
                    .frame(width: 240, height: 120)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
            } else {
                PaperGIFButtonTextureEditor(
                    texture: Binding(
                        get: { control.buttonTexture ?? defaultTexture },
                        set: { control.buttonTexture = $0 }
                    ),
                    background: effectiveBackground
                )
            }
        }
        .navigationTitle("Background")
    }

    private var effectiveBackground: PaperGIFRemoteButtonBackground {
        control.buttonBackground ?? defaultBackground
    }
}
