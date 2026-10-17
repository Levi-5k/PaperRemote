import SwiftUI
import ImageIO

public struct DeviceBoardPreview: View {
    public let layout: DeviceLayout
    public let inputs: [DeviceInput]
    public let selectedInputID: String?
    public let onSelect: (String) -> Void

    public init(layout: DeviceLayout, inputs: [DeviceInput], selectedInputID: String?,
                onSelect: @escaping (String) -> Void) {
        self.layout = layout
        self.inputs = inputs
        self.selectedInputID = selectedInputID
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
                    inputButton(placement, scale: scale, hasArtwork: artwork != nil)
                }
            }
            .frame(width: layout.width * scale, height: layout.height * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(layout.width / layout.height, contentMode: .fit)
    }

    private func inputButton(_ placement: DeviceInputPlacement, scale: Double, hasArtwork: Bool) -> some View {
        let input = inputs.first { $0.id == placement.id }
        let name = input?.name ?? placement.id
        let symbol = input?.kind == "encoder" || input?.kind == "dial"
            ? "dial.medium" : input?.kind == "slider" ? "slider.horizontal.3" : "button.programmable"
        let background = selectedInputID == placement.id ? Color.accentColor.opacity(0.35)
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

    private var artworkImage: CGImage? {
        guard let encoded = layout.artworkPNG, let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
