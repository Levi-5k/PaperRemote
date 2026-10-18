import SwiftUI
import ImageIO

public struct DeviceBoardPreview: View {
    public let layout: DeviceLayout
    public let inputs: [DeviceInput]
    public let selectedInputID: String?
    public let onSelect: (String) -> Void
    /// Live shaft angles in degrees (clockwise from top), keyed by input ID; turns those inputs.
    /// Pass unwrapped angles (for example 359 → 361, not 359 → 1) so a knob never spins the long way.
    public let inputAngles: [String: Double]
    /// Interpolation between angle updates: about one update interval, so motion is continuous.
    public let angleSmoothing: Double

    public init(layout: DeviceLayout, inputs: [DeviceInput], selectedInputID: String?,
                inputAngles: [String: Double] = [:], angleSmoothing: Double = 0.1,
                onSelect: @escaping (String) -> Void) {
        self.layout = layout
        self.inputs = inputs
        self.selectedInputID = selectedInputID
        self.inputAngles = inputAngles
        self.angleSmoothing = angleSmoothing
        self.onSelect = onSelect
    }

    public var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / layout.width, geometry.size.height / layout.height)
            let artwork = artworkImage
            ZStack(alignment: .topLeading) {
                if let artwork {
                    Image(decorative: artwork, scale: 1)
                        .resizable()
                        .frame(width: layout.width * scale, height: layout.height * scale)
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12))
                    if layout.artworkPNG != nil {
                        Text("Board artwork could not be displayed").font(.caption)
                    }
                }
                if let screen = layout.screen {
                    Rectangle().fill(Color.primary.opacity(0.12))
                        .overlay(Text("Screen").font(.caption).minimumScaleFactor(0.3))
                        .frame(width: screen.width * scale, height: screen.height * scale)
                        .offset(x: screen.x * scale, y: screen.y * scale)
                }
                ForEach(layout.inputs) { placement in
                    inputButton(placement, scale: scale, artwork: artwork)
                }
            }
            .frame(width: layout.width * scale, height: layout.height * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(layout.width / layout.height, contentMode: .fit)
    }

    private func inputButton(_ placement: DeviceInputPlacement, scale: Double, artwork: CGImage?) -> some View {
        let hasArtwork = artwork != nil
        let input = inputs.first { $0.id == placement.id }
        let name = input?.name ?? placement.id
        let symbol = input?.kind == "encoder" || input?.kind == "dial"
            ? "dial.medium" : input?.kind == "slider" ? "slider.horizontal.3" : "button.programmable"
        let angle = inputAngles[placement.id]
        let isSelected = selectedInputID == placement.id
        // A turning knob is marked with a ring on top; a fill underneath flickers against its edge.
        let background = isSelected && angle == nil ? Color.accentColor.opacity(0.35)
            : hasArtwork ? Color.clear : Color.secondary.opacity(0.2)
        let radius = hasArtwork ? min(placement.width, placement.height) * scale / 2 : 8
        return Button { onSelect(placement.id) } label: {
            ZStack {
                if !hasArtwork {
                    VStack(spacing: 2) {
                        Image(systemName: symbol)
                        Text(name).font(.caption2).lineLimit(2)
                    }
                }
                Color.clear
                if let angle {
                    ZStack {
                        // Turn the knob's own artwork, then mark its direction.
                        if let artwork {
                            Image(decorative: artwork, scale: 1)
                                .resizable()
                                .frame(width: layout.width * scale, height: layout.height * scale)
                                .offset(x: (layout.width / 2 - placement.x - placement.width / 2) * scale,
                                        y: (layout.height / 2 - placement.y - placement.height / 2) * scale)
                                .frame(width: placement.width * scale, height: placement.height * scale)
                                .clipShape(Circle())
                        }
                        pointer(size: min(placement.width, placement.height) * scale)
                    }
                    .rotationEffect(.degrees(angle))
                    .animation(angleSmoothing > 0 ? .linear(duration: angleSmoothing) : nil, value: angle)
                    .allowsHitTesting(false)
                    if isSelected {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 3).allowsHitTesting(false)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .accessibilityLabel(name)
        .help(name)
        .frame(width: placement.width * scale, height: placement.height * scale)
        .offset(x: placement.x * scale, y: placement.y * scale)
    }

    private func pointer(size: Double) -> some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.accentColor)
                .overlay(Capsule().stroke(Color.white.opacity(0.8), lineWidth: 1))
                .frame(width: max(3, size * 0.07), height: size * 0.3)
                .padding(.top, size * 0.08)
            Spacer(minLength: 0)
        }
        .frame(width: size, height: size)
    }

    private var artworkImage: CGImage? {
        guard let encoded = layout.artworkPNG, let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
