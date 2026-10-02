import SwiftUI
import UIKit
import XCTest
@testable import Paperbound

final class HighlightActionBarTests: XCTestCase {
    private let bar = CGSize(width: 296, height: 169)
    private let phone = CGRect(x: 0, y: 0, width: 393, height: 760)

    // MARK: - Placement: basic preference

    func testPlacesAboveWhenThereIsRoom() {
        let selection = CGRect(x: 60, y: 400, width: 260, height: 40)
        let p = ActionBarPlacement.place(barSize: bar, selection: selection, container: phone, avoiding: [])
        XCTAssertTrue(p.isAbove)
        XCTAssertEqual(p.frame.maxY, selection.minY - 24, accuracy: 0.001)
        assertInside(p.frame, phone)
    }

    func testPlacesBelowWhenSelectionIsNearTheTop() {
        let selection = CGRect(x: 60, y: 40, width: 260, height: 40)
        let p = ActionBarPlacement.place(barSize: bar, selection: selection, container: phone, avoiding: [])
        XCTAssertFalse(p.isAbove)
        XCTAssertEqual(p.frame.minY, selection.maxY + 24, accuracy: 0.001)
        assertInside(p.frame, phone)
    }

    func testTallSelectionOverlapsOnTheSideWithMoreRoom() {
        // Selection fills almost the whole page: neither above nor below fits.
        let selection = CGRect(x: 30, y: 120, width: 330, height: 560)
        let p = ActionBarPlacement.place(barSize: bar, selection: selection, container: phone, avoiding: [])
        assertInside(p.frame, phone)
        XCTAssertTrue(p.isAbove, "more room above (120) than below (80)")
        XCTAssertEqual(p.frame.minY, 8, accuracy: 0.001)

        let lower = CGRect(x: 30, y: 60, width: 330, height: 560)
        let q = ActionBarPlacement.place(barSize: bar, selection: lower, container: phone, avoiding: [])
        assertInside(q.frame, phone)
        XCTAssertFalse(q.isAbove)
        XCTAssertEqual(q.frame.maxY, phone.maxY - 8, accuracy: 0.001)
    }

    func testCentredOnSelectionWhenUnconstrained() {
        let selection = CGRect(x: 120, y: 500, width: 150, height: 22)
        let p = ActionBarPlacement.place(barSize: CGSize(width: 200, height: 60), selection: selection, container: phone, avoiding: [])
        XCTAssertEqual(p.frame.midX, selection.midX, accuracy: 0.001)
        XCTAssertEqual(p.frame.size, CGSize(width: 200, height: 60))
    }

    func testClampedAtLeftAndRightEdges() {
        let left = CGRect(x: 4, y: 500, width: 40, height: 20)
        let p = ActionBarPlacement.place(barSize: bar, selection: left, container: phone, avoiding: [])
        XCTAssertEqual(p.frame.minX, 8, accuracy: 0.001)

        let right = CGRect(x: 360, y: 500, width: 30, height: 20)
        let q = ActionBarPlacement.place(barSize: bar, selection: right, container: phone, avoiding: [])
        XCTAssertEqual(q.frame.maxX, phone.maxX - 8, accuracy: 0.001)
    }

    func testRespectsOffsetContainer() {
        // Container already inset for the status bar and reader chrome.
        let container = CGRect(x: 0, y: 110, width: 393, height: 600)
        let selection = CGRect(x: 40, y: 140, width: 200, height: 20)
        let p = ActionBarPlacement.place(barSize: bar, selection: selection, container: container, avoiding: [])
        XCTAssertFalse(p.isAbove, "no room between chrome and selection")
        assertInside(p.frame, container)
    }

    func testMarginShrinksWhenContainerIsTight() {
        let container = CGRect(x: 0, y: 0, width: 300, height: 400)
        let selection = CGRect(x: 100, y: 300, width: 100, height: 20)
        let p = ActionBarPlacement.place(barSize: bar, selection: selection, container: container, avoiding: [])
        assertInside(p.frame, container)
        XCTAssertEqual(p.frame.minX, 2, accuracy: 0.001)
    }

    func testIsDeterministic() {
        let selection = CGRect(x: 200, y: 300, width: 120, height: 30)
        let fold = CGRect(x: 418, y: 0, width: 20, height: 900)
        let container = CGRect(x: 0, y: 0, width: 856, height: 900)
        let a = ActionBarPlacement.place(barSize: bar, selection: selection, container: container, avoiding: [fold])
        let b = ActionBarPlacement.place(barSize: bar, selection: selection, container: container, avoiding: [fold])
        XCTAssertEqual(a, b)
    }

    // MARK: - Placement: Duo fold

    private let duo = CGRect(x: 0, y: 0, width: 856, height: 900)
    private let fold = CGRect(x: 418, y: 0, width: 20, height: 900)

    func testNeverIntersectsFoldForSelectionsAcrossTheSpread() {
        for size in [bar, HighlightActionBar.preferredSize(compact: true), CGSize(width: 120, height: 50)] {
            for x in stride(from: CGFloat(0), through: 840, by: 7) {
                for y in stride(from: CGFloat(0), through: 880, by: 55) {
                    let selection = CGRect(x: x, y: y, width: 16, height: 20)
                    let p = ActionBarPlacement.place(barSize: size, selection: selection, container: duo, avoiding: [fold])
                    XCTAssertFalse(p.frame.intersects(fold), "bar \(p.frame) hits fold for selection \(selection)")
                    assertInside(p.frame, duo)
                }
            }
        }
    }

    func testSelectionRightNextToFoldStaysInItsPanel() {
        // Just left of the fold: clamp into the left panel, flush with the fold gap.
        let leftSel = CGRect(x: 380, y: 400, width: 36, height: 20)
        let p = ActionBarPlacement.place(barSize: bar, selection: leftSel, container: duo, avoiding: [fold])
        XCTAssertLessThanOrEqual(p.frame.maxX, fold.minX - 8 + 0.001)
        XCTAssertEqual(p.frame.maxX, fold.minX - 8, accuracy: 0.001)
        XCTAssertTrue(p.isAbove)

        // Just right of the fold: clamp into the right panel.
        let rightSel = CGRect(x: 440, y: 400, width: 36, height: 20)
        let q = ActionBarPlacement.place(barSize: bar, selection: rightSel, container: duo, avoiding: [fold])
        XCTAssertEqual(q.frame.minX, fold.maxX + 8, accuracy: 0.001)
    }

    func testSelectionStraddlingFoldPicksNearerPanel() {
        let selection = CGRect(x: 400, y: 400, width: 30, height: 20) // midX 415, left of fold centre
        let p = ActionBarPlacement.place(barSize: bar, selection: selection, container: duo, avoiding: [fold])
        XCTAssertFalse(p.frame.intersects(fold))
        XCTAssertLessThan(p.frame.maxX, fold.minX)
    }

    func testZeroWidthFoldIsNotStraddled() {
        let line = CGRect(x: 428, y: 0, width: 0, height: 900)
        for x in stride(from: CGFloat(300), through: 560, by: 4) {
            let selection = CGRect(x: x, y: 500, width: 20, height: 20)
            let p = ActionBarPlacement.place(barSize: bar, selection: selection, container: duo, avoiding: [line])
            XCTAssertFalse(p.frame.minX < line.minX && p.frame.maxX > line.minX, "straddles fold: \(p.frame)")
        }
    }

    func testBarWiderThanPanelFallsBackToRoomierPanel() {
        // Narrow left panel (200pt), wide right panel.
        let container = CGRect(x: 0, y: 0, width: 800, height: 600)
        let divider = CGRect(x: 200, y: 0, width: 16, height: 600)
        let selection = CGRect(x: 60, y: 300, width: 80, height: 20)
        let p = ActionBarPlacement.place(barSize: bar, selection: selection, container: container, avoiding: [divider])
        XCTAssertFalse(p.frame.intersects(divider))
        XCTAssertGreaterThanOrEqual(p.frame.minX, divider.maxX)
        XCTAssertEqual(p.frame.minX, divider.maxX + 8, accuracy: 0.001, "as close to the selection as the panel allows")
        XCTAssertTrue(p.isAbove)
        assertInside(p.frame, container)
    }

    func testBarWiderThanEveryPanelStillStaysInsideContainer() {
        let container = CGRect(x: 0, y: 0, width: 400, height: 600)
        let divider = CGRect(x: 190, y: 0, width: 20, height: 600)
        let selection = CGRect(x: 60, y: 300, width: 80, height: 20)
        let p = ActionBarPlacement.place(barSize: bar, selection: selection, container: container, avoiding: [divider])
        assertInside(p.frame, container)
    }

    func testHorizontalFoldKeepsBarInSelectionsPanel() {
        // Duo rotated: fold runs across the screen.
        let container = CGRect(x: 0, y: 0, width: 900, height: 856)
        let hfold = CGRect(x: 0, y: 418, width: 900, height: 20)
        // Just below the fold: above would straddle it, so go below.
        let below = CGRect(x: 300, y: 450, width: 200, height: 20)
        let p = ActionBarPlacement.place(barSize: bar, selection: below, container: container, avoiding: [hfold])
        XCTAssertFalse(p.frame.intersects(hfold))
        XCTAssertFalse(p.isAbove)
        XCTAssertGreaterThanOrEqual(p.frame.minY, hfold.maxY)

        // Just above the fold: above is fine.
        let above = CGRect(x: 300, y: 380, width: 200, height: 20)
        let q = ActionBarPlacement.place(barSize: bar, selection: above, container: container, avoiding: [hfold])
        XCTAssertTrue(q.isAbove)
        XCTAssertLessThanOrEqual(q.frame.maxY, hfold.minY)

        for y in stride(from: CGFloat(0), through: 830, by: 9) {
            let s = CGRect(x: 300, y: y, width: 200, height: 20)
            let r = ActionBarPlacement.place(barSize: bar, selection: s, container: container, avoiding: [hfold])
            XCTAssertFalse(r.frame.intersects(hfold), "\(r.frame) for \(s)")
            assertInside(r.frame, container)
        }
    }

    func testCameraCutoutNudgesBarSideways() {
        let camera = CGRect(x: 160, y: 0, width: 80, height: 40)
        let selection = CGRect(x: 150, y: 220, width: 100, height: 20)
        let p = ActionBarPlacement.place(barSize: CGSize(width: 120, height: 150), selection: selection, container: phone, avoiding: [camera])
        XCTAssertFalse(p.frame.intersects(camera))
        XCTAssertTrue(p.isAbove)
        assertInside(p.frame, phone)
    }

    func testFoldAndCutoutTogether() {
        let camera = CGRect(x: 600, y: 0, width: 60, height: 50)
        for x in stride(from: CGFloat(440), through: 830, by: 13) {
            let selection = CGRect(x: x, y: 210, width: 20, height: 20)
            let p = ActionBarPlacement.place(barSize: bar, selection: selection, container: duo, avoiding: [fold, camera])
            XCTAssertFalse(p.frame.intersects(fold))
            XCTAssertFalse(p.frame.intersects(camera))
            assertInside(p.frame, duo)
        }
    }

    // MARK: - Bar sizing

    func testPreferredSizeSanity() {
        let regular = HighlightActionBar.preferredSize(compact: false)
        let compact = HighlightActionBar.preferredSize(compact: true)
        XCTAssertLessThanOrEqual(compact.width, 340)
        XCTAssertGreaterThanOrEqual(compact.height, 44)
        XCTAssertGreaterThanOrEqual(regular.height, 44 * 3)
        XCTAssertLessThan(regular.width, 340)
        XCTAssertGreaterThan(regular.height, compact.height)
    }

    @MainActor
    func testRenderedSizeMatchesPreferredSize() {
        for compact in [false, true] {
            for mode in [HighlightActionBar.Mode.create, .edit] {
                let renderer = ImageRenderer(content: makeBar(mode: mode, compact: compact, style: .highlight, color: .butter))
                renderer.scale = 1
                let image = try? XCTUnwrap(renderer.uiImage)
                let expected = HighlightActionBar.preferredSize(compact: compact)
                XCTAssertEqual(image?.size.width ?? 0, expected.width, accuracy: 1, "compact \(compact) \(mode)")
                XCTAssertEqual(image?.size.height ?? 0, expected.height, accuracy: 1, "compact \(compact) \(mode)")
            }
        }
    }

    func testLabelContrastPicksReadableInk() {
        for color in HighlightColor.allCases {
            let solid = color.actionBarSolid
            let l = solid.actionBarRelativeLuminance
            let chosen = solid.actionBarPrefersDarkLabel ? (l + 0.05) / 0.05 : 1.05 / (l + 0.05)
            XCTAssertGreaterThanOrEqual(chosen, 4.5, "\(color) label contrast \(chosen)")
        }
    }

    // MARK: - Visual proofs

    @MainActor
    func testRenderVisualProofs() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/pb-agent-c-proofs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let cases: [(String, HighlightActionBar.Mode, Bool, HighlightStyle, HighlightColor)] = [
            ("create-regular", .create, false, .highlight, .butter),
            ("edit-regular", .edit, false, .squiggly, .sky),
            ("create-compact", .create, true, .underline, .rose),
            ("edit-compact", .edit, true, .strikethrough, .moss),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, mode, compact, style, color) in cases {
                let scene = ProofScene(mode: mode, compact: compact, style: style, color: color)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: scene)
                renderer.scale = 2
                let data = try XCTUnwrap(renderer.uiImage?.pngData(), "render \(name)")
                let url = folder.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                try data.write(to: url, options: .atomic)
            }
        }

        // Every style in every colour, for checking the preview glyphs.
        for scheme in [ColorScheme.light, .dark] {
            let sheet = GlyphSheet().environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 3
            let data = try XCTUnwrap(renderer.uiImage?.pngData())
            try data.write(to: folder.appendingPathComponent("glyphs-\(scheme == .dark ? "dark" : "light").png"), options: .atomic)
        }
    }

    // MARK: - Helpers

    private func assertInside(_ frame: CGRect, _ container: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(frame.minX, container.minX - 0.001, "\(frame) outside \(container)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, container.minY - 0.001, "\(frame) outside \(container)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, container.maxX + 0.001, "\(frame) outside \(container)", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, container.maxY + 0.001, "\(frame) outside \(container)", file: file, line: line)
    }
}

@MainActor
private func makeBar(mode: HighlightActionBar.Mode, compact: Bool, style: HighlightStyle, color: HighlightColor) -> HighlightActionBar {
    HighlightActionBar(
        mode: mode,
        style: style,
        color: color,
        compact: compact,
        onStyle: { _ in },
        onColor: { _ in },
        onCopy: {},
        onDelete: mode == .edit ? {} : nil
    )
}

/// A page-like backdrop with a selected passage and the bar placed over it
/// by `ActionBarPlacement`, as the reader would show it.
private struct ProofScene: View {
    let mode: HighlightActionBar.Mode
    let compact: Bool
    let style: HighlightStyle
    let color: HighlightColor
    @Environment(\.colorScheme) private var scheme

    private let size = CGSize(width: 393, height: 460)
    private let lines = [
        "It was the best of times, it was the worst",
        "of times, it was the age of wisdom, it was",
        "the age of foolishness, it was the epoch of",
        "belief, it was the epoch of incredulity, it",
        "was the season of Light, it was the season",
        "of Darkness, it was the spring of hope, it",
        "was the winter of despair, we had every-",
        "thing before us, we had nothing before us,",
        "we were all going direct to Heaven, we were",
        "all going direct the other way. In short,",
        "the period was so far like the present",
        "period, that some of its noisiest authorities",
    ]
    private let lineHeight: CGFloat = 26
    private let top: CGFloat = 70
    private let selectedLines = 7...8

    var body: some View {
        let paper = scheme == .dark ? Color(red: 0.12, green: 0.115, blue: 0.11) : Color(red: 0.97, green: 0.95, blue: 0.9)
        let ink = scheme == .dark ? Color(red: 0.86, green: 0.84, blue: 0.8) : Color(red: 0.16, green: 0.14, blue: 0.12)
        let selection = CGRect(x: 24, y: top + CGFloat(selectedLines.lowerBound) * lineHeight,
                               width: size.width - 48, height: CGFloat(selectedLines.count) * lineHeight)
        let barSize = HighlightActionBar.preferredSize(compact: compact)
        let container = CGRect(origin: .zero, size: size).insetBy(dx: 0, dy: 10)
        let placement = ActionBarPlacement.place(barSize: barSize, selection: selection, container: container, avoiding: [])

        ZStack(alignment: .topLeading) {
            paper
            ForEach(Array(lines.enumerated()), id: \.offset) { index, text in
                Text(text)
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(ink)
                    .padding(.horizontal, 2)
                    .background {
                        if selectedLines.contains(index) {
                            Rectangle().fill(Color.accentColor.opacity(0.22))
                        }
                    }
                    .offset(x: 22, y: top + CGFloat(index) * lineHeight)
            }
            makeBar(mode: mode, compact: compact, style: style, color: color)
                .environment(\.highlightActionBarOpaqueSurface, true)
                .offset(x: placement.frame.minX, y: placement.frame.minY)
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct GlyphSheet: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 10) {
            ForEach(HighlightColor.allCases) { color in
                HStack(spacing: 18) {
                    ForEach(HighlightStyle.allCases) { style in
                        HighlightStyleGlyph(style: style, color: color, fontSize: 19)
                            .frame(width: 56, height: 44)
                    }
                    HighlightStyleMenuLabel(style: .squiggly, color: color)
                }
            }
        }
        .padding(16)
        .background(scheme == .dark ? Color.black : Color.white)
    }
}
