//
//  MarkerInkTests.swift
//  PaperboundTests
//
//  Annotation ink: determinism, containment within the line, placement of
//  each pen style, selection handle hit testing, plus rendered visual proofs
//  (light and dark paper) written to /private/tmp/pb-agent-b-proofs/ so the
//  look can be judged by eye, not just by numbers.
//

import SwiftUI
import UIKit
import XCTest
@testable import Paperbound

final class MarkerInkTests: XCTestCase {

    private typealias Generator = (CGRect, UInt64) -> Path

    private let generators: [(String, Generator)] = [
        ("highlight", MarkerInk.highlightPath(for:seed:)),
        ("highlightSecondPass", MarkerInk.highlightSecondPassPath(for:seed:)),
        ("highlightEdge", MarkerInk.highlightEdgePath(for:seed:)),
        ("underline", MarkerInk.underlinePath(for:seed:)),
        ("strikethrough", MarkerInk.strikethroughPath(for:seed:)),
        ("squiggle", MarkerInk.squigglePath(for:seed:))
    ]

    private let sampleRects: [CGRect] = [
        CGRect(x: 12, y: 30, width: 60, height: 8),
        CGRect(x: 40, y: 100, width: 180, height: 12),
        CGRect(x: 5, y: 5, width: 320, height: 18),
        CGRect(x: 100, y: 250, width: 420, height: 26),
        CGRect(x: 0, y: 0, width: 540, height: 40),
        CGRect(x: 30, y: 60, width: 14, height: 16)
    ]

    // MARK: Determinism

    func testGeneratorsAreDeterministicPerSeed() {
        let rect = CGRect(x: 20, y: 40, width: 300, height: 18)
        for (name, make) in generators {
            let a = make(rect, 42).description
            let b = make(rect, 42).description
            let c = make(rect, 43).description
            XCTAssertFalse(a.isEmpty, name)
            XCTAssertEqual(a, b, "\(name) must be identical for the same seed")
            XCTAssertNotEqual(a, c, "\(name) must vary between seeds")
        }
    }

    func testSeedDiffersPerLineAndIsStable() {
        let id = UUID(uuidString: "6E1F3A52-2B7C-4D1E-9F0A-1234567890AB")!
        let seeds = (0..<8).map { MarkerInk.seed(for: id, line: $0) }
        XCTAssertEqual(Set(seeds).count, seeds.count)
        XCTAssertEqual(MarkerInk.seed(for: id, line: 3), MarkerInk.seed(for: id, line: 3))
        XCTAssertNotEqual(MarkerInk.seed(for: id, line: 0), MarkerInk.seed(for: UUID(), line: 0))
    }

    // MARK: Containment and placement

    func testPathsStayWithinThirtyPercentOfLineHeight() {
        for rect in sampleRects {
            for seed in UInt64(1)...UInt64(40) {
                for (name, make) in generators {
                    let box = make(rect, seed).boundingRect
                    guard !box.isNull, !box.isEmpty else { continue }
                    let slack = rect.height * 0.3
                    let allowed = rect.insetBy(dx: -slack, dy: -slack)
                    XCTAssertTrue(allowed.contains(box), "\(name) seed \(seed) rect \(rect) box \(box)")
                }
            }
        }
    }

    func testHighlightCoversTheLineWithOvershoot() {
        for rect in sampleRects {
            let box = MarkerInk.highlightPath(for: rect, seed: 7).boundingRect
            XCTAssertLessThan(box.minY, rect.minY, "band reaches above the line")
            XCTAssertGreaterThan(box.maxY, rect.maxY, "band reaches below the line")
            XCTAssertGreaterThan(box.height, rect.height * 1.08)
            XCTAssertLessThan(box.height, rect.height * 1.3)
        }
    }

    func testStrikethroughSitsMidLineAndUnderlinesSitLow() {
        for rect in sampleRects {
            for seed in UInt64(1)...UInt64(10) {
                let strike = MarkerInk.strikethroughPath(for: rect, seed: seed).boundingRect
                let under = MarkerInk.underlinePath(for: rect, seed: seed).boundingRect
                let squiggle = MarkerInk.squigglePath(for: rect, seed: seed).boundingRect
                let strikeMid = (strike.midY - rect.minY) / rect.height
                let underMid = (under.midY - rect.minY) / rect.height
                let squiggleMid = (squiggle.midY - rect.minY) / rect.height
                XCTAssertTrue((0.45...0.62).contains(strikeMid), "strike at \(strikeMid)")
                XCTAssertTrue((0.85...1.05).contains(underMid), "underline at \(underMid)")
                XCTAssertTrue((0.8...1.08).contains(squiggleMid), "squiggle at \(squiggleMid)")
                XCTAssertGreaterThan(squiggle.height, rect.height * 0.15, "squiggle has visible waves")
                XCTAssertLessThan(under.height, rect.height * 0.25 + 2, "underline is a thin line")
            }
        }
    }

    func testPenWidthStaysFine() {
        XCTAssertEqual(MarkerInk.penWidth(forLineHeight: 4), 1.3, accuracy: 0.001)
        XCTAssertEqual(MarkerInk.penWidth(forLineHeight: 8), 1.3, accuracy: 0.001)
        XCTAssertEqual(MarkerInk.penWidth(forLineHeight: 40), 1.7, accuracy: 0.001)
        XCTAssertEqual(MarkerInk.penWidth(forLineHeight: 200), 1.7, accuracy: 0.001)
    }

    func testDegenerateRectsProduceEmptyPaths() {
        for (_, make) in generators {
            XCTAssertTrue(make(.zero, 1).isEmpty)
            XCTAssertTrue(make(CGRect(x: 10, y: 10, width: 100, height: 0), 1).isEmpty)
        }
    }

    func testInkPalette() {
        for color in HighlightColor.allCases {
            for style in HighlightStyle.allCases {
                for dark in [false, true] {
                    let ink = MarkerInk.ink(for: color, style: style, darkPaper: dark)
                    XCTAssertTrue((0.1...1).contains(ink.opacity))
                }
                // Pen ink is darker than highlighter pigment on light paper.
                let pen = MarkerInk.inkRGBA(for: color, style: .underline, darkPaper: false)
                let marker = MarkerInk.inkRGBA(for: color, style: .highlight, darkPaper: false)
                XCTAssertLessThan(pen.luminance, marker.luminance, color.rawValue)
            }
        }
    }

    // MARK: Selection handles

    private let block = CGRect(x: 50, y: 100, width: 500, height: 800)

    func testHandlePointsSingleLine() throws {
        let line = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.025)
        let points = try XCTUnwrap(TextSelectionOverlay.handlePoints(lineRects: [line], textBlock: block))
        XCTAssertEqual(points.start.x, 100, accuracy: 0.001)
        XCTAssertEqual(points.start.y, 180, accuracy: 0.001)
        XCTAssertEqual(points.end.x, 300, accuracy: 0.001)
        XCTAssertEqual(points.end.y, 200, accuracy: 0.001)
        XCTAssertNil(TextSelectionOverlay.handlePoints(lineRects: [], textBlock: block))
    }

    func testHandlePointsMultiLine() throws {
        let lines = [
            CGRect(x: 0.3, y: 0.1, width: 0.6, height: 0.025),
            CGRect(x: 0.0, y: 0.13, width: 0.9, height: 0.025),
            CGRect(x: 0.0, y: 0.16, width: 0.2, height: 0.025)
        ]
        let points = try XCTUnwrap(TextSelectionOverlay.handlePoints(lineRects: lines, textBlock: block))
        XCTAssertEqual(points.start, CGPoint(x: 200, y: 180))
        XCTAssertEqual(points.end.x, 150, accuracy: 0.001)
        XCTAssertEqual(points.end.y, 248, accuracy: 0.001)

        XCTAssertEqual(TextSelectionOverlay.handle(at: CGPoint(x: 200, y: 175), lineRects: lines, textBlock: block), .start)
        XCTAssertEqual(TextSelectionOverlay.handle(at: CGPoint(x: 150, y: 253), lineRects: lines, textBlock: block), .end)
        // Along the bar counts too.
        XCTAssertEqual(TextSelectionOverlay.handle(at: CGPoint(x: 203, y: 190), lineRects: lines, textBlock: block), .start)
        XCTAssertNil(TextSelectionOverlay.handle(at: CGPoint(x: 400, y: 600), lineRects: lines, textBlock: block))
        XCTAssertNil(TextSelectionOverlay.handle(at: CGPoint(x: 350, y: 214), lineRects: lines, textBlock: block))
    }

    func testHandleHitRadiusIsGenerous() {
        XCTAssertGreaterThanOrEqual(TextSelectionOverlay.hitRadius, 22)
        let line = CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.025)
        // Start knob centre is (100, 176); 18pt left of it is outside the
        // 5pt knob but well inside the hit radius.
        XCTAssertEqual(TextSelectionOverlay.handle(at: CGPoint(x: 82, y: 176), lineRects: [line], textBlock: block), .start)
        // End knob centre is (300, 204).
        XCTAssertEqual(TextSelectionOverlay.handle(at: CGPoint(x: 300, y: 224), lineRects: [line], textBlock: block), .end)
        XCTAssertNil(TextSelectionOverlay.handle(at: CGPoint(x: 100, y: 130), lineRects: [line], textBlock: block))
        XCTAssertNil(TextSelectionOverlay.handle(at: CGPoint(x: 0, y: 0), lineRects: [line], textBlock: block))
        XCTAssertNil(TextSelectionOverlay.handle(at: .zero, lineRects: [], textBlock: block))
    }

    func testShortSelectionPicksNearestHandle() {
        let word = CGRect(x: 0.1, y: 0.1, width: 0.04, height: 0.025) // 20pt wide
        XCTAssertEqual(TextSelectionOverlay.handle(at: CGPoint(x: 101, y: 178), lineRects: [word], textBlock: block), .start)
        XCTAssertEqual(TextSelectionOverlay.handle(at: CGPoint(x: 119, y: 202), lineRects: [word], textBlock: block), .end)
    }

    // MARK: Visual proofs

    @MainActor
    func testRenderVisualProofs() throws {
        let folder = URL(fileURLWithPath: "/private/tmp/pb-agent-b-proofs", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            let renderer = ImageRenderer(content: MarkerInkProofSheet(darkPaper: dark))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage, "proof did not render")
            let data = try XCTUnwrap(image.pngData())
            try data.write(to: folder.appendingPathComponent(dark ? "marker-ink-dark.png" : "marker-ink-light.png"))
            XCTAssertEqual(image.size, CGSize(width: 600, height: 400))
        }
    }
}

/// A 600 x 400 sample page: each style in each colour, plus a selection.
private struct MarkerInkProofSheet: View {
    let darkPaper: Bool

    static let size = CGSize(width: 600, height: 400)
    static let fontSize: CGFloat = 14
    static let samples = [
        "the river ran quietly", "under a pale moon", "she kept the letter",
        "far from the harbour", "and never looked back"
    ]

    private struct Line {
        let text: String
        let rect: CGRect   // view points
    }

    private var font: UIFont { UIFont(name: "Georgia", size: Self.fontSize) ?? .systemFont(ofSize: Self.fontSize) }

    private func line(_ text: String, x: CGFloat, y: CGFloat) -> Line {
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return Line(text: text, rect: CGRect(x: x, y: y, width: ceil(width), height: ceil(font.lineHeight)))
    }

    private func unit(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX / Self.size.width, y: rect.minY / Self.size.height,
               width: rect.width / Self.size.width, height: rect.height / Self.size.height)
    }

    var body: some View {
        var lines: [Line] = []
        var marks: [PageMark] = []
        let styles = HighlightStyle.allCases
        let colors = HighlightColor.allCases
        // Two columns of ten rows: styles down, colours across rows.
        var row = 0
        for style in styles {
            for color in colors {
                let column = row / 10
                let x: CGFloat = 24 + CGFloat(column) * 296
                let y: CGFloat = 18 + CGFloat(row % 10) * 28
                let sample = Self.samples[(row + styles.firstIndex(of: style)!) % Self.samples.count]
                let l = line(sample, x: x, y: y)
                lines.append(l)
                var idBytes = [UInt8](repeating: 0, count: 16)
                idBytes[0] = UInt8(row)
                idBytes[15] = 0xAB
                let id = UUID(uuid: (idBytes[0], 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, idBytes[15]))
                marks.append(PageMark(id: id, style: style, color: color, lineRects: [unit(l.rect)]))
                row += 1
            }
        }
        // A two-line paragraph: a multi-line highlight on line one, a selection
        // across both lines starting mid-way through the second phrase.
        let p1 = line("It was the kind of evening that asks nothing of you,", x: 24, y: 312)
        let p2 = line("only that you sit by the window and read until dark.", x: 24, y: 340)
        lines += [p1, p2]
        let half = line("It was the kind of evening ", x: 24, y: 312)
        marks.append(PageMark(id: UUID(uuid: (9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9)), style: .highlight, color: .butter,
                              lineRects: [unit(CGRect(x: half.rect.maxX, y: p1.rect.minY, width: p1.rect.maxX - half.rect.maxX, height: p1.rect.height)),
                                          unit(CGRect(x: p2.rect.minX, y: p2.rect.minY, width: 120, height: p2.rect.height))]))
        let only = line("only that you sit by the ", x: 24, y: 340)
        let selection = [unit(CGRect(x: only.rect.maxX, y: p2.rect.minY, width: p2.rect.maxX - only.rect.maxX, height: p2.rect.height))]
        let blockRect = CGRect(origin: .zero, size: Self.size)

        let paper = darkPaper ? Color(red: 0x1C / 255, green: 0x1A / 255, blue: 0x17 / 255) : Color(red: 0.985, green: 0.975, blue: 0.955)
        let inkColor = darkPaper ? Color(red: 0.86, green: 0.83, blue: 0.77) : Color(red: 0.08, green: 0.07, blue: 0.06)

        return ZStack(alignment: .topLeading) {
            paper
            ForEach(lines.indices, id: \.self) { index in
                Text(lines[index].text)
                    .font(.custom(font.fontName, size: Self.fontSize))
                    .foregroundStyle(inkColor)
                    .fixedSize()
                    .frame(width: lines[index].rect.width + 8, height: lines[index].rect.height, alignment: .leading)
                    .offset(x: lines[index].rect.minX, y: lines[index].rect.minY)
            }
            MarkerInkView(marks: marks, textBlock: blockRect, emphasizedMarkID: nil, isDarkPaper: darkPaper)
            TextSelectionOverlay(lineRects: selection, textBlock: blockRect, tint: .blue)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .compositingGroup()
        .environment(\.colorScheme, darkPaper ? .dark : .light)
    }
}
