import SwiftUI

struct InkSmokeView: View {
    var body: some View {
        PaperGIFLiveEffect { t in

            Color.black
                .colorEffect(
                    ShaderLibrary.inkSmoke(
                        .boundingRect,
                        .float(Float(t)),
                        .float(0.45),
                        .float(1.8),
                        .float(4.0),
                        .float(0.45),
                        .color(Color(inkSmokeHex: "#000000")),
                        .color(Color(inkSmokeHex: "#12121A")),
                        .color(Color(inkSmokeHex: "#1A1020")),
                        .color(Color(inkSmokeHex: "#0E141C")),
                        .color(Color(inkSmokeHex: "#2A2438"))
                    )
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension Color {
    init(inkSmokeHex hex: String) {
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
