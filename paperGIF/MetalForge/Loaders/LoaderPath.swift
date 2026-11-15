import SwiftUI

enum LoaderGeometry {

    static func corners(_ radius: LoaderRadius?, _ size: CGSize) -> (
        tl: CGSize, tr: CGSize, br: CGSize, bl: CGSize
    ) {
        guard let radius else { return (.zero, .zero, .zero, .zero) }
        switch radius {
        case .pill:
            let s = CGSize(width: size.width / 2, height: size.height / 2)
            return (s, s, s, s)
        case let .px(a, b, c, d):
            return (
                CGSize(width: a, height: a),
                CGSize(width: b, height: b),
                CGSize(width: c, height: c),
                CGSize(width: d, height: d)
            )
        case let .pct(a, b, c, d):
            return (
                CGSize(width: a * size.width, height: a * size.height),
                CGSize(width: b * size.width, height: b * size.height),
                CGSize(width: c * size.width, height: c * size.height),
                CGSize(width: d * size.width, height: d * size.height)
            )
        }
    }

    static func roundedRect(_ rect: CGRect, _ radius: LoaderRadius?) -> Path {
        guard radius != nil else { return Path(rect) }
        if case .pill = radius { return Path(ellipseIn: rect) }
        var c = corners(radius, rect.size)
        let scale = min(
            1,
            min(
                min(
                    safeRatio(rect.width, c.tl.width + c.tr.width),
                    safeRatio(rect.width, c.bl.width + c.br.width)
                ),
                min(
                    safeRatio(rect.height, c.tl.height + c.bl.height),
                    safeRatio(rect.height, c.tr.height + c.br.height)
                )
            )
        )
        if scale < 1 {
            c = (scaled(c.tl, scale), scaled(c.tr, scale), scaled(c.br, scale), scaled(c.bl, scale))
        }
        return cornerPath(rect, tl: c.tl, tr: c.tr, br: c.br, bl: c.bl)
    }

    static func insetRadius(_ radius: LoaderRadius?, _ size: CGSize, by border: LoaderBorder) -> LoaderRadius? {
        guard radius != nil else { return nil }
        let c = corners(radius, size)
        return .px(
            max(0, min(c.tl.width - border.left, c.tl.height - border.top)),
            max(0, min(c.tr.width - border.right, c.tr.height - border.top)),
            max(0, min(c.br.width - border.right, c.br.height - border.bottom)),
            max(0, min(c.bl.width - border.left, c.bl.height - border.bottom))
        )
    }

    private static func scaled(_ s: CGSize, _ f: Double) -> CGSize {
        CGSize(width: s.width * f, height: s.height * f)
    }

    static func clipRect(_ rect: CGRect, _ radius: LoaderRadius?, _ border: LoaderBorder?) -> Path {
        guard let border else { return roundedRect(rect, radius) }
        let inner = CGRect(
            x: rect.minX + border.left,
            y: rect.minY + border.top,
            width: max(0, rect.width - border.left - border.right),
            height: max(0, rect.height - border.top - border.bottom)
        )
        return roundedRect(inner, insetRadius(radius, rect.size, by: border))
    }

    static func borderRegion(_ rect: CGRect, _ radius: LoaderRadius?, _ border: LoaderBorder) -> Path {
        let inner = CGRect(
            x: rect.minX + border.left,
            y: rect.minY + border.top,
            width: max(0, rect.width - border.left - border.right),
            height: max(0, rect.height - border.top - border.bottom)
        )
        var p = roundedRect(rect, radius)
        p.addPath(roundedRect(inner, insetRadius(radius, rect.size, by: border)))
        return p
    }

    static func polygon(_ points: [CGPoint], in rect: CGRect) -> Path {
        var p = Path()
        guard let first = points.first else { return p }
        p.move(to: CGPoint(x: rect.minX + first.x * rect.width, y: rect.minY + first.y * rect.height))
        for pt in points.dropFirst() {
            p.addLine(to: CGPoint(x: rect.minX + pt.x * rect.width, y: rect.minY + pt.y * rect.height))
        }
        p.closeSubpath()
        return p
    }

    private static func safeRatio(_ a: Double, _ b: Double) -> Double {
        b <= 0 ? .infinity : a / b
    }

    private static func cornerPath(
        _ r: CGRect,
        tl: CGSize,
        tr: CGSize,
        br: CGSize,
        bl: CGSize
    ) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + tl.width, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr.width, y: r.minY))
        addCorner(&p, CGPoint(x: r.maxX - tr.width, y: r.minY + tr.height), tr, .topRight)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br.height))
        addCorner(&p, CGPoint(x: r.maxX - br.width, y: r.maxY - br.height), br, .bottomRight)
        p.addLine(to: CGPoint(x: r.minX + bl.width, y: r.maxY))
        addCorner(&p, CGPoint(x: r.minX + bl.width, y: r.maxY - bl.height), bl, .bottomLeft)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl.height))
        addCorner(&p, CGPoint(x: r.minX + tl.width, y: r.minY + tl.height), tl, .topLeft)
        p.closeSubpath()
        return p
    }

    private enum Corner { case topLeft, topRight, bottomRight, bottomLeft }

    private static func addCorner(_ p: inout Path, _ centre: CGPoint, _ r: CGSize, _ c: Corner) {
        if r.width <= 0 || r.height <= 0 {
            switch c {
            case .topRight: p.addLine(to: CGPoint(x: centre.x + r.width, y: centre.y))
            case .bottomRight: p.addLine(to: CGPoint(x: centre.x, y: centre.y + r.height))
            case .bottomLeft: p.addLine(to: CGPoint(x: centre.x - r.width, y: centre.y))
            case .topLeft: p.addLine(to: CGPoint(x: centre.x, y: centre.y - r.height))
            }
            return
        }
        let k = 0.5522847498307936
        switch c {
        case .topRight:
            p.addCurve(
                to: CGPoint(x: centre.x + r.width, y: centre.y),
                control1: CGPoint(x: centre.x + r.width * k, y: centre.y - r.height),
                control2: CGPoint(x: centre.x + r.width, y: centre.y - r.height * k)
            )
        case .bottomRight:
            p.addCurve(
                to: CGPoint(x: centre.x, y: centre.y + r.height),
                control1: CGPoint(x: centre.x + r.width, y: centre.y + r.height * k),
                control2: CGPoint(x: centre.x + r.width * k, y: centre.y + r.height)
            )
        case .bottomLeft:
            p.addCurve(
                to: CGPoint(x: centre.x - r.width, y: centre.y),
                control1: CGPoint(x: centre.x - r.width * k, y: centre.y + r.height),
                control2: CGPoint(x: centre.x - r.width, y: centre.y + r.height * k)
            )
        case .topLeft:
            p.addCurve(
                to: CGPoint(x: centre.x, y: centre.y - r.height),
                control1: CGPoint(x: centre.x - r.width, y: centre.y - r.height * k),
                control2: CGPoint(x: centre.x - r.width * k, y: centre.y - r.height)
            )
        }
    }
}

struct LoaderPolyline {
    var points: [CGPoint] = []
    var cumulative: [Double] = []

    var length: Double { cumulative.last ?? 0 }

    init(_ path: Path, tolerance: Int = 24) {
        var pts: [CGPoint] = []
        var start = CGPoint.zero
        var current = CGPoint.zero
        path.forEach { element in
            switch element {
            case let .move(to: p):
                pts.append(p)
                start = p
                current = p
            case let .line(to: p):
                pts.append(p)
                current = p
            case let .quadCurve(to: p, control: c):
                for i in 1...tolerance {
                    let t = Double(i) / Double(tolerance)
                    pts.append(LoaderPolyline.quad(current, c, p, t))
                }
                current = p
            case let .curve(to: p, control1: c1, control2: c2):
                for i in 1...tolerance {
                    let t = Double(i) / Double(tolerance)
                    pts.append(LoaderPolyline.cubic(current, c1, c2, p, t))
                }
                current = p
            case .closeSubpath:
                pts.append(start)
                current = start
            }
        }
        points = pts
        var total = 0.0
        cumulative = pts.isEmpty ? [] : [0]
        for i in 1..<max(1, pts.count) {
            total += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
            cumulative.append(total)
        }
    }

    func point(atFraction f: Double) -> CGPoint {
        guard points.count > 1, length > 0 else { return points.first ?? .zero }
        let target = min(max(f, 0), 1) * length
        var lo = 0
        var hi = cumulative.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= target { lo = mid } else { hi = mid }
        }
        let span = cumulative[hi] - cumulative[lo]
        let w = span <= 0 ? 0 : (target - cumulative[lo]) / span
        return CGPoint(
            x: points[lo].x + (points[hi].x - points[lo].x) * w,
            y: points[lo].y + (points[hi].y - points[lo].y) * w
        )
    }

    func tangentDegrees(atFraction f: Double) -> Double {
        guard points.count > 1, length > 0 else { return 0 }
        let target = min(max(f, 0), 1) * length
        var lo = 0
        var hi = cumulative.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= target { lo = mid } else { hi = mid }
        }
        let dx = points[hi].x - points[lo].x
        let dy = points[hi].y - points[lo].y
        if dx == 0 && dy == 0 { return 0 }
        return atan2(dy, dx) * 180 / .pi
    }

    static func cubic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        let x = u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x
        let y = u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y
        return CGPoint(x: x, y: y)
    }

    static func quad(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * a.x + 2 * u * t * b.x + t * t * c.x,
            y: u * u * a.y + 2 * u * t * b.y + t * t * c.y
        )
    }
}

enum LoaderPathParser {

    private static var cache: [String: Path] = [:]

    static func path(_ d: String) -> Path {
        if let hit = cache[d] { return hit }
        let built = parse(d)
        cache[d] = built
        return built
    }

    static func parse(_ d: String) -> Path {
        var p = Path()
        var tokens = Tokeniser(d)
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var command: Character = "M"

        while tokens.hasMore() {
            if let letter = tokens.peekLetter() {
                command = letter
                tokens.consumeCommand()
            } else if command == "M" {
                command = "L"
            } else if command == "m" {
                command = "l"
            }

            let relative = command.isLowercase
            switch Character(command.lowercased()) {
            case "m":
                let x = tokens.number(), y = tokens.number()
                current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                p.move(to: current)
                start = current
                lastControl = nil
            case "l":
                let x = tokens.number(), y = tokens.number()
                current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                p.addLine(to: current)
                lastControl = nil
            case "h":
                let x = tokens.number()
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                p.addLine(to: current)
                lastControl = nil
            case "v":
                let y = tokens.number()
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                p.addLine(to: current)
                lastControl = nil
            case "c":
                let c1 = tokens.point(relative ? current : .zero)
                let c2 = tokens.point(relative ? current : .zero)
                let to = tokens.point(relative ? current : .zero)
                p.addCurve(to: to, control1: c1, control2: c2)
                lastControl = c2
                current = to
            case "s":
                let c1 = lastControl.map {
                    CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                let c2 = tokens.point(relative ? current : .zero)
                let to = tokens.point(relative ? current : .zero)
                p.addCurve(to: to, control1: c1, control2: c2)
                lastControl = c2
                current = to
            case "q":
                let c = tokens.point(relative ? current : .zero)
                let to = tokens.point(relative ? current : .zero)
                p.addQuadCurve(to: to, control: c)
                lastControl = c
                current = to
            case "a":
                let rx = tokens.number(), ry = tokens.number()
                let rot = tokens.number()
                let large = tokens.number() != 0
                let sweep = tokens.number() != 0
                let to = tokens.point(relative ? current : .zero)
                addArc(&p, from: current, to: to, rx: rx, ry: ry, rotation: rot, largeArc: large, sweep: sweep)
                current = to
                lastControl = nil
            case "z":
                p.closeSubpath()
                current = start
                lastControl = nil
            default:
                return p
            }
        }
        return p
    }

    private static func addArc(
        _ p: inout Path,
        from: CGPoint,
        to: CGPoint,
        rx: Double,
        ry: Double,
        rotation: Double,
        largeArc: Bool,
        sweep: Bool
    ) {
        if rx == 0 || ry == 0 || (from.x == to.x && from.y == to.y) {
            p.addLine(to: to)
            return
        }
        var rx = abs(rx)
        var ry = abs(ry)
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (from.x - to.x) / 2, dy = (from.y - to.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }

        let sign: Double = largeArc == sweep ? -1 : 1
        let num = max(0, rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1)
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coef = sign * sqrt(den == 0 ? 0 : num / den)
        let cx1 = coef * rx * y1 / ry
        let cy1 = -coef * ry * x1 / rx
        let cx = cosPhi * cx1 - sinPhi * cy1 + (from.x + to.x) / 2
        let cy = sinPhi * cx1 + cosPhi * cy1 + (from.y + to.y) / 2

        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / Double(segments)
        var start = theta
        for _ in 0..<segments {
            let end = start + step
            let k = 4.0 / 3.0 * tan(step / 4)
            let p1 = onArc(cx, cy, rx, ry, cosPhi, sinPhi, start)
            let p2 = onArc(cx, cy, rx, ry, cosPhi, sinPhi, end)
            let d1 = derivative(rx, ry, cosPhi, sinPhi, start)
            let d2 = derivative(rx, ry, cosPhi, sinPhi, end)
            p.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + k * d1.x, y: p1.y + k * d1.y),
                control2: CGPoint(x: p2.x - k * d2.x, y: p2.y - k * d2.y)
            )
            start = end
        }
    }

    private static func onArc(
        _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double,
        _ cosPhi: Double, _ sinPhi: Double, _ t: Double
    ) -> CGPoint {
        let x = rx * cos(t)
        let y = ry * sin(t)
        return CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
    }

    private static func derivative(
        _ rx: Double, _ ry: Double, _ cosPhi: Double, _ sinPhi: Double, _ t: Double
    ) -> CGPoint {
        let x = -rx * sin(t)
        let y = ry * cos(t)
        return CGPoint(x: cosPhi * x - sinPhi * y, y: sinPhi * x + cosPhi * y)
    }

    private static func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        let dot = ux * vx + uy * vy
        let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
        var a = acos(min(1, max(-1, len == 0 ? 1 : dot / len)))
        if ux * vy - uy * vx < 0 { a = -a }
        return a
    }

    private struct Tokeniser {
        private let chars: [Character]
        private var i = 0

        init(_ s: String) { chars = Array(s) }

        mutating func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" || chars[i] == "\t" {
                i += 1
            }
        }

        mutating func hasMore() -> Bool {
            skipSeparators()
            return i < chars.count
        }

        mutating func peekLetter() -> Character? {
            skipSeparators()
            guard i < chars.count, chars[i].isLetter else { return nil }
            return chars[i]
        }

        mutating func consumeCommand() { i += 1 }

        mutating func number() -> Double {
            skipSeparators()
            var out = ""
            if i < chars.count, chars[i] == "-" || chars[i] == "+" {
                out.append(chars[i])
                i += 1
            }
            while i < chars.count, chars[i].isNumber || chars[i] == "." {
                out.append(chars[i])
                i += 1
            }
            if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                out.append(chars[i])
                i += 1
                if i < chars.count, chars[i] == "-" || chars[i] == "+" {
                    out.append(chars[i])
                    i += 1
                }
                while i < chars.count, chars[i].isNumber {
                    out.append(chars[i])
                    i += 1
                }
            }
            return Double(out) ?? 0
        }

        mutating func point(_ origin: CGPoint) -> CGPoint {
            let x = number()
            let y = number()
            return CGPoint(x: origin.x + x, y: origin.y + y)
        }
    }
}
