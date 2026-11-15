import SwiftUI

public struct StatusPillStyle: MFLook {
    public var idleLabel: String
    public var busyLabel: String
    public var busyOneLabel: String
    public var doneLabel: String
    public var failLabel: String
    public var retryLabel: String
    public var accent: Color
    public var success: Color
    public var danger: Color
    public var dangerTint: Color
    public var primary: Color
    public var onPrimary: Color
    public var resetAfter: Double
    public var demoFiles: Int
    public var demo: String
    public var appearance: String
    public var surface: Color
    public var fill: Color
    public var fillHover: Color
    public var ink: Color
    public var ink2: Color
    public var focus: Color
    public var size: Double
    public var roundness: Double
    public var pad: Double
    public var shadow: Double
    public var tray: Bool
    public var speed: Double
    public var bounce: Double
    public var blur: Double
    public var press: Double
    public var doneEffect: String
    public var doneLength: Double
    public var doneStrength: Double
    public var doneSize: Double
    public var doneCount: Int
    public var sheenColor: Color
    public var holoA: Color
    public var holoB: Color
    public var holoC: Color
    public var holoGlitter: Color
    public var sparkA: Color
    public var sparkB: Color
    public var sparkC: Color
    public var sparkD: Color
    public var auraA: Color
    public var auraB: Color
    public var auraC: Color
    public var errorEffect: String
    public var errorLength: Double
    public var errorStrength: Double
    public var errorSize: Double
    public var errorCount: Int
    public var glitchA: Color
    public var glitchB: Color
    public var emberA: Color
    public var emberB: Color
    public var emberC: Color
    public var flareA: Color
    public var flareB: Color
    public var flareC: Color
    public var surfaceDark: Color
    public var fillDark: Color
    public var fillHoverDark: Color
    public var inkDark: Color
    public var ink2Dark: Color
    public var focusDark: Color
    public var accentDark: Color
    public var successDark: Color
    public var dangerDark: Color
    public var dangerTintDark: Color
    public var primaryDark: Color
    public var onPrimaryDark: Color
    public var isDark = false

    public init(
        idleLabel: String = "Up to date",
        busyLabel: String = "Syncing {n} files",
        busyOneLabel: String = "Syncing {n} file",
        doneLabel: String = "Synced",
        failLabel: String = "Sync failed",
        retryLabel: String = "Retry",
        accent: Color = Color(mfHex: 0x3355FF),
        success: Color = Color(mfHex: 0x1FB257),
        danger: Color = Color(mfHex: 0xE5484D),
        dangerTint: Color = Color(mfHex: 0xFCE9E8),
        primary: Color = Color(mfHex: 0x1A1915),
        onPrimary: Color = Color(mfHex: 0xFFFFFF),
        resetAfter: Double = 1.8,
        demoFiles: Int = 4,
        demo: String = "alternate",
        appearance: String = "auto",
        surface: Color = Color(mfHex: 0xFFFFFF),
        fill: Color = Color(mfHex: 0xEFEEE9),
        fillHover: Color = Color(mfHex: 0xE8E6E0),
        ink: Color = Color(mfHex: 0x1A1915),
        ink2: Color = Color(mfHex: 0x8D8A81),
        focus: Color = Color(mfHex: 0x3355FF),
        size: Double = 44,
        roundness: Double = 1,
        pad: Double = 5,
        shadow: Double = 1,
        tray: Bool = true,
        speed: Double = 1,
        bounce: Double = 1,
        blur: Double = 1,
        press: Double = 1,
        doneEffect: String = "sheen",
        doneLength: Double = 1,
        doneStrength: Double = 1,
        doneSize: Double = 1,
        doneCount: Int = 84,
        sheenColor: Color = Color(mfHex: 0xFFFFFF),
        holoA: Color = Color(mfHex: 0xFF5353),
        holoB: Color = Color(mfHex: 0x5353FF),
        holoC: Color = Color(mfHex: 0x53FF53),
        holoGlitter: Color = Color(mfHex: 0xFFFFFF),
        sparkA: Color = Color(mfHex: 0x1FB257),
        sparkB: Color = Color(mfHex: 0x6FD69A),
        sparkC: Color = Color(mfHex: 0x12924A),
        sparkD: Color = Color(mfHex: 0xA8E040),
        auraA: Color = Color(mfHex: 0x1FB257),
        auraB: Color = Color(mfHex: 0x18B6A4),
        auraC: Color = Color(mfHex: 0x8BE04E),
        errorEffect: String = "none",
        errorLength: Double = 1,
        errorStrength: Double = 1,
        errorSize: Double = 1,
        errorCount: Int = 46,
        glitchA: Color = Color(mfHex: 0xE5484D),
        glitchB: Color = Color(mfHex: 0x991A26),
        emberA: Color = Color(mfHex: 0xE5484D),
        emberB: Color = Color(mfHex: 0xF2858A),
        emberC: Color = Color(mfHex: 0xB42318),
        flareA: Color = Color(mfHex: 0xE5484D),
        flareB: Color = Color(mfHex: 0xFF6A2B),
        flareC: Color = Color(mfHex: 0xB31A24),
        surfaceDark: Color = Color(mfHex: 0x252420),
        fillDark: Color = Color(mfHex: 0x33322D),
        fillHoverDark: Color = Color(mfHex: 0x3C3B35),
        inkDark: Color = Color(mfHex: 0xF2F1EC),
        ink2Dark: Color = Color(mfHex: 0xA09D93),
        focusDark: Color = Color(mfHex: 0x6E88FF),
        accentDark: Color = Color(mfHex: 0x6E88FF),
        successDark: Color = Color(mfHex: 0x2DC46B),
        dangerDark: Color = Color(mfHex: 0xFF5C61),
        dangerTintDark: Color = Color(mfHex: 0x43262A),
        primaryDark: Color = Color(mfHex: 0xF2F1EC),
        onPrimaryDark: Color = Color(mfHex: 0x1A1915)
    ) {
        self.idleLabel = idleLabel
        self.busyLabel = busyLabel
        self.busyOneLabel = busyOneLabel
        self.doneLabel = doneLabel
        self.failLabel = failLabel
        self.retryLabel = retryLabel
        self.accent = accent
        self.success = success
        self.danger = danger
        self.dangerTint = dangerTint
        self.primary = primary
        self.onPrimary = onPrimary
        self.resetAfter = resetAfter
        self.demoFiles = demoFiles
        self.demo = demo
        self.appearance = appearance
        self.surface = surface
        self.fill = fill
        self.fillHover = fillHover
        self.ink = ink
        self.ink2 = ink2
        self.focus = focus
        self.size = size
        self.roundness = roundness
        self.pad = pad
        self.shadow = shadow
        self.tray = tray
        self.speed = speed
        self.bounce = bounce
        self.blur = blur
        self.press = press
        self.doneEffect = doneEffect
        self.doneLength = doneLength
        self.doneStrength = doneStrength
        self.doneSize = doneSize
        self.doneCount = doneCount
        self.sheenColor = sheenColor
        self.holoA = holoA
        self.holoB = holoB
        self.holoC = holoC
        self.holoGlitter = holoGlitter
        self.sparkA = sparkA
        self.sparkB = sparkB
        self.sparkC = sparkC
        self.sparkD = sparkD
        self.auraA = auraA
        self.auraB = auraB
        self.auraC = auraC
        self.errorEffect = errorEffect
        self.errorLength = errorLength
        self.errorStrength = errorStrength
        self.errorSize = errorSize
        self.errorCount = errorCount
        self.glitchA = glitchA
        self.glitchB = glitchB
        self.emberA = emberA
        self.emberB = emberB
        self.emberC = emberC
        self.flareA = flareA
        self.flareB = flareB
        self.flareC = flareC
        self.surfaceDark = surfaceDark
        self.fillDark = fillDark
        self.fillHoverDark = fillHoverDark
        self.inkDark = inkDark
        self.ink2Dark = ink2Dark
        self.focusDark = focusDark
        self.accentDark = accentDark
        self.successDark = successDark
        self.dangerDark = dangerDark
        self.dangerTintDark = dangerTintDark
        self.primaryDark = primaryDark
        self.onPrimaryDark = onPrimaryDark
    }

    public func resolved(_ scheme: ColorScheme) -> Self {
        guard appearance == "dark" || (appearance != "light" && scheme == .dark) else { return self }
        var s = self
        s.surface = surfaceDark
        s.fill = fillDark
        s.fillHover = fillHoverDark
        s.ink = inkDark
        s.ink2 = ink2Dark
        s.focus = focusDark
        s.accent = accentDark
        s.success = successDark
        s.danger = dangerDark
        s.dangerTint = dangerTintDark
        s.primary = primaryDark
        s.onPrimary = onPrimaryDark
        s.isDark = true
        return s
    }
}

public struct StatusPill: View {
    public enum Status: Equatable, Sendable {
        case idle
        case working(left: Int, total: Int)
        case done
        case failed
    }

    private let binding: Binding<Status>?
    private let onRetry: (() -> Void)?
    private let base: StatusPillStyle
    @Environment(\.colorScheme) private var colorScheme
    private var style: StatusPillStyle { base.resolved(colorScheme) }

    @State private var own: Status = .idle
    @State private var runs = 0
    @State private var lastLeft = 0
    @State private var lastTotal = 1
    @State private var burst = MFBurst()
    @State private var job: Task<Void, Never>?
    @State private var demo: Task<Void, Never>?

    public init(
        status: Binding<Status>? = nil,
        style: StatusPillStyle = .init(),
        onRetry: (() -> Void)? = nil
    ) {
        self.binding = status
        self.onRetry = onRetry
        self.base = style
    }

    private var status: Status { binding?.wrappedValue ?? own }

    private func set(_ s: Status) {
        if let binding { binding.wrappedValue = s } else { own = s }
    }

    private var label: String {
        switch status {
        case .idle: return style.idleLabel
        case .working(let left, _):
            return (left == 1 ? style.busyOneLabel : style.busyLabel).replacingOccurrences(of: "{n}", with: String(left))
        case .done: return style.doneLabel
        case .failed: return style.failLabel
        }
    }

    private var fraction: CGFloat {
        switch status {
        case .working(let left, let total): return CGFloat(max(0, total - left)) / CGFloat(max(1, total))
        case .done: return 1
        default: return 0
        }
    }

    private var isFailed: Bool { status == .failed }

    public var body: some View {
        let t = style.mfTheme
        MFTray(t: t, burst: burst) {
            HStack(spacing: t.keyGap) {
                mainKey(t)
                if isFailed, onRetry != nil {
                    retryKey(t).transition(.mfBlur(t, x: -30 * t.u))
                }
            }
        }
        .onChange(of: status) { old, new in changed(old, new) }
        .onDisappear {
            job?.cancel()
            demo?.cancel()
        }
    }

    private func mainKey(_ t: MFTheme) -> some View {
        let done = status == .done
        let fill: Color = done ? style.success : (isFailed ? style.dangerTint : t.fill)
        let ink: Color = done ? .white : (isFailed ? style.danger : t.ink)
        let working: Bool = { if case .working = status { return true }; return false }()
        let icon: String? = done ? "check" : (isFailed ? "alert" : (working ? nil : "cloudCheck"))
        return HStack(spacing: t.inline) {
            ZStack {
                ring(t)
                    .modifier(MFFx(blur: working ? 0 : 3 * t.blurK, opacity: working ? 1 : 0, scale: working ? 1 : 0.6))
                if let icon {
                    MFIcon(name: icon, t: t, weight: done ? .bold : .semibold)
                        .foregroundStyle(done || isFailed ? ink : t.ink2)
                        .transition(.mfBlur(t, radius: 4, scale: 0.4))
                }
            }
            .frame(width: t.ic, height: t.ic)
            MFMorphText(label, t: t, stagger: 13).font(t.label).monospacedDigit()
        }
        .padding(.leading, t.glyph)
        .padding(.trailing, t.edge)
        .foregroundStyle(ink)
        .frame(width: t.keyWidth(label), alignment: .leading)
        .mfKey(t, fill: fill, burst: burst)
        .mfSheen(burst.ok, t, delay: 0.38)
        .animation(.easeOut(duration: 0.22), value: status)
        .animation(t.spring(.morph), value: label)
        .contentShape(t.keyShape)
        .onTapGesture { if binding == nil && status == .idle { runDemo(nil) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func ring(_ t: MFTheme) -> some View {
        let d = t.ic * 1.16 * 17 / 24
        let w = t.ic * 1.16 * 2.6 / 24
        return ZStack {
            Circle().stroke(style.accent.opacity(0.22), lineWidth: w)
            Circle()
                .trim(from: 0, to: max(0.001, fraction))
                .stroke(style.accent, style: StrokeStyle(lineWidth: w, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.38, bounce: 0), value: fraction)
        }
        .frame(width: d, height: d)
    }

    private func retryKey(_ t: MFTheme) -> some View {
        Button(action: retry) {
            HStack(spacing: t.inline) {
                MFIcon(name: "retry", t: t)
                Text(style.retryLabel).font(t.label).lineLimit(1).fixedSize()
            }
            .padding(.leading, t.glyph)
            .padding(.trailing, t.edge)
            .foregroundStyle(style.onPrimary)
            .frame(width: t.keyWidth(style.retryLabel), alignment: .leading)
            .mfKey(t, fill: style.primary)
        }
        .buttonStyle(MFPress(t: t))
        .accessibilityLabel(style.retryLabel)
    }

    private func changed(_ old: Status, _ new: Status) {
        let t = style.mfTheme
        job?.cancel()
        switch new {
        case .done:
            burst.done()
            job = Task { @MainActor in
                guard await t.wait(style.resetAfter * 1000) else { return }
                withAnimation(t.spring(.morph)) { set(.idle) }
            }
        case .failed:
            burst.fail()
        case .working(let left, let total):
            lastLeft = left
            lastTotal = total
        case .idle:
            break
        }
    }

    private func retry() {
        guard isFailed else { return }
        onRetry?()
        if binding == nil { runDemo(lastLeft) }
    }

    private func runDemo(_ from: Int?) {
        let t = style.mfTheme
        let run = runs
        runs += 1
        let total = max(1, from == nil ? style.demoFiles : lastTotal)
        let failing = from == nil && (style.demo == "fail" || (style.demo == "alternate" && run % 2 == 1))
        let failAt = max(1, total / 2)
        demo?.cancel()
        demo = Task { @MainActor in
            var left = from ?? total
            withAnimation(t.spring(.morph)) { set(.working(left: left, total: total)) }
            while true {
                guard await t.wait(520) else { return }
                if failing && left == failAt {
                    withAnimation(t.spring(.morph)) { set(.failed) }
                    return
                }
                if left - 1 > 0 {
                    left -= 1
                    withAnimation(t.spring(.morph)) { set(.working(left: left, total: total)) }
                } else {
                    withAnimation(t.spring(.morph)) { set(.done) }
                    return
                }
            }
        }
    }
}

private struct StatusPillPreview: View {
    @State private var status: StatusPill.Status = .idle

    var body: some View {
        VStack(spacing: 24) {
            StatusPill()
            StatusPill(status: $status) { status = .working(left: 2, total: 4) }
            Button("Sync 4 files") { status = .working(left: 4, total: 4) }
        }
        .padding(24)
    }
}

#Preview {
    StatusPillPreview()
}
