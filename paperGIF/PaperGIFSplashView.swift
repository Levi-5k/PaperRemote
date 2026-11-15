import CoreMotion
import SwiftUI
import WebKit

enum PaperGIFSplashPreference {
    static let enabledKey = "splash.enabled"
    static let seenKey = "splash.hasLaunched"
}

/// Opening drip simulation. Drops fall from the word, bump each other, and pile
/// on the bottom edge. Tap to skip. The static launch screen cannot run it.
struct PaperGIFSplashView: View {
    var onFinished: () -> Void
    @State private var finished = false

    private let playSeconds = 2.0

    var body: some View {
        PaperGIFLightDripSplashWebView()
            .ignoresSafeArea()
            .background(Self.background)
            .contentShape(Rectangle())
            .onTapGesture(perform: finish)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("OP Remote")
            .accessibilityHint("Double tap to continue")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, finish)
            .preferredColorScheme(.dark)
            .task {
                try? await Task.sleep(for: .seconds(playSeconds))
                finish()
            }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinished()
    }

    static let background = Color(red: 2 / 255, green: 7 / 255, blue: 4 / 255)
}

private struct PaperGIFLightDripSplashWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences = preferences
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = true
        view.backgroundColor = UIColor(red: 2 / 255, green: 7 / 255, blue: 4 / 255, alpha: 1)
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        if let url = Self.pageURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    private static var pageURL: URL? {
        if let nested = Bundle.main.url(
            forResource: "splash",
            withExtension: "html",
            subdirectory: "MetalForge/LightDrip"
        ) {
            return nested
        }
        return Bundle.main.url(forResource: "splash", withExtension: "html")
    }

    /// Feeds screen-space gravity into the drip simulation. A shake adds a shove.
    final class Coordinator {
        private let motion = CMMotionManager()
        private weak var webView: WKWebView?
        private var smoothedRight = 0.0
        private var smoothedDown = 1.0
        private var smoothedShake = 0.0
        private var sentRight = Double.nan
        private var sentDown = Double.nan
        private var sentShake = Double.nan

        func attach(_ webView: WKWebView) {
            self.webView = webView
            guard !motion.isDeviceMotionActive, !motion.isAccelerometerActive else { return }
            if motion.isDeviceMotionAvailable {
                motion.deviceMotionUpdateInterval = 1.0 / 30.0
                motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
                    guard let self, let sample else { return }
                    self.apply(gravity: sample.gravity, shake: sample.userAcceleration)
                }
            } else if motion.isAccelerometerAvailable {
                motion.accelerometerUpdateInterval = 1.0 / 30.0
                motion.startAccelerometerUpdates(to: .main) { [weak self] sample, _ in
                    guard let self, let sample else { return }
                    self.apply(gravity: sample.acceleration, shake: CMAcceleration(x: 0, y: 0, z: 0))
                }
            }
        }

        func stop() {
            motion.stopDeviceMotionUpdates()
            motion.stopAccelerometerUpdates()
            webView = nil
        }

        private func apply(gravity: CMAcceleration, shake: CMAcceleration) {
            guard let webView else { return }
            let tilt = screenTilt(gravity, view: webView)
            let wobble = min(1.8, hypot(hypot(shake.x, shake.y), shake.z))
            smoothedRight += (tilt.right - smoothedRight) * 0.28
            smoothedDown += (tilt.down - smoothedDown) * 0.28
            smoothedShake += (wobble - smoothedShake) * 0.35
            guard abs(smoothedRight - sentRight) > 0.01
                    || abs(smoothedDown - sentDown) > 0.01
                    || abs(smoothedShake - sentShake) > 0.05 else { return }
            sentRight = smoothedRight
            sentDown = smoothedDown
            sentShake = smoothedShake
            let script = """
            window.paperGIFSplash?.setGravity(\(Self.js(smoothedRight)), \(Self.js(smoothedDown)), \(Self.js(smoothedShake)))
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        /// Gravity in screen space: positive right means that side of the screen is lower.
        private func screenTilt(_ gravity: CMAcceleration, view: UIView) -> (right: Double, down: Double) {
            switch view.window?.windowScene?.interfaceOrientation ?? .portrait {
            case .portraitUpsideDown:
                return (-gravity.x, gravity.y)
            case .landscapeLeft:
                return (-gravity.y, -gravity.x)
            case .landscapeRight:
                return (gravity.y, gravity.x)
            default:
                return (gravity.x, -gravity.y)
            }
        }

        private static func js(_ value: Double) -> String {
            String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
    }
}
