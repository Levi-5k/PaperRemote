import SwiftUI

public struct LoaderPalette {
    public var accent: Color
    public var ink: Color
    public var background: Color

    public init(accent: Color, ink: Color, background: Color) {
        self.accent = accent
        self.ink = ink
        self.background = background
    }
}

enum LoaderRenderer {

    struct Inherited {
        var fill: LoaderPaint?
        var stroke: LoaderPaint?
        var strokeWidth: Double?
        var roundCap = false
        var roundJoin = false
        var dash: [Double]?
        var viewport = CGSize(width: 56, height: 56)
        var perspective: (d: Double, at: CGPoint)?
    }

    struct Context {
        var keyframes: [String: [LoaderKeyStop]]
        var time: Double
        var speed: Double
        var palette: LoaderPalette
        var resolved: ResolvedPalette
    }

    struct ResolvedPalette {
        var accent: Color.Resolved
        var ink: Color.Resolved
        var background: Color.Resolved
    }

    static func draw(
        _ spec: LoaderSpec,
        keyframes: [String: [LoaderKeyStop]],
        into gc: inout GraphicsContext,
        size: CGSize,
        time: Double,
        speed: Double,
        palette: LoaderPalette
    ) {
        let scale = min(size.width, size.height) / spec.box
        var ctx = gc
        ctx.translateBy(
            x: (size.width - spec.box * scale) / 2,
            y: (size.height - spec.box * scale) / 2
        )
        ctx.scaleBy(x: scale, y: scale)
        let resolved = ResolvedPalette(
            accent: palette.accent.resolve(in: gc.environment),
            ink: palette.ink.resolve(in: gc.environment),
            background: palette.background.resolve(in: gc.environment)
        )
        let state = Context(
            keyframes: keyframes,
            time: time,
            speed: speed,
            palette: palette,
            resolved: resolved
        )
        node(spec.root, ctx, state, Inherited(viewport: CGSize(width: spec.box, height: spec.box)))
    }

    private static func node(
        _ n: LoaderNode,
        _ incoming: GraphicsContext,
        _ state: Context,
        _ inherited: Inherited
    ) {
        let v = LoaderSampler.values(n, state.keyframes, state.time, state.speed)

        if let o = v.opacity, o < 1, !n.children.isEmpty {
            var outer = incoming
            outer.opacity *= o
            outer.drawLayer { layer in
                draw(n, v, layer, state, inherited)
            }
            return
        }

        var ctx = incoming
        if let o = v.opacity { ctx.opacity *= o }
        draw(n, v, ctx, state, inherited)
    }

    private static func draw(
        _ n: LoaderNode,
        _ v: LoaderValues,
        _ incoming: GraphicsContext,
        _ state: Context,
        _ inherited: Inherited
    ) {
        let frame = resolvedFrame(n, v)

        var ctx = incoming

        if let d = v.offset, let motion = n.motionPath {
            let poly = LoaderPolyline(LoaderPathParser.path(motion))
            let p = poly.point(atFraction: d)
            ctx.translateBy(x: p.x - frame.midX, y: p.y - frame.midY)
            let deg = poly.tangentDegrees(atFraction: d)
            if deg != 0 {
                ctx.translateBy(x: frame.midX, y: frame.midY)
                ctx.rotate(by: .degrees(deg))
                ctx.translateBy(x: -frame.midX, y: -frame.midY)
            }
        }

        let ops = v.transform ?? []
        let has3D = ops.contains { isThreeD($0) }

        if has3D {
            drawProjected(n, frame, ops, ctx, state, inherited)
            return
        }

        if !ops.isEmpty {
            let o = originPoint(n, frame, inherited)
            ctx.translateBy(x: o.x, y: o.y)
            for op in ops { apply(op, &ctx) }
            ctx.translateBy(x: -o.x, y: -o.y)
        }

        if let poly = n.clipPath {
            ctx.clip(to: LoaderGeometry.polygon(poly, in: frame))
        }
        if let mask = n.mask {
            ctx.clipToLayer { layer in
                layer.fill(Path(frame), with: maskShading(mask, frame))
            }
        }

        paint(n, frame, ctx, state, inherited)

        guard !n.children.isEmpty else { return }
        var child = ctx

        if n.clip {
            child.clip(to: LoaderGeometry.clipRect(frame, n.radius, n.border))
        }
        if let box = n.clipBox {
            child.clip(to: Path(roundedRect: box.rect, cornerRadius: box.radius))
        }

        var next = inherited
        switch n.shape {
        case .box, .svg:
            child.translateBy(x: frame.minX, y: frame.minY)
            if case .svg = n.shape { next.viewport = frame.size }
            if let d = n.perspective {
                next.perspective = (d, CGPoint(x: frame.width / 2, y: frame.height / 2))
            } else if let p = inherited.perspective {
                next.perspective = (p.d, CGPoint(x: p.at.x - frame.minX, y: p.at.y - frame.minY))
            }
        default:
            if n.fill != nil { next.fill = n.fill }
            if n.stroke != nil { next.stroke = n.stroke }
            if n.strokeWidth != nil { next.strokeWidth = n.strokeWidth }
            if n.roundCap { next.roundCap = true }
            if n.roundJoin { next.roundJoin = true }
            if n.dash != nil { next.dash = n.dash }
        }

        if let goo = n.goo {
            child.drawLayer { outer in
                outer.addFilter(
                    .alphaThreshold(
                        min: min(0.999, max(0, -goo.b / goo.m)),
                        color: colour(n.fill ?? .accent(1), state) ?? state.palette.accent
                    )
                )
                outer.drawLayer { inner in
                    inner.addFilter(.blur(radius: goo.sigma))
                    for c in n.children { node(c, inner, state, next) }
                }
            }
        } else {
            for c in n.children { node(c, child, state, next) }
        }
    }

    private static func resolvedFrame(_ n: LoaderNode, _ v: LoaderValues) -> CGRect {
        guard let h = v.height else { return n.frame }
        let value = h.pct ? h.v / 100 * n.heightBase : h.v
        if n.heightAnchorBottom == true {
            return CGRect(
                x: n.frame.minX,
                y: n.frame.minY + n.frame.height - value,
                width: n.frame.width,
                height: value
            )
        }
        return CGRect(x: n.frame.minX, y: n.frame.minY, width: n.frame.width, height: value)
    }

    private static func originPoint(_ n: LoaderNode, _ frame: CGRect, _ inherited: Inherited) -> CGPoint {
        let o = n.origin ?? CGPoint(x: 0.5, y: 0.5)
        if let box = n.originBox {
            return CGPoint(x: box.minX + box.width * o.x, y: box.minY + box.height * o.y)
        }
        switch n.shape {
        case .box, .svg:
            return CGPoint(x: frame.minX + frame.width * o.x, y: frame.minY + frame.height * o.y)
        default:
            return CGPoint(x: inherited.viewport.width * o.x, y: inherited.viewport.height * o.y)
        }
    }

    private static func apply(_ op: LoaderOp, _ ctx: inout GraphicsContext) {
        switch op {
        case let .translateX(v): ctx.translateBy(x: v, y: 0)
        case let .translateY(v): ctx.translateBy(x: 0, y: v)
        case let .translate(x, y): ctx.translateBy(x: x, y: y)
        case let .rotate(deg): ctx.rotate(by: .degrees(deg))
        case let .scale(x, y): ctx.scaleBy(x: x, y: y)
        case let .scaleX(v): ctx.scaleBy(x: v, y: 1)
        case let .scaleY(v): ctx.scaleBy(x: 1, y: v)
        case .rotateX, .rotateY, .rotate3d: break
        }
    }

    private static func isThreeD(_ op: LoaderOp) -> Bool {
        switch op {
        case .rotateX, .rotateY, .rotate3d: return true
        default: return false
        }
    }

    private static func paint(
        _ n: LoaderNode,
        _ frame: CGRect,
        _ ctx: GraphicsContext,
        _ state: Context,
        _ inherited: Inherited
    ) {
        switch n.shape {
        case .svg, .group:
            return
        case .box:
            if let g = n.gradient {
                var gctx = ctx
                if n.radius != nil {
                    gctx.clip(to: LoaderGeometry.roundedRect(frame, n.radius))
                }
                paintGradient(g, frame, gctx, state)
            } else if let f = n.fill, let shading = shading(f, state) {
                ctx.fill(LoaderGeometry.roundedRect(frame, n.radius), with: shading)
            }
            if let b = n.border, let shading = shading(b.paint, state) {
                if b.dashed {
                    let w = max(b.top, b.left)
                    let inset = frame.insetBy(dx: w / 2, dy: w / 2)
                    ctx.stroke(
                        LoaderGeometry.roundedRect(inset, LoaderGeometry.insetRadius(n.radius, frame.size, by: LoaderBorder(w / 2, w / 2, w / 2, w / 2, paint: b.paint))),
                        with: shading,
                        style: StrokeStyle(lineWidth: w, dash: [w * 3, w * 3])
                    )
                } else {
                    ctx.fill(
                        LoaderGeometry.borderRegion(frame, n.radius, b),
                        with: shading,
                        style: FillStyle(eoFill: true)
                    )
                }
            }
        default:
            paintShape(n, ctx, state, inherited)
        }
    }

    private static func paintShape(
        _ n: LoaderNode,
        _ incoming: GraphicsContext,
        _ state: Context,
        _ inherited: Inherited
    ) {
        var ctx = incoming
        if let r = n.svgRotate {
            ctx.translateBy(x: r.cx, y: r.cy)
            ctx.rotate(by: .degrees(r.deg))
            ctx.translateBy(x: -r.cx, y: -r.cy)
        }

        let path = shapePath(n.shape)
        let fill = n.fill ?? inherited.fill
        let stroke = n.stroke ?? inherited.stroke

        if let fill, let shading = shading(fill, state) {
            ctx.fill(path, with: shading)
        }
        if let stroke, let shading = shading(stroke, state) {
            let width = n.strokeWidth ?? inherited.strokeWidth ?? 1
            let dash = n.dash ?? inherited.dash
            var pattern: [CGFloat] = []
            var phase: CGFloat = 0
            if let dash {
                let unit = dashUnit(n, path)
                pattern = dash.map { $0 * unit }
                phase = (LoaderSampler.values(n, state.keyframes, state.time, state.speed).dashOffset ?? 0) * unit
            }
            ctx.stroke(
                path,
                with: shading,
                style: StrokeStyle(
                    lineWidth: width,
                    lineCap: (n.roundCap || inherited.roundCap) ? .round : .butt,
                    lineJoin: (n.roundJoin || inherited.roundJoin) ? .round : .miter,
                    dash: pattern,
                    dashPhase: phase
                )
            )
        }
    }

    private static func dashUnit(_ n: LoaderNode, _ path: Path) -> Double {
        guard let declared = n.pathLength, declared > 0 else { return 1 }
        let real = LoaderPolyline(path).length
        return real / declared
    }

    private static func shapePath(_ shape: LoaderShape) -> Path {
        switch shape {
        case let .circle(cx, cy, r):
            return Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        case let .ellipse(cx, cy, rx, ry):
            return Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        case let .rect(x, y, w, h, r):
            return Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
        case let .line(x1, y1, x2, y2):
            var p = Path()
            p.move(to: CGPoint(x: x1, y: y1))
            p.addLine(to: CGPoint(x: x2, y: y2))
            return p
        case let .path(d):
            return LoaderPathParser.path(d)
        case let .polyline(values):
            var p = Path()
            var i = 0
            while i + 1 < values.count {
                let pt = CGPoint(x: values[i], y: values[i + 1])
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                i += 2
            }
            return p
        case .box, .svg, .group:
            return Path()
        }
    }

    private static func paintGradient(
        _ g: LoaderGradient,
        _ frame: CGRect,
        _ ctx: GraphicsContext,
        _ state: Context
    ) {
        switch g {
        case let .split(axisY, at, a, b):
            let first = axisY
                ? CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height * at)
                : CGRect(x: frame.minX, y: frame.minY, width: frame.width * at, height: frame.height)
            let second = axisY
                ? CGRect(x: frame.minX, y: frame.minY + frame.height * at, width: frame.width, height: frame.height * (1 - at))
                : CGRect(x: frame.minX + frame.width * at, y: frame.minY, width: frame.width * (1 - at), height: frame.height)
            if let s = shading(a, state) { ctx.fill(Path(first), with: s) }
            if let s = shading(b, state) { ctx.fill(Path(second), with: s) }

        case let .conicTicks(period, width, paint):
            guard let s = shading(paint, state) else { return }
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            let radius = hypot(frame.width, frame.height)
            var deg = 0.0
            while deg < 360 {
                var p = Path()
                p.move(to: centre)
                p.addArc(
                    center: centre,
                    radius: radius,
                    startAngle: .degrees(deg - 90),
                    endAngle: .degrees(deg + width - 90),
                    clockwise: false
                )
                p.closeSubpath()
                ctx.fill(p, with: s)
                deg += period
            }

        case let .conicSweep(stops):
            var gradient: [Gradient.Stop] = []
            for stop in stops {
                gradient.append(
                    Gradient.Stop(
                        color: colour(stop.paint, state) ?? .clear,
                        location: min(1, max(0, stop.deg / 360))
                    )
                )
            }
            ctx.fill(
                Path(frame),
                with: .conicGradient(
                    Gradient(stops: gradient),
                    center: CGPoint(x: frame.midX, y: frame.midY),
                    angle: .degrees(-90)
                )
            )

        case let .linearTicks(axisX, period, width, paint):
            guard let s = shading(paint, state) else { return }
            var at = 0.0
            let limit = axisX ? frame.width : frame.height
            while at < limit {
                let r = axisX
                    ? CGRect(x: frame.minX + at, y: frame.minY, width: width, height: frame.height)
                    : CGRect(x: frame.minX, y: frame.minY + at, width: frame.width, height: width)
                ctx.fill(Path(r), with: s)
                at += period
            }
        }
    }

    private static func maskShading(_ mask: LoaderMask, _ frame: CGRect) -> GraphicsContext.Shading {
        switch mask {
        case let .linear(axisY, s0, s1, s2, s3):
            let gradient = Gradient(stops: [
                .init(color: .clear, location: s0),
                .init(color: .black, location: s1),
                .init(color: .black, location: s2),
                .init(color: .clear, location: s3),
            ])
            return .linearGradient(
                gradient,
                startPoint: axisY ? CGPoint(x: frame.midX, y: frame.minY) : CGPoint(x: frame.minX, y: frame.midY),
                endPoint: axisY ? CGPoint(x: frame.midX, y: frame.maxY) : CGPoint(x: frame.maxX, y: frame.midY)
            )
        case let .radial(r0, r1):
            let outer = hypot(frame.width, frame.height) / 2
            return .radialGradient(
                Gradient(stops: [
                    .init(color: .clear, location: r0),
                    .init(color: .black, location: r1),
                ]),
                center: CGPoint(x: frame.midX, y: frame.midY),
                startRadius: 0,
                endRadius: outer
            )
        }
    }

    private static func drawProjected(
        _ n: LoaderNode,
        _ frame: CGRect,
        _ ops: [LoaderOp],
        _ ctx: GraphicsContext,
        _ state: Context,
        _ inherited: Inherited
    ) {
        guard let border = n.border, let shading = shading(border.paint, state) else { return }
        let d = inherited.perspective?.d ?? 0
        let at = inherited.perspective?.at ?? CGPoint(x: frame.midX, y: frame.midY)
        let m = matrix(ops)
        let outer = project(LoaderGeometry.roundedRect(frame, n.radius), m, frame, at, d)
        let inner = project(
            LoaderGeometry.roundedRect(
                CGRect(
                    x: frame.minX + border.left,
                    y: frame.minY + border.top,
                    width: max(0, frame.width - border.left - border.right),
                    height: max(0, frame.height - border.top - border.bottom)
                ),
                LoaderGeometry.insetRadius(n.radius, frame.size, by: border)
            ),
            m,
            frame,
            at,
            d
        )
        var region = outer
        region.addPath(inner)
        ctx.fill(region, with: shading, style: FillStyle(eoFill: true))
    }

    private static func project(
        _ path: Path,
        _ m: [Double],
        _ frame: CGRect,
        _ at: CGPoint,
        _ d: Double
    ) -> Path {
        let poly = LoaderPolyline(path, tolerance: 12)
        var out = Path()
        let cx = frame.midX
        let cy = frame.midY
        for (i, p) in poly.points.enumerated() {
            let x = p.x - cx
            let y = p.y - cy
            let px = m[0] * x + m[3] * y
            let py = m[1] * x + m[4] * y
            let pz = m[2] * x + m[5] * y
            var sx = px + cx
            var sy = py + cy
            if d > 0 {
                let w = 1 - pz / d
                let scale = w <= 0.01 ? 100 : 1 / w
                sx = at.x + (px + cx - at.x) * scale
                sy = at.y + (py + cy - at.y) * scale
            }
            if i == 0 { out.move(to: CGPoint(x: sx, y: sy)) } else { out.addLine(to: CGPoint(x: sx, y: sy)) }
        }
        out.closeSubpath()
        return out
    }

    private static func matrix(_ ops: [LoaderOp]) -> [Double] {
        var m: [Double] = [1, 0, 0, 0, 1, 0]
        for op in ops {
            let n: [Double]
            switch op {
            case let .rotateX(deg):
                let a = deg * .pi / 180
                n = [1, 0, 0, 0, cos(a), sin(a)]
            case let .rotateY(deg):
                let a = deg * .pi / 180
                n = [cos(a), 0, -sin(a), 0, 1, 0]
            case let .rotate3d(ax, ay, az, deg):
                n = rotate3dColumns(ax, ay, az, deg)
            case let .rotate(deg):
                let a = deg * .pi / 180
                n = [cos(a), sin(a), 0, -sin(a), cos(a), 0]
            case let .scale(x, y):
                n = [x, 0, 0, 0, y, 0]
            case let .scaleX(x):
                n = [x, 0, 0, 0, 1, 0]
            case let .scaleY(y):
                n = [1, 0, 0, 0, y, 0]
            default:
                continue
            }
            m = compose(m, n)
        }
        return m
    }

    private static func rotate3dColumns(_ x: Double, _ y: Double, _ z: Double, _ deg: Double) -> [Double] {
        let len = sqrt(x * x + y * y + z * z)
        guard len > 0 else { return [1, 0, 0, 0, 1, 0] }
        let ux = x / len, uy = y / len, uz = z / len
        let a = deg * .pi / 180
        let c = cos(a), s = sin(a), t = 1 - c
        return [
            t * ux * ux + c, t * ux * uy + s * uz, t * ux * uz - s * uy,
            t * ux * uy - s * uz, t * uy * uy + c, t * uy * uz + s * ux,
        ]
    }

    private static func compose(_ a: [Double], _ b: [Double]) -> [Double] {
        [
            a[0] * b[0] + a[3] * b[1], a[1] * b[0] + a[4] * b[1], a[2] * b[0] + a[5] * b[1],
            a[0] * b[3] + a[3] * b[4], a[1] * b[3] + a[4] * b[4], a[2] * b[3] + a[5] * b[4],
        ]
    }

    private static func colour(_ paint: LoaderPaint, _ state: Context) -> Color? {
        switch paint {
        case .clear: return nil
        case let .accent(a): return over(state.resolved.accent, a, state)
        case let .ink(a): return over(state.resolved.ink, a, state)
        case .bg: return state.palette.background
        case let .hex(h, a):
            guard a < 1 else { return Color(loaderHex: h) }
            let c = Color.components(hex: h)
            return mix(c, a, state)
        }
    }

    private static func over(_ c: Color.Resolved, _ a: Double, _ state: Context) -> Color {
        mix((Double(c.red), Double(c.green), Double(c.blue)), a, state)
    }

    private static func mix(
        _ c: (Double, Double, Double),
        _ a: Double,
        _ state: Context
    ) -> Color {
        let f = max(0, min(1, a))
        guard f < 1 else { return Color(.sRGB, red: c.0, green: c.1, blue: c.2, opacity: 1) }
        let b = state.resolved.background
        return Color(
            .sRGB,
            red: c.0 * f + Double(b.red) * (1 - f),
            green: c.1 * f + Double(b.green) * (1 - f),
            blue: c.2 * f + Double(b.blue) * (1 - f),
            opacity: 1
        )
    }

    private static func shading(_ paint: LoaderPaint, _ state: Context) -> GraphicsContext.Shading? {
        colour(paint, state).map { .color($0) }
    }
}

extension Color {
    static func components(hex: String) -> (Double, Double, Double) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let full = raw.count == 3 ? raw.map { "\($0)\($0)" }.joined() : raw
        let value = UInt64(full, radix: 16) ?? 0
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    init(loaderHex hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let full = raw.count == 3 ? raw.map { "\($0)\($0)" }.joined() : raw
        let value = UInt64(full, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
