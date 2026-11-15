import PhotosUI
import PaperDeviceKit
import SwiftUI
import UIKit

enum PaperGIFButtonColors {
    static func color(_ hex: String) -> Color {
        let digits = hex.filter(\.isHexDigit)
        let value = UInt32(digits, radix: 16) ?? 0
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
            blue: Double(value & 255) / 255)
    }

    /// `202020` means the style's own text color. Anything else is an explicit text and icon color.
    static func textColor(tintHex: String, style: PaperGIFRemoteButtonBackground) -> Color {
        tintHex.filter(\.isHexDigit).caseInsensitiveCompare("202020") == .orderedSame
            ? (style == .filled ? .white : .black)
            : color(tintHex)
    }

    static func hex(_ color: Color) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

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
    var backgroundHex: String? = nil
    var foregroundHex: String? = nil
    var imageTintHex: String? = nil
    var retina = false
    var smooth = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let density = retina ? max(displayScale, 1) : 1
        let width = max(1, Int((CGFloat(pixelWidth) * density).rounded()))
        let height = max(1, Int((CGFloat(pixelHeight) * density).rounded()))
        let radius = max(0, min(Int((10 * density).rounded()), min(width, height) / 2))
        let shape = RoundedRectangle(cornerRadius: CGFloat(radius) * scale / density)
        ZStack {
            if let image = PaperGIFButtonTextureRenderer.image(
                texture: texture,
                background: background,
                width: width,
                height: height,
                radius: radius,
                backgroundHex: backgroundHex, foregroundHex: foregroundHex, imageTintHex: imageTintHex
            ) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(retina || smooth ? .high : (scale >= 1 ? .none : .medium))
            } else {
                shape.fill(backgroundHex.map(PaperGIFButtonColors.color) ?? Color(white: Double(background.idleFillLuminance) / 255))
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
    var pixelWidth = 240
    var pixelHeight = 120
    var allowsColorImages = false
    var fullResolutionColor = false
    var backgroundHex: String? = nil
    var foregroundHex: String? = nil
    var imageTintHex: String? = nil
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var cropSource: CGImage?
    @State private var showingCrop = false
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        Section {
            PaperGIFButtonBackgroundPreview(
                background: background,
                texture: texture,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                scale: min(240 / CGFloat(max(1, pixelWidth)), 240 / CGFloat(max(1, pixelHeight))),
                backgroundHex: backgroundHex, foregroundHex: foregroundHex, imageTintHex: imageTintHex,
                retina: fullResolutionColor
            )
            .aspectRatio(CGFloat(max(1, pixelWidth)) / CGFloat(max(1, pixelHeight)), contentMode: .fit)
            .frame(maxWidth: 240, maxHeight: 240)
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
            if allowsColorImages { Toggle("Full Color", isOn: $texture.preserveColor) }
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
            if fullResolutionColor && texture.imageID != nil && !texture.preserveColor {
                Text("Replace the image to keep its color. This one was saved for a panel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !(fullResolutionColor && texture.preserveColor) {
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
            }
        } header: {
            Text("Image")
        }
        .onChange(of: selectedPhoto) {
            guard let selectedPhoto else { return }
            importPhoto(selectedPhoto)
        }
        .sheet(isPresented: $showingCrop) {
            if let cropSource {
                PaperGIFCropView(image: cropSource, targetSize: CGSize(width: pixelWidth, height: pixelHeight),
                    confirmationTitle: "Use Image") { rect, turns in
                    showingCrop = false
                    isImporting = true
                    let keepColor = fullResolutionColor
                    let keepPanelColor = allowsColorImages
                    Task {
                        defer { isImporting = false }
                        do {
                            let id = UUID()
                            let width = max(1, pixelWidth), height = max(1, pixelHeight)
                            try await Task.detached(priority: .userInitiated) {
                                let rotated = try PaperGIFEncoder.rotatedImage(cropSource, quarterTurns: turns)
                                let cropped = try DeviceImageEncoder.crop(rotated, normalizedRect: rect)
                                if keepColor {
                                    let file = try PaperGIFButtonImageStore.makePhoneImageFile(from: cropped)
                                    try PaperGIFButtonImageStore.save(file, id: id)
                                } else {
                                    let framed = try DeviceImageEncoder.encode(cropped,
                                        for: DeviceDisplay(width: width, height: height, touch: false, pixelFormat: "rgb565"))
                                    let file = try PaperGIFButtonImageStore.makeImageFile(from: framed.preview, color: keepPanelColor)
                                    try PaperGIFButtonImageStore.save(file, id: id)
                                }
                            }.value
                            texture.imageID = id
                            if keepColor {
                                texture.preserveColor = true
                                texture.fade = 0
                            }
                        } catch { importError = error.localizedDescription }
                    }
                } onCancel: { showingCrop = false }
            }
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
                cropSource = try await Task.detached(priority: .userInitiated) {
                    try PaperGIFEncoder.previewImage(from: data)
                }.value
                showingCrop = true
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
    var allowsColorImages = false
    var fullResolutionColor = false

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
            PaperGIFButtonTextureEditor(texture: $texture, background: background, allowsColorImages: allowsColorImages,
                fullResolutionColor: fullResolutionColor)
        }
        .navigationTitle("Button Background")
    }
}

/// Per-button background override.
struct PaperGIFControlBackgroundEditor: View {
    @Binding var control: PaperGIFRemoteControl
    let defaultBackground: PaperGIFRemoteButtonBackground
    let defaultTexture: PaperGIFRemoteButtonTexture
    var targetSize = CGSize(width: 240, height: 120)
    var allowsColorImages = false
    var fullResolutionColor = false

    var body: some View {
        Form {
            Section("Colors") {
                ColorPicker("Text & Icon", selection: Binding(
                    get: { PaperGIFButtonColors.color(control.tintHex) },
                    set: { control.tintHex = PaperGIFButtonColors.hex($0) }), supportsOpacity: false)
                Toggle("Custom Background", isOn: Binding(get: { control.backgroundTintHex != nil },
                    set: { control.backgroundTintHex = $0 ? "FFFFFF" : nil }))
                if control.backgroundTintHex != nil {
                    ColorPicker("Background", selection: Binding(
                        get: { PaperGIFButtonColors.color(control.backgroundTintHex ?? "FFFFFF") },
                        set: { control.backgroundTintHex = PaperGIFButtonColors.hex($0) }), supportsOpacity: false)
                }
                Toggle("Tint Image / Pattern", isOn: Binding(get: { control.imageTintHex != nil },
                    set: { control.imageTintHex = $0 ? control.tintHex : nil }))
                if control.imageTintHex != nil {
                    ColorPicker("Image / Pattern", selection: Binding(
                        get: { PaperGIFButtonColors.color(control.imageTintHex ?? control.tintHex) },
                        set: { control.imageTintHex = PaperGIFButtonColors.hex($0) }), supportsOpacity: false)
                }
                Button { control.tintHex = "202020"; control.backgroundTintHex = nil; control.imageTintHex = nil }
                    label: { Label("Reset Colors", systemImage: "arrow.counterclockwise") }
            }
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
                        scale: 1, backgroundHex: control.backgroundTintHex,
                        foregroundHex: control.tintHex == "202020" ? nil : control.tintHex,
                        imageTintHex: control.imageTintHex,
                        retina: fullResolutionColor
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
                    background: effectiveBackground,
                    pixelWidth: max(1, Int(targetSize.width)),
                    pixelHeight: max(1, Int(targetSize.height)),
                    allowsColorImages: allowsColorImages,
                    fullResolutionColor: fullResolutionColor,
                    backgroundHex: control.backgroundTintHex,
                    foregroundHex: control.tintHex == "202020" ? nil : control.tintHex,
                    imageTintHex: control.imageTintHex
                )
            }
        }
        .navigationTitle("Background")
    }

    private var effectiveBackground: PaperGIFRemoteButtonBackground {
        control.buttonBackground ?? defaultBackground
    }
}
