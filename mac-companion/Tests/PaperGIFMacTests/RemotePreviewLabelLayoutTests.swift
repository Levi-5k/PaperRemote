import AppKit
import SwiftUI
import XCTest
@testable import PaperGIFMac

final class RemotePreviewLabelLayoutTests: XCTestCase {
    func testLiveCapAndResizeRecomputeNativeFont() {
        for scale in [CGFloat(0.25), 0.5, 1, 2] {
            for compact in [false, true] {
                for nominal in [9, 17, 24] {
                    let layout = RemotePreviewLabelFitting.layout(
                        size: CGSize(width: 300 * scale, height: 150 * scale), scale: scale,
                        compact: compact, maxButtonTextSize: nominal
                    )
                    XCTAssertEqual(layout.maximumFontSize, CGFloat(nominal) * scale)
                    XCTAssertEqual(RemotePreviewLabelFitting.fontSize(for: "Go", in: layout.labelSize,
                                                                      maximum: layout.maximumFontSize), layout.maximumFontSize)
                }
            }
        }
        let title = "Jog X Negative Y Positive"
        var previous: CGFloat = 0
        for width in [CGFloat(30), 60, 120, 240, 480] {
            let layout = RemotePreviewLabelFitting.layout(size: CGSize(width: width, height: width / 3),
                                                          scale: 1, compact: true, maxButtonTextSize: 17)
            let font = RemotePreviewLabelFitting.fontSize(for: title, in: layout.labelSize, maximum: layout.maximumFontSize)
            XCTAssertGreaterThanOrEqual(font, previous)
            XCTAssertLessThanOrEqual(font, 17)
            previous = font
        }
        XCTAssertGreaterThan(previous, 9)
    }

    func testHorizontalTitleIsButtonCenteredWithSymmetricIconReservation() {
        for size in [CGSize(width: 38, height: 12), CGSize(width: 56, height: 22), CGSize(width: 300, height: 80)] {
            let layout = RemotePreviewLabelFitting.layout(size: size, scale: 0.5, compact: true)
            let font = RemotePreviewLabelFitting.fontSize(for: "Up Left", in: layout.labelSize, maximum: layout.maximumFontSize)
            let measured = RemotePreviewLabelFitting.measuredSize("Up Left", fontSize: font, width: layout.labelSize.width)
            let frames = layout.frames(in: size, measuredLabelHeight: measured.height)
            XCTAssertTrue(layout.horizontal)
            XCTAssertEqual(frames.label.midX, size.width / 2, accuracy: 0.0001)
            XCTAssertEqual(frames.label.midY, size.height / 2, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(frames.label.minX, frames.icon.maxX + layout.iconHalo + layout.spacing - 0.0001)
            checkSafeEdges(layout, frames: frames, size: size)
        }
    }

    func testVerticalGroupCentersActualMeasuredTextNotAvailableArea() {
        let size = CGSize(width: 100, height: 240)
        for title in ["Go", "A longer title that wraps onto several lines", ""] {
            let layout = RemotePreviewLabelFitting.layout(size: size, scale: 1, compact: false, hasTitle: !title.isEmpty)
            let font = RemotePreviewLabelFitting.fontSize(for: title, in: layout.labelSize, maximum: layout.maximumFontSize)
            let measured = RemotePreviewLabelFitting.measuredSize(title, fontSize: font, width: layout.labelSize.width)
            let frames = layout.frames(in: size, measuredLabelHeight: measured.height)
            let top = frames.icon.minY - layout.iconHalo
            let bottom = title.isEmpty ? frames.icon.maxY + layout.iconHalo : frames.label.maxY
            XCTAssertFalse(layout.horizontal)
            XCTAssertEqual((top + bottom) / 2, size.height / 2, accuracy: 0.0001)
            XCTAssertEqual(frames.label.height, measured.height, accuracy: 0.0001)
            XCTAssertLessThan(frames.label.height, layout.labelSize.height)
            checkSafeEdges(layout, frames: frames, size: size)
        }
        let layout = RemotePreviewLabelFitting.layout(size: size, scale: 1, compact: false, hasIcon: false)
        let frames = layout.frames(in: size, measuredLabelHeight: 20)
        XCTAssertEqual(frames.label.midY, size.height / 2)
        XCTAssertEqual(layout.iconSize, 0)
        XCTAssertEqual(layout.spacing, 0)
    }

    @MainActor
    func testActualSwiftUIHeightFitsMeasuredCenteredFrame() {
        for title in ["Go", "Supercalifragilisticexpialidocious", "Line one\nLine two\nLine three"] {
            let size = CGSize(width: 45, height: 110)
            let layout = RemotePreviewLabelFitting.layout(size: size, scale: 0.5, compact: false, maxButtonTextSize: 17)
            let font = RemotePreviewLabelFitting.fontSize(for: title, in: layout.labelSize, maximum: layout.maximumFontSize)
            let measured = RemotePreviewLabelFitting.measuredSize(title, fontSize: font, width: layout.labelSize.width)
            let frames = layout.frames(in: size, measuredLabelHeight: measured.height)
            let view = NSHostingView(rootView: Text(verbatim: title)
                .font(Font(NSFont.systemFont(ofSize: font, weight: .semibold)))
                .lineLimit(nil).allowsTightening(false).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(width: frames.label.width))
            XCTAssertLessThanOrEqual(view.fittingSize.height, frames.label.height + 0.0001)
        }
    }

    private func checkSafeEdges(_ layout: RemotePreviewLabelFitting.Layout,
                               frames: (icon: CGRect, label: CGRect), size: CGSize) {
        let halo = frames.icon.insetBy(dx: -layout.iconHalo, dy: -layout.iconHalo)
        for frame in [halo, frames.label] {
            XCTAssertGreaterThanOrEqual(frame.minX, layout.padding - 0.0001)
            XCTAssertGreaterThanOrEqual(frame.minY, layout.padding - 0.0001)
            XCTAssertLessThanOrEqual(frame.maxX, size.width - layout.padding + 0.0001)
            XCTAssertLessThanOrEqual(frame.maxY, size.height - layout.padding + 0.0001)
        }
    }
}