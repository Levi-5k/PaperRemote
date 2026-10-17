import SwiftUI

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
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12))
                if let screen = layout.screen {
                    Rectangle().fill(Color.primary.opacity(0.12))
                        .overlay(Text("Screen").font(.caption).minimumScaleFactor(0.3))
                        .frame(width: screen.width * scale, height: screen.height * scale)
                        .offset(x: screen.x * scale, y: screen.y * scale)
                }
                ForEach(layout.inputs) { placement in
                    let input = inputs.first { $0.id == placement.id }
                    Button { onSelect(placement.id) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: input?.kind == "encoder" || input?.kind == "dial"
                                  ? "dial.medium" : input?.kind == "slider" ? "slider.horizontal.3" : "button.programmable")
                            Text(input?.name ?? placement.id).font(.caption2).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                    .background(selectedInputID == placement.id ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(input?.name ?? placement.id)
                    .frame(width: placement.width * scale, height: placement.height * scale)
                    .offset(x: placement.x * scale, y: placement.y * scale)
                }
            }
            .frame(width: layout.width * scale, height: layout.height * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(layout.width / layout.height, contentMode: .fit)
    }
}
