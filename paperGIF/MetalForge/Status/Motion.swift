import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public protocol MFLook {
    var isDark: Bool { get }
    var surface: Color { get }
    var fill: Color { get }
    var fillHover: Color { get }
    var ink: Color { get }
    var ink2: Color { get }
    var focus: Color { get }
    var size: Double { get }
    var roundness: Double { get }
    var pad: Double { get }
    var shadow: Double { get }
    var tray: Bool { get }
    var speed: Double { get }
    var bounce: Double { get }
    var blur: Double { get }
    var press: Double { get }
    var doneEffect: String { get }
    var doneLength: Double { get }
    var doneStrength: Double { get }
    var doneSize: Double { get }
    var doneCount: Int { get }
    var sheenColor: Color { get }
    var holoA: Color { get }
    var holoB: Color { get }
    var holoC: Color { get }
    var holoGlitter: Color { get }
    var sparkA: Color { get }
    var sparkB: Color { get }
    var sparkC: Color { get }
    var sparkD: Color { get }
    var auraA: Color { get }
    var auraB: Color { get }
    var auraC: Color { get }
    var errorEffect: String { get }
    var errorLength: Double { get }
    var errorStrength: Double { get }
    var errorSize: Double { get }
    var errorCount: Int { get }
    var glitchA: Color { get }
    var glitchB: Color { get }
    var emberA: Color { get }
    var emberB: Color { get }
    var emberC: Color { get }
    var flareA: Color { get }
    var flareB: Color { get }
    var flareC: Color { get }
}

struct MFFX: Sendable {
    var doneLength: Double
    var doneStrength: Double
    var doneSize: Double
    var doneCount: Int
    var errorLength: Double
    var errorStrength: Double
    var errorSize: Double
    var errorCount: Int
    var sheen: Color
    var colors: [String: [Color]]

    func length(_ ok: Bool) -> Double { max(0.1, ok ? doneLength : errorLength) }
    func strength(_ ok: Bool) -> Double { max(0, ok ? doneStrength : errorStrength) }
    func size(_ ok: Bool) -> Double { max(0.1, ok ? doneSize : errorSize) }
    func count(_ ok: Bool) -> Int { max(0, ok ? doneCount : errorCount) }
}

public extension Color {
    init(mfHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

public enum MFSpring: Sendable {
    case pop, morph, snap, settle, firm, press

    var duration: Double {
        switch self {
        case .pop: return 0.50
        case .morph: return 0.40
        case .snap: return 0.38
        case .settle: return 0.32
        case .firm: return 0.30
        case .press: return 0.26
        }
    }

    var bounce: Double {
        switch self {
        case .pop: return 0.50
        case .morph: return 0.36
        case .snap: return 0.25
        case .settle: return 0.20
        case .firm: return -0.12
        case .press: return 0.40
        }
    }
}

struct MFTheme: Sendable {
    var surface: Color
    var fill: Color
    var fillHover: Color
    var ink: Color
    var ink2: Color
    var focus: Color
    var h: CGFloat
    var roundness: CGFloat
    var pad: CGFloat
    var shadow: Double
    var tray: Bool
    var speed: Double
    var bounce: Double
    var blurK: CGFloat
    var pressK: CGFloat
    var done: String
    var fail: String
    var fx: MFFX
    var dark: Bool = false

    var sheen: Bool { done == "sheen" }
    var u: CGFloat { h / 44 }
    var kr: CGFloat { max(6, h / 2 * roundness) }
    var tr: CGFloat { kr + pad }
    var inner: CGFloat { max(16, h - 2 * pad) }
    var ir: CGFloat { max(4, kr - pad) }
    var fs: CGFloat { 15 * u }
    var ic: CGFloat { 18 * u }
    var hp: CGFloat { 20 * u }
    var gap: CGFloat { 8 * u }
    var ink3: Color { ink2.opacity(0.62) }
    var keyShape: RoundedRectangle { RoundedRectangle(cornerRadius: kr, style: .continuous) }
    var label: Font { .system(size: fs, weight: .semibold) }
    var regular: Font { .system(size: fs, weight: .regular) }

    func spring(_ kind: MFSpring) -> Animation {
        var d = kind.duration
        var b = kind.bounce
        d = d / max(0.25, speed)
        if b > 0 { b = min(0.85, b * bounce) }
        return .spring(duration: d, bounce: b)
    }

    func seconds(_ ms: Double) -> Double {
        ms / 1000 / max(0.25, speed)
    }

    func wait(_ ms: Double) async -> Bool {
        if ms > 0 {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds(ms) * 1_000_000_000))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }
}

extension MFLook {
    var mfTheme: MFTheme {
        MFTheme(
            surface: surface, fill: fill, fillHover: fillHover, ink: ink, ink2: ink2, focus: focus,
            h: CGFloat(size), roundness: CGFloat(roundness), pad: CGFloat(pad), shadow: shadow, tray: tray,
            speed: speed, bounce: bounce, blurK: CGFloat(blur), pressK: CGFloat(press), done: doneEffect, fail: errorEffect,
            fx: MFFX(
                doneLength: doneLength, doneStrength: doneStrength, doneSize: doneSize, doneCount: doneCount,
                errorLength: errorLength, errorStrength: errorStrength, errorSize: errorSize, errorCount: errorCount,
                sheen: sheenColor,
                colors: [
                    "holo": [holoA, holoB, holoC, holoGlitter], "glitch": [glitchA, glitchB],
                    "sparks": [sparkA, sparkB, sparkC, sparkD], "embers": [emberA, emberB, emberC],
                    "aura": [auraA, auraB, auraC], "flare": [flareA, flareB, flareC],
                ]
            ),
            dark: isDark
        )
    }
}

enum MFMeasure {
    static func width(_ text: String, size: CGFloat, semibold: Bool) -> CGFloat {
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: size, weight: semibold ? .semibold : .regular)
        #else
        let font = NSFont.systemFont(ofSize: size, weight: semibold ? .semibold : .regular)
        #endif
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func width(_ text: String, size: CGFloat, weight: Font.Weight, mono: Bool = false) -> CGFloat {
        #if canImport(UIKit)
        let w: UIFont.Weight
        #else
        let w: NSFont.Weight
        #endif
        switch weight {
        case .bold: w = .bold
        case .heavy, .black: w = .heavy
        case .semibold: w = .semibold
        case .medium: w = .medium
        case .light, .thin, .ultraLight: w = .light
        default: w = .regular
        }
        #if canImport(UIKit)
        let font = mono ? UIFont.monospacedSystemFont(ofSize: size, weight: w) : UIFont.systemFont(ofSize: size, weight: w)
        #else
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: w) : NSFont.systemFont(ofSize: size, weight: w)
        #endif
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

func mfList(_ text: String) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for part in text.split(separator: ",") {
        let item = part.trimmingCharacters(in: .whitespaces)
        if !item.isEmpty && !seen.contains(item) {
            seen.insert(item)
            out.append(item)
        }
    }
    return out
}

struct MFFx: ViewModifier {
    var blur: CGFloat = 0
    var opacity: Double = 1
    var scale: CGFloat = 1
    var x: CGFloat = 0
    var y: CGFloat = 0
    var angle: Double = 0

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .scaleEffect(scale)
            .rotationEffect(.degrees(angle))
            .offset(x: x, y: y)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static func mfBlur(_ t: MFTheme, radius: CGFloat = 9, scale: CGFloat = 0.6, x: CGFloat = 0, y: CGFloat = 0) -> AnyTransition {
        .modifier(
            active: MFFx(blur: radius * t.blurK, opacity: 0, scale: scale, x: x, y: y),
            identity: MFFx()
        )
    }

    static func mfFace(_ t: MFTheme) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: MFFx(blur: 8 * t.blurK, opacity: 0, scale: 0.8), identity: MFFx())
                .animation(t.spring(.snap)),
            removal: .modifier(active: MFFx(blur: 8 * t.blurK, opacity: 0, scale: 0.8), identity: MFFx())
                .animation(.easeIn(duration: t.seconds(130)))
        )
    }
}

enum MFRoll {
    case none, auto, up, down
}

struct MFGlyph: Identifiable {
    let id: Int
    let ch: Character
    var delay: Double = 0
    var dy: CGFloat = 0
    var rolled = false
}

struct MFMorphText: View {
    let text: String
    let t: MFTheme
    var roll: MFRoll
    var stagger: Double
    var intro: Bool
    var em: CGFloat?

    @State private var glyphs: [MFGlyph]
    @State private var serial: Int
    @State private var outDy: CGFloat = 0
    @State private var outRolled = false
    @State private var pending: Task<Void, Never>?

    init(_ text: String, t: MFTheme, roll: MFRoll = .auto, stagger: Double = 16, intro: Bool = false, em: CGFloat? = nil) {
        self.text = text
        self.t = t
        self.roll = roll
        self.stagger = stagger
        self.intro = intro
        self.em = em
        let start = intro ? "" : text
        _glyphs = State(initialValue: start.enumerated().map { MFGlyph(id: $0.offset, ch: $0.element) })
        _serial = State(initialValue: start.count)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(glyphs) { g in
                Text(String(g.ch))
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.asymmetric(insertion: insertion(g), removal: removal))
            }
        }
        .fixedSize()
        .onChange(of: text) { _, next in morph(to: next) }
        .onAppear {
            if current != text { morph(to: text) }
        }
    }

    private var current: String { String(glyphs.map(\.ch)) }

    private func insertion(_ g: MFGlyph) -> AnyTransition {
        AnyTransition.modifier(
            active: MFFx(blur: 5 * t.blurK, opacity: 0, scale: g.rolled ? 1 : 0.55, y: g.dy),
            identity: MFFx()
        )
        .animation(t.spring(.snap).delay(g.delay))
    }

    private var removal: AnyTransition {
        AnyTransition.modifier(
            active: MFFx(blur: 5 * t.blurK, opacity: 0, scale: outRolled ? 1 : 0.55, y: outDy),
            identity: MFFx()
        )
        .animation(.easeIn(duration: t.seconds(170)))
    }

    private func direction(_ a: String, _ b: String) -> Int {
        switch roll {
        case .none: return 0
        case .up: return 1
        case .down: return -1
        case .auto:
            let da = a.filter(\.isNumber)
            let db = b.filter(\.isNumber)
            if da.isEmpty && db.isEmpty { return 0 }
            let va = Double(da) ?? 0
            let vb = Double(db) ?? 0
            return vb > va ? 1 : (vb < va ? -1 : 0)
        }
    }

    private func morph(to next: String) {
        pending?.cancel()
        let r = direction(current, next)
        let dy = CGFloat(r) * 0.62 * (em ?? t.fs)
        outDy = -dy
        outRolled = r != 0
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12_000_000)
            if Task.isCancelled { return }
            apply(next, dy: dy, rolled: r != 0)
        }
    }

    private func apply(_ next: String, dy: CGFloat, rolled: Bool) {
        let a = glyphs
        let b = Array(next)
        var p = 0
        while p < a.count && p < b.count && a[p].ch == b[p] { p += 1 }
        var s = 0
        while s < a.count - p && s < b.count - p && a[a.count - 1 - s].ch == b[b.count - 1 - s] { s += 1 }
        var id = serial
        var fresh: [MFGlyph] = []
        for (k, ch) in b[p..<(b.count - s)].enumerated() {
            id += 1
            fresh.append(MFGlyph(id: id, ch: ch, delay: t.seconds(Double(k) * stagger), dy: dy, rolled: rolled))
        }
        serial = id
        let next = Array(a[0..<p]) + fresh + Array(a[(a.count - s)...])
        withAnimation(t.spring(.snap)) { glyphs = next }
    }
}

struct MFSpinner: View {
    var size: CGFloat
    var body: some View {
        TimelineView(.animation) { ctx in
            let a = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.75) / 0.75 * 360
            ZStack {
                Circle().stroke(lineWidth: size * 0.13).opacity(0.28)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round))
                    .rotationEffect(.degrees(a - 90))
            }
            .frame(width: size * 0.66, height: size * 0.66)
        }
        .frame(width: size, height: size)
    }
}

enum MFGlyphs {
    static let table: [String: String] = [
        "plus": "0 12 5.5 1 12 18.5 0 5.5 12 1 18.5 12",
        "minus": "0 6 12 1 18 12",
        "trash": "0 4.5 7 1 19.5 7 0 9.5 7 1 9.5 5.3 2 9.5 4.6 10.1 4 10.8 4 1 13.2 4 2 13.9 4 14.5 4.6 14.5 5.3 1 14.5 7 0 6.6 7 1 7.4 18.1 2 7.453 19.165 8.333 20.001 9.4 20 1 14.6 20 2 15.667 20.001 16.547 19.165 16.6 18.1 1 17.4 7 0 10.3 11 1 10.3 16.3 0 13.7 11 1 13.7 16.3",
        "bag": "0 5.7 8.5 1 18.3 8.5 1 17.4 18.6 2 17.299 19.405 16.611 20.006 15.8 20 1 8.2 20 2 7.389 20.006 6.701 19.405 6.6 18.6 1 5.7 8.5 3 0 9 10.6 1 9 7.8 2 9 6.143 10.343 4.8 12 4.8 2 13.657 4.8 15 6.143 15 7.8 1 15 10.6",
        "check": "0 5.5 12.6 1 9.7 16.8 1 18.5 7.5",
        "mail": "5 3.5 5.5 17 13 3.2 0 4.8 7.8 1 12 13 1 19.2 7.8",
        "timer": "4 12 13.2 7.3 0 12 9.8 1 12 13.2 1 14.2 14.7 0 9.6 3.8 1 14.4 3.8",
        "pause": "0 9.2 6.8 1 9.2 17.2 0 14.8 6.8 1 14.8 17.2",
        "play": "0 8.6 7.1 1 8.6 16.9 2 8.6 17.7 9.5 18.2 10.2 17.8 1 17.8 12.9 2 18.4 12.5 18.4 11.6 17.8 11.2 1 10.2 6.3 2 9.5 5.8 8.6 6.3 8.6 7.1 3",
        "stop": "5 7.2 7.2 9.6 9.6 2.4",
        "save": "0 12 14.8 1 12 4.6 0 8.2 8.4 1 12 4.6 1 15.8 8.4 0 5 13.6 1 5 17 2 5 18.381 6.119 19.5 7.5 19.5 1 16.5 19.5 2 17.881 19.5 19 18.381 19 17 1 19 13.6",
        "alert": "4 12 12 8.5 0 12 7.8 1 12 12.6 0 12 16.2 1 12.01 16.2",
        "retry": "0 19 12 2 19 15.34 16.641 18.214 13.365 18.865 2 10.09 19.516 6.81 17.763 5.533 14.678 2 4.255 11.593 5.335 8.034 8.111 6.179 2 10.888 4.324 14.589 4.688 16.95 7.05 0 19.2 4.6 1 19.2 8.2 1 15.6 8.2",
        "send": "0 20 4 1 10.6 13.4 0 20 4 1 14.4 20 1 10.6 13.4 1 4 9.6 1 20 4 3",
        "undo": "0 9 14 1 4.5 9.5 1 9 5 0 4.8 9.5 1 14 9.5 2 16.761 9.5 19 11.739 19 14.5 2 19 17.261 16.761 19.5 14 19.5 1 12 19.5",
        "search": "4 11 11 6.5 0 20 20 1 15.6 15.6",
        "x": "0 7 7 1 17 17 0 17 7 1 7 17",
        "lock": "5 5 10.5 14 9.5 2.6 0 8.5 10.5 1 8.5 8 2 8.5 6.067 10.067 4.5 12 4.5 2 13.933 4.5 15.5 6.067 15.5 8 1 15.5 10.5",
        "eye": "0 2.8 12 2 4.7 8.1 8.1 5.7 12 5.7 2 15.9 5.7 19.3 8.1 21.2 12 2 19.3 15.9 15.9 18.3 12 18.3 2 8.1 18.3 4.7 15.9 2.8 12 3 4 12 12 2.8",
        "eyeOff": "0 4.5 4.5 1 19.5 19.5 0 9.8 5.95 2 10.522 5.785 11.26 5.701 12 5.7 2 15.9 5.7 19.3 8.1 21.2 12 2 20.58 13.27 19.8 14.37 18.87 15.27 0 15.6 17.4 2 14.469 17.929 13.247 18.234 12 18.3 2 8.1 18.3 4.7 15.9 2.8 12 2 3.75 10.05 5.1 8.5 6.7 7.45 0 10 10.1 2 9.22 11.213 9.352 12.726 10.313 13.687 2 11.274 14.648 12.787 14.78 13.9 14",
        "chevrons": "0 8.2 9.6 1 12 5.8 1 15.8 9.6 0 8.2 14.4 1 12 18.2 1 15.8 14.4",
        "more": "4 5.6 12 1 4 12 12 1 4 18.4 12 1",
        "pencil": "0 14.6 5.6 1 18.4 9.4 0 4.6 19.4 1 5.5 15.3 1 15.9 4.9 2 16.483 4.328 17.417 4.328 18 4.9 1 19.1 6 2 19.672 6.583 19.672 7.517 19.1 8.1 1 8.7 18.5 1 4.6 19.4 3",
        "copy": "5 8.6 8.6 11 11 2.6 0 15.4 8.6 1 15.4 6.7 2 15.4 5.485 14.415 4.5 13.2 4.5 1 6.7 4.5 2 5.485 4.5 4.5 5.485 4.5 6.7 1 4.5 13.2 2 4.5 14.415 5.485 15.4 6.7 15.4 1 8.6 15.4",
        "share": "0 12 14.6 1 12 4.5 0 8.3 8.2 1 12 4.5 1 15.7 8.2 0 8.2 10.9 1 7.4 10.9 2 5.964 10.9 4.8 12.064 4.8 13.5 1 4.8 17.4 2 4.8 18.836 5.964 20 7.4 20 1 16.6 20 2 18.036 20 19.2 18.836 19.2 17.4 1 19.2 13.5 2 19.2 12.064 18.036 10.9 16.6 10.9 1 15.8 10.9",
        "archive": "5 3.8 4.6 16.4 4.6 1.6 0 5.5 9.2 1 5.5 17.4 2 5.5 18.615 6.485 19.6 7.7 19.6 1 16.3 19.6 2 17.515 19.6 18.5 18.615 18.5 17.4 1 18.5 9.2 0 10 13.2 1 14 13.2",
        "bell": "0 6.4 16.6 1 6.4 11.4 2 6.4 8.307 8.907 5.8 12 5.8 2 15.093 5.8 17.6 8.307 17.6 11.4 1 17.6 16.6 1 19.1 18.1 1 4.9 18.1 1 6.4 16.6 3 0 10.1 20.4 2 10.446 21.136 11.187 21.606 12 21.606 2 12.813 21.606 13.554 21.136 13.9 20.4",
        "home": "0 4.6 10.4 1 12 4.6 1 19.4 10.4 1 19.4 18.1 2 19.4 19.149 18.549 20 17.5 20 1 14.4 20 1 14.4 14.7 1 9.6 14.7 1 9.6 20 1 6.5 20 2 5.451 20 4.6 19.149 4.6 18.1 1 4.6 10.4 3",
        "user": "4 12 8.6 3.6 0 5.2 19.4 2 6.1 16.2 8.7 14.2 12 14.2 2 15.3 14.2 17.9 16.2 18.8 19.4",
        "heart": "0 12 19.2 2 12 19.2 4.8 14.9 4.8 9.7 2 4.911 8.039 6.015 6.61 7.594 6.083 2 9.174 5.557 10.915 6.038 12 7.3 2 13.085 6.038 14.826 5.557 16.406 6.083 2 17.985 6.61 19.089 8.039 19.2 9.7 2 19.2 14.9 12 19.2 12 19.2 3",
        "heartFill": "0 12 19.2 2 12 19.2 4.8 14.9 4.8 9.7 2 4.911 8.039 6.015 6.61 7.594 6.083 2 9.174 5.557 10.915 6.038 12 7.3 2 13.085 6.038 14.826 5.557 16.406 6.083 2 17.985 6.61 19.089 8.039 19.2 9.7 2 19.2 14.9 12 19.2 12 19.2 3",
        "bookmark": "0 7.2 4.6 1 16.8 4.6 2 17.408 4.6 17.9 5.092 17.9 5.7 1 17.9 19.5 1 12 15.7 1 6.1 19.5 1 6.1 5.7 2 6.1 5.092 6.592 4.6 7.2 4.6 3",
        "bookmarkFill": "0 7.2 4.6 1 16.8 4.6 2 17.408 4.6 17.9 5.092 17.9 5.7 1 17.9 19.5 1 12 15.7 1 6.1 19.5 1 6.1 5.7 2 6.1 5.092 6.592 4.6 7.2 4.6 3",
        "download": "0 12 4.6 1 12 14.8 0 8.2 11 1 12 14.8 1 15.8 11 0 5 15.6 1 5 17 2 5 18.381 6.119 19.5 7.5 19.5 1 16.5 19.5 2 17.881 19.5 19 18.381 19 17 1 19 15.6",
        "cloudCheck": "0 7.3 18.6 2 4.98 18.766 2.966 17.02 2.8 14.7 2 2.634 12.38 4.38 10.366 6.7 10.2 2 7.594 7.79 10.014 6.299 12.569 6.582 2 15.123 6.866 17.157 8.853 17.5 11.4 2 19.488 11.483 21.033 13.162 20.95 15.15 2 20.867 17.138 19.188 18.683 17.2 18.6 1 7.3 18.6 3 0 9.7 14.2 1 11.3 15.8 1 14.4 12.6",
        "open": "0 8.2 15.8 1 15.8 8.2 0 9.6 8.2 1 15.8 8.2 1 15.8 14.4",
        "group": "4 9.2 8.8 3.1 0 3.8 18.6 2 4.5 15.9 6.6 14.3 9.2 14.3 2 11.8 14.3 13.9 15.9 14.6 18.6 0 15.4 6.1 2 16.559 6.546 17.323 7.659 17.323 8.9 2 17.323 10.141 16.559 11.254 15.4 11.7 0 17.2 14.5 2 19 15 20.1 16.4 20.5 18.6",
        "link": "0 10.4 13.6 2 11.075 14.278 11.993 14.659 12.95 14.659 2 13.907 14.659 14.825 14.278 15.5 13.6 1 18.1 11 2 19.508 9.592 19.508 7.308 18.1 5.9 2 16.692 4.492 14.408 4.492 13 5.9 1 11.9 7 0 13.6 10.4 2 12.925 9.722 12.007 9.341 11.05 9.341 2 10.093 9.341 9.175 9.722 8.5 10.4 1 5.9 13 2 4.492 14.408 4.492 16.692 5.9 18.1 2 7.308 19.508 9.592 19.508 11 18.1 1 12.1 17",
        "calendar": "5 4.2 5.6 15.6 14.2 3 0 4.2 10.2 1 19.8 10.2 0 8.6 3.6 1 8.6 7.2 0 15.4 3.6 1 15.4 7.2",
        "calendarCheck": "5 4.2 5.6 15.6 14.2 3 0 4.2 10.2 1 19.8 10.2 0 8.6 3.6 1 8.6 7.2 0 15.4 3.6 1 15.4 7.2 0 9.4 14.6 1 11.2 16.4 1 14.7 12.8",
        "back": "0 14.6 6.4 1 9 12 1 14.6 17.6",
        "card": "5 3.6 6 16.8 12 2.6 0 3.6 10 1 20.4 10 0 7.2 14.6 1 10.4 14.6",
        "receipt": "0 6.6 3.9 1 17.4 3.9 1 17.4 20.1 1 15.2 18.7 1 13.1 20.1 1 10.9 18.7 1 8.8 20.1 1 6.6 18.7 1 6.6 3.9 3 0 9.4 8.6 1 14.6 8.6 0 9.4 12.1 1 14.6 12.1",
        "chart": "0 5 19.2 1 19 19.2 0 7.6 15.6 1 7.6 11 0 12 15.6 1 12 6.8 0 16.4 15.6 1 16.4 9.4",
        "chevronDown": "0 7.5 10 1 12 14.5 1 16.5 10",
        "briefcase": "5 4 7.5 16 12 2.8 0 9 7.5 1 9 6.2 2 9 5.133 9.533 4.6 10.6 4.6 1 13.4 4.6 2 14.467 4.6 15 5.133 15 6.2 1 15 7.5 0 4 12.8 1 20 12.8",
        "leaf": "0 5.2 18.8 2 4.6 10.6 9.4 5.6 18.8 5.2 2 18.4 14.6 13.4 19.4 5.2 18.8 3 0 5.2 18.8 1 12.6 11.4",
        "moon": "0 19.2 14.6 2 17.961 17.87 14.65 19.873 11.178 19.451 2 7.706 19.03 4.97 16.294 4.549 12.822 2 4.127 9.35 6.13 6.039 9.4 4.8 2 7.825 7.613 8.311 11.13 10.591 13.409 2 12.87 15.689 16.387 16.175 19.2 14.6 3",
        "drop": "0 12 4 2 9.5 7 6.5 10.5 6.5 14 2 6.5 17.038 8.962 19.5 12 19.5 2 15.038 19.5 17.5 17.038 17.5 14 2 17.5 10.5 14.5 7 12 4 3",
        "smile": "4 12 12 8 0 8.8 13.8 2 10.4 15.9 13.6 15.9 15.2 13.8 0 9.4 9.8 1 9.41 9.8 0 14.6 9.8 1 14.61 9.8",
        "bolt": "0 13.2 3.6 1 5.8 13.4 1 11.2 13.4 1 10.6 20.4 1 18.2 10.6 1 12.8 10.6 1 13.2 3.6 3",
        "bubble": "5 4 5 16 11.5 3.4 0 9.4 16.5 1 7.6 20 1 12.6 16.5",
        "target": "4 12 12 8 4 12 12 4.4 0 12 12 1 12.01 12",
        "flag": "0 6.5 20.5 1 6.5 4.5 0 6.5 5 1 17 5 1 15 8.5 1 17 12 1 6.5 12",
        "sparkle": "0 12 4 2 12.6 9 15 11.4 20 12 2 15 12.6 12.6 15 12 20 2 11.4 15 9 12.6 4 12 2 9 11.4 11.4 9 12 4 3",
        "mic": "5 9 3.5 6 10.5 3 0 6 11 2 10 18.333 14 18.333 18 11 0 12 16.5 1 12 20.5",
        "leave": "0 13.4 4.6 1 7.6 4.6 2 6.385 4.6 5.4 5.585 5.4 6.8 1 5.4 17.2 2 5.4 18.415 6.385 19.4 7.6 19.4 1 13.4 19.4 0 10.4 12 1 19.4 12 0 16 8.6 1 19.4 12 1 16 15.4",
        "rows": "0 4 6.5 1 20 6.5 0 4 12 1 20 12 0 4 17.5 1 14 17.5",
    ]

    static let filled: Set<String> = [
        "heartFill",
        "bookmarkFill",
    ]

    static let paths: [String: Path] = table.mapValues(build)

    static func build(_ text: String) -> Path {
        let ops = text.split(separator: " ").compactMap { Double($0) }
        var p = Path()
        var i = 0
        func pt(_ k: Int) -> CGPoint { CGPoint(x: ops[k], y: ops[k + 1]) }
        while i < ops.count {
            switch Int(ops[i]) {
            case 0 where i + 2 < ops.count:
                p.move(to: pt(i + 1))
                i += 3
            case 1 where i + 2 < ops.count:
                p.addLine(to: pt(i + 1))
                i += 3
            case 2 where i + 6 < ops.count:
                p.addCurve(to: pt(i + 5), control1: pt(i + 1), control2: pt(i + 3))
                i += 7
            case 3:
                p.closeSubpath()
                i += 1
            case 4 where i + 3 < ops.count:
                let r = ops[i + 3]
                p.addEllipse(in: CGRect(x: ops[i + 1] - r, y: ops[i + 2] - r, width: 2 * r, height: 2 * r))
                i += 4
            case 5 where i + 5 < ops.count:
                p.addRoundedRect(in: CGRect(x: ops[i + 1], y: ops[i + 2], width: ops[i + 3], height: ops[i + 4]), cornerSize: CGSize(width: ops[i + 5], height: ops[i + 5]), style: .circular)
                i += 6
            default:
                i = ops.count
            }
        }
        return p
    }
}

struct MFIconShape: Shape {
    let name: String

    func path(in rect: CGRect) -> Path {
        (MFGlyphs.paths[name] ?? Path()).applying(CGAffineTransform(a: rect.width / 24, b: 0, c: 0, d: rect.height / 24, tx: rect.minX, ty: rect.minY))
    }
}

struct MFIcon: View {
    let name: String
    let t: MFTheme
    var weight: Font.Weight = .semibold

    var body: some View {
        ZStack {
            glyph(name)
                .id(name)
                .transition(.asymmetric(
                    insertion: .modifier(active: MFFx(blur: 4 * t.blurK, opacity: 0, scale: 0.4, angle: -40), identity: MFFx()),
                    removal: .modifier(active: MFFx(blur: 4 * t.blurK, opacity: 0, scale: 0.4), identity: MFFx())
                ))
        }
        .frame(width: t.ic, height: t.ic)
        .animation(t.spring(.pop), value: name)
    }

    private var stroke: CGFloat {
        switch weight {
        case .heavy, .black: return 3
        case .bold: return 2.4
        default: return 2
        }
    }

    @ViewBuilder private func glyph(_ n: String) -> some View {
        if n == "spinner" {
            MFSpinner(size: t.ic)
        } else {
            ZStack {
                if MFGlyphs.filled.contains(n) { MFIconShape(name: n).fill() }
                MFIconShape(name: n)
                    .stroke(style: StrokeStyle(lineWidth: stroke * t.ic / 24, lineCap: .round, lineJoin: .round))
            }
            .frame(width: t.ic, height: t.ic)
        }
    }
}

struct MFPress: ButtonStyle {
    var t: MFTheme
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        MFPressBody(label: configuration.label, pressed: configuration.isPressed && enabled, t: t)
    }
}

struct MFPressBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let t: MFTheme
    @State private var width: CGFloat = 44

    var body: some View {
        label
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { width = g.size.width }
                        .onChange(of: g.size.width) { _, w in width = w }
                }
            )
            .scaleEffect(pressed ? 1 + min(0.14, 7 / max(width, 1)) * t.pressK : 1)
            .animation(pressed ? t.spring(.press) : t.spring(.pop), value: pressed)
    }
}

struct MFTrayBackground: View {
    let t: MFTheme
    var radius: CGFloat? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? t.tr, style: .continuous)
        let shade = t.dark ? Color.black : Color(mfHex: 0x1A1915)
        let deep = t.dark ? 3.0 : 1.0
        ZStack {
            shape.fill(t.surface)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .shadow(color: shade.opacity(min(0.6, 0.16 * deep) * t.shadow), radius: 14, y: 16)
            shape.fill(t.surface)
                .padding(.horizontal, 3)
                .shadow(color: shade.opacity(min(0.45, 0.10 * deep) * t.shadow), radius: 6, y: 5)
            shape.fill(t.surface)
                .shadow(color: shade.opacity(min(0.3, 0.05 * deep * 2) * t.shadow), radius: 0.8, y: 1)
            shape.strokeBorder((t.dark ? Color.white.opacity(0.07) : shade.opacity(0.06)).opacity(min(1, t.shadow)), lineWidth: 1)
        }
    }
}

struct MFTray<Content: View>: View {
    let t: MFTheme
    var shake: Int = 0
    var burst: MFBurst? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(t.pad)
            .background {
                if t.tray { MFTrayBackground(t: t) }
            }
            .background {
                if let burst {
                    MFFlourishLayer(burst: burst, t: t, outer: true, radius: t.tr)
                        .padding(-MFFlourish.reach)
                }
            }
            .modifier(MFShake(trigger: shake, speed: t.speed))
    }
}

struct MFShake: ViewModifier {
    let trigger: Int
    let speed: Double
    var amplitude: CGFloat = 11

    func body(content: Content) -> some View {
        let k = max(0.25, speed)
        let a = amplitude
        content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, x in
            view.offset(x: x)
        } keyframes: { _ in
            CubicKeyframe(a, duration: 0.05 / k)
            CubicKeyframe(-a * 0.75, duration: 0.09 / k)
            CubicKeyframe(a * 0.45, duration: 0.08 / k)
            CubicKeyframe(-a * 0.2, duration: 0.08 / k)
            SpringKeyframe(0, duration: 0.24 / k, spring: Spring(duration: 0.26 / k, bounce: 0.4))
        }
    }
}

struct MFNudge: ViewModifier {
    let trigger: Int
    let speed: Double
    var dx: CGFloat = 0
    var dy: CGFloat = 0

    func body(content: Content) -> some View {
        let k = max(0.25, speed)
        let x = dx
        let y = dy
        content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, v in
            view.offset(x: x * v, y: y * v)
        } keyframes: { _ in
            CubicKeyframe(1, duration: 0.09 / k)
            SpringKeyframe(0, duration: 0.5 / k, spring: Spring(duration: 0.5 / k, bounce: 0.5))
        }
    }
}

struct MFBump: ViewModifier {
    let trigger: Int
    let speed: Double
    var amount: CGFloat = 0.04

    func body(content: Content) -> some View {
        let k = max(0.25, speed)
        let a = amount
        content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, v in
            view.scaleEffect(1 + a * v)
        } keyframes: { _ in
            LinearKeyframe(1, duration: 0.01)
            SpringKeyframe(0, duration: 0.5 / k, spring: Spring(duration: 0.5 / k, bounce: 0.5))
        }
    }
}

struct MFSheen: ViewModifier {
    let trigger: Int
    let on: Bool
    let radius: CGFloat
    var delay: Double = 0
    var color: Color = .white
    var alpha: Double = 0.58
    var width: Double = 0.18
    var length: Double = 0.85

    func body(content: Content) -> some View {
        content.overlay {
            if on {
                GeometryReader { g in
                    let w = g.size.width
                    LinearGradient(
                        stops: [
                            .init(color: color.opacity(0), location: max(0, 0.5 - width)),
                            .init(color: color.opacity(min(1, alpha)), location: 0.5),
                            .init(color: color.opacity(0), location: min(1, 0.5 + width)),
                        ],
                        startPoint: UnitPoint(x: 0, y: 0.38),
                        endPoint: UnitPoint(x: 1, y: 0.62)
                    )
                    .frame(width: w, height: g.size.height)
                    .keyframeAnimator(initialValue: CGFloat(-1.2), trigger: trigger) { view, x in
                        view.offset(x: x * w)
                    } keyframes: { _ in
                        LinearKeyframe(-1.2, duration: 0.001 + delay)
                        LinearKeyframe(1.2, duration: length, timingCurve: UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.25, y: 0.7), endControlPoint: UnitPoint(x: 0.25, y: 1)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func mfKey(_ t: MFTheme, fill: Color, minWidth: CGFloat? = nil, burst: MFBurst? = nil, side: MFSide = .both) -> some View {
        self
            .modifier(MFJitter(
                trigger: burst?.err ?? 0, on: burst != nil && side != .ok && t.fail == "glitch",
                amount: CGFloat(t.fx.size(false)), pace: t.fx.length(false) / max(0.25, t.speed)
            ))
            .frame(minWidth: minWidth ?? t.h, minHeight: t.h, maxHeight: t.h)
            .background {
                ZStack {
                    t.keyShape.fill(fill)
                    if let burst { MFFlourishLayer(burst: burst, t: t, outer: false, side: side) }
                }
            }
            .clipShape(t.keyShape)
            .contentShape(t.keyShape)
    }

    func mfSheen(_ trigger: Int, _ t: MFTheme, radius: CGFloat? = nil, delay: Double = 0) -> some View {
        modifier(MFSheen(
            trigger: trigger, on: t.sheen, radius: radius ?? t.kr, delay: delay / max(0.25, t.speed),
            color: t.fx.sheen, alpha: 0.58 * t.fx.strength(true), width: 0.18 * t.fx.size(true),
            length: 0.85 * t.fx.length(true) / max(0.25, t.speed)
        ))
    }

    func mfInside<Content: View>(_ t: MFTheme, alignment: Alignment = .leading, @ViewBuilder content: () -> Content) -> some View {
        overlay(alignment: alignment) {
            ZStack(alignment: alignment) {
                content()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .clipShape(t.keyShape)
        }
    }
}

public struct MFBurst: Equatable {
    public var ok = 0
    public var err = 0
    var okAt = Date.distantPast
    var errAt = Date.distantPast

    public init() {}

    public mutating func done() {
        ok += 1
        okAt = .now
    }

    public mutating func fail() {
        err += 1
        errAt = .now
    }
}

enum MFSide {
    case both, ok, err
}

enum MFFlourish {
    static let inner: Set<String> = ["holo", "glitch"]
    static let outer: Set<String> = ["sparks", "embers", "aura", "flare"]
    static let reach: CGFloat = 170

    static func duration(_ kind: String) -> Double {
        switch kind {
        case "holo": return 1.0
        case "glitch": return 0.55
        case "sparks": return 1.6
        case "embers": return 1.0
        case "aura": return 1.6
        case "flare": return 0.85
        default: return 0
        }
    }
}

struct MFRun: Equatable {
    let id: Int
    let kind: String
    let ok: Bool
    let start: Date
    let dur: Double
    let rate: Double
}

struct MFFlourishLayer: View {
    let burst: MFBurst
    let t: MFTheme
    let outer: Bool
    var radius: CGFloat = 0
    var side: MFSide = .both
    @State private var run: MFRun?
    @State private var serial = 0
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.self) private var env

    var body: some View {
        ZStack {
            if let run {
                TimelineView(.animation) { tl in
                    let e = max(0, min(run.dur, tl.date.timeIntervalSince(run.start) * run.rate))
                    layer(run.kind, run.ok, e)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: burst.ok) { _, _ in if side != .err { fire(t.done) } }
        .onChange(of: burst.err) { _, _ in if side != .ok { fire(t.fail) } }
        .onAppear {
            let now = Date.now
            if side != .ok, now.timeIntervalSince(burst.errAt) < 0.3 {
                fire(t.fail)
            } else if side != .err, now.timeIntervalSince(burst.okAt) < 0.3 {
                fire(t.done)
            }
        }
    }

    private func rgb(_ kind: String, _ i: Int) -> Shader.Argument {
        let list = t.fx.colors[kind] ?? []
        let c = (i < list.count ? list[i] : Color.black).resolve(in: env)
        return .float3(c.red, c.green, c.blue)
    }

    @ViewBuilder private func layer(_ kind: String, _ ok: Bool, _ e: Double) -> some View {
        let strength = Float(t.fx.strength(ok))
        let size = Float(t.fx.size(ok))
        switch kind {
        case "holo", "glitch":
            GeometryReader { g in
                Rectangle()
                    .fill(.white)
                    .colorEffect(ShaderLibrary.mfHolo(
                        .float2(g.size), .float(e), .float(kind == "glitch" ? 1 : 0),
                        rgb(kind, 0), rgb(kind, 1), rgb(kind, 2), rgb(kind, 3), .float(strength), .float(size)
                    ))
            }
        case "aura", "flare":
            GeometryReader { g in
                let m = MFFlourish.reach
                Rectangle()
                    .fill(.white)
                    .colorEffect(ShaderLibrary.mfAura(
                        .float4(m, m, g.size.width - 2 * m, g.size.height - 2 * m), .float(radius), .float(e), .float(kind == "flare" ? 1 : 0),
                        rgb(kind, 0), rgb(kind, 1), rgb(kind, 2), .float(strength), .float(size)
                    ))
            }
        case "sparks", "embers":
            MFSparks(
                time: e, embers: kind == "embers", radius: radius, colors: t.fx.colors[kind] ?? [],
                count: t.fx.count(ok), scale: t.fx.size(ok), strength: t.fx.strength(ok)
            )
        default:
            EmptyView()
        }
    }

    private func fire(_ kind: String) {
        guard !reduce, (outer ? MFFlourish.outer : MFFlourish.inner).contains(kind) else { return }
        serial += 1
        let id = serial
        let ok = ["holo", "sparks", "aura"].contains(kind)
        let dur = MFFlourish.duration(kind)
        let rate = max(0.25, t.speed) / t.fx.length(ok)
        let lead = (outer ? 0.06 : 0.18) / max(0.25, t.speed)
        run = MFRun(id: id, kind: kind, ok: ok, start: Date.now.addingTimeInterval(lead), dur: dur, rate: rate)
        let wall = lead + dur / rate
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(wall * 1_000_000_000))
            if run?.id == id { run = nil }
        }
    }
}

struct MFSparks: View {
    let time: Double
    let embers: Bool
    let radius: CGFloat
    let colors: [Color]
    let count: Int
    let scale: Double
    let strength: Double

    private static func hs(_ n: Double) -> Double {
        let v = sin(n * 91.3458) * 47453.5453
        return v - floor(v)
    }

    private static func perim(_ u0: Double, _ c: CGPoint, _ b: CGSize, _ r: Double) -> (CGPoint, CGVector) {
        let lx = 2 * (b.width - r), ly = 2 * (b.height - r), q = Double.pi / 2 * r
        var u = u0
        func arc(_ a0: Double, _ cx: Double, _ cy: Double) -> (CGPoint, CGVector) {
            let a = a0 + u / max(r, 0.001)
            return (CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r), CGVector(dx: cos(a), dy: sin(a)))
        }
        if u < lx { return (CGPoint(x: c.x - b.width + r + u, y: c.y - b.height), CGVector(dx: 0, dy: -1)) }
        u -= lx
        if u < q { return arc(-Double.pi / 2, c.x + b.width - r, c.y - b.height + r) }
        u -= q
        if u < ly { return (CGPoint(x: c.x + b.width, y: c.y - b.height + r + u), CGVector(dx: 1, dy: 0)) }
        u -= ly
        if u < q { return arc(0, c.x + b.width - r, c.y + b.height - r) }
        u -= q
        if u < lx { return (CGPoint(x: c.x + b.width - r - u, y: c.y + b.height), CGVector(dx: 0, dy: 1)) }
        u -= lx
        if u < q { return arc(Double.pi / 2, c.x - b.width + r, c.y + b.height - r) }
        u -= q
        if u < ly { return (CGPoint(x: c.x - b.width, y: c.y + b.height - r - u), CGVector(dx: -1, dy: 0)) }
        u -= ly
        return arc(Double.pi, c.x - b.width + r, c.y - b.height + r)
    }

    var body: some View {
        Canvas { ctx, size in
            let m = MFFlourish.reach
            let b = CGSize(width: max(1, size.width / 2 - m), height: max(1, size.height / 2 - m))
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(Double(radius), b.width, b.height)
            let lx = 2 * (b.width - r), ly = 2 * (b.height - r), q = Double.pi / 2 * r
            let total = 2 * lx + 2 * ly + 4 * q
            func ink(_ i: Int) -> Color { i < colors.count ? colors[i] : .black }
            for n in 0..<count {
                let i = Double(n)
                let u = embers ? lx + q + 0.5 * ly + Self.hs(i + 1) * (ly + lx + 2 * q) : Self.hs(i + 1) * total
                let (pos, nrm) = Self.perim(u.truncatingRemainder(dividingBy: total), c, b, r)
                let age = time - Self.hs(i + 7) * (embers ? 0.22 : 0.14)
                let life = embers ? 0.55 + 0.45 * Self.hs(i + 3) : 0.8 + 0.6 * Self.hs(i + 3)
                let k = age / life
                if age < 0 || k > 1 { continue }
                var v: CGVector
                let g: Double
                let nx = Double(nrm.dx)
                let ny = Double(nrm.dy)
                if embers {
                    let sp: Double = 20 + 50 * Self.hs(i + 11)
                    let vx: Double = nx * sp * scale
                    let vy: Double = (ny * sp * 0.4 + 30) * scale
                    v = CGVector(dx: vx, dy: vy)
                    g = 620 * scale
                } else {
                    let sp: Double = 90 + 170 * Self.hs(i + 11)
                    let jx: Double = (Self.hs(i + 13) - 0.5) * 60
                    let jy: Double = 70 * Self.hs(i + 17)
                    let vx: Double = (nx * sp + jx) * scale
                    let vy: Double = (ny * sp - jy) * scale
                    v = CGVector(dx: vx, dy: vy)
                    g = 240 * scale
                }
                let drag = 2.2
                let f = (1 - exp(-drag * age)) / drag
                let p = CGPoint(x: pos.x + v.dx * f, y: pos.y + v.dy * f + 0.5 * g * age * age)
                let sz = (embers ? 2.5 + 2.5 * Self.hs(i + 19) : 3 + 4.5 * Self.hs(i + 19)) * (1 - k * k * 0.6)
                let twinkle = embers ? 1 : 0.75 + 0.25 * sin(age * 30 + i)
                let alpha = min(1, min(1, max(0, age / 0.06)) * (1 - max(0, min(1, (k - 0.55) / 0.45))) * twinkle * strength)
                let pick = Self.hs(i + 23)
                let color: Color
                if embers {
                    color = pick < 0.5 ? ink(0) : pick < 0.8 ? ink(1) : ink(2)
                } else {
                    color = pick < 0.4 ? ink(0) : pick < 0.7 ? ink(1) : pick < 0.88 ? ink(2) : ink(3)
                }
                let strip = !embers && Self.hs(i + 29) >= 0.55
                if strip {
                    var piece = ctx
                    piece.translateBy(x: p.x, y: p.y)
                    piece.rotate(by: .radians(Self.hs(i + 31) * 6.28 + age * 6))
                    piece.fill(Path(CGRect(x: -sz * 0.45, y: -sz * 0.2, width: sz * 0.9, height: sz * 0.4)), with: .color(color.opacity(alpha)))
                } else {
                    let d = sz * 0.86
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)), with: .color(color.opacity(alpha)))
                }
            }
        }
    }
}

struct MFJitter: ViewModifier {
    let trigger: Int
    let on: Bool
    var amount: CGFloat = 1
    var pace: Double = 1

    func body(content: Content) -> some View {
        let k: CGFloat = on ? amount : 0
        let d = max(0.1, pace)
        content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, x in
            view.offset(x: x * k)
        } keyframes: { _ in
            LinearKeyframe(2.4, duration: 0.035 * d)
            LinearKeyframe(-2.2, duration: 0.05 * d)
            LinearKeyframe(1.8, duration: 0.05 * d)
            LinearKeyframe(-2.0, duration: 0.05 * d)
            LinearKeyframe(1.3, duration: 0.05 * d)
            LinearKeyframe(-1.0, duration: 0.05 * d)
            LinearKeyframe(0.6, duration: 0.05 * d)
            LinearKeyframe(0, duration: 0.06 * d)
        }
    }
}

enum MFKeyboard {
    case code, email, plain, password, number
}

extension View {
    #if os(iOS)
    @ViewBuilder func mfKeyboard(_ kind: MFKeyboard) -> some View {
        switch kind {
        case .code:
            self.keyboardType(.numberPad).textContentType(.oneTimeCode)
        case .email:
            self.keyboardType(.emailAddress).textContentType(.emailAddress).textInputAutocapitalization(.never)
        case .plain:
            self.textInputAutocapitalization(.never)
        case .password:
            self.keyboardType(.asciiCapable).textContentType(.password).textInputAutocapitalization(.never)
        case .number:
            self.keyboardType(.numberPad)
        }
    }
    #else
    func mfKeyboard(_ kind: MFKeyboard) -> some View {
        self
    }
    #endif
}

struct MFFillMask: Shape {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width * max(0, min(1, fraction)), height: rect.height))
    }
}

struct MFSpan: Shape {
    var left: CGFloat
    var right: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(left, right) }
        set {
            left = newValue.first
            right = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let w = max(0, right - left)
        let r = min(radius, w / 2, rect.height / 2)
        return RoundedRectangle(cornerRadius: r, style: .continuous).path(in: CGRect(x: left, y: rect.minY, width: w, height: rect.height))
    }
}

struct MFCountdown: View {
    let fraction: Double
    let color: Color
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: size * 0.14)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(fraction > 0.002 ? 1 : 0)
        }
        .frame(width: size * 0.78, height: size * 0.78)
        .frame(width: size, height: size)
    }
}

struct MFDensity: Sendable {
    var p: CGFloat
    var g: CGFloat
    var s: CGFloat
}

extension MFTheme {
    var unit: CGFloat { 4 * u }
    var glyph: CGFloat { (h - ic) / 2 }
    var inline: CGFloat { h * 0.18 }
    var keyline: CGFloat { glyph + ic + inline }
    var edge: CGFloat { glyph + inline }
    var avatar: CGFloat { (h * 0.68).rounded() }
    var keyGap: CGFloat { (h * 6 / 44).rounded() }
    var control: MFDensity { MFDensity(p: pad, g: keyGap, s: 2 * keyGap) }
    var card: MFDensity { MFDensity(p: (8 * u).rounded(), g: (8 * u).rounded(), s: (16 * u).rounded()) }

    func font(_ k: CGFloat = 1, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: fs * k, weight: weight)
    }

    func width(_ text: String, k: CGFloat = 1, weight: Font.Weight = .semibold, mono: Bool = false) -> CGFloat {
        MFMeasure.width(text, size: fs * k, weight: weight, mono: mono)
    }

    func keyWidth(_ text: String, icon: Bool = true, k: CGFloat = 1, weight: Font.Weight = .semibold, extra: CGFloat = 0) -> CGFloat {
        let words = text.isEmpty ? 0 : width(text, k: k, weight: weight) + extra
        if !icon { return edge + words + edge }
        return words > 0 ? glyph + ic + inline + words + edge : h
    }

    func fit(_ text: String, room: CGFloat, k: CGFloat = 1, weight: Font.Weight = .semibold) -> (scale: CGFloat, cut: Bool) {
        let need = width(text, k: k, weight: weight)
        let f = max(0.65, min(1, room / max(1, need)))
        return (f, need * f > room + 0.5)
    }
}

func mfInitials(_ s: String) -> String {
    let parts = s.split(whereSeparator: { " @._-".contains($0) }).map(String.init).filter { !$0.isEmpty }
    guard let first = parts.first else { return "?" }
    if parts.count > 1, let a = first.first, let b = parts[1].first { return String([a, b]).uppercased() }
    return String(first.prefix(2)).uppercased()
}

func mfFirstName(_ s: String) -> String {
    String(s.split(separator: " ").first ?? Substring(s))
}

func mfEmail(_ s: String) -> Bool {
    s.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]{2,}$", options: .regularExpression) != nil
}

struct MFFitLabel: View {
    let text: String
    let t: MFTheme
    let room: CGFloat
    var k: CGFloat = 1
    var weight: Font.Weight = .semibold
    var stagger: Double = 12

    var body: some View {
        let f = t.fit(text, room: room, k: k, weight: weight)
        MFMorphText(text, t: t, stagger: stagger, em: t.fs * k * f.scale)
            .font(.system(size: t.fs * k * f.scale, weight: weight))
            .frame(width: f.cut ? max(0, room) : nil, alignment: .leading)
            .mask(alignment: .leading) {
                if f.cut {
                    LinearGradient(stops: [.init(color: .black, location: max(0, 1 - 18 * t.u / max(1, room))), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
                } else {
                    Color.black.padding(-40)
                }
            }
    }
}

struct MFAvatar: View {
    let name: String
    let tone: Color
    let ink: Color
    let size: CGFloat
    var radius: CGFloat? = nil
    var ring: Color? = nil
    var ringWidth: CGFloat = 2

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? size / 2, style: .continuous)
        Text(mfInitials(name))
            .font(.system(size: size * 0.37, weight: .semibold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .fixedSize()
            .frame(width: size, height: size)
            .background(shape.fill(tone))
            .background {
                if let ring {
                    RoundedRectangle(cornerRadius: (radius ?? size / 2) + ringWidth, style: .continuous)
                        .fill(ring)
                        .padding(-ringWidth)
                }
            }
            .accessibilityLabel(name)
    }
}

struct MFCheck: View {
    let on: Bool
    let t: MFTheme
    let fill: Color
    let ink: Color
    var size: CGFloat? = nil
    var trigger = 0

    var body: some View {
        let d = size ?? t.h * 0.5
        ZStack {
            Circle().strokeBorder(t.ink3, lineWidth: 1.6).opacity(on ? 0 : 1)
            Circle().fill(fill).opacity(on ? 1 : 0)
            if on {
                MFIconShape(name: "check")
                    .stroke(style: StrokeStyle(lineWidth: 3 * d * 0.64 / 24, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(ink)
                    .frame(width: d * 0.64, height: d * 0.64)
                    .transition(.modifier(active: MFFx(blur: 4 * t.blurK, opacity: 0, scale: 0.4, angle: -40), identity: MFFx()))
            }
        }
        .frame(width: d, height: d)
        .animation(.easeOut(duration: 0.2), value: on)
        .modifier(MFBump(trigger: trigger, speed: t.speed, amount: -0.2))
    }
}

struct MFBox: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat
    var d: Double = 0
}

struct MFFlowState: Equatable {
    var W: CGFloat = 0
    var H: CGFloat = 0
    var P: CGFloat = 0
    var boxes: [String: MFBox] = [:]
    var shown: Set<String> = []

    func box(_ name: String) -> MFBox { boxes[name] ?? MFBox(x: 0, y: 0, w: 0, h: 0) }
    func on(_ name: String) -> Bool { shown.contains(name) }
}

struct MFTarget {
    var W: CGFloat
    var H: CGFloat
    var P: CGFloat
    var nodes: [String: MFBox]
}

enum MFFlow {
    static func jump(_ flow: Binding<MFFlowState>, _ T: MFTarget) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            var f = flow.wrappedValue
            f.W = T.W
            f.H = T.H
            f.P = T.P
            for (k, b) in T.nodes { f.boxes[k] = b }
            f.shown = Set(T.nodes.keys)
            flow.wrappedValue = f
        }
    }

    @MainActor
    static func go(_ flow: Binding<MFFlowState>, _ T: MFTarget, t: MFTheme, quick: Bool = false) async {
        let cur = flow.wrappedValue
        let leave = cur.shown.filter { T.nodes[$0] == nil }
        let stay = T.nodes.filter { cur.shown.contains($0.key) }
        let arrive = T.nodes.filter { !cur.shown.contains($0.key) }.sorted { ($0.value.d, $0.key) < ($1.value.d, $1.key) }
        let grow = T.H > cur.H + 0.5
        let wider = T.W > cur.W + 0.5
        let wait0: Double = leave.isEmpty ? 0 : (quick ? 70 : 120 + min(Double(leave.count) * 8, 80))
        let same = abs(T.W - cur.W) < 0.5
        let tH: Double = grow ? (quick ? 0 : 100) : wait0
        let tW: Double = wider ? (quick ? 0 : 30) : (same ? tH : wait0 + (T.H < cur.H - 0.5 ? 90 : 0))
        let pH: MFSpring = grow ? .morph : .settle
        let pW: MFSpring = wider ? .snap : (same ? pH : .settle)
        let a0: Double = quick ? 40 : max(grow ? 170 : 130, max(tW, tH) + 70)

        var events: [(Double, () -> Void)] = []
        if !leave.isEmpty {
            events.append((0, {
                withAnimation(t.spring(.snap)) { flow.wrappedValue.shown.subtract(leave) }
            }))
        }
        events.append((tW, {
            withAnimation(t.spring(pW)) {
                var f = flow.wrappedValue
                f.W = T.W
                for (k, b) in stay {
                    var o = f.box(k)
                    o.x = b.x
                    o.w = b.w
                    f.boxes[k] = o
                }
                flow.wrappedValue = f
            }
        }))
        events.append((tH, {
            withAnimation(t.spring(pH)) {
                var f = flow.wrappedValue
                f.H = T.H
                f.P = T.P
                for (k, b) in stay {
                    var o = f.box(k)
                    o.y = b.y
                    o.h = b.h
                    f.boxes[k] = o
                }
                flow.wrappedValue = f
            }
        }))
        for (i, (k, b)) in arrive.enumerated() {
            let at = a0 + (b.d > 0 ? b.d : (quick ? 0 : Double(i) * 28))
            events.append((at, {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { flow.wrappedValue.boxes[k] = b }
                withAnimation(t.spring(.pop)) { _ = flow.wrappedValue.shown.insert(k) }
            }))
        }
        events.sort { $0.0 < $1.0 }
        var now = 0.0
        for (at, run) in events {
            if at > now {
                guard await t.wait(at - now) else { return }
                now = at
            }
            if Task.isCancelled { return }
            run()
        }
    }
}

struct MFFlowTray<Content: View>: View {
    let t: MFTheme
    let flow: MFFlowState
    var shake: Int = 0
    var burst: MFBurst? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let r = t.kr + flow.P
        MFSized(w: max(0, flow.W), h: max(0, flow.H)) {
            ZStack(alignment: .topLeading) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        .background {
            if t.tray { MFTrayBackground(t: t, radius: r) }
        }
        .background {
            if let burst {
                MFFlourishLayer(burst: burst, t: t, outer: true, radius: r)
                    .padding(-MFFlourish.reach)
            }
        }
        .modifier(MFShake(trigger: shake, speed: t.speed))
    }
}

extension View {
    func mfNode(_ name: String, _ flow: MFFlowState, _ t: MFTheme, rise: CGFloat = 0) -> some View {
        let b = flow.box(name)
        let on = flow.on(name)
        return self
            .frame(width: max(0, b.w), height: max(0, b.h), alignment: .topLeading)
            .modifier(MFFx(blur: on ? 0 : 7 * t.blurK, opacity: on ? 1 : 0, scale: on ? 1 : 0.94, y: on ? 0 : rise * t.u))
            .offset(x: b.x, y: b.y)
            .allowsHitTesting(on)
            .accessibilityHidden(!on)
    }

    func mfPlate(_ t: MFTheme, fill: Color, burst: MFBurst? = nil, side: MFSide = .both) -> some View {
        self
            .modifier(MFJitter(
                trigger: burst?.err ?? 0, on: burst != nil && side != .ok && t.fail == "glitch",
                amount: CGFloat(t.fx.size(false)), pace: t.fx.length(false) / max(0.25, t.speed)
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                ZStack {
                    t.keyShape.fill(fill)
                    if let burst { MFFlourishLayer(burst: burst, t: t, outer: false, side: side) }
                }
            }
            .clipShape(t.keyShape)
            .contentShape(t.keyShape)
    }
}

struct MFRowHighlight: ButtonStyle {
    let t: MFTheme
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(t.keyShape.fill(fill).opacity(configuration.isPressed ? 1 : 0))
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension View {
    func mfOutside(_ on: Bool, _ action: @escaping () -> Void) -> some View {
        background {
            if on {
                Color.black.opacity(0.001)
                    .frame(width: 2400, height: 2400)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: action)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct MFPressWatch: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, p in pressed = p }
    }
}

extension MFTheme {
    func grow(_ pressed: Bool, width: CGFloat) -> CGFloat {
        pressed ? 1 + min(0.14, 7 / max(width, 1)) * pressK : 1
    }
}

struct MFSized: Layout {
    var w: CGFloat
    var h: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(w, h) }
        set {
            w = newValue.first
            h = newValue.second
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: max(0, w), height: max(0, h))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews {
            s.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}

final class MFRoomBox {
    var last: CGFloat = -1
}

struct MFRoomReader: Layout {
    let box: MFRoomBox
    let report: (CGFloat) -> Void

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let w = proposal.width, w.isFinite, w > 0, abs(w - box.last) > 0.5 {
            box.last = w
            let send = report
            DispatchQueue.main.async { send(w) }
        }
        let size = subviews.first?.sizeThatFits(proposal) ?? .zero
        guard let w = proposal.width, w.isFinite, w > 0 else { return size }
        return CGSize(width: min(size.width, w), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: proposal)
    }
}

extension View {
    func mfRoom(_ box: MFRoomBox, _ report: @escaping (CGFloat) -> Void) -> some View {
        MFRoomReader(box: box, report: report) { self }
    }
}
