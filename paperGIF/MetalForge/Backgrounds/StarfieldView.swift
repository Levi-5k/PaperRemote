import SwiftUI

struct StarfieldView: View {
    var body: some View {
        PaperGIFLiveEffect { t in

            Color.black
                .colorEffect(
                    ShaderLibrary.starfield(
                        .boundingRect,
                        .float(Float(t)),
                        .float(0.35),
                        .float(2.0),
                        .float(50.0),
                        .float(80.0),
                        .float(0.03),
                        .float(0.06),
                        .float(3.0),
                        .float(0.3),
                        .color(Color(starfieldHex: "#FFFFFF")),
                        .color(Color(starfieldHex: "#000000"))
                    )
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension Color {
    init(starfieldHex hex: String) {
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
