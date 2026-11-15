import SwiftUI

public struct Loader: View {
    public var name: LoaderName
    public var color: Color?
    public var track: Color?
    public var background: Color?
    public var size: CGFloat
    public var speed: Double
    public var scheme: ColorScheme?
    public var time: Double?
    public var label: String?

    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperGIFEffectTab) private var owner
    @State private var onScreen = false
    @State private var ownerIsSelected = true

    public init(
        _ name: LoaderName,
        color: Color? = nil,
        track: Color? = nil,
        background: Color? = nil,
        size: CGFloat = LoaderDefaults.size,
        speed: Double = LoaderDefaults.speed,
        scheme: ColorScheme? = nil,
        time: Double? = nil,
        label: String? = "Loading"
    ) {
        self.name = name
        self.color = color
        self.track = track
        self.background = background
        self.size = size
        self.speed = speed
        self.scheme = scheme
        self.time = time
        self.label = label
    }

    public var body: some View {
        Group {
            if let time {
                canvas(at: time)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !onScreen || scenePhase != .active || !ownerIsSelected)) { timeline in
                    canvas(at: timeline.date.timeIntervalSinceReferenceDate)
                        .transaction { $0.animation = nil }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(label ?? "")
        .accessibilityHidden(label == nil)
        .onAppear {
            onScreen = true
            ownerIsSelected = PaperGIFEffectVisibility.allows(owner)
        }
        .onDisappear { onScreen = false }
        .onReceive(NotificationCenter.default.publisher(for: .paperGIFEffectVisibility)) { _ in
            ownerIsSelected = PaperGIFEffectVisibility.allows(owner)
        }
    }

    private func canvas(at t: Double) -> some View {
        let spec = name.spec
        let roles = Loader.roles(for: scheme ?? systemScheme)
        let palette = LoaderPalette(
            accent: color ?? roles.accent,
            ink: track ?? roles.ink,
            background: background ?? roles.background
        )
        return Canvas(rendersAsynchronously: false) { ctx, canvasSize in
            var context = ctx
            LoaderRenderer.draw(
                spec,
                keyframes: LoaderCatalog.keyframes,
                into: &context,
                size: canvasSize,
                time: t,
                speed: speed,
                palette: palette
            )
        }
    }

    static func roles(for scheme: ColorScheme) -> (accent: Color, ink: Color, background: Color) {
        scheme == .light
            ? (Color(loaderHex: "#1D1D1F"), Color(loaderHex: "#000000"), Color(loaderHex: "#FFFFFF"))
            : (Color(loaderHex: "#F5F5F3"), Color(loaderHex: "#FFFFFF"), Color(loaderHex: "#0B0B0C"))
    }
}
