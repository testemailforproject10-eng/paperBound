//
//  DemoEPUB.swift
//  Paperbound
//
//  DEBUG only. Puts the sample EPUB ("The Lamplighter's Almanac", the same
//  book as the test fixture) in the library, so `-paperbound-demo-epub` can
//  open the EPUB reader straight from launch for screenshots and on-screen
//  checks. The bytes live in the generated DemoEPUBData.swift.
//

#if DEBUG
import Foundation
import SwiftData

@MainActor
enum DemoEPUB {

    static let launchArgument = "-paperbound-demo-epub"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Imports the sample through the normal EPUB import path (so it gets the
    /// real cover and metadata), or returns it if it is already on the shelf.
    /// Re-importing is cheap: the content fingerprint finds the existing book.
    static func installIfNeeded(store: LibraryStore, context: ModelContext) async throws -> Book {
        guard let data = Data(base64Encoded: sampleBase64, options: .ignoreUnknownCharacters) else {
            throw LibraryError.copyFailed("the embedded demo EPUB is damaged")
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("The Lamplighter's Almanac.epub")
        try data.write(to: temporary, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: temporary) }

        let outcome = try await store.importBook(at: temporary, into: context)
        // A file deleted from under the record (e.g. "Clean up unused files"
        // after a crash) would leave a book that cannot open; start over.
        if !store.fileExists(for: outcome.book) {
            try store.delete(outcome.book, from: context)
            return try await store.importBook(at: temporary, into: context).book
        }
        return outcome.book
    }
}
#endif
