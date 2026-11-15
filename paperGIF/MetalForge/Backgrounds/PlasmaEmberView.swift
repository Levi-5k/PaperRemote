import SwiftUI

struct PlasmaEmberView: View {
    var body: some View {
        PaperGIFLiveEffect { t in

            Color.black
                .colorEffect(
                    ShaderLibrary.plasmaEmber(
                        .boundingRect,
                        .float(Float(t)),
                        .color(Color(plasmaEmberHex: "#000000")),
                        .color(Color(plasmaEmberHex: "#1A0A08")),
                        .color(Color(plasmaEmberHex: "#3A1810")),
                        .color(Color(plasmaEmberHex: "#6A3020")),
                        .color(Color(plasmaEmberHex: "#C47848")),
                        .float(1.0),
                        .float(0.55),
                        .float(1.0)
                    )
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension Color {
    init(plasmaEmberHex hex: String) {
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
