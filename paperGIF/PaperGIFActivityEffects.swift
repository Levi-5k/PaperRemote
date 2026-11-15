import SwiftUI

/// Quiet canvas behind empty Media screens. Off is the default so no shader is created.
enum PaperGIFActivityBackdrop: String, CaseIterable, Identifiable {
    case off
    case stars
    case smoke
    case lilac

    static let storageKey = "activity.emptyBackground"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .stars: "Stars"
        case .smoke: "Smoke"
        case .lilac: "Lilac"
        }
    }
}

/// Full-screen empty-state background. The shader exists only while this screen is visible and active.
struct PaperGIFEmptyBackdrop: View {
    var isVisible: Bool
    @AppStorage(PaperGIFActivityBackdrop.storageKey) private var raw = PaperGIFActivityBackdrop.off.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if showsEffect, let backdrop {
                effect(backdrop)
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var backdrop: PaperGIFActivityBackdrop? {
        let value = PaperGIFActivityBackdrop(rawValue: raw) ?? .off
        return value == .off ? nil : value
    }

    private var showsEffect: Bool {
        isVisible && scenePhase == .active && backdrop != nil
    }

    @ViewBuilder
    private func effect(_ backdrop: PaperGIFActivityBackdrop) -> some View {
        switch backdrop {
        case .off:
            Color.clear
        case .stars:
            StarfieldView()
        case .smoke:
            SmokeView()
        case .lilac:
            PlasmaLilacView()
        }
    }
}

struct PaperGIFEmptyScreen<Content: View>: View {
    var isVisible: Bool
    @ViewBuilder var content: () -> Content
    @AppStorage(PaperGIFActivityBackdrop.storageKey) private var raw = PaperGIFActivityBackdrop.off.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            PaperGIFEmptyBackdrop(isVisible: isVisible)
                .ignoresSafeArea()
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, showsBackdrop ? .dark : colorScheme)
    }

    private var showsBackdrop: Bool {
        isVisible && scenePhase == .active && (PaperGIFActivityBackdrop(rawValue: raw) ?? .off) != .off
    }
}

/// Determinate transfer or conversion fill. Create it only while the work is on screen.
struct PaperGIFTransferBar: View {
    var fraction: Double
    var label: String

    var body: some View {
        PaperGIFLiveEffect(hidesAccessibility: false) { time in
            ProgressBarView(
                time: time,
                fill: min(max(fraction, 0), 1),
                alive: 0.45,
                warp: time,
                style: Double(ProgressBarStyle.bands.rawValue)
            )
        }
        .frame(height: 12)
        .clipShape(Capsule())
        .allowsHitTesting(false)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((min(max(fraction, 0), 1) * 100).rounded())) percent")
    }
}

/// Indeterminate wait. Signal is the only loader compiled into the app.
struct PaperGIFActivityLoader: View {
    var label: String
    var size: CGFloat = 22

    var body: some View {
        Loader(.signal, size: size, label: label)
            .allowsHitTesting(false)
    }
}

struct PaperGIFActivityWait: View {
    var label: String
    var isLive: Bool

    var body: some View {
        VStack(spacing: 12) {
            if isLive {
                PaperGIFActivityLoader(label: label, size: 44)
            } else {
                ProgressView()
                    .accessibilityLabel(label)
            }
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
