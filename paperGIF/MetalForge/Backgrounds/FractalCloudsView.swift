import SwiftUI

struct FractalCloudsView: View {
    var body: some View {
        PaperGIFLiveEffect { t in

            Color.black
                .colorEffect(
                    ShaderLibrary.fractalClouds(
                        .boundingRect,
                        .float(Float(t)),
                        .float(0.35),
                        .float(3.0),
                        .float(0.08),
                        .float(0.04),
                        .float(2.0),
                        .float(-0.15),
                        .color(Color(fractalCloudsHex: "#000000")),
                        .color(Color(fractalCloudsHex: "#2A3148")),
                        .color(Color(fractalCloudsHex: "#000000")),
                        .float(0.15)
                    )
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension Color {
    init(fractalCloudsHex hex: String) {
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
