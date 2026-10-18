import SwiftUI
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import PaperDeviceKit

final class DeviceDialTests: XCTestCase {
    private func descriptor() throws -> DeviceDescriptor {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try DeviceDescriptor.decode(Data(contentsOf:
            root.appendingPathComponent("protocol/fixtures/device-descriptor-v1-supermini-dial.json")))
    }

    func testDialControlsAndPrecisionContract() throws {
        let controls = try descriptor().controls
        XCTAssertTrue(DeviceDialView.isSupported(by: controls))
        XCTAssertFalse(DeviceDialView.isSupported(by: []))
        let step = try XCTUnwrap(controls.first { $0.id == "dialStep" })
        XCTAssertEqual(try step.normalized(.number(0.125)), .number(0.13))
        let mode = try XCTUnwrap(controls.first { $0.id == "dialMode" })
        for value in ["single", "multi", "continuous"] {
            XCTAssertEqual(try mode.normalized(.string(value)), .string(value))
        }
        XCTAssertThrowsError(try mode.normalized(.string("unknown")))
        let position = try XCTUnwrap(controls.first { $0.id == "dialPosition" })
        XCTAssertThrowsError(try position.normalized(.number(0)))
        XCTAssertEqual(DeviceControlSnapshot(values: ["dialPosition": .number(-720)]).filtered(for: controls),
                       ["dialPosition": .number(-720)])
    }

    func testEndStopCanBeDraggedToEitherSideOfStart() {
        XCTAssertEqual(DeviceDialView.signedTravel(dragAngle: 90, start: 0, previous: 45), 90)
        // Dragging the end stop past the start flips the dial to counterclockwise.
        XCTAssertEqual(DeviceDialView.signedTravel(dragAngle: 350, start: 0, previous: 5), -10)
        XCTAssertEqual(DeviceDialView.signedTravel(dragAngle: 20, start: 0, previous: -5), 20)
        XCTAssertEqual(DeviceDialView.signedTravel(dragAngle: 300, start: 30, previous: -60), -90)
        // Crossing the far side pins the stop at a full turn instead of collapsing it.
        XCTAssertEqual(DeviceDialView.signedTravel(dragAngle: 10, start: 0, previous: 350), 360)
        XCTAssertEqual(DeviceDialView.signedTravel(dragAngle: 350, start: 0, previous: -350), -360)
        XCTAssertEqual(DeviceDialView.signedTravel(dragAngle: 0.2, start: 0, previous: 3), 1)
        XCTAssertEqual(DeviceDialView.signedTravel(dragAngle: 359.8, start: 0, previous: -3), -1)
    }

    func testSignedEndStopsAreValidControlValues() throws {
        let controls = try descriptor().controls
        let sweep = try XCTUnwrap(controls.first { $0.id == "dialSweep" })
        XCTAssertEqual(try sweep.normalized(.number(-90)), .number(-90))
        let turns = try XCTUnwrap(controls.first { $0.id == "dialTurns" })
        XCTAssertEqual(try turns.normalized(.number(-2.5)), .number(-2.5))
        XCTAssertNil(controls.first { $0.id == "dialReversed" })
    }

    @MainActor
    func testLivePositionRendersInAllModesAndWithoutSensor() throws {
        let model = DeviceControlsModel()
        model.configure(controls: try descriptor().controls, transports: [])
        for mode in ["single", "multi", "continuous"] {
            for present in [true, false] {
                model.receive(.init(values: [
                    "dialPresent": .bool(present), "dialPosition": .number(mode == "continuous" ? -720 : 180),
                    "dialAngle": .number(180), "dialMode": .string(mode), "dialStart": .number(0),
                    "dialSweep": .number(present ? 270 : -90), "dialTurns": .number(present ? 3 : -2),
                    "dialStep": .number(0.1), "dialJitter": .number(0.2)
                ]), via: "Bluetooth")
                let view = DeviceDialView(model: model).padding().frame(width: 520)
                    .environment(\.colorScheme, .light).background(Color.white)
                let image = try XCTUnwrap(ImageRenderer(content: view).cgImage)
                XCTAssertEqual(image.width, 520)
                XCTAssertGreaterThan(image.height, 400)
                #if os(macOS)
                if present, mode == "single",
                   let path = ProcessInfo.processInfo.environment["PAPERREMOTE_DIAL_SNAPSHOT"] {
                    let hosting = NSHostingView(rootView: view)
                    hosting.frame = CGRect(x: 0, y: 0, width: 520, height: image.height)
                    let window = NSWindow(contentRect: hosting.frame, styleMask: [], backing: .buffered, defer: false)
                    window.contentView = hosting
                    hosting.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: path))
                    window.contentView = nil
                }
                #endif
            }

        }
    }

    private actor CountingTransport: DeviceControlTransport {
        nonisolated let name: String
        var reads = 0
        init(name: String) { self.name = name }
        func snapshot() async throws -> DeviceControlSnapshot {
            reads += 1
            return .init(values: ["dialPosition": .number(Double(reads))])
        }
        func set(_ request: DeviceControlSetRequest) async throws -> DeviceControlSnapshot {
            try await snapshot()
        }
    }

    @MainActor
    func testWifiMonitorsLivePositionAndStopsWhenCancelled() async throws {
        let model = DeviceControlsModel()
        let transport = CountingTransport(name: "Wi-Fi")
        model.configure(controls: try descriptor().controls, transports: [transport])
        await model.refresh()
        let task = Task { await model.monitorDial() }
        try await Task.sleep(for: .milliseconds(750))
        task.cancel()
        await task.value
        let reads = await transport.reads
        XCTAssertGreaterThanOrEqual(reads, 3)
        XCTAssertEqual(model.values["dialPosition"], .number(Double(reads)))
        XCTAssertFalse(model.isLoading)
        try await Task.sleep(for: .milliseconds(250))
        let after = await transport.reads
        XCTAssertEqual(after, reads)
    }

    @MainActor
    func testBluetoothUsesPushesInsteadOfHighRatePolling() async throws {
        let model = DeviceControlsModel()
        let transport = CountingTransport(name: "Bluetooth")
        model.configure(controls: try descriptor().controls, transports: [transport])
        await model.refresh()
        let task = Task { await model.monitorDial() }
        try await Task.sleep(for: .milliseconds(450))
        model.receive(.init(values: ["dialPosition": .number(-720)]), via: "Bluetooth")
        task.cancel()
        await task.value
        let reads = await transport.reads
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.values["dialPosition"], .number(-720))
    }
}
