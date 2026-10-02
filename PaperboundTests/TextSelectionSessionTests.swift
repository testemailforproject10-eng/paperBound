//
//  TextSelectionSessionTests.swift
//  PaperboundTests
//
//  The selection rules and the reader's highlight actions, against the real
//  sample book's text layer.
//

import PDFKit
import SwiftData
import XCTest
@testable import Paperbound

@MainActor
final class TextSelectionSessionTests: XCTestCase {

    private var file: URL!
    private var document: PDFDocument!

    override func setUp() async throws {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("selection-\(UUID()).pdf")
        try SampleLibrary.write(to: file)
        document = try XCTUnwrap(PDFDocument(url: file))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: file)
    }

    private func selector(page index: Int = 0) throws -> PageTextSelector {
        try XCTUnwrap(PageTextSelector(page: try XCTUnwrap(document.page(at: index)), pageIndex: index,
                                       appliesRotation: false))
    }

    /// Centre of the first glyph of the first occurrence of `word`, in unit space.
    private func point(of word: String, page index: Int = 0) throws -> CGPoint {
        let page = try XCTUnwrap(document.page(at: index))
        let text = try XCTUnwrap(page.string) as NSString
        let range = text.range(of: word)
        XCTAssertNotEqual(range.location, NSNotFound, "\(word) is not on page \(index)")
        // characterBounds(at:) drifts after line breaks on this PDF; a
        // one-character selection lands on the right glyph.
        let middle = NSRange(location: range.location + range.length / 2, length: 1)
        let bounds = try XCTUnwrap(page.selection(for: middle)).bounds(for: page)
        return try selector(page: index).unitPoint(forPagePoint: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    // MARK: - Long press

    func testLongPressSelectsTheWordAndShowsTheLoupe() throws {
        let session = TextSelectionSession()
        let selector = try selector()
        let target = try point(of: "remembers")
        XCTAssertTrue(session.beginLongPress(on: selector, at: target))
        XCTAssertEqual(session.selection?.text, "remembers")
        XCTAssertNotNil(session.loupe)
        XCTAssertTrue(session.isActive)
        session.endDrag()
        XCTAssertNil(session.loupe)
        XCTAssertEqual(session.selection?.text, "remembers", "Lifting the finger keeps the selection.")
    }

    func testDraggingAfterLongPressExtendsByWholeWordsInBothDirections() throws {
        let session = TextSelectionSession()
        let selector = try selector()
        session.beginLongPress(on: selector, at: try point(of: "sheet"))
        session.continueLongPress(on: selector, to: try point(of: "remembers"))
        XCTAssertEqual(session.selection?.text, "sheet remembers")
        // Back past the first word: the first word stays selected.
        session.continueLongPress(on: selector, to: try point(of: "What"))
        let text = try XCTUnwrap(session.selection?.text)
        XCTAssertTrue(text.hasPrefix("What"), text)
        XCTAssertTrue(text.hasSuffix("sheet"), text)
    }

    // MARK: - Handles

    func testDraggingTheEndHandleMovesOnlyTheEnd() throws {
        let session = TextSelectionSession()
        let selector = try selector()
        session.beginLongPress(on: selector, at: try point(of: "What"))
        session.endDrag()
        let start = try XCTUnwrap(session.selection?.range.location)
        session.beginHandleDrag(.end)
        session.dragHandle(on: selector, to: try point(of: "remembers"))
        session.endDrag()
        XCTAssertEqual(session.selection?.range.location, start)
        XCTAssertTrue(try XCTUnwrap(session.selection?.text).hasPrefix("What"))
        XCTAssertGreaterThan(try XCTUnwrap(session.selection?.text).count, "What".count)
    }

    func testDraggingAHandlePastTheOtherSwapsInsteadOfInverting() throws {
        let session = TextSelectionSession()
        let selector = try selector()
        session.beginLongPress(on: selector, at: try point(of: "remembers"))
        session.endDrag()
        session.beginHandleDrag(.start)
        session.dragHandle(on: selector, to: try point(of: "sheet"))
        let before = try XCTUnwrap(session.selection)
        XCTAssertGreaterThan(before.range.length, 0)
        XCTAssertEqual(session.activeHandle, .start)
        // Now drag the start handle beyond the original end.
        session.dragHandle(on: selector, to: try point(of: "page"))
        let after = try XCTUnwrap(session.selection)
        XCTAssertGreaterThan(after.range.length, 0)
        XCTAssertEqual(session.activeHandle, .end, "The moving end became the end.")
    }

    // MARK: - Taps

    func testTappingTheSelectionGrowsItToTheSentence() throws {
        let session = TextSelectionSession()
        let selector = try selector()
        session.beginLongPress(on: selector, at: try point(of: "remembers"))
        session.endDrag()
        let word = try XCTUnwrap(session.selection)
        session.expandToSentence(on: selector)
        let sentence = try XCTUnwrap(session.selection)
        XCTAssertGreaterThan(sentence.range.length, word.range.length)
        XCTAssertTrue(NSLocationInRange(word.range.location, sentence.range))
    }

    func testEditingAMarkClearsTheSelectionAndClearingEndsBoth() throws {
        let session = TextSelectionSession()
        session.beginLongPress(on: try selector(), at: try point(of: "remembers"))
        let id = UUID()
        session.edit(markID: id, onPage: 0)
        XCTAssertNil(session.selection)
        XCTAssertEqual(session.editingMarkID, id)
        XCTAssertTrue(session.isActive)
        session.clear()
        XCTAssertFalse(session.isActive)
    }

    // MARK: - Reader actions

    func testAddingRestylingAndDeletingAHighlight() async throws {
        let container = try ModelContainer(for: Book.self, Bookmark.self, Highlight.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = LibraryStore.unavailable()
        let name = "highlights-\(UUID()).pdf"
        let book = Book(title: "Highlights", fileName: name, format: .pdf, contentFingerprint: name)
        let bookFile = store.fileURL(for: book)
        try SampleLibrary.write(to: bookFile)
        defer { try? FileManager.default.removeItem(at: bookFile) }
        container.mainContext.insert(book)
        let suite = "highlights-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let model = ReaderViewModel(book: book, settings: settings, store: store, context: container.mainContext)
        await model.load()
        defer { model.unload() }

        let selector = try XCTUnwrap(model.textSelector(forPage: 0))
        let selection = try XCTUnwrap(selector.wordSelection(at: try point(of: "remembers")))
        let created = try XCTUnwrap(model.addHighlight(selection, style: .squiggly, color: .sky))
        XCTAssertEqual(created.quotedText, "remembers")
        XCTAssertEqual(created.characterRange, selection.range)
        XCTAssertEqual(model.marks(onPage: 0).map(\.style), [.squiggly])
        XCTAssertTrue(model.marks(onPage: 1).isEmpty)
        XCTAssertEqual(settings.lastHighlightStyle, .squiggly, "The last style is remembered.")
        XCTAssertEqual(settings.lastHighlightColor, .sky)

        model.restyleHighlight(created.id, style: .underline)
        XCTAssertEqual(model.marks(onPage: 0).first?.style, .underline)
        XCTAssertEqual(model.marks(onPage: 0).first?.color, .sky)
        model.restyleHighlight(created.id, color: .rose)
        XCTAssertEqual(model.marks(onPage: 0).first?.color, .rose)

        model.deleteHighlight(created.id)
        XCTAssertTrue(model.marks(onPage: 0).isEmpty)

        // A selection finds every mark under it, and only those.
        let first = try XCTUnwrap(model.addHighlight(selection, style: .highlight, color: .butter))
        let strike = try XCTUnwrap(model.addHighlight(selection, style: .strikethrough, color: .butter))
        let elsewhere = try XCTUnwrap(selector.wordSelection(at: try point(of: "surface")))
        let other = try XCTUnwrap(model.addHighlight(elsewhere, style: .underline, color: .sky))
        XCTAssertEqual(model.highlights(overlapping: selection).map(\.id), [first.id, strike.id])
        XCTAssertEqual(model.highlights(overlapping: elsewhere).map(\.id), [other.id])

        let pageLength = (try XCTUnwrap(document.page(at: 0)?.string) as NSString).length
        let wholePage = PageTextSelection(pageIndex: 0, range: NSRange(location: 0, length: pageLength),
                                          text: "", lineRects: [])
        XCTAssertEqual(Set(model.highlights(overlapping: wholePage).map(\.id)), [first.id, strike.id, other.id])
        let otherPage = PageTextSelection(pageIndex: 1, range: wholePage.range, text: "", lineRects: [])
        XCTAssertTrue(model.highlights(overlapping: otherPage).isEmpty)

        model.deleteHighlights(model.highlights(overlapping: wholePage).map(\.id))
        XCTAssertTrue(model.marks(onPage: 0).isEmpty, "Clearing a whole-page selection removes every mark on it.")
    }

    func testHighlightsWrittenBeforeStylesReadAsHighlighter() {
        let legacy = Highlight(quotedText: "x", location: .pdfPage(index: 0, yOffset: 0),
                               normalizedRects: [], orderKey: 0)
        legacy.styleRaw = "something-unknown"
        XCTAssertEqual(legacy.style, .highlight)
        XCTAssertNil(Highlight(quotedText: "x", location: .start, normalizedRects: [], orderKey: 0).characterRange)
    }
}
