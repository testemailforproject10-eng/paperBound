//
//  EPUBImportTests.swift
//  PaperboundTests
//
//  EPUB import through `LibraryStore.importBook`: metadata and cover from the
//  OPF, fingerprint de-duplication, and the refusals — DRM and damaged files
//  must fail with a readable message and leave nothing in the library folder.
//
//  Uses the fixtures built by Tools/make-epub-fixtures.sh.
//

import SwiftData
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Paperbound

@MainActor
final class EPUBImportTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: LibraryStore!
    private var scratch: [URL] = []

    override func setUp() async throws {
        try await super.setUp()
        container = try ModelContainer(
            for: Book.self, Bookmark.self, Highlight.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        store = try LibraryStore()
    }

    override func tearDown() async throws {
        let books = (try? context.fetch(FetchDescriptor<Book>())) ?? []
        for book in books { try? store.delete(book, from: context) }
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch = []
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "epub"),
            "\(name).epub is missing from the test bundle; run Tools/make-epub-fixtures.sh."
        )
    }

    /// A copy outside the bundle with a chosen name, as the Files app would hand over.
    private func copyOfFixture(_ name: String, as fileName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-import-\(UUID().uuidString)")
            .appendingPathComponent(fileName)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: try fixtureURL(name), to: url)
        scratch.append(url.deletingLastPathComponent())
        return url
    }

    private func writeScratch(_ data: Data, named fileName: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-import-\(UUID().uuidString)-\(fileName)")
        try data.write(to: url)
        scratch.append(url)
        return url
    }

    private func libraryFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: store.booksDirectory.path)) ?? []
        return Set(names)
    }

    private func stagedImportFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return names.filter { $0.hasPrefix("paperbound-import-") }
    }

    private func bookCount() throws -> Int {
        try context.fetch(FetchDescriptor<Book>()).count
    }

    /// Imports `url`, expecting a refusal, and checks that it left nothing behind.
    private func assertRefused(
        _ url: URL,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ check: (LibraryError) -> Void
    ) async throws {
        let filesBefore = libraryFiles()
        do {
            _ = try await store.importBook(at: url, into: context)
            XCTFail("Expected the import to be refused", file: file, line: line)
        } catch let error as LibraryError {
            check(error)
            XCTAssertFalse(
                (error.errorDescription ?? "").isEmpty, "The refusal needs a readable message",
                file: file, line: line
            )
        } catch {
            XCTFail("Expected a LibraryError, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(try bookCount(), 0, "A refused file must not create a book", file: file, line: line)
        XCTAssertEqual(libraryFiles(), filesBefore, "A refused file must not reach the library folder", file: file, line: line)
        XCTAssertEqual(stagedImportFiles(), [], "The staging copy must be cleaned up", file: file, line: line)
    }

    // MARK: - Good file

    func testImportingAnEPUBReadsTitleAuthorLanguageAndCover() async throws {
        let source = try copyOfFixture("Sample", as: "lamplighter.epub")
        let outcome = try await store.importBook(at: source, into: context)
        let book = outcome.book

        XCTAssertFalse(outcome.wasAlreadyPresent)
        XCTAssertEqual(book.format, .epub)
        XCTAssertEqual(book.title, "The Lamplighter's Almanac", "Title must come from the OPF, not the file name")
        XCTAssertEqual(book.author, "Wren Halloway")
        XCTAssertEqual(book.language, "en")
        XCTAssertGreaterThan(book.pageCount, 0, "pageCount is the Readium positions count")
        XCTAssertTrue(book.fileName.hasSuffix(".epub"))
        XCTAssertTrue(store.fileExists(for: book))
        XCTAssertEqual(
            try Data(contentsOf: store.fileURL(for: book)),
            try Data(contentsOf: source),
            "The library copy must be byte-identical to the original"
        )

        let coverData = try XCTUnwrap(book.coverData, "The declared cover image becomes the shelf tile")
        let cover = try XCTUnwrap(UIImage(data: coverData))
        XCTAssertGreaterThan(cover.size.height, cover.size.width, "The fixture cover is portrait")
        XCTAssertLessThanOrEqual(cover.size.width * cover.scale, 480.5, "Covers are stored as thumbnails")
        XCTAssertEqual(stagedImportFiles(), [])
    }

    func testTheImportedEPUBOpensInTheReaderEngine() async throws {
        let outcome = try await store.importBook(at: try copyOfFixture("Sample", as: "a.epub"), into: context)
        let engine = try EPUBReadingEngine(
            documentID: outcome.book.id,
            fileURL: store.fileURL(for: outcome.book),
            initialLocation: outcome.book.savedLocation
        )
        try await engine.open()
        defer { engine.close() }
        XCTAssertEqual(engine.pageCount, outcome.book.pageCount)
    }

    func testThePDFPathStillWorksThroughImportBook() async throws {
        let pdf = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-import-\(UUID().uuidString).pdf")
        try SampleLibrary.write(to: pdf)
        scratch.append(pdf)

        let outcome = try await store.importBook(at: pdf, into: context)
        XCTAssertEqual(outcome.book.format, .pdf)
        XCTAssertEqual(outcome.book.title, SampleLibrary.title)
        XCTAssertNil(outcome.book.language)
    }

    // MARK: - Duplicates

    func testReimportingTheSameEPUBReturnsTheExistingBook() async throws {
        let first = try await store.importBook(at: try copyOfFixture("Sample", as: "one.epub"), into: context)
        first.book.isFavorite = true
        try context.save()
        let filesAfterFirst = libraryFiles()

        // Same bytes under another name, as a second "Open in" would deliver.
        let second = try await store.importBook(at: try copyOfFixture("Sample", as: "renamed.epub"), into: context)

        XCTAssertTrue(second.wasAlreadyPresent)
        XCTAssertEqual(second.book.id, first.book.id)
        XCTAssertTrue(second.book.isFavorite, "The existing record, with its state, is returned")
        XCTAssertEqual(try bookCount(), 1)
        XCTAssertEqual(libraryFiles(), filesAfterFirst, "A duplicate must not add a second copy")
    }

    // MARK: - Refusals

    func testDRMProtectedEPUBIsRefusedBeforeCopying() async throws {
        let protected = try copyOfFixture("Protected", as: "Bought Elsewhere.epub")
        try await assertRefused(protected) { error in
            guard case let .protectedBook(name) = error else {
                return XCTFail("Expected protectedBook, got \(error)")
            }
            XCTAssertEqual(name, "Bought Elsewhere.epub")
            XCTAssertTrue(error.localizedDescription.contains("DRM"), error.localizedDescription)
        }
    }

    func testFairPlayEPUBIsRefusedBeforeCopying() async throws {
        // Apple Books purchases carry META-INF/sinf.xml; Readium would open
        // them and render ciphertext, so the engine checks for it by hand.
        let fairPlay = try copyOfFixture("FairPlay", as: "From Apple Books.epub")
        try await assertRefused(fairPlay) { error in
            guard case .protectedBook = error else {
                return XCTFail("Expected protectedBook, got \(error)")
            }
        }
    }

    func testCorruptEPUBIsRefusedWithAReadableError() async throws {
        let garbage = try writeScratch(Data("PK\u{3}\u{4} this is not a zip at all".utf8), named: "garbage.epub")
        try await assertRefused(garbage) { error in
            guard case let .unreadableBook(name) = error else {
                return XCTFail("Expected unreadableBook, got \(error)")
            }
            XCTAssertTrue(name.hasSuffix("garbage.epub"))
        }
    }

    func testTruncatedEPUBIsRefused() async throws {
        let whole = try Data(contentsOf: try fixtureURL("Sample"))
        let truncated = try writeScratch(whole.prefix(whole.count / 2), named: "truncated.epub")
        try await assertRefused(truncated) { error in
            guard case .unreadableBook = error else {
                return XCTFail("Expected unreadableBook, got \(error)")
            }
        }
    }

    func testAPDFRenamedToEPUBIsRefused() async throws {
        let pdf = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-import-\(UUID().uuidString)-disguised.epub")
        try SampleLibrary.write(to: pdf)
        scratch.append(pdf)
        try await assertRefused(pdf) { error in
            guard case .unreadableBook = error else {
                return XCTFail("Expected unreadableBook, got \(error)")
            }
        }
    }

    func testEmptyFileIsRefused() async throws {
        let empty = try writeScratch(Data(), named: "empty.epub")
        try await assertRefused(empty) { error in
            guard case .unreadableBook = error else {
                return XCTFail("Expected unreadableBook, got \(error)")
            }
        }
    }

    // MARK: - Types

    func testImportableTypesOfferZippedEPUBOnly() {
        let types = LibraryStore.importableTypes
        XCTAssertTrue(types.contains(.pdf))
        XCTAssertTrue(types.contains(.epub))
        XCTAssertEqual(UTType.epub.identifier, "org.idpf.epub-container")
        XCTAssertFalse(types.contains { $0.identifier == "org.idpf.epub-folder" })
    }

    func testInfoPlistDeclaresEPUBDocuments() throws {
        // The test bundle runs inside the app, so Bundle.main is Paperbound.
        let documentTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]]
        )
        let contentTypes = documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertTrue(contentTypes.contains("org.idpf.epub-container"))
        XCTAssertTrue(contentTypes.contains("com.adobe.pdf"))
    }

    // MARK: - Metadata helpers

    func testAuthorLineJoinsSeveralCreators() {
        let metadata = EPUBImportMetadata(
            title: "T", authors: ["Ada", " ", "Grace"], language: nil, positionCount: 1, coverJPEG: nil
        )
        let line = metadata.authorLine ?? ""
        XCTAssertTrue(line.contains("Ada") && line.contains("Grace"), line)
        XCTAssertNil(
            EPUBImportMetadata(title: nil, authors: [], language: nil, positionCount: 1, coverJPEG: nil).authorLine
        )
    }
}
