import simd
import SwiftUI

/// One published stroke for a touch-capable background. Each loop is a separate pointer path.
struct PaperGIFPhoneTouchOutline: Equatable {
    var generation: UInt64 = 0
    var loops: [[SIMD2<Float>]] = []
}

enum PaperGIFPhoneTouchOutlineRelay {
    static func apply(
        _ outline: PaperGIFPhoneTouchOutline,
        seen: inout UInt64,
        down: (SIMD2<Float>) -> Void,
        move: (SIMD2<Float>, SIMD2<Float>) -> Void
    ) {
        guard outline.generation != seen else { return }
        seen = outline.generation
        for loop in outline.loops where loop.count >= 2 {
            down(loop[0])
            var previous = loop[0]
            for point in loop.dropFirst() {
                move(previous, point)
                previous = point
            }
            move(previous, loop[0])
        }
    }
}

enum PaperGIFPhoneTouchOutlineSampler {
    /// Rounded-rect perimeter in top-left UV, matching the MetalForge drag gesture.
    static func loop(frame: CGRect, canvas: CGSize) -> [SIMD2<Float>] {
        let width = max(canvas.width, 1)
        let height = max(canvas.height, 1)
        let rect = frame.insetBy(dx: 1, dy: 1)
        guard rect.width > 8, rect.height > 8 else { return [] }
        // A page- or screen-sized rect is not a button. Stroking it stirs the whole sim.
        guard PaperGIFPhoneShaderSpace.isButton(rect, on: canvas) else { return [] }
        let radius = min(8, rect.width / 2, rect.height / 2)
        let spacing = max(8, min(width, height) * 0.004)
        var points: [SIMD2<Float>] = []

        func add(_ x: CGFloat, _ y: CGFloat) {
            let u = x / width
            let v = y / height
            // A frame outside the shader used to clamp onto the screen border and stir the whole sim.
            guard u >= -0.002, u <= 1.002, v >= -0.002, v <= 1.002 else { return }
            let point = SIMD2<Float>(Float(min(max(u, 0), 1)), Float(min(max(v, 0), 1)))
            if points.last == point { return }
            points.append(point)
        }

        func edge(from: CGPoint, to: CGPoint) {
            let length = hypot(to.x - from.x, to.y - from.y)
            let steps = max(4, Int(length / spacing))
            for step in 0...steps {
                let t = CGFloat(step) / CGFloat(steps)
                add(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t)
            }
        }

        func corner(center: CGPoint, start: CGFloat, end: CGFloat) {
            let steps = 6
            for step in 0...steps {
                let angle = start + (end - start) * CGFloat(step) / CGFloat(steps)
                add(center.x + cos(angle) * radius, center.y + sin(angle) * radius)
            }
        }

        let minX = rect.minX
        let minY = rect.minY
        let maxX = rect.maxX
        let maxY = rect.maxY
        edge(from: CGPoint(x: minX + radius, y: minY), to: CGPoint(x: maxX - radius, y: minY))
        corner(center: CGPoint(x: maxX - radius, y: minY + radius), start: -.pi / 2, end: 0)
        edge(from: CGPoint(x: maxX, y: minY + radius), to: CGPoint(x: maxX, y: maxY - radius))
        corner(center: CGPoint(x: maxX - radius, y: maxY - radius), start: 0, end: .pi / 2)
        edge(from: CGPoint(x: maxX - radius, y: maxY), to: CGPoint(x: minX + radius, y: maxY))
        corner(center: CGPoint(x: minX + radius, y: maxY - radius), start: .pi / 2, end: .pi)
        edge(from: CGPoint(x: minX, y: maxY - radius), to: CGPoint(x: minX, y: minY + radius))
        corner(center: CGPoint(x: minX + radius, y: minY + radius), start: .pi, end: .pi * 1.5)
        guard points.count >= 8 else { return [] }
        return points
    }
}

enum PaperGIFPhoneShaderSpace {
    static let name = "phoneRemoteShader"

    /// `tile` is canvas-local. `canvasInShader` is that canvas in the shader's coordinate space.
    static func buttonFrame(tile: CGRect, canvasInShader: CGRect) -> CGRect {
        CGRect(
            x: canvasInShader.minX + tile.minX,
            y: canvasInShader.minY + tile.minY,
            width: tile.width,
            height: tile.height
        )
    }

    /// Prefer a layout measurement only when it is the same tile inside the shader.
    /// A named-space read that comes back as the whole screen must not win.
    static func resolvedButtonFrame(
        measured: CGRect?, tile: CGRect, origin: CGPoint, shader: CGSize
    ) -> CGRect {
        let computed = CGRect(
            x: origin.x + tile.minX,
            y: origin.y + tile.minY,
            width: tile.width,
            height: tile.height
        )
        guard let measured, isButton(measured, on: shader) else { return computed }
        let sizeMatches = abs(measured.width - tile.width) < 12 && abs(measured.height - tile.height) < 12
        let inside = measured.minX >= -8 && measured.minY >= -8
            && measured.maxX <= shader.width + 8 && measured.maxY <= shader.height + 8
        let nearComputed = hypot(measured.minX - computed.minX, measured.minY - computed.minY) < 80
        return sizeMatches && inside && nearComputed ? measured : computed
    }

    static func outlineFrame(measured: CGRect?, fallback: CGRect, canvas: CGSize) -> CGRect {
        guard let measured, isButton(measured, on: canvas) else { return fallback }
        return measured
    }

    static func isButton(_ frame: CGRect, on canvas: CGSize) -> Bool {
        guard frame.width > 8, frame.height > 8, canvas.width > 1, canvas.height > 1 else { return false }
        let coversWidth = frame.width >= canvas.width * 0.90
        let coversHeight = frame.height >= canvas.height * 0.55
        return !(coversWidth && coversHeight)
    }
}

/// See-through amount for phone remote controls so a full-screen background can show through.
enum PaperGIFPhoneRemoteChrome {
    static let opacityKey = "phoneRemote.elementOpacity"
    static let defaultOpacity = 0.62
}

/// Canvas behind the phone remote. Off is the default so the shader is not created.
enum PaperGIFPhoneRemoteBackground: String, CaseIterable, Identifiable {
    case off
    case stars
    case clouds
    case ink
    case ember
    case fluid
    case aurora
    case molten
    case chrome
    case smoke
    case lilac
    case ocean

    static let storageKey = "phoneRemote.background"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .stars: "Stars"
        case .clouds: "Clouds"
        case .ink: "Ink"
        case .ember: "Ember"
        case .fluid: "Fluid"
        case .aurora: "Aurora"
        case .molten: "Molten"
        case .chrome: "Chrome"
        case .smoke: "Smoke"
        case .lilac: "Lilac"
        case .ocean: "Ocean"
        }
    }

    var acceptsTouchOutline: Bool {
        switch self {
        case .fluid, .aurora: true
        case .off, .stars, .clouds, .ink, .ember, .molten, .chrome, .smoke, .lilac, .ocean: false
        }
    }
}

struct PaperGIFPhoneRemoteBackgroundView: View {
    var background: PaperGIFPhoneRemoteBackground
    var isAnimating: Bool
    var outline: PaperGIFPhoneTouchOutline = PaperGIFPhoneTouchOutline()

    var body: some View {
        Group {
            if !isAnimating || background == .off {
                Color.black
            } else {
                switch background {
                case .off:
                    Color.black
                case .stars:
                    StarfieldView()
                case .clouds:
                    FractalCloudsView()
                case .ink:
                    InkSmokeView()
                case .ember:
                    PlasmaEmberView()
                case .fluid:
                    FluidTouchBackground(outline: outline)
                case .aurora:
                    AuroraTouchBackground(outline: outline)
                case .molten:
                    MoltenView()
                case .chrome:
                    LiquidChromeView()
                case .smoke:
                    SmokeView()
                case .lilac:
                    PlasmaLilacView()
                case .ocean:
                    DotsView()
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum PaperGIFPhoneRemoteStatus {
    static func pillState(for message: String) -> StatusPill.Status {
        switch message {
        case PaperGIFPhoneActionMessage.sending:
            return .working(left: 1, total: 1)
        case PaperGIFPhoneActionMessage.sent:
            return .done
        case PaperGIFPhoneActionMessage.failed:
            return .failed
        default:
            return .idle
        }
    }

    static func detail(for message: String) -> String? {
        switch message {
        case "Ready",
             PaperGIFPhoneActionMessage.sending,
             PaperGIFPhoneActionMessage.sent,
             PaperGIFPhoneActionMessage.failed:
            return nil
        default:
            return message
        }
    }

    static var style: StatusPillStyle {
        StatusPillStyle(
            idleLabel: "Ready",
            busyLabel: "Sending",
            busyOneLabel: "Sending",
            doneLabel: "Sent",
            failLabel: "Request failed",
            resetAfter: 1.6,
            appearance: "dark",
            size: 30,
            pad: 0,
            shadow: 0,
            tray: false,
            errorEffect: "none"
        )
    }
}

struct PaperGIFPhoneSliderTrack: View {
    var fraction: Double
    var tint: Color
    var vertical: Bool
    var animated: Bool

    var body: some View {
        GeometryReader { geo in
            if animated {
                animatedTrack(in: geo.size)
            } else {
                staticTrack(in: geo.size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func animatedTrack(in size: CGSize) -> some View {
        let length = max(6, vertical ? size.height : size.width)
        let thickness = max(6, vertical ? size.width : size.height)
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let time = ctx.date.timeIntervalSinceReferenceDate
            ProgressBarView(
                time: time,
                fill: fraction,
                alive: 0.35,
                warp: time,
                style: Double(ProgressBarStyle.bands.rawValue),
                colors: Self.colors(tint)
            )
            .frame(width: length, height: thickness)
            .rotationEffect(vertical ? .degrees(-90) : .zero)
            .frame(width: size.width, height: size.height)
            .clipShape(Capsule())
        }
    }

    private func staticTrack(in size: CGSize) -> some View {
        ZStack(alignment: vertical ? .bottom : .leading) {
            Capsule().fill(Color.white.opacity(0.18))
            Capsule().fill(tint)
                .frame(
                    width: vertical ? nil : max(6, size.width * fraction),
                    height: vertical ? max(6, size.height * fraction) : nil
                )
        }
    }

    private static func colors(_ tint: Color) -> ProgressBarColors {
        ProgressBarColors(
            track: Color.white.opacity(0.14),
            deep: tint.opacity(0.55),
            mid: tint,
            glow: tint.opacity(0.9),
            bright: Color.white.opacity(0.85),
            core: .white,
            trail: tint.opacity(0.7),
            trailHot: Color.white.opacity(0.75)
        )
    }
}
