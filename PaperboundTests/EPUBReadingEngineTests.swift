//
//  EPUBReadingEngineTests.swift
//  PaperboundTests
//
//  Drives the Readium-backed engine over the fixture books built by
//  Tools/make-epub-fixtures.sh: Sample.epub (four chapters, nested nav TOC,
//  image, footnote) and Protected.epub (the same book flagged as Adobe DRM).
//

import ReadiumNavigator
import ReadiumShared
import XCTest
@testable import Paperbound

@MainActor
final class EPUBReadingEngineTests: XCTestCase {

    private func fixtureURL(_ name: String) throws -> URL {
        // The fixtures sit in PaperboundTests/Fixtures, which the synchronized
        // folder copies into the test bundle's resources.
        try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "epub"),
            "\(name).epub is missing from the test bundle; run Tools/make-epub-fixtures.sh."
        )
    }

    private func openSample(at location: ReadingLocation? = nil) async throws -> EPUBReadingEngine {
        let engine = try EPUBReadingEngine(
            documentID: UUID(),
            fileURL: try fixtureURL("Sample"),
            initialLocation: location
        )
        try await engine.open()
        return engine
    }

    // MARK: - Fixtures

    func testFixturesAreBundledWithTheTests() throws {
        for name in ["Sample", "Protected"] {
            let url = try fixtureURL(name)
            let data = try Data(contentsOf: url)
            // OCF: `mimetype` must be the first entry, stored, so its content
            // sits at a fixed offset right after the 30-byte local header.
            XCTAssertEqual(data.prefix(2), Data("PK".utf8), name)
            XCTAssertEqual(String(data: data[38..<58], encoding: .ascii), "application/epub+zip", name)
        }
    }

    // MARK: - Opening

    func testOpensTheSampleAndReadsItsMetadata() async throws {
        let engine = try await openSample()
        XCTAssertTrue(engine.isOpen)
        XCTAssertEqual(engine.format, .epub)
        XCTAssertEqual(engine.title, "The Lamplighter's Almanac")
        XCTAssertNotNil(engine.publication)
        XCTAssertTrue(engine.capabilities.contains(.reflowTypography))
        XCTAssertTrue(engine.capabilities.contains(.fullTextSearch))
        XCTAssertFalse(engine.capabilities.contains(.continuousZoom))
        engine.close()
        XCTAssertFalse(engine.isOpen)
        XCTAssertNil(engine.publication)
    }

    func testPositionsAreThePageCount() async throws {
        let engine = try await openSample()
        // Four chapters of prose plus a cover: comfortably more than one
        // position per chapter.
        XCTAssertGreaterThan(engine.pageCount, 5)
        XCTAssertEqual(engine.pageCount, engine.positions.count)
        XCTAssertEqual(engine.positions.first?.locations.position, 1)
    }

    func testOutlineIsTheNestedTableOfContents() async throws {
        let engine = try await openSample()
        let outline = engine.outline()
        XCTAssertEqual(outline.map(\.title), [
            "I. The Lamp on Harrow Street",
            "II. What the River Kept",
            "The Ferryman's Ledger",
            "III. A Winter of Letters",
            "IV. The Last Page"
        ])
        XCTAssertEqual(outline.map(\.depth), [0, 0, 1, 0, 0])
        XCTAssertEqual(outline[1].location.epubHref, "OEBPS/chapter2.xhtml")
        // The nested entry keeps its fragment so the navigator lands on it.
        let ledger = try XCTUnwrap(outline[2].location.readiumLocator)
        XCTAssertEqual(ledger.locations.fragments, ["ledger"])
    }

    func testMissingFileIsReportedBeforeOpening() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID()).epub")
        XCTAssertThrowsError(try EPUBReadingEngine(documentID: UUID(), fileURL: url, initialLocation: nil)) {
            guard case ReadingEngineError.fileMissing = $0 else {
                return XCTFail("Expected fileMissing, got \($0)")
            }
        }
    }

    func testProtectedBookIsRefused() async throws {
        let engine = try EPUBReadingEngine(
            documentID: UUID(), fileURL: try fixtureURL("Protected"), initialLocation: nil
        )
        do {
            try await engine.open()
            XCTFail("A DRM-flagged EPUB must not open")
        } catch ReadingEngineError.encryptedDocument {
            XCTAssertFalse(engine.isOpen)
        }
    }

    func testCorruptFileIsUnreadableNotACrash() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("corrupt-\(UUID()).epub")
        try Data("this is not a zip file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = try EPUBReadingEngine(documentID: UUID(), fileURL: url, initialLocation: nil)
        do {
            try await engine.open()
            XCTFail("Garbage must not open")
        } catch ReadingEngineError.unreadableDocument {
            XCTAssertFalse(engine.isOpen)
        }
    }

    // MARK: - Locations

    func testStartsAtTheFirstPositionAndRestoresASavedOne() async throws {
        let engine = try await openSample()
        XCTAssertEqual(engine.currentLocation(), engine.firstLocation())
        XCTAssertEqual(engine.label(for: engine.firstLocation()), "1")

        let saved = ReadingLocation(locator: engine.positions[4])
        let reopened = try await openSample(at: saved)
        XCTAssertEqual(reopened.currentLocation(), saved)
        XCTAssertEqual(reopened.label(for: saved), "5")
    }

    func testLocatorSurvivesReadingLocationAndJSON() async throws {
        let engine = try await openSample()
        let original = engine.positions[3]
            .copy(text: { $0 = Locator.Text(after: "after", before: "before", highlight: "match") })

        let location = ReadingLocation(locator: original)
        XCTAssertEqual(location.readiumLocator, original)
        XCTAssertEqual(location.epubHref, original.href.string)
        XCTAssertEqual(location.epubTotalProgression, original.locations.totalProgression)
        XCTAssertNil(location.pdfPageIndex)

        // The same path a bookmark or `Book.savedLocation` takes.
        let data = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(ReadingLocation.self, from: data)
        XCTAssertEqual(decoded, location)
        XCTAssertEqual(decoded.readiumLocator, original)
        XCTAssertEqual(decoded.readiumLocator?.text.highlight, "match")
    }

    func testDamagedLocatorJSONFallsBackToTheChapter() {
        let location = ReadingLocation.epubLocator(
            href: "OEBPS/chapter3.xhtml", progression: 0.5, totalProgression: 0.6, locatorJSON: "not json"
        )
        let locator = location.readiumLocator
        XCTAssertEqual(locator?.href.string, "OEBPS/chapter3.xhtml")
        XCTAssertEqual(locator?.locations.progression, 0.5)
        XCTAssertNil(ReadingLocation.pdfPage(index: 3, yOffset: 0).readiumLocator)
    }

    func testAdvancingWalksThePositions() async throws {
        let engine = try await openSample()
        let first = engine.firstLocation()

        XCTAssertNil(engine.location(byAdvancing: first, pages: -1), "Nothing before the start")
        let second = try XCTUnwrap(engine.location(byAdvancing: first, pages: 1))
        XCTAssertEqual(second, ReadingLocation(locator: engine.positions[1]))
        XCTAssertEqual(engine.location(byAdvancing: second, pages: -1), first)

        let last = ReadingLocation(locator: try XCTUnwrap(engine.positions.last))
        XCTAssertNil(engine.location(byAdvancing: last, pages: 1), "Nothing after the end")
        XCTAssertEqual(engine.location(byAdvancing: first, pages: engine.pageCount - 1), last)

        // A locator the navigator reports mid-position still advances from
        // the position that contains it.
        let midway = engine.positions[2].copy(locations: {
            $0.position = nil
            $0.progression = ($0.progression ?? 0) + 0.01
        })
        XCTAssertEqual(engine.positionIndex(for: ReadingLocation(locator: midway)), 2)
        XCTAssertEqual(
            engine.location(byAdvancing: ReadingLocation(locator: midway), pages: 1),
            ReadingLocation(locator: engine.positions[3])
        )
    }

    func testProgressAndOrderKeysIncreaseThroughTheBook() async throws {
        let engine = try await openSample()
        var location = engine.firstLocation()
        var progress = engine.normalizedProgress(for: location)
        var key = engine.orderKey(for: location)
        XCTAssertGreaterThanOrEqual(progress, 0)

        while let next = engine.location(byAdvancing: location, pages: 1) {
            let nextProgress = engine.normalizedProgress(for: next)
            let nextKey = engine.orderKey(for: next)
            XCTAssertGreaterThan(nextProgress, progress, "Progress must rise at \(engine.label(for: next))")
            XCTAssertGreaterThan(nextKey, key)
            location = next
            progress = nextProgress
            key = nextKey
        }
        XCTAssertEqual(progress, 1, accuracy: 0.0001, "The last position counts as finished")
    }

    func testStablePageIDIgnoresSmallMovesInsideAChapter() async throws {
        let engine = try await openSample()
        let a = ReadingLocation.epubLocator(href: "OEBPS/chapter1.xhtml", progression: 0.01,
                                            totalProgression: nil, locatorJSON: "{}")
        let b = ReadingLocation.epubLocator(href: "OEBPS/chapter1.xhtml", progression: 0.05,
                                            totalProgression: nil, locatorJSON: "{}")
        let c = ReadingLocation.epubLocator(href: "OEBPS/chapter2.xhtml", progression: 0.01,
                                            totalProgression: nil, locatorJSON: "{}")
        XCTAssertEqual(engine.stablePageID(for: a), engine.stablePageID(for: b))
        XCTAssertNotEqual(engine.stablePageID(for: a), engine.stablePageID(for: c))
    }

    func testRenderingIsLeftToTheNavigator() async throws {
        let engine = try await openSample()
        do {
            _ = try await engine.renderPage(at: engine.firstLocation(), pixelSize: CGSize(width: 100, height: 100))
            XCTFail("EPUB pages are not rasterized by the engine")
        } catch ReadingEngineError.renderFailed {
            // Expected.
        }
    }

    // MARK: - Content

    func testSearchFindsTextWithContext() async throws {
        let engine = try await openSample()
        let results = try await engine.search("ferryman")
        XCTAssertGreaterThan(results.count, 3)
        let first = try XCTUnwrap(results.first)
        let snippet = Array(first.snippet)
        let match = String(snippet[first.matchRange]).lowercased()
        XCTAssertEqual(match, "ferryman")
        XCTAssertNotNil(first.location.epubHref)
        let tooShort = try await engine.search("x")
        XCTAssertTrue(tooShort.isEmpty, "One-letter queries are ignored, as for PDF")
        let absent = try await engine.search("zebra crossing")
        XCTAssertTrue(absent.isEmpty)
    }

    func testTextForSpeechComesFromThePosition() async throws {
        let engine = try await openSample()
        let chapterOne = try XCTUnwrap(engine.outline().first?.location)
        XCTAssertNil(engine.text(at: chapterOne), "Nothing is cached before loading")
        let loaded = await engine.loadText(at: chapterOne)
        let text = try XCTUnwrap(loaded)
        XCTAssertTrue(text.contains("Ada Marsh"), text)
        XCTAssertEqual(engine.text(at: chapterOne), text, "Loaded text is cached for the sync path")
    }
}

/// Proves the navigator `EPUBReaderView` hosts can actually lay the sample out
/// inside the app: resources load through Readium's scheme handler (no HTTP
/// server) and it reports a first location we can turn into a
/// `ReadingLocation`. Visual checks are Phase 3's.
@MainActor
final class EPUBNavigatorSmokeTests: XCTestCase, EPUBNavigatorDelegate {

    private var reported: XCTestExpectation?
    private var firstLocator: Locator?

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard firstLocator == nil else { return }
        firstLocator = locator
        reported?.fulfill()
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        XCTFail("Navigator error: \(error)")
    }

    func testNavigatorOpensTheSampleAtASavedPosition() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Sample", withExtension: "epub"))
        let engine = try EPUBReadingEngine(documentID: UUID(), fileURL: url, initialLocation: nil)
        try await engine.open()
        let publication = try XCTUnwrap(engine.publication)
        let target = try XCTUnwrap(engine.outline().first { $0.title.hasPrefix("III.") }?.location)

        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: target.readiumLocator
        )
        navigator.delegate = self
        reported = expectation(description: "navigator reports a location")

        // Torn down fully after the test (see HostedTestWindow).
        let host = try HostedTestWindow(navigator, size: CGSize(width: 390, height: 844))
        addTeardownBlock { await host.close() }

        await fulfillment(of: [reported!], timeout: 20)
        let location = ReadingLocation(locator: try XCTUnwrap(firstLocator))
        XCTAssertEqual(location.epubHref, "OEBPS/chapter3.xhtml")
        XCTAssertEqual(engine.positionIndex(for: location), engine.positionIndex(for: target))
    }
}
