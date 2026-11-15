import SwiftUI

struct LiquidChromeView: View {
    var body: some View {
        PaperGIFLiveEffect { t in

            Color.black
                .colorEffect(
                    ShaderLibrary.liquidChrome(
                        .boundingRect,
                        .float(Float(t)),
                        .float(0.22),
                        .float(2.0),
                        .float(1.5),
                        .float(0.45),
                        .float(12.0),
                        .float(0.18),
                        .float(0.15),
                        .color(Color(hex: "#05030D")),
                        .color(Color(hex: "#333340")),
                        .color(Color(hex: "#808099")),
                        .color(Color(hex: "#263366"))
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
