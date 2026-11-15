import SwiftUI

struct PlasmaLilacView: View {
    var body: some View {
        PaperGIFLiveEffect { t in

            Color.black
                .colorEffect(
                    ShaderLibrary.plasmaLilac(
                        .boundingRect,
                        .float(Float(t)),
                        .color(Color(hex: "#2A0A4A")),
                        .color(Color(hex: "#6B4FA0")),
                        .color(Color(hex: "#C499D9")),
                        .color(Color(hex: "#F5C6E0")),
                        .color(Color(hex: "#FFEEEE")),
                        .float(1.15),
                        .float(0.72),
                        .float(1.0)
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
