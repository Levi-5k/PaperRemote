import SwiftUI

public enum LoaderPaint {
    case clear
    case accent(Double)
    case ink(Double)
    case bg
    case hex(String, Double)
}

public enum LoaderRadius {
    case pill
    case px(Double, Double, Double, Double)
    case pct(Double, Double, Double, Double)
}

public struct LoaderBorder {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double
    public var dashed: Bool
    public var paint: LoaderPaint

    public init(
        _ top: Double,
        _ right: Double,
        _ bottom: Double,
        _ left: Double,
        dashed: Bool = false,
        paint: LoaderPaint
    ) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
        self.dashed = dashed
        self.paint = paint
    }
}

public struct LoaderConicStop {
    public var deg: Double
    public var paint: LoaderPaint

    public init(_ deg: Double, _ paint: LoaderPaint) {
        self.deg = deg
        self.paint = paint
    }
}

public enum LoaderGradient {
    case split(axisY: Bool, at: Double, a: LoaderPaint, b: LoaderPaint)
    case conicTicks(period: Double, width: Double, paint: LoaderPaint)
    case conicSweep([LoaderConicStop])
    case linearTicks(axisX: Bool, period: Double, width: Double, paint: LoaderPaint)
}

public enum LoaderMask {
    case linear(axisY: Bool, Double, Double, Double, Double)
    case radial(r0: Double, r1: Double)
}

public struct LoaderGoo {
    public var sigma: Double
    public var m: Double
    public var b: Double

    public init(sigma: Double, m: Double, b: Double) {
        self.sigma = sigma
        self.m = m
        self.b = b
    }
}

public enum LoaderOp {
    case translateX(Double)
    case translateY(Double)
    case translate(Double, Double)
    case rotate(Double)
    case rotateX(Double)
    case rotateY(Double)
    case rotate3d(Double, Double, Double, Double)
    case scale(Double, Double)
    case scaleX(Double)
    case scaleY(Double)
}

public enum LoaderEase {
    case linear
    case bezier(Double, Double, Double, Double)
    case steps(Int, atStart: Bool)
}

public struct LoaderTrack {
    public var name: String
    public var dur: Double
    public var delay: Double
    public var delayScaled: Bool
    public var ease: LoaderEase
    public var reverse: Bool

    public init(
        _ name: String,
        dur: Double,
        delay: Double = 0,
        delayScaled: Bool = false,
        ease: LoaderEase = .linear,
        reverse: Bool = false
    ) {
        self.name = name
        self.dur = dur
        self.delay = delay
        self.delayScaled = delayScaled
        self.ease = ease
        self.reverse = reverse
    }
}

public struct LoaderLength {
    public var v: Double
    public var pct: Bool

    public init(_ v: Double, pct: Bool) {
        self.v = v
        self.pct = pct
    }
}

public struct LoaderKeyStop {
    public var p: Double
    public var transform: [LoaderOp]?
    public var opacity: Double?
    public var height: LoaderLength?
    public var dashOffset: Double?
    public var offset: Double?
    public var ease: LoaderEase?

    public init(
        _ p: Double,
        transform: [LoaderOp]? = nil,
        opacity: Double? = nil,
        height: LoaderLength? = nil,
        dashOffset: Double? = nil,
        offset: Double? = nil,
        ease: LoaderEase? = nil
    ) {
        self.p = p
        self.transform = transform
        self.opacity = opacity
        self.height = height
        self.dashOffset = dashOffset
        self.offset = offset
        self.ease = ease
    }
}

public enum LoaderShape {
    case box
    case svg
    case group
    case circle(cx: Double, cy: Double, r: Double)
    case ellipse(cx: Double, cy: Double, rx: Double, ry: Double)
    case rect(x: Double, y: Double, w: Double, h: Double, r: Double)
    case line(x1: Double, y1: Double, x2: Double, y2: Double)
    case path(String)
    case polyline([Double])
}

public struct LoaderClipBox {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    public var r: Double

    public init(x: Double, y: Double, w: Double, h: Double, r: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.r = r
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    public var radius: Double { min(r, min(w, h) / 2) }
}

public struct LoaderNode {
    public var shape: LoaderShape
    public var frame: CGRect
    public var fill: LoaderPaint?
    public var stroke: LoaderPaint?
    public var strokeWidth: Double?
    public var roundCap: Bool
    public var roundJoin: Bool
    public var dash: [Double]?
    public var pathLength: Double?
    public var svgRotate: (deg: Double, cx: Double, cy: Double)?
    public var gradient: LoaderGradient?
    public var border: LoaderBorder?
    public var radius: LoaderRadius?
    public var clip: Bool
    public var clipPath: [CGPoint]?
    public var clipBox: LoaderClipBox?
    public var mask: LoaderMask?
    public var goo: LoaderGoo?
    public var motionPath: String?
    public var opacity: Double?
    public var transform: [LoaderOp]?
    public var origin: CGPoint?
    public var originBox: CGRect?
    public var perspective: Double?
    public var preserve3d: Bool
    public var anim: [LoaderTrack]?
    public var heightAnchorBottom: Bool?
    public var heightBase: Double
    public var children: [LoaderNode]

    public init(
        _ shape: LoaderShape,
        frame: CGRect = .zero,
        fill: LoaderPaint? = nil,
        stroke: LoaderPaint? = nil,
        strokeWidth: Double? = nil,
        roundCap: Bool = false,
        roundJoin: Bool = false,
        dash: [Double]? = nil,
        pathLength: Double? = nil,
        svgRotate: (deg: Double, cx: Double, cy: Double)? = nil,
        gradient: LoaderGradient? = nil,
        border: LoaderBorder? = nil,
        radius: LoaderRadius? = nil,
        clip: Bool = false,
        clipPath: [CGPoint]? = nil,
        clipBox: LoaderClipBox? = nil,
        mask: LoaderMask? = nil,
        goo: LoaderGoo? = nil,
        motionPath: String? = nil,
        opacity: Double? = nil,
        transform: [LoaderOp]? = nil,
        origin: CGPoint? = nil,
        originBox: CGRect? = nil,
        perspective: Double? = nil,
        preserve3d: Bool = false,
        anim: [LoaderTrack]? = nil,
        heightAnchorBottom: Bool? = nil,
        heightBase: Double = 0,
        children: [LoaderNode] = []
    ) {
        self.shape = shape
        self.frame = frame
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.roundCap = roundCap
        self.roundJoin = roundJoin
        self.dash = dash
        self.pathLength = pathLength
        self.svgRotate = svgRotate
        self.gradient = gradient
        self.border = border
        self.radius = radius
        self.clip = clip
        self.clipPath = clipPath
        self.clipBox = clipBox
        self.mask = mask
        self.goo = goo
        self.motionPath = motionPath
        self.opacity = opacity
        self.transform = transform
        self.origin = origin
        self.originBox = originBox
        self.perspective = perspective
        self.preserve3d = preserve3d
        self.anim = anim
        self.heightAnchorBottom = heightAnchorBottom
        self.heightBase = heightBase
        self.children = children
    }
}

public struct LoaderSpec {
    public var id: String
    public var title: String
    public var group: String
    public var box: Double
    public var root: LoaderNode

    public init(id: String, title: String, group: String, box: Double = 56, root: LoaderNode) {
        self.id = id
        self.title = title
        self.group = group
        self.box = box
        self.root = root
    }
}
