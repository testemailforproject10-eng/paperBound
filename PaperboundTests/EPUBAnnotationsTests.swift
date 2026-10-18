//
//  EPUBAnnotationsTests.swift
//  PaperboundTests
//
//  EPUB reading tools: quote anchoring and overlap, highlight storage and the
//  Locator round-trip, the action bar's rules on an EPUB selection, decoration
//  mapping, search-result navigation, bookmark ordering and read-aloud text.
//  The book is the Sample.epub fixture (Tools/make-epub-fixtures.sh).
//

import ReadiumNavigator
import ReadiumShared
import SwiftData
import XCTest
@testable import Paperbound

@MainActor
final class EPUBAnnotationsTests: XCTestCase {

    // MARK: - Fixtures

    private func sampleURL() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Sample", withExtension: "epub"))
    }

    private func openEngine() async throws -> EPUBReadingEngine {
        let engine = try EPUBReadingEngine(documentID: UUID(), fileURL: try sampleURL(), initialLocation: nil)
        try await engine.open()
        return engine
    }

    private struct Harness {
        let container: ModelContainer
        let book: Book
        let settings: AppSettings
        let model: ReaderViewModel
        let cleanup: () -> Void
    }

    /// A real reader model on the sample EPUB, with an in-memory store.
    private func makeReader() async throws -> Harness {
        let container = try ModelContainer(for: Book.self, Bookmark.self, Highlight.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = LibraryStore.unavailable()
        let name = "annotations-\(UUID()).epub"
        let book = Book(title: "Sample", fileName: name, format: .epub, contentFingerprint: name)
        let file = store.fileURL(for: book)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try sampleURL(), to: file)
        container.mainContext.insert(book)
        let suite = "annotations-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        let model = ReaderViewModel(book: book, settings: settings, store: store, context: container.mainContext)
        await model.load()
        XCTAssertNil(model.loadError)
        XCTAssertNotNil(model.epubEngine)
        return Harness(container: container, book: book, settings: settings, model: model) {
            model.unload()
            try? FileManager.default.removeItem(at: file)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private static let chapter1 = "OEBPS/chapter1.xhtml"
    private static let chapter3 = "OEBPS/chapter3.xhtml"

    /// A selection locator as Readium builds one: the visible page's href and
    /// progression, plus the quote.
    private func selectionLocator(
        _ highlight: String, before: String? = nil, after: String? = nil,
        href: String = chapter1, progression: Double = 0
    ) throws -> Locator {
        Locator(
            href: try XCTUnwrap(AnyURL(string: href)),
            mediaType: .xhtml,
            locations: .init(progression: progression, totalProgression: 0.1, position: 2,
                             otherLocations: ["cssSelector": .string("#chapter-1 > p:nth-child(9)")]),
            text: .init(after: after, before: before, highlight: highlight)
        )
    }

    private func chapterText(_ href: String, engine: EPUBReadingEngine) async throws -> String {
        let publication = try XCTUnwrap(engine.publication)
        let resource = try XCTUnwrap(publication.get(try XCTUnwrap(AnyURL(string: href))))
        guard case let .success(data) = await resource.read() else {
            XCTFail("Could not read \(href)")
            return ""
        }
        return EPUBTextAnchor.canonicalText(fromHTML: String(decoding: data, as: UTF8.self))
    }

    // MARK: - Canonical text and anchoring

    func testCanonicalTextIsTheBodyTextWithoutWhitespace() {
        let html = """
        <?xml version="1.0"?><html><head><title>Not this</title><style>p{}</style></head>
        <body class="x">
          <h1>Title</h1>
          <!-- a comment -->
          <p>Fish &amp; chips&#160;for <em>two</em>, &#x2014; &lsquo;please&rsquo;.</p>
        </body></html>
        """
        XCTAssertEqual(EPUBTextAnchor.canonicalText(fromHTML: html), "TitleFish&chipsfortwo,\u{2014}\u{2018}please\u{2019}.")
    }

    func testLocateIgnoresWhitespaceDifferences() {
        let text = EPUBTextAnchor.canonical("The lamp would not light. She tried the valve twice.")
        // Selection.toString() keeps the line break the layout put there.
        let range = EPUBTextAnchor.locate(highlight: "She tried\n  the valve", before: nil, after: nil, in: text)
        XCTAssertEqual(range.map { (text as NSString).substring(with: $0) }, "Shetriedthevalve")
    }

    func testLocateUsesContextToChooseBetweenRepeats() {
        let text = EPUBTextAnchor.canonical("Went down to the ferry. Then later: went down to the ferry again.")
        let first = EPUBTextAnchor.locate(highlight: "down to the ferry", before: "Went ", after: ". Then", in: text)
        let second = EPUBTextAnchor.locate(highlight: "down to the ferry", before: "later: went ", after: " again", in: text)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertLessThan(first!.location, second!.location)
        // No context: the progression hint decides.
        let hinted = EPUBTextAnchor.locate(highlight: "down to the ferry", before: nil, after: nil, in: text,
                                           progressionHint: 0.9)
        XCTAssertEqual(hinted, second)
        XCTAssertNil(EPUBTextAnchor.locate(highlight: "not in the text", before: nil, after: nil, in: text))
        XCTAssertNil(EPUBTextAnchor.locate(highlight: "   ", before: nil, after: nil, in: text))
    }

    func testRangesOverlapOnlyInTheSameResource() {
        let a = EPUBTextRange(href: "OEBPS/chapter1.xhtml", range: NSRange(location: 10, length: 10))
        XCTAssertTrue(a.overlaps(EPUBTextRange(href: "/OEBPS/chapter1.xhtml#p3", range: NSRange(location: 19, length: 5))))
        XCTAssertFalse(a.overlaps(EPUBTextRange(href: "OEBPS/chapter1.xhtml", range: NSRange(location: 20, length: 5))),
                       "Touching is not overlapping")
        XCTAssertFalse(a.overlaps(EPUBTextRange(href: "OEBPS/chapter2.xhtml", range: NSRange(location: 10, length: 10))))
    }

    func testSelectionsAnchorInTheRealChapter() async throws {
        let engine = try await openEngine()
        let text = try await chapterText(Self.chapter1, engine: engine)
        // "Harrow top would not light. Went down to the ferry." occurs twice
        // in chapter 1; the quote's context picks the second.
        let first = EPUBTextAnchor.locate(
            highlight: "Harrow top would not light.", before: "Thirteen lit. ", after: " Went down", in: text)
        let second = EPUBTextAnchor.locate(
            highlight: "Harrow top would not light.", before: "there it was again: ", after: " Went down", in: text)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertGreaterThan(second!.location, first!.location)
    }

    // MARK: - Decorations

    func testEveryStyleMapsToADecorationTheNavigatorCanDraw() {
        let templates = EPUBAnnotationDecorations.templates()
        for style in HighlightStyle.allCases {
            let id = EPUBAnnotationDecorations.styleID(for: style)
            XCTAssertNotNil(templates[id], "\(style) has a template")
            let decorated = EPUBAnnotationDecorations.style(for: style, color: .rose, isActive: true)
            XCTAssertEqual(decorated.id, id)
            let config = decorated.config as? Decoration.Style.HighlightConfig
            XCTAssertEqual(config?.isActive, true)
            XCTAssertEqual(config?.tint, EPUBAnnotationDecorations.tint(for: .rose))
        }
        XCTAssertEqual(EPUBAnnotationDecorations.styleID(for: .highlight), .highlight)
        XCTAssertEqual(EPUBAnnotationDecorations.styleID(for: .underline), .underline)
        XCTAssertEqual(Set(HighlightStyle.allCases.map(EPUBAnnotationDecorations.styleID(for:))).count, 4)
    }

    func testOnlyEPUBMarksBecomeDecorations() throws {
        let pdf = Highlight(quotedText: "pdf", location: .pdfPage(index: 0, yOffset: 0),
                            normalizedRects: [CGRect(x: 0, y: 0, width: 1, height: 0.1)], orderKey: 0)
        let selection = EPUBTextSelection(locator: try selectionLocator("lamplighter"), frame: nil, range: nil)
        let epub = EPUBAnnotationsController.makeHighlight(from: selection, style: .squiggly, color: .moss,
                                                           engine: nil, resourceTextLength: nil)
        let decorations = EPUBAnnotationDecorations.decorations(for: [pdf, epub], activeID: epub.id)
        XCTAssertEqual(decorations.map(\.id), [epub.id.uuidString])
        XCTAssertEqual(decorations.first?.style.id, EPUBAnnotationDecorations.squigglyStyle)
        XCTAssertEqual(decorations.first?.locator.text.highlight, "lamplighter")
        XCTAssertEqual(decorations.first?.locator.href.string, Self.chapter1)
    }

    // MARK: - Storage

    func testHighlightStoresItsLocatorAndRoundTripsThroughTheStore() async throws {
        let engine = try await openEngine()
        let text = try await chapterText(Self.chapter1, engine: engine)
        let locator = try selectionLocator("the twelve lamps she had already lit",
                                           before: "the long grey back of the river, and ",
                                           after: ", each one a small promise")
        let range = try XCTUnwrap(EPUBTextAnchor.locate(
            highlight: locator.text.highlight!, before: locator.text.before, after: locator.text.after, in: text))
        let selection = EPUBTextSelection(locator: locator, frame: nil,
                                          range: EPUBTextRange(href: Self.chapter1, range: range))
        let made = EPUBAnnotationsController.makeHighlight(
            from: selection, style: .underline, color: .sky, engine: engine,
            resourceTextLength: (text as NSString).length)

        let container = try ModelContainer(for: Book.self, Bookmark.self, Highlight.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let book = Book(title: "t", fileName: "t.epub", format: .epub, contentFingerprint: "t")
        container.mainContext.insert(book)
        made.book = book
        container.mainContext.insert(made)
        try container.mainContext.save()

        let fetched = try XCTUnwrap(try ModelContext(container).fetch(FetchDescriptor<Highlight>()).first)
        XCTAssertEqual(fetched.style, .underline)
        XCTAssertEqual(fetched.color, .sky)
        XCTAssertEqual(fetched.quotedText, "the twelve lamps she had already lit")
        XCTAssertNotNil(fetched.locatorJSON)
        XCTAssertTrue(fetched.normalizedRects.isEmpty)
        XCTAssertEqual(fetched.epubTextRange, EPUBTextRange(href: Self.chapter1, range: range))

        let stored = try XCTUnwrap(fetched.epubLocator)
        XCTAssertEqual(stored.href.string, Self.chapter1)
        XCTAssertEqual(stored.text.highlight, locator.text.highlight)
        XCTAssertEqual(stored.text.before, locator.text.before)
        XCTAssertEqual(stored.text.after, locator.text.after)
        XCTAssertNil(stored.locations.otherLocations["cssSelector"],
                     "The page's CSS selector is dropped: the quote is the anchor")
        // Progression comes from where the quote sits in the chapter.
        let expected = Double(range.location) / Double((text as NSString).length)
        XCTAssertEqual(try XCTUnwrap(stored.locations.progression), expected, accuracy: 1e-9)
        // The location carries the same locator (numbers compared with an
        // accuracy: a double may shift in its last digit through JSON).
        XCTAssertEqual(fetched.location.epubHref, stored.href.string)
        if case let .epubLocator(_, progression, total, _) = fetched.location {
            XCTAssertEqual(progression, try XCTUnwrap(stored.locations.progression), accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(total), try XCTUnwrap(stored.locations.totalProgression), accuracy: 1e-12)
        } else {
            XCTFail("An EPUB mark is stored at an EPUB location")
        }
        XCTAssertEqual(fetched.orderKey, engine.orderKey(for: fetched.location))
        XCTAssertEqual(stored.locations.position.map { $0 - 1 }, engine.positionIndex(for: fetched.location))
    }

    func testPDFHighlightsAreUntouchedByTheNewField() {
        let pdf = Highlight(quotedText: "x", location: .pdfPage(index: 2, yOffset: 0),
                            normalizedRects: [], characterRange: NSRange(location: 4, length: 3), orderKey: 2)
        XCTAssertNil(pdf.locatorJSON)
        XCTAssertNil(pdf.epubLocator)
        XCTAssertNil(pdf.epubTextRange)
        XCTAssertEqual(pdf.characterRange, NSRange(location: 4, length: 3))
    }

    func testMarksSortInReadingOrderAcrossChapters() async throws {
        let engine = try await openEngine()
        func mark(_ quote: String, before: String, href: String) async throws -> Highlight {
            let text = try await chapterText(href, engine: engine)
            let range = try XCTUnwrap(EPUBTextAnchor.locate(highlight: quote, before: before, after: nil, in: text))
            let selection = EPUBTextSelection(locator: try selectionLocator(quote, before: before, href: href),
                                              frame: nil, range: EPUBTextRange(href: href, range: range))
            return EPUBAnnotationsController.makeHighlight(from: selection, style: .highlight, color: .butter,
                                                           engine: engine, resourceTextLength: (text as NSString).length)
        }
        let late = try await mark("Instead she put on her coat again", before: "", href: Self.chapter1)
        let early = try await mark("Every evening at a quarter past six", before: "", href: Self.chapter1)
        let later = try await mark("She read it several times", before: "", href: Self.chapter3)
        XCTAssertLessThan(early.orderKey, late.orderKey)
        XCTAssertLessThan(late.orderKey, later.orderKey)
    }

    // MARK: - Overlap rule

    func testOverlapUsesRangesAndFallsBackToQuotes() throws {
        func mark(_ quote: String, range: NSRange?, href: String = Self.chapter1) throws -> Highlight {
            let selection = EPUBTextSelection(locator: try selectionLocator(quote, href: href), frame: nil,
                                              range: range.map { EPUBTextRange(href: href, range: $0) })
            return EPUBAnnotationsController.makeHighlight(from: selection, style: .highlight, color: .butter,
                                                           engine: nil, resourceTextLength: nil)
        }
        let a = try mark("alpha", range: NSRange(location: 0, length: 10))
        let b = try mark("beta", range: NSRange(location: 20, length: 10))
        let other = try mark("alpha", range: NSRange(location: 0, length: 10), href: Self.chapter3)
        let unanchored = try mark("gamma delta", range: nil)
        let all = [a, b, other, unanchored]
        let anchor: (Highlight) -> EPUBTextRange? = { $0.epubTextRange }

        func ids(_ range: NSRange?, quote: String = "zzz") -> Set<UUID> {
            Set(EPUBAnnotationsController.highlights(
                overlapping: range.map { EPUBTextRange(href: Self.chapter1, range: $0) },
                href: Self.chapter1, quote: quote, in: all, anchor: anchor).map(\.id))
        }
        XCTAssertEqual(ids(NSRange(location: 5, length: 20)), [a.id, b.id])
        XCTAssertEqual(ids(NSRange(location: 10, length: 10)), [], "Between the two marks")
        XCTAssertEqual(ids(NSRange(location: 25, length: 1)), [b.id])
        // The unanchored mark is matched by its quote.
        XCTAssertEqual(ids(NSRange(location: 100, length: 4), quote: "delta"), [unanchored.id])
        // An unanchored selection compares quotes with every mark in the chapter.
        XCTAssertEqual(ids(nil, quote: "alp ha"), [a.id])
    }

    // MARK: - The action bar on a real EPUB reader

    func testActionBarRulesOnAnEPUBSelection() async throws {
        let harness = try await makeReader()
        defer { harness.cleanup() }
        let model = harness.model
        let annotations = model.epubAnnotations

        let locator = try selectionLocator("the twelve lamps she had already lit",
                                           before: "the long grey back of the river, and ",
                                           after: ", each one a small promise")
        await annotations.loadTexts(around: Self.chapter1)
        annotations.selectionDidChange(locator: locator, frame: CGRect(x: 40, y: 300, width: 200, height: 40))
        let selection = try XCTUnwrap(annotations.selection)
        XCTAssertNotNil(selection.range, "Anchored from the chapter text")
        var bar = try XCTUnwrap(annotations.bar)
        XCTAssertEqual(bar.mode, .create)
        XCTAssertTrue(bar.chosenStyles.isEmpty)
        XCTAssertFalse(bar.canRemove)
        XCTAssertEqual(bar.anchor, CGRect(x: 40, y: 300, width: 200, height: 40))

        // A colour marks fresh text in the last style.
        annotations.applyMark(color: .rose)
        XCTAssertEqual(model.book.highlights.count, 1)
        let first = try XCTUnwrap(model.book.highlights.first)
        XCTAssertEqual(first.color, .rose)
        XCTAssertNotNil(first.locatorJSON)
        XCTAssertNotNil(annotations.selection, "The selection stays open after a tap")
        bar = try XCTUnwrap(annotations.bar)
        XCTAssertEqual(bar.chosenColors, [.rose])
        XCTAssertTrue(bar.canRemove)

        // A new style goes on in the colour already there.
        annotations.applyMark(style: .strikethrough)
        XCTAssertEqual(Set(model.book.highlights.map(\.style)), [first.style, .strikethrough])
        XCTAssertEqual(Set(model.book.highlights.map(\.color)), [.rose])
        // A colour recolours everything under the selection.
        annotations.applyMark(color: .moss)
        XCTAssertEqual(Set(model.book.highlights.map(\.color)), [.moss])
        // A chosen style tapped again comes off.
        annotations.applyMark(style: .strikethrough)
        XCTAssertEqual(model.book.highlights.map(\.style), [first.style])
        XCTAssertEqual(harness.settings.lastHighlightColor, .moss)

        // The marks are drawn through the bridge.
        let drawn = model.epubBridge.decorations(in: EPUBAnnotationDecorations.highlightsGroup)
        XCTAssertEqual(drawn.map(\.id), [first.id.uuidString])

        // A shorter selection inside the mark sees it as chosen.
        let inner = try selectionLocator("lamps she had", before: "the long grey back of the river, and the twelve ",
                                         after: " already lit")
        annotations.selectionDidChange(locator: inner, frame: CGRect(x: 60, y: 300, width: 80, height: 20))
        XCTAssertEqual(annotations.highlights(overlapping: try XCTUnwrap(annotations.selection)).map(\.id), [first.id])
        XCTAssertEqual(annotations.bar?.chosenStyles, [first.style])
        // Text elsewhere does not.
        let elsewhere = try selectionLocator("She had been the lamplighter for nine years.")
        annotations.selectionDidChange(locator: elsewhere, frame: CGRect(x: 10, y: 10, width: 10, height: 10))
        XCTAssertEqual(annotations.bar?.chosenStyles, [])

        // Clear removes every mark under the selection, and keeps it open.
        annotations.selectionDidChange(locator: inner, frame: CGRect(x: 60, y: 300, width: 80, height: 20))
        annotations.removeMarks()
        XCTAssertTrue(model.book.highlights.isEmpty)
        XCTAssertNotNil(annotations.selection)

        // Tapping a mark opens it in edit mode; its own style again removes it.
        annotations.applyMark(style: .underline)
        let mark = try XCTUnwrap(model.book.highlights.first)
        annotations.markActivated(id: mark.id.uuidString, rect: CGRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertNil(annotations.selection)
        XCTAssertEqual(annotations.editingMarkID, mark.id)
        XCTAssertEqual(annotations.bar?.mode, .edit)
        let active = model.epubBridge.decorations(in: EPUBAnnotationDecorations.highlightsGroup).first
        XCTAssertEqual((active?.style.config as? Decoration.Style.HighlightConfig)?.isActive, true)
        annotations.applyMark(color: .sky)
        XCTAssertEqual(mark.color, .sky)
        annotations.applyMark(style: .underline)
        XCTAssertTrue(model.book.highlights.isEmpty)
        XCTAssertNil(annotations.editingMarkID)

        // A tap elsewhere closes an open mark and is swallowed.
        annotations.selectionDidChange(locator: inner, frame: CGRect(x: 60, y: 300, width: 80, height: 20))
        annotations.applyMark(style: .highlight)
        let again = try XCTUnwrap(model.book.highlights.first)
        annotations.markActivated(id: again.id.uuidString, rect: .zero)
        XCTAssertTrue(annotations.dismissForTap())
        XCTAssertNil(annotations.editingMarkID)
        XCTAssertFalse(annotations.dismissForTap(), "Nothing open: the tap is the reader's")
    }

    // MARK: - Search

    func testSearchResultsNavigateToTheMatchAndFlashIt() async throws {
        let harness = try await makeReader()
        defer { harness.cleanup() }
        let model = harness.model
        let engine = try XCTUnwrap(model.epubEngine)

        let results = try await engine.search("ironmonger", limit: 10)
        let result = try XCTUnwrap(results.first)
        let locator = try XCTUnwrap(result.location.readiumLocator)
        XCTAssertEqual(locator.href.string, Self.chapter3)
        XCTAssertEqual(locator.text.highlight?.lowercased(), "ironmonger")
        // The match anchors in its chapter, so Readium can scroll to it.
        let text = try await chapterText(Self.chapter3, engine: engine)
        let range = try XCTUnwrap(EPUBTextAnchor.locate(highlight: locator.text.highlight!, before: locator.text.before,
                                                        after: locator.text.after, in: text))
        XCTAssertEqual((text as NSString).substring(with: range).lowercased(), "ironmonger")
        // The label is the position the navigator lands on.
        XCTAssertEqual(result.pageLabel, engine.label(for: result.location))
        XCTAssertEqual(engine.positionIndex(for: result.location).map { $0 + 1 }.map(String.init), result.pageLabel)

        // Jumping asks the navigator to go to the result's own locator...
        model.epubAnnotations.flash(result)
        model.go(to: result.location)
        XCTAssertEqual(model.epubNavigationRequest?.location, result.location)
        // ...and marks it for a moment.
        let flashed = model.epubBridge.decorations(in: EPUBAnnotationDecorations.searchGroup)
        XCTAssertEqual(flashed.count, 1)
        XCTAssertEqual(flashed.first?.locator, locator)
        XCTAssertEqual(model.epubAnnotations.flashedSearchResultID, result.id)
        model.epubAnnotations.flash(result, for: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.epubBridge.decorations(in: EPUBAnnotationDecorations.searchGroup).isEmpty)
        XCTAssertNil(model.epubAnnotations.flashedSearchResultID)
    }

    // MARK: - Contents and bookmarks

    func testContentsAreNestedAndNavigate() async throws {
        let harness = try await makeReader()
        defer { harness.cleanup() }
        let model = harness.model
        await model.loadOutlineIfNeeded()
        XCTAssertEqual(model.outline.map(\.depth), [0, 0, 1, 0, 0])
        let ledger = try XCTUnwrap(model.outline.first { $0.title == "The Ferryman's Ledger" })
        XCTAssertEqual(ledger.location.epubHref, "OEBPS/chapter2.xhtml")
        model.go(to: ledger.location)
        XCTAssertEqual(model.epubNavigationRequest?.location, ledger.location)
        XCTAssertEqual(model.currentLocation, ledger.location)
    }

    func testBookmarksUseLocatorsAndSortInReadingOrder() async throws {
        let harness = try await makeReader()
        defer { harness.cleanup() }
        let model = harness.model
        let engine = try XCTUnwrap(model.epubEngine)
        let indices = [engine.positions.count - 1, 0, engine.positions.count / 2, 3]
        for index in indices {
            model.go(toPageIndex: index)
            XCTAssertFalse(model.currentPageIsBookmarked)
            model.toggleBookmark()
            XCTAssertTrue(model.currentPageIsBookmarked)
        }
        let sorted = harness.book.sortedBookmarks
        XCTAssertEqual(sorted.count, 4)
        XCTAssertEqual(sorted.compactMap { engine.positionIndex(for: $0.location) }, indices.sorted())
        for bookmark in sorted {
            XCTAssertNotNil(bookmark.location.readiumLocator, "Stored as a Locator")
            XCTAssertEqual(bookmark.orderKey, engine.orderKey(for: bookmark.location))
        }
        // Toggling again on the same place removes it.
        model.go(toPageIndex: 3)
        model.toggleBookmark()
        XCTAssertEqual(harness.book.bookmarks.count, 3)
    }

    // MARK: - Read aloud

    func testReadAloudTextCoversEachPositionOnce() async throws {
        let engine = try await openEngine()
        let chapterPositions = engine.positions.indices.filter {
            EPUBTextAnchor.sameResource(engine.positions[$0].href.string, Self.chapter1)
        }
        XCTAssertGreaterThan(chapterPositions.count, 1, "Chapter 1 spans several positions")
        var texts: [String] = []
        for index in chapterPositions {
            let text = await engine.loadText(at: ReadingLocation(locator: engine.positions[index]))
            texts.append(text ?? "")
        }
        print("Read-aloud texts for chapter 1 positions:", texts.map(\.count))
        XCTAssertTrue(texts[0].contains("Every evening at a quarter past six"))
        // Each position's text ends inside its own chapter, and the chapter's
        // last sentence is read by some position.
        XCTAssertTrue(texts.joined().contains("Instead she put on her coat again"))
        XCTAssertFalse(texts[0].contains("What the River Kept"), "Does not run into chapter 2")
        // Each position starts where it should: the second does not repeat
        // the chapter's opening.
        XCTAssertFalse(texts[1].contains("Every evening at a quarter past six"))
        XCTAssertTrue(texts.last!.contains("Instead she put on her coat again"))
    }
}
