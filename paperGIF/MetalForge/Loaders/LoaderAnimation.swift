import SwiftUI

public struct LoaderValues {
    public var transform: [LoaderOp]?
    public var opacity: Double?
    public var height: LoaderLength?
    public var dashOffset: Double?
    public var offset: Double?

    public init() {}
}

public enum LoaderTiming {

    public static func bezier(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        func cx(_ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * c + t * t * t
        }
        func cy(_ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * b + 3 * u * t * t * d + t * t * t
        }
        func dx(_ t: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * a + 6 * u * t * (c - a) + 3 * t * t * (1 - c)
        }

        var t = x
        for _ in 0..<8 {
            let err = cx(t) - x
            if abs(err) < 1e-7 { return cy(t) }
            let slope = dx(t)
            if abs(slope) < 1e-7 { break }
            t -= err / slope
        }
        var lo = 0.0
        var hi = 1.0
        t = x
        for _ in 0..<30 {
            let v = cx(t)
            if abs(v - x) < 1e-7 { break }
            if v > x { hi = t } else { lo = t }
            t = (lo + hi) / 2
        }
        return cy(t)
    }

    public static func apply(_ ease: LoaderEase, _ x: Double) -> Double {
        switch ease {
        case .linear:
            return x
        case let .bezier(a, b, c, d):
            return bezier(a, b, c, d, x)
        case let .steps(n, atStart):
            let raw = atStart ? ceil(x * Double(n)) : floor(x * Double(n))
            return min(1, max(0, raw / Double(n)))
        }
    }

    public static func progress(_ track: LoaderTrack, _ t: Double, _ speed: Double) -> Double? {
        let sp = 1 / (speed == 0 ? 1 : speed)
        let dur = track.dur * sp
        if dur <= 0 { return 0 }
        let delay = track.delayScaled ? track.delay * sp : track.delay
        if delay > 0, t < delay { return nil }
        var f = (t - delay) / dur
        f -= floor(f)
        return track.reverse ? 1 - f : f
    }
}

enum LoaderSampler {

    static func values(
        _ node: LoaderNode,
        _ keyframes: [String: [LoaderKeyStop]],
        _ t: Double,
        _ speed: Double
    ) -> LoaderValues {
        var base = LoaderValues()
        base.transform = node.transform
        base.opacity = node.opacity

        var out = base
        for track in node.anim ?? [] {
            guard let stops = keyframes[track.name] else { continue }
            guard let f = LoaderTiming.progress(track, t, speed) else { continue }
            var underlying = base
            underlying.transform = baseTransform(stops, node.transform)
            apply(stops, f, underlying, track.ease, into: &out)
        }
        return out
    }

    private static func apply(
        _ stops: [LoaderKeyStop],
        _ f: Double,
        _ base: LoaderValues,
        _ ease: LoaderEase,
        into out: inout LoaderValues
    ) {
        if let (a, b, w) = span(stops, f, ease, { $0.transform != nil }) {
            out.transform = lerpOps(a.transform ?? base.transform ?? [], b.transform ?? base.transform ?? [], w)
        }
        if let (a, b, w) = span(stops, f, ease, { $0.opacity != nil }) {
            let av = a.opacity ?? base.opacity ?? 1
            let bv = b.opacity ?? base.opacity ?? 1
            out.opacity = av + (bv - av) * w
        }
        if let (a, b, w) = span(stops, f, ease, { $0.height != nil }) {
            let av = a.height ?? base.height ?? LoaderLength(0, pct: false)
            let bv = b.height ?? base.height ?? LoaderLength(0, pct: false)
            out.height = LoaderLength(av.v + (bv.v - av.v) * w, pct: av.pct)
        }
        if let (a, b, w) = span(stops, f, ease, { $0.dashOffset != nil }) {
            let av = a.dashOffset ?? 0
            let bv = b.dashOffset ?? 0
            out.dashOffset = av + (bv - av) * w
        }
        if let (a, b, w) = span(stops, f, ease, { $0.offset != nil }) {
            let av = a.offset ?? 0
            let bv = b.offset ?? 0
            out.offset = av + (bv - av) * w
        }
    }

    private static func span(
        _ stops: [LoaderKeyStop],
        _ f: Double,
        _ ease: LoaderEase,
        _ owns: (LoaderKeyStop) -> Bool
    ) -> (LoaderKeyStop, LoaderKeyStop, Double)? {
        let owning = stops.filter(owns)
        guard !owning.isEmpty else { return nil }

        var line = owning
        if let first = owning.first, first.p > 0 {
            line.insert(LoaderKeyStop(0), at: 0)
        }
        if let last = owning.last, last.p < 1 {
            line.append(LoaderKeyStop(1))
        }

        var i = 0
        while i < line.count - 2, line[i + 1].p <= f { i += 1 }
        let a = line[i]
        let b = line[min(i + 1, line.count - 1)]
        let width = b.p - a.p
        let raw = width <= 0 ? 0 : min(1, max(0, (f - a.p) / width))
        return (a, b, LoaderTiming.apply(a.ease ?? ease, raw))
    }

    private static func baseTransform(_ stops: [LoaderKeyStop], _ staticOps: [LoaderOp]?) -> [LoaderOp]? {
        guard let staticOps else { return nil }
        guard let shape = stops.first(where: { $0.transform != nil })?.transform else { return staticOps }
        if shape.count != staticOps.count { return shape.map(identity) }
        for i in 0..<shape.count where !sameKind(shape[i], staticOps[i]) {
            return shape.map(identity)
        }
        return staticOps
    }

    private static func sameKind(_ a: LoaderOp, _ b: LoaderOp) -> Bool {
        switch (a, b) {
        case (.translateX, .translateX), (.translateY, .translateY), (.translate, .translate),
            (.rotate, .rotate), (.rotateX, .rotateX), (.rotateY, .rotateY), (.rotate3d, .rotate3d),
            (.scale, .scale), (.scaleX, .scaleX), (.scaleY, .scaleY):
            return true
        default:
            return false
        }
    }

    private static func identity(_ op: LoaderOp) -> LoaderOp {
        switch op {
        case .translateX: return .translateX(0)
        case .translateY: return .translateY(0)
        case .translate: return .translate(0, 0)
        case .rotate: return .rotate(0)
        case .rotateX: return .rotateX(0)
        case .rotateY: return .rotateY(0)
        case let .rotate3d(x, y, z, _): return .rotate3d(x, y, z, 0)
        case .scale: return .scale(1, 1)
        case .scaleX: return .scaleX(1)
        case .scaleY: return .scaleY(1)
        }
    }

    static func lerpOps(_ fromRaw: [LoaderOp], _ toRaw: [LoaderOp], _ f: Double) -> [LoaderOp] {
        let from = fromRaw.isEmpty ? toRaw.map(identity) : fromRaw
        let to = toRaw.isEmpty ? fromRaw.map(identity) : toRaw
        guard from.count == to.count else { return to }
        var out: [LoaderOp] = []
        out.reserveCapacity(from.count)
        for i in 0..<from.count {
            out.append(lerpOp(from[i], to[i], f))
        }
        return out
    }

    private static func lerpOp(_ a: LoaderOp, _ b: LoaderOp, _ f: Double) -> LoaderOp {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        switch (a, b) {
        case let (.translateX(x), .translateX(y)): return .translateX(m(x, y))
        case let (.translateY(x), .translateY(y)): return .translateY(m(x, y))
        case let (.translate(ax, ay), .translate(bx, by)): return .translate(m(ax, bx), m(ay, by))
        case let (.rotate(x), .rotate(y)): return .rotate(m(x, y))
        case let (.rotateX(x), .rotateX(y)): return .rotateX(m(x, y))
        case let (.rotateY(x), .rotateY(y)): return .rotateY(m(x, y))
        case let (.rotate3d(ax, ay, az, av), .rotate3d(_, _, _, bv)):
            return .rotate3d(ax, ay, az, m(av, bv))
        case let (.scale(ax, ay), .scale(bx, by)): return .scale(m(ax, bx), m(ay, by))
        case let (.scaleX(x), .scaleX(y)): return .scaleX(m(x, y))
        case let (.scaleY(x), .scaleY(y)): return .scaleY(m(x, y))
        default: return b
        }
    }
}
