import SwiftUI

struct DotsView: View {
    var body: some View {
        PaperGIFLiveEffect { t in

            Color.black
                .colorEffect(
                    ShaderLibrary.dotsOcean(
                        .boundingRect,
                        .float(Float(t)),
                        .float(0.55),
                        .float(0.45),
                        .color(Color(hex: "#7EB6C9")),
                        .color(Color(hex: "#000000")),
                        .float(1.0),
                        .float(1.0),
                        .float(1.0),
                        .float(1.0),
                        .float(-0.55),
                        .float(0.5),
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
