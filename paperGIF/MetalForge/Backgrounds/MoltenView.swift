import SwiftUI

struct MoltenView: View {
    var body: some View {
        PaperGIFLiveEffect { t in

            Color.black
                .colorEffect(
                    ShaderLibrary.molten(
                        .boundingRect,
                        .float(Float(t)),
                        .float(0.55),
                        .float(2.6),
                        .float(1.4),
                        .float(6.0),
                        .float(14.0),
                        .float(0.75),
                        .float(0.4),
                        .float(1.35),
                        .color(Color(hex: "#070404")),
                        .color(Color(hex: "#D92405")),
                        .color(Color(hex: "#FF8410")),
                        .color(Color(hex: "#FFF2B8"))
                    )
                )
        }
    }
}

private extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >>  8) & 0xFF) / 255
        let b = Double( v        & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
