//
//  PageTextSelectorTests.swift
//  PaperboundTests
//
//  Checks the text selection engine against the generated sample book, whose
//  first page has a centred two-line title, a subtitle, a heading and justified
//  body paragraphs: enough layout variety to exercise line grouping, margins
//  and paragraph detection with known text.
//

import PDFKit
import XCTest
@testable import Paperbound

@MainActor final class PageTextSelectorTests: XCTestCase {

    private var fileURL: URL!
    private var document: PDFDocument!
    private var page: PDFPage!
    private var selector: PageTextSelector!

    override func setUp() async throws {
        try await super.setUp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-text-selector-\(UUID().uuidString).pdf")
        try SampleLibrary.write(to: url)
        fileURL = url
        document = try XCTUnwrap(PDFDocument(url: url))
        page = try XCTUnwrap(document.page(at: 0))
        selector = try XCTUnwrap(PageTextSelector(page: page, pageIndex: 0))
    }

    override func tearDown() async throws {
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        selector = nil
        page = nil
        document = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func range(of needle: String) throws -> NSRange {
        let found = (selector.pageText as NSString).range(of: needle)
        XCTAssertNotEqual(found.location, NSNotFound, "sample text should contain \(needle)")
        guard found.location != NSNotFound else { throw XCTSkip("missing \(needle)") }
        return found
    }

    /// The unit-space box PDFKit itself reports for a range, as ground truth.
    private func unitBounds(of range: NSRange) throws -> CGRect {
        let selection = try XCTUnwrap(page.selection(for: range))
        return selector.unitRect(forPageRect: selection.bounds(for: page))
    }

    private func center(_ rect: CGRect) -> CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    // MARK: - Coordinates

    func testUnitAndPagePointsRoundTrip() {
        let crop = page.bounds(for: .cropBox)
        let topLeft = selector.pagePoint(forUnitPoint: .zero)
        XCTAssertEqual(topLeft.x, crop.minX, accuracy: 0.0001)
        XCTAssertEqual(topLeft.y, crop.maxY, accuracy: 0.0001)

        let unitOrigin = selector.unitPoint(forPagePoint: CGPoint(x: crop.minX, y: crop.maxY))
        XCTAssertEqual(unitOrigin.x, 0, accuracy: 0.0001)
        XCTAssertEqual(unitOrigin.y, 0, accuracy: 0.0001)

        let bottomRight = selector.unitPoint(forPagePoint: CGPoint(x: crop.maxX, y: crop.minY))
        XCTAssertEqual(bottomRight.x, 1, accuracy: 0.0001)
        XCTAssertEqual(bottomRight.y, 1, accuracy: 0.0001)

        for point in [CGPoint(x: 0.13, y: 0.71), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.92, y: 0.04)] {
            let back = selector.unitPoint(forPagePoint: selector.pagePoint(forUnitPoint: point))
            XCTAssertEqual(back.x, point.x, accuracy: 0.0001)
            XCTAssertEqual(back.y, point.y, accuracy: 0.0001)
        }

        let pageRect = CGRect(x: crop.minX + 43.2, y: crop.minY + 64.8, width: 86.4, height: 129.6)
        let unit = selector.unitRect(forPageRect: pageRect)
        XCTAssertEqual(unit.minX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(unit.width, 0.2, accuracy: 0.0001)
        XCTAssertEqual(unit.maxY, 0.9, accuracy: 0.0001)
        XCTAssertEqual(unit.height, 0.2, accuracy: 0.0001)
    }

    /// Rotated pages map to the page as displayed. PDFKit's own
    /// `transform(for:)` (crop box to rotated, y-up box space) is the reference.
    func testRotatedPagesMapThroughTheDisplayRotation() throws {
        let crop = page.bounds(for: .cropBox)
        let samples = [CGPoint(x: crop.minX + 30, y: crop.minY + 500), CGPoint(x: crop.maxX - 10, y: crop.minY + 12)]
        for degrees in [90, 180, 270] {
            page.rotation = degrees
            defer { page.rotation = 0 }
            let rotated = try XCTUnwrap(PageTextSelector(page: page, pageIndex: 0))
            XCTAssertEqual(rotated.rotation, degrees)
            let transform = page.transform(for: .cropBox)
            let displayed = degrees == 180 ? crop.size : CGSize(width: crop.height, height: crop.width)
            for point in samples {
                let reference = point.applying(transform)
                let expected = CGPoint(x: reference.x / displayed.width, y: 1 - reference.y / displayed.height)
                let unit = rotated.unitPoint(forPagePoint: point)
                XCTAssertEqual(unit.x, expected.x, accuracy: 0.001, "rotation \(degrees)")
                XCTAssertEqual(unit.y, expected.y, accuracy: 0.001, "rotation \(degrees)")
                let back = rotated.pagePoint(forUnitPoint: unit)
                XCTAssertEqual(back.x, point.x, accuracy: 0.001)
                XCTAssertEqual(back.y, point.y, accuracy: 0.001)
            }

            // Selection still works in display space.
            let word = try range(of: "fibres")
            let target = center(rotated.unitRect(forPageRect: try XCTUnwrap(page.selection(for: word)).bounds(for: page)))
            let wordSelection = try XCTUnwrap(rotated.wordSelection(at: target))
            XCTAssertEqual(wordSelection.text, "fibres", "rotation \(degrees)")
            XCTAssertEqual(wordSelection.lineRects.count, 1)
            XCTAssertTrue(wordSelection.lineRects[0].insetBy(dx: -0.0001, dy: -0.0001).contains(target))
            let start = try range(of: "compressed mat")
            let end = try range(of: "direction it was")
            XCTAssertEqual(rotated.selection(from: start.location, to: NSMaxRange(end) - 1, snapToWords: true)?.lineRects.count, 3)

            let unrotated = try XCTUnwrap(PageTextSelector(page: page, pageIndex: 0, appliesRotation: false))
            XCTAssertEqual(unrotated.rotation, 0)
        }
    }

    // MARK: - Words

    func testWordSelectionAtGlyphCentreReturnsThatWordWithoutPunctuation() throws {
        // "fibres," is followed by a comma in the sample text.
        let word = try range(of: "fibres")
        let point = center(try unitBounds(of: word))

        let selection = try XCTUnwrap(selector.wordSelection(at: point))
        XCTAssertEqual(selection.text, "fibres")
        XCTAssertEqual(selection.range, word)
        XCTAssertEqual(selection.pageIndex, 0)
        XCTAssertEqual(selection.lineRects.count, 1)
        XCTAssertTrue(selection.lineRects[0].contains(point))
    }

    func testWordSelectionOnPunctuationPicksTheAdjacentWord() throws {
        let comma = try range(of: "fibres,")
        let commaIndex = NSMaxRange(comma) - 1
        let point = center(try unitBounds(of: NSRange(location: commaIndex, length: 1)))
        XCTAssertEqual(selector.characterIndex(nearestTo: point), commaIndex)
        XCTAssertEqual(selector.wordSelection(at: point)?.text, "fibres")
    }

    // MARK: - Nearest character

    func testLeftMarginResolvesToTheLinesFirstCharacter() throws {
        let lineStart = try range(of: "one laid down wet")
        let firstGlyph = try unitBounds(of: NSRange(location: lineStart.location, length: 1))
        let margin = CGPoint(x: 0.02, y: firstGlyph.midY)
        XCTAssertLessThan(margin.x, firstGlyph.minX)
        XCTAssertEqual(selector.characterIndex(nearestTo: margin), lineStart.location)

        // The right margin of the same line resolves to its last glyph.
        let lineEnd = try range(of: "under pressure, each one still")
        let rightMargin = CGPoint(x: 0.98, y: firstGlyph.midY)
        XCTAssertEqual(selector.characterIndex(nearestTo: rightMargin), NSMaxRange(lineEnd) - 1)
    }

    func testPointBelowTheLastLineResolvesToTheLastLine() throws {
        let text = selector.pageText as NSString
        var lastGlyph = text.length - 1
        while lastGlyph > 0, selector.unitRect(forCharacterAt: lastGlyph) == nil { lastGlyph -= 1 }
        let lastRect = try XCTUnwrap(selector.unitRect(forCharacterAt: lastGlyph))

        for x in [0.05, 0.5, 0.95] {
            let index = try XCTUnwrap(selector.characterIndex(nearestTo: CGPoint(x: x, y: 0.995)))
            let rect = try XCTUnwrap(selector.unitRect(forCharacterAt: index))
            XCTAssertEqual(rect.midY, lastRect.midY, accuracy: 0.0001, "x \(x)")
        }
        // Above everything resolves to the top line.
        let top = try XCTUnwrap(selector.characterIndex(nearestTo: CGPoint(x: 0.01, y: 0.001)))
        XCTAssertEqual(top, 0)
    }

    func testEveryGlyphCentreResolvesToItself() throws {
        let text = selector.pageText as NSString
        for index in 0..<text.length {
            guard let rect = selector.unitRect(forCharacterAt: index) else { continue }
            XCTAssertEqual(selector.characterIndex(nearestTo: center(rect)), index, "character \(index)")
        }
    }

    func testNearestCharacterLookupIsFastEnoughForDragging() {
        var generator = SystemRandomNumberGenerator()
        let points = (0..<20_000).map { _ in
            CGPoint(x: CGFloat.random(in: 0...1, using: &generator), y: CGFloat.random(in: 0...1, using: &generator))
        }
        let start = ProcessInfo.processInfo.systemUptime
        var found = 0
        for point in points where selector.characterIndex(nearestTo: point) != nil { found += 1 }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(found, points.count)
        // Far below one frame per lookup even on a slow simulator.
        XCTAssertLessThan(elapsed / Double(points.count), 0.000_2)
    }

    // MARK: - Ranges

    func testSelectionAcrossThreeLinesGivesThreeOrderedRects() throws {
        let start = try range(of: "compressed mat of fibres")
        let end = try range(of: "direction it was travelling")
        let selection = try XCTUnwrap(selector.selection(from: start.location, to: NSMaxRange(end) - 1, snapToWords: false))

        XCTAssertEqual(selection.lineRects.count, 3)
        for index in 1..<selection.lineRects.count {
            let upper = selection.lineRects[index - 1]
            let lower = selection.lineRects[index]
            XCTAssertLessThanOrEqual(upper.maxY, lower.minY + 0.000_001)
            XCTAssertFalse(upper.intersects(lower.insetBy(dx: 0, dy: 0.000_01)))
        }
        // The first rect starts at "compressed", not at the line's left edge.
        let firstGlyph = try unitBounds(of: NSRange(location: start.location, length: 1))
        XCTAssertEqual(selection.lineRects[0].minX, firstGlyph.minX, accuracy: 0.002)
        // Consistent height: every body line rect is the same height.
        let heights = selection.lineRects.map(\.height)
        XCTAssertEqual(heights.max()! - heights.min()!, 0, accuracy: 0.002)

        XCTAssertTrue(selection.text.hasPrefix("compressed mat of fibres, each one laid down"))
        XCTAssertTrue(selection.text.hasSuffix("holding the direction it was travelling"))
        XCTAssertFalse(selection.text.contains("\n"), "wrapped lines inside a paragraph copy as spaces")
        XCTAssertFalse(selection.text.contains("  "))

        let reversed = selector.selection(from: NSMaxRange(end) - 1, to: start.location, snapToWords: false)
        XCTAssertEqual(reversed, selection)
    }

    func testSnapToWordsExpandsMidWordIndicesToWholeWords() throws {
        let compressed = try range(of: "compressed")
        let fibres = try range(of: "fibres")
        let snapped = try XCTUnwrap(selector.selection(from: fibres.location + 2, to: compressed.location + 4, snapToWords: true))
        XCTAssertEqual(snapped.text, "compressed mat of fibres")
        XCTAssertEqual(snapped.range, NSRange(location: compressed.location, length: NSMaxRange(fibres) - compressed.location))

        let raw = try XCTUnwrap(selector.selection(from: compressed.location + 4, to: fibres.location + 2, snapToWords: false))
        XCTAssertEqual(raw.text, "ressed mat of fib")
    }

    func testTrailingWhitespaceAndNewlinesAreTrimmed() throws {
        let line = try range(of: "under pressure, each one still")
        // Extend over the line break and the next line's first character's preceding newline.
        let selection = try XCTUnwrap(selector.selection(for: NSRange(location: line.location - 1, length: line.length + 2)))
        XCTAssertEqual(selection.text, "under pressure, each one still")
        XCTAssertEqual(selection.range, line)
        XCTAssertEqual(selection.lineRects.count, 1)
    }

    func testSentenceSelectionReturnsTheWholeWrappedSentence() throws {
        let word = try range(of: "slowly")
        let selection = try XCTUnwrap(selector.sentenceSelection(containing: word))
        XCTAssertEqual(selection.text, "Tear a page slowly and it will separate along that grain; tear it quickly and it will not.")
        XCTAssertEqual(selection.lineRects.count, 2)

        // A heading is its own sentence, not glued to the paragraph after it.
        let heading = try range(of: "sheet remembers")
        let headingSentence = try XCTUnwrap(selector.sentenceSelection(containing: heading))
        XCTAssertFalse(headingSentence.text.contains("A page is not"))
        XCTAssertTrue(headingSentence.text.hasSuffix("What a sheet remembers"))
    }

    func testParagraphBreaksSurviveInCopiedText() throws {
        let start = try range(of: "betrays a forgery.")
        let end = try range(of: "This matters")
        let selection = try XCTUnwrap(selector.selection(for: NSRange(location: start.location, length: NSMaxRange(end) - start.location)))
        XCTAssertEqual(selection.text, "betrays a forgery.\nThis matters")
    }

    func testSelectionForRangeReproducesTheSelection() throws {
        let start = try range(of: "Tear a page")
        let end = try range(of: "visible from")
        let original = try XCTUnwrap(selector.selection(from: start.location, to: NSMaxRange(end) - 1, snapToWords: true))
        XCTAssertEqual(selector.selection(for: original.range), original)

        // A fresh selector over a fresh document gives the same result, which
        // is what redrawing a saved highlight after relaunch relies on.
        let reopened = try XCTUnwrap(PDFDocument(url: fileURL)?.page(at: 0))
        let again = try XCTUnwrap(PageTextSelector(page: reopened, pageIndex: 0))
        XCTAssertEqual(again.selection(for: original.range), original)
    }

    func testOutOfRangeAndWhitespaceOnlyRangesAreHandled() throws {
        let length = (selector.pageText as NSString).length
        XCTAssertNil(selector.selection(for: NSRange(location: length + 10, length: 5)))
        XCTAssertNil(selector.selection(for: NSRange(location: NSNotFound, length: 0)))
        let space = (selector.pageText as NSString).range(of: " ")
        XCTAssertNil(selector.selection(for: space))
        XCTAssertNotNil(selector.selection(from: -50, to: length + 50, snapToWords: true))
    }

    // MARK: - Pages without text

    func testInitReturnsNilForAPageWithoutText() {
        XCTAssertNil(PageTextSelector(page: PDFPage(), pageIndex: 3))
    }

    func testFigurePageWithLabelsStillSelects() throws {
        let figurePage = try XCTUnwrap(document.page(at: document.pageCount - 1))
        let figure = try XCTUnwrap(PageTextSelector(page: figurePage, pageIndex: document.pageCount - 1))
        let caption = (figure.pageText as NSString).range(of: "signature")
        XCTAssertNotEqual(caption.location, NSNotFound)
        let bounds = figure.unitRect(forPageRect: try XCTUnwrap(figurePage.selection(for: caption)).bounds(for: figurePage))
        let selection = try XCTUnwrap(figure.wordSelection(at: center(bounds)))
        XCTAssertEqual(selection.text, "signature")
        XCTAssertEqual(selection.pageIndex, document.pageCount - 1)
    }
}
