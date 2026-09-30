//
//  PDFEngineTests.swift
//  PaperboundTests
//
//  End-to-end over a real PDF: the sample book is generated, imported and then
//  driven through the engine exactly as the reader drives it.
//

import PDFKit
import SwiftData
import XCTest
@testable import Paperbound

@MainActor
final class PDFEngineTests: XCTestCase {

    private var sampleURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        sampleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-test-\(UUID().uuidString).pdf")
        try SampleLibrary.write(to: sampleURL)
    }

    override func tearDown() async throws {
        if let sampleURL {
            try? FileManager.default.removeItem(at: sampleURL)
        }
        try await super.tearDown()
    }

    private func makeEngine(at location: ReadingLocation? = nil) throws -> PDFReadingEngine {
        try PDFReadingEngine(
            documentID: UUID(),
            fileURL: sampleURL,
            initialLocation: location
        )
    }

    // MARK: - Document generation

    func testSampleBookIsAValidMultiPagePDF() throws {
        let document = try XCTUnwrap(PDFDocument(url: sampleURL))
        XCTAssertGreaterThanOrEqual(document.pageCount, 5, "The sample should paginate into several sheets.")
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(page.bounds(for: .cropBox).width, SampleLibrary.pageSize.width, accuracy: 1)
        XCTAssertEqual(page.bounds(for: .cropBox).height, SampleLibrary.pageSize.height, accuracy: 1)
    }

    func testSampleBookCarriesRealTextAndItsOwnMetadata() throws {
        let metadata = PDFReadingEngine.metadata(for: sampleURL)
        XCTAssertEqual(metadata.title, SampleLibrary.title)
        XCTAssertEqual(metadata.author, SampleLibrary.author)
        XCTAssertGreaterThan(metadata.pageCount, 4)

        let document = try XCTUnwrap(PDFDocument(url: sampleURL))
        // The title wraps across two lines in the rendered page, so compare
        // against flattened text — the same normalisation the search path does.
        let firstPageText = try XCTUnwrap(document.page(at: 0)?.string)
        let flattened = firstPageText.replacingOccurrences(of: "\n", with: " ")
        XCTAssertTrue(
            flattened.contains(SampleLibrary.title),
            "First page text began: \(firstPageText.prefix(240).debugDescription)"
        )
        XCTAssertTrue(flattened.contains("A page is not a surface"))
    }

    // MARK: - Opening

    func testOpeningExposesPagesAndCapabilities() async throws {
        let engine = try makeEngine()
        XCTAssertFalse(engine.isOpen)
        try await engine.open()
        XCTAssertTrue(engine.isOpen)
        XCTAssertGreaterThan(engine.pageCount, 4)
        XCTAssertEqual(engine.format, .pdf)
        XCTAssertTrue(engine.capabilities.contains(.textSelection))
        XCTAssertNotNil(engine.pdfDocument)
    }

    func testMissingFileIsReportedNotCrashed() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).pdf")
        XCTAssertThrowsError(
            try PDFReadingEngine(documentID: UUID(), fileURL: missing, initialLocation: nil)
        ) { error in
            guard case ReadingEngineError.fileMissing = error else {
                return XCTFail("Expected a fileMissing error, got \(error)")
            }
        }
    }

    func testARestoredLocationBeyondTheEndIsClamped() async throws {
        let engine = try makeEngine(at: .pdfPage(index: 9_999, yOffset: 0))
        try await engine.open()
        let index = try XCTUnwrap(engine.currentLocation().pdfPageIndex)
        XCTAssertLessThan(index, engine.pageCount)
    }

    // MARK: - Navigation

    func testNavigationMovesAndClampsAtBothEnds() async throws {
        let engine = try makeEngine()
        try await engine.open()

        XCTAssertEqual(engine.firstLocation().pdfPageIndex, 0)
        XCTAssertNil(engine.location(byAdvancing: engine.firstLocation(), pages: -1))

        let second = try XCTUnwrap(engine.location(byAdvancing: engine.firstLocation(), pages: 1))
        XCTAssertEqual(second.pdfPageIndex, 1)

        let last = ReadingLocation.pdfPage(index: engine.pageCount - 1, yOffset: 0)
        XCTAssertNil(engine.location(byAdvancing: last, pages: 1))
    }

    func testGoToRejectsOutOfBoundsPages() async throws {
        let engine = try makeEngine()
        try await engine.open()
        do {
            try await engine.go(to: .pdfPage(index: engine.pageCount + 5, yOffset: 0))
            XCTFail("Expected an out-of-bounds error")
        } catch {
            guard case ReadingEngineError.locationOutOfBounds = error else {
                return XCTFail("Expected locationOutOfBounds, got \(error)")
            }
        }
    }

    func testProgressAndOrderKeyAdvanceMonotonically() async throws {
        let engine = try makeEngine()
        try await engine.open()
        var previousProgress = -1.0
        var previousKey = -1.0
        for index in 0..<engine.pageCount {
            let location = ReadingLocation.pdfPage(index: index, yOffset: 0)
            let progress = engine.normalizedProgress(for: location)
            let key = engine.orderKey(for: location)
            XCTAssertGreaterThan(progress, previousProgress)
            XCTAssertGreaterThan(key, previousKey)
            previousProgress = progress
            previousKey = key
        }
        XCTAssertEqual(previousProgress, 1.0, accuracy: 0.0001)
    }

    // MARK: - Content

    func testSearchFindsTextThatIsActuallyInTheBook() async throws {
        let engine = try makeEngine()
        try await engine.open()
        let results = try await engine.search("paper")
        XCTAssertGreaterThan(results.count, 3)

        let first = try XCTUnwrap(results.first)
        XCTAssertNotNil(first.location.pdfPageIndex)
        XCTAssertFalse(first.snippet.isEmpty)

        // The reported range must actually cover the match inside the snippet.
        let characters = Array(first.snippet)
        XCTAssertLessThanOrEqual(first.matchRange.upperBound, characters.count)
        let matched = String(characters[first.matchRange]).lowercased()
        XCTAssertEqual(matched, "paper")
    }

    func testSearchForAbsentTextReturnsNothing() async throws {
        let engine = try makeEngine()
        try await engine.open()
        let results = try await engine.search("zygomorphic quetzalcoatl")
        XCTAssertTrue(results.isEmpty)
    }

    func testVeryShortQueriesAreIgnored() async throws {
        let engine = try makeEngine()
        try await engine.open()
        let singleCharacter = try await engine.search("a")
        let empty = try await engine.search("")
        XCTAssertTrue(singleCharacter.isEmpty)
        XCTAssertTrue(empty.isEmpty)
    }

    func testTextIsAvailableForSpeechAndAccessibility() async throws {
        let engine = try makeEngine()
        try await engine.open()
        let text = try XCTUnwrap(engine.text(at: .pdfPage(index: 1, yOffset: 0)))
        XCTAssertGreaterThan(text.count, 200, "A body page should carry a real text layer.")
    }

    // MARK: - Rendering

    func testRenderProducesTheExactPixelSizeRequested() async throws {
        let engine = try makeEngine()
        try await engine.open()
        let image = try await engine.renderPage(
            at: .pdfPage(index: 0, yOffset: 0),
            pixelSize: CGSize(width: 432, height: 648)
        )
        XCTAssertEqual(image.width, 432)
        XCTAssertEqual(image.height, 648)
    }

    func testRenderingOutOfBoundsThrowsRatherThanReturningBlank() async throws {
        let engine = try makeEngine()
        try await engine.open()
        do {
            _ = try await engine.renderPage(
                at: .pdfPage(index: 9_999, yOffset: 0),
                pixelSize: CGSize(width: 100, height: 100)
            )
            XCTFail("Expected an out-of-bounds error")
        } catch {
            guard case ReadingEngineError.locationOutOfBounds = error else {
                return XCTFail("Expected locationOutOfBounds, got \(error)")
            }
        }
    }

    func testConcurrentRendersDoNotInterfereWithEachOther() async throws {
        let engine = try makeEngine()
        try await engine.open()
        let size = CGSize(width: 216, height: 324)

        let images = try await withThrowingTaskGroup(of: CGImage.self) { group -> [CGImage] in
            for index in 0..<min(6, engine.pageCount) {
                group.addTask {
                    try await engine.renderPage(at: .pdfPage(index: index, yOffset: 0), pixelSize: size)
                }
            }
            var collected: [CGImage] = []
            for try await image in group { collected.append(image) }
            return collected
        }

        XCTAssertEqual(images.count, min(6, engine.pageCount))
        for image in images {
            XCTAssertEqual(image.width, 216)
            XCTAssertEqual(image.height, 324)
        }
    }

    func testStablePageIDsAreDistinctAndPageShaped() async throws {
        let engine = try makeEngine()
        try await engine.open()
        let ids = (0..<engine.pageCount).map {
            engine.stablePageID(for: .pdfPage(index: $0, yOffset: 0))
        }
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids.first, "pdf:0")
    }

    func testAspectRatioMatchesTheSampleBooksPageShape() async throws {
        let engine = try makeEngine()
        try await engine.open()
        for index in [0, engine.pageCount / 2, engine.pageCount - 1] {
            let location = ReadingLocation.pdfPage(index: index, yOffset: 0)
            let box = try XCTUnwrap(engine.pdfDocument?.page(at: index)?.bounds(for: .cropBox))
            let ratio = engine.aspectRatio(at: location)
            XCTAssertEqual(ratio, Double(box.height / box.width), accuracy: 0.01)
            XCTAssertEqual(engine.aspectRatio(at: location), ratio)
        }
    }

    func testClosingReleasesTheDocumentButKeepsGeometry() async throws {
        let engine = try makeEngine()
        try await engine.open()
        let pageCount = engine.pageCount
        engine.close()
        XCTAssertFalse(engine.isOpen)
        XCTAssertNil(engine.pdfDocument)
        // The page count remains available without opening every page.
        XCTAssertEqual(engine.pageCount, pageCount)
    }
}

// MARK: - Library

@MainActor
final class LibraryStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: LibraryStore!
    private var sampleURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: Book.self, Bookmark.self, Highlight.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        store = try LibraryStore()
        sampleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-test-\(UUID().uuidString).pdf")
        try SampleLibrary.write(to: sampleURL)
    }

    override func tearDown() async throws {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        for book in books { try? store.delete(book, from: context) }
        try? FileManager.default.removeItem(at: sampleURL)
        try await super.tearDown()
    }

    func testImportCopiesTheFileAndReadsItsMetadata() throws {
        let outcome = try store.importFile(at: sampleURL, into: context)
        XCTAssertFalse(outcome.wasAlreadyPresent)
        XCTAssertEqual(outcome.book.title, SampleLibrary.title)
        XCTAssertEqual(outcome.book.author, SampleLibrary.author)
        XCTAssertGreaterThan(outcome.book.pageCount, 4)
        XCTAssertNotNil(outcome.book.coverData)
        XCTAssertTrue(store.fileExists(for: outcome.book))
    }

    func testTheOriginalFileIsNeverModified() throws {
        let before = try Data(contentsOf: sampleURL)
        let outcome = try store.importFile(at: sampleURL, into: context)
        outcome.book.savedEnvironment = .oldJournal
        outcome.book.savedLocation = .pdfPage(index: 3, yOffset: 0)
        try context.save()
        let after = try Data(contentsOf: sampleURL)
        XCTAssertEqual(before, after, "Importing and reading must leave the source file byte-identical.")
    }

    func testReimportingTheSameFileReusesTheExistingBook() throws {
        let first = try store.importFile(at: sampleURL, into: context)
        first.book.savedLocation = .pdfPage(index: 4, yOffset: 0)
        try context.save()

        let second = try store.importFile(at: sampleURL, into: context)
        XCTAssertTrue(second.wasAlreadyPresent)
        XCTAssertEqual(second.book.id, first.book.id)
        XCTAssertEqual(second.book.savedLocation, .pdfPage(index: 4, yOffset: 0))
        XCTAssertEqual(try context.fetch(FetchDescriptor<Book>()).count, 1)
    }

    func testUnsupportedExtensionsAreRefusedClearly() throws {
        let fake = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-\(UUID().uuidString).mobi")
        try Data("not a book".utf8).write(to: fake)
        defer { try? FileManager.default.removeItem(at: fake) }

        XCTAssertThrowsError(try store.importFile(at: fake, into: context)) { error in
            guard case LibraryError.unsupportedType = error else {
                return XCTFail("Expected unsupportedType, got \(error)")
            }
        }
    }

    func testEpubIsRefusedUntilAReflowableEngineExists() throws {
        let fake = FileManager.default.temporaryDirectory
            .appendingPathComponent("book-\(UUID().uuidString).epub")
        try Data("PK not really".utf8).write(to: fake)
        defer { try? FileManager.default.removeItem(at: fake) }

        XCTAssertThrowsError(try store.importFile(at: fake, into: context)) { error in
            guard case ReadingEngineError.unsupportedFormat = error else {
                return XCTFail("Expected unsupportedFormat, got \(error)")
            }
        }
    }

    func testDeletingABookRemovesItsImportedCopy() throws {
        let outcome = try store.importFile(at: sampleURL, into: context)
        let url = store.fileURL(for: outcome.book)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try store.delete(outcome.book, from: context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try context.fetch(FetchDescriptor<Book>()).isEmpty)
    }

    func testFingerprintDistinguishesDifferentFiles() {
        let a = LibraryStore.fingerprint(for: Data("one".utf8))
        let b = LibraryStore.fingerprint(for: Data("two".utf8))
        let aAgain = LibraryStore.fingerprint(for: Data("one".utf8))
        XCTAssertEqual(a, aAgain)
        XCTAssertNotEqual(a, b)
    }

    func testCoverRenderingProducesAJPEG() throws {
        let data = try XCTUnwrap(LibraryStore.renderCover(for: sampleURL))
        XCTAssertGreaterThan(data.count, 1_000)
        // JPEG SOI marker.
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
    }

    func testSampleInstallationIsIdempotent() throws {
        let first = try XCTUnwrap(SampleLibrary.installIfNeeded(store: store, context: context))
        let second = try XCTUnwrap(SampleLibrary.installIfNeeded(store: store, context: context))
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Book>()).count, 1)
    }
}
