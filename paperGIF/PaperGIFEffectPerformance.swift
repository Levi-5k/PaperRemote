import MetalKit
import SwiftUI

extension Notification.Name {
    static let paperGIFEffectVisibility = Notification.Name("paperGIFEffectVisibility")
}

private struct PaperGIFEffectTabKey: EnvironmentKey {
    static let defaultValue: PaperGIFAppTab? = nil
}

extension EnvironmentValues {
    var paperGIFEffectTab: PaperGIFAppTab? {
        get { self[PaperGIFEffectTabKey.self] }
        set { self[PaperGIFEffectTabKey.self] = newValue }
    }
}

/// Which tab may spend GPU time. Updated by the root tab view and read by
/// effects that stay mounted after the user leaves their tab.
enum PaperGIFEffectVisibility {
    static var liveTab = PaperGIFAppTab.remote
    static var sceneIsActive = true

    static func allows(_ tab: PaperGIFAppTab?) -> Bool {
        guard sceneIsActive else { return false }
        guard let tab else { return true }
        return liveTab == tab
    }

    static var remoteLive: Bool { allows(.remote) }

    static func publish(tab: PaperGIFAppTab, sceneIsActive: Bool) {
        liveTab = tab
        self.sceneIsActive = sceneIsActive
        NotificationCenter.default.post(name: .paperGIFEffectVisibility, object: tab)
    }
}

enum PaperGIFMetalEffect {
    static let framesPerSecond = 30

    static func release(_ view: MTKView) {
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = nil
    }
}

/// Pauses the simulation when the view leaves the window or another tab is selected.
final class PaperGIFPausingMTKView: MTKView {
    private var visibilityToken: NSObjectProtocol?

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        visibilityToken = NotificationCenter.default.addObserver(
            forName: .paperGIFEffectVisibility,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyVisibility()
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let visibilityToken {
            NotificationCenter.default.removeObserver(visibilityToken)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyVisibility()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        applyVisibility()
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        applyVisibility()
    }
    #else
    override func layout() {
        super.layout()
        applyVisibility()
    }
    #endif

    func applyVisibility() {
        let onScreen = window != nil && !isHidden && alpha > 0.01 && intersectsWindow() && PaperGIFEffectVisibility.remoteLive
        isPaused = !onScreen
        enableSetNeedsDisplay = !onScreen
    }

    private func intersectsWindow() -> Bool {
        guard let window else { return false }
        return convert(bounds, to: window).intersects(window.bounds)
    }
}

struct PaperGIFLiveEffect<Content: View>: View {
    var hidesAccessibility = true
    @ViewBuilder var content: (TimeInterval) -> Content
    @State private var onScreen = false
    @State private var ownerIsSelected = true
    @State private var start = Date.now
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperGIFEffectTab) private var owner

    private var paused: Bool { !onScreen || scenePhase != .active || !ownerIsSelected }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { ctx in
            content(ctx.date.timeIntervalSince(start))
                .transaction { $0.animation = nil }
        }
        .compositingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(hidesAccessibility)
        .onAppear {
            onScreen = true
            ownerIsSelected = PaperGIFEffectVisibility.allows(owner)
        }
        .onDisappear { onScreen = false }
        .onReceive(NotificationCenter.default.publisher(for: .paperGIFEffectVisibility)) { _ in
            ownerIsSelected = PaperGIFEffectVisibility.allows(owner)
        }
    }
}
