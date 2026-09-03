import SwiftUI

enum PaperGIFSettingKey {
    static let monochromeMode = "conversion.monochromeMode"
    static let threshold = "conversion.threshold"
    static let monochromeLevels = "conversion.monochromeLevels"
    static let halftoneDotSpacing = "conversion.halftoneDotSpacing"
    static let halftoneAngle = "conversion.halftoneAngle"
    static let halftoneDotGain = "conversion.halftoneDotGain"
    static let maximumFramesPerSecond = "conversion.maximumFramesPerSecond"
    static let scanRateHz = "playback.scanRateHz"
    static let transitionScans = "playback.transitionScans"
    static let cleanRefreshInterval = "playback.cleanRefreshInterval"
    static let adaptiveCleaning = "playback.adaptiveCleaning"
}

struct PaperGIFSettingsView: View {
    @Binding var monochromeMode: PaperGIFMonochromeMode
    @Binding var threshold: Double
    @Binding var monochromeLevels: Int
    @Binding var halftoneDotSpacing: Int
    @Binding var halftoneAngle: Int
    @Binding var halftoneDotGain: Int
    @Binding var maximumFramesPerSecond: Double
    @Binding var scanRateHz: Int
    @Binding var transitionScans: Int
    @Binding var cleanRefreshInterval: Int
    @Binding var adaptiveCleaning: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Rendering", selection: $monochromeMode) {
                        ForEach(PaperGIFMonochromeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("Maximum frame rate") {
                        Text("\(Int(maximumFramesPerSecond)) fps")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $maximumFramesPerSecond, in: 1...30, step: 1)

                    if monochromeMode.usesThreshold {
                        LabeledContent("Black threshold") {
                            Text("\(Int(threshold))")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $threshold, in: 32...224, step: 1)
                    }

                    if monochromeMode.usesMonochromeLevels {
                        LabeledContent("Monochrome levels") {
                            Text(monochromeLevels == 0 ? "Off" : "\(monochromeLevels)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(monochromeLevels) },
                                set: { monochromeLevels = Int($0.rounded()) }
                            ),
                            in: 0...16,
                            step: 1
                        )
                    }

                    if monochromeMode.usesHalftone {
                        Stepper("Dot spacing: \(halftoneDotSpacing) px", value: $halftoneDotSpacing, in: 3...24)
                        Stepper("Screen angle: \(halftoneAngle)°", value: $halftoneAngle, in: 0...90, step: 15)
                        Stepper("Dot gain: \(halftoneDotGain)%", value: $halftoneDotGain, in: -50...50, step: 5)
                    }
                } header: {
                    Text("Animation")
                } footer: {
                    Text(renderingDescription)
                }

                Section {
                    Picker("Panel scan rate", selection: $scanRateHz) {
                        Text("30 Hz").tag(30)
                        Text("40 Hz").tag(40)
                        Text("50 Hz").tag(50)
                        Text("60 Hz").tag(60)
                    }

                    Stepper("Transition scans: \(transitionScans)", value: $transitionScans, in: 1...9)

                    LabeledContent("Nominal transition") {
                        Text("\(transitionMilliseconds) ms")
                            .foregroundStyle(.secondary)
                    }

                    Toggle("Adaptive cleaning", isOn: $adaptiveCleaning)

                    if adaptiveCleaning {
                        Stepper(
                            "Maximum partial updates: \(cleanRefreshInterval)",
                            value: $cleanRefreshInterval,
                            in: 30...600,
                            step: 30
                        )
                    }
                } header: {
                    Text("Experimental Display Drive")
                } footer: {
                    Text("One transition scan enables the fastest waveform. Full-screen M5Paper animation is typically limited to about 4–6 fps and may show more ghosting.")
                }

                Section {
                    Button("Restore Balanced Defaults") {
                        monochromeMode = .threshold
                        threshold = 128
                        monochromeLevels = 16
                        halftoneDotSpacing = 8
                        halftoneAngle = 45
                        halftoneDotGain = 0
                        maximumFramesPerSecond = 10
                        scanRateHz = Int(PaperGIFPlaybackConfiguration.balanced.scanRateHz)
                        transitionScans = Int(PaperGIFPlaybackConfiguration.balanced.transitionScans)
                        cleanRefreshInterval = Int(PaperGIFPlaybackConfiguration.balanced.cleanRefreshInterval)
                        adaptiveCleaning = PaperGIFPlaybackConfiguration.balanced.adaptiveCleaning
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var transitionMilliseconds: Int {
        Int((Double(transitionScans) / Double(scanRateHz) * 1_000).rounded())
    }

    private var renderingDescription: String {
        switch monochromeMode {
        case .threshold:
            "The threshold controls which grayscale values become black."
        case .monochrome:
            "The threshold shifts the tone range and levels controls how many panel grays are used."
        case .halftone:
            "Spacing controls pattern scale, angle rotates the dot grid, and gain makes dots heavier or lighter."
        case .combined:
            "Halftone screening blends between the selected panel gray levels after applying the threshold tone shift."
        }
    }
}