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

    func testHorizontalTitleUsesAllRemainingWidthAfterOneIconReservation() {
        for size in [CGSize(width: 38, height: 12), CGSize(width: 56, height: 22), CGSize(width: 300, height: 80)] {
            let layout = RemotePreviewLabelFitting.layout(size: size, scale: 0.5, compact: true)
            let font = RemotePreviewLabelFitting.fontSize(for: "Up Left", in: layout.labelSize, maximum: layout.maximumFontSize)
            let measured = RemotePreviewLabelFitting.measuredSize("Up Left", fontSize: font, width: layout.labelSize.width)
            let frames = layout.frames(in: size, measuredLabelHeight: measured.height)
            XCTAssertTrue(layout.horizontal)
            let extent = layout.iconSize + 2 * layout.iconHalo
            XCTAssertEqual(layout.labelSize.width, size.width - 2 * layout.padding - extent - layout.spacing, accuracy: 0.0001)
            XCTAssertEqual(frames.label.midX, (layout.padding + extent + layout.spacing + size.width - layout.padding) / 2, accuracy: 0.0001)
            XCTAssertEqual(frames.label.maxX, size.width - layout.padding, accuracy: 0.0001)
            XCTAssertEqual(frames.label.midY, size.height / 2, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(frames.label.minX, frames.icon.maxX + layout.iconHalo + layout.spacing - 0.0001)
            checkSafeEdges(layout, frames: frames, size: size)
        }
    }

    func testVerticalGroupCentersActualMeasuredTextNotAvailableArea() {
        let size = CGSize(width: 100, height: 240)
        for title in ["Go", "A longer title that may use multiple lines", ""] {
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
    func testActualSwiftUIMultilineFitsMeasuredFrame() {
        for title in ["Go", "Up Left Down Right", "Supercalifragilisticexpialidocious", "Line one\nLine two\nLine three"] {
            let size = CGSize(width: 45, height: 110)
            let layout = RemotePreviewLabelFitting.layout(size: size, scale: 0.5, compact: false, maxButtonTextSize: 17)
            let font = RemotePreviewLabelFitting.fontSize(for: title, in: layout.labelSize, maximum: layout.maximumFontSize)
            let measured = RemotePreviewLabelFitting.measuredSize(title, fontSize: font, width: layout.labelSize.width)
            let frames = layout.frames(in: size, measuredLabelHeight: measured.height)
            let view = NSHostingView(rootView: Text(verbatim: RemotePreviewLabelFitting.normalizedTitle(title))
                .font(Font(NSFont.systemFont(ofSize: font, weight: .semibold)))
                .lineLimit(nil).allowsTightening(false).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: floor(frames.label.width)))
            XCTAssertLessThanOrEqual(view.fittingSize.width, frames.label.width + 0.0001)
            XCTAssertLessThanOrEqual(view.fittingSize.height, frames.label.height + 0.0001)
        }
    }

    func testWordWrappedMeasurementPreservesNewlinesAndShrinksWholeWords() {
        XCTAssertEqual(RemotePreviewLabelFitting.normalizedTitle("Line one\r\nLine two\rLine three\u{2028}Line four"),
                       "Line one\nLine two\nLine three\nLine four")
        let bounds = CGSize(width: 80, height: 200)
        let title = "Up Left Down Right"
        XCTAssertEqual(RemotePreviewLabelFitting.fontSize(for: title, in: bounds, maximum: 24), 24)
        XCTAssertGreaterThan(RemotePreviewLabelFitting.measuredSize(title, fontSize: 24, width: 80).height,
                             RemotePreviewLabelFitting.measuredSize("Go", fontSize: 24, width: 80).height)
        XCTAssertGreaterThan(RemotePreviewLabelFitting.measuredSize("Go\n\nGo", fontSize: 24, width: 80).height,
                             RemotePreviewLabelFitting.measuredSize("Go\nGo", fontSize: 24, width: 80).height)
        for word in ["Supercalifragilisticexpialidocious", "第一行很长的按钮标题第二行", "word-with/slashes"] {
            let rejected = RemotePreviewLabelFitting.measuredSize(word, fontSize: 24, width: 80)
            XCTAssertGreaterThan(rejected.width, 80)
            XCTAssertTrue(rejected.height.isInfinite)
            let fitted = RemotePreviewLabelFitting.fontSize(for: word, in: bounds, maximum: 24)
            XCTAssertGreaterThan(fitted, 0)
            XCTAssertLessThan(fitted, 24)
            XCTAssertLessThanOrEqual(RemotePreviewLabelFitting.widestWordWidth(word, fontSize: fitted), 80)
            XCTAssertEqual(RemotePreviewLabelFitting.measuredSize(word, fontSize: fitted, width: 80).height,
                           RemotePreviewLabelFitting.measuredSize("Go", fontSize: fitted, width: 80).height)
        }
        for title in ["Jog X Negative Y Positive", "Supercalifragilisticexpialidocious",
                      "第一行很长的按钮标题第二行", "Line one\nLine two\nLine three"] {
            let measured = RemotePreviewLabelFitting.measuredSize(title, fontSize: 24, width: 20)
            XCTAssertGreaterThan(measured.width, 20)
            XCTAssertTrue(measured.height.isInfinite)
            for bounds in [CGSize(width: 20, height: 100), CGSize(width: 100, height: 5)] {
                let fitted = RemotePreviewLabelFitting.fontSize(for: title, in: bounds, maximum: 24)
                XCTAssertGreaterThan(fitted, 0)
                XCTAssertLessThan(fitted, 24)
                XCTAssertLessThanOrEqual(RemotePreviewLabelFitting.widestWordWidth(title, fontSize: fitted), bounds.width)
                let actual = RemotePreviewLabelFitting.measuredSize(title, fontSize: fitted, width: bounds.width)
                XCTAssertLessThanOrEqual(actual.width, bounds.width)
                XCTAssertLessThanOrEqual(actual.height, bounds.height)
                let larger = RemotePreviewLabelFitting.measuredSize(title, fontSize: fitted + 0.001, width: bounds.width)
                XCTAssertTrue(larger.width > bounds.width || larger.height > bounds.height)
            }
        }
    }

    func testShortHorizontalLabelsKeepMaximumAndNoIconUsesFullWidth() {
        for hasIcon in [false, true] {
            let size = CGSize(width: 300, height: 80)
            let layout = RemotePreviewLabelFitting.layout(size: size, scale: 1, compact: true, hasIcon: hasIcon)
            for title in ["Go", "Up Left", "Play"] {
                XCTAssertEqual(RemotePreviewLabelFitting.fontSize(for: title, in: layout.labelSize, maximum: layout.maximumFontSize), 24)
            }
            if !hasIcon {
                XCTAssertEqual(layout.labelSize.width, size.width - 2 * layout.padding)
                XCTAssertEqual(layout.frames(in: size, measuredLabelHeight: 20).label.midX, size.width / 2)
            }
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