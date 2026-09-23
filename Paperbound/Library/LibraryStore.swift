//
//  LibraryStore.swift
//  Paperbound
//
//  Owns the app's managed copy of every imported file.
//
//  The originals are copied in and then never written to. Wear, bookmarks and
//  environments live entirely in SwiftData; deleting the whole database would
//  leave every source file byte-identical to the day it was imported.
//

import CryptoKit
import Foundation
import PDFKit
import SwiftData
import UIKit
import UniformTypeIdentifiers

enum LibraryError: LocalizedError {
    case unsupportedType(String)
    case accessDenied(URL)
    case copyFailed(String)
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case let .unsupportedType(ext):
            return "Paperbound cannot import .\(ext) files yet."
        case let .accessDenied(url):
            return "Permission to read \(url.lastPathComponent) was refused."
        case let .copyFailed(reason):
            return "The file could not be copied into your library: \(reason)"
        case .storageUnavailable:
            return "The library folder could not be created."
        }
    }
}

struct ImportOutcome {
    var book: Book
    /// True when an identical file was already in the library and was reused.
    var wasAlreadyPresent: Bool
}

@MainActor
final class LibraryStore {

    let booksDirectory: URL

    init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent("Books", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.booksDirectory = directory
    }

    private init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.booksDirectory = directory
    }

    /// Last-resort store used only when Application Support is unavailable, so
    /// that the app can present a readable failure instead of trapping at launch.
    static func unavailable() -> LibraryStore {
        LibraryStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("PaperboundBooks", isDirectory: true)
        )
    }

    // MARK: - Paths

    func fileURL(for book: Book) -> URL {
        booksDirectory.appendingPathComponent(book.fileName)
    }

    func fileExists(for book: Book) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: book).path)
    }

    // MARK: - Import

    @discardableResult
    func importFile(at sourceURL: URL, into context: ModelContext) throws -> ImportOutcome {
        let ext = sourceURL.pathExtension.lowercased()
        guard let format = BookFormat.from(fileExtension: ext) else {
            throw LibraryError.unsupportedType(ext.isEmpty ? "unknown" : ext)
        }
        guard format == .pdf else {
            // EPUB reaches the library only once a Readium-backed engine exists;
            // importing a file the reader cannot open would be a dead end.
            throw ReadingEngineError.unsupportedFormat(ext)
        }

        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        } catch {
            throw LibraryError.accessDenied(sourceURL)
        }

        let fingerprint = Self.fingerprint(for: data)

        // Re-importing the same file should return the existing book, wear and
        // reading position intact, rather than silently creating a duplicate.
        if let existing = try? context.fetch(
            FetchDescriptor<Book>(predicate: #Predicate { $0.contentFingerprint == fingerprint })
        ).first {
            return ImportOutcome(book: existing, wasAlreadyPresent: true)
        }

        let bookID = UUID()
        let destinationName = "\(bookID.uuidString).\(format.fileExtension)"
        let destination = booksDirectory.appendingPathComponent(destinationName)

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try data.write(to: destination, options: [.atomic])
        } catch {
            throw LibraryError.copyFailed(error.localizedDescription)
        }

        let metadata = PDFReadingEngine.metadata(for: destination)
        let fallbackTitle = sourceURL.deletingPathExtension().lastPathComponent

        let book = Book(
            id: bookID,
            title: metadata.title ?? fallbackTitle,
            author: metadata.author,
            fileName: destinationName,
            format: format,
            contentFingerprint: fingerprint
        )
        book.pageCount = metadata.pageCount
        book.coverData = Self.renderCover(for: destination)

        context.insert(book)
        try context.save()

        return ImportOutcome(book: book, wasAlreadyPresent: false)
    }

    // MARK: - Delete

    func delete(_ book: Book, from context: ModelContext) throws {
        let url = fileURL(for: book)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        context.delete(book)
        try context.save()
    }

    /// Removes files in the managed folder that no longer belong to any book.
    func removeOrphanedFiles(knownBooks: [Book]) {
        let known = Set(knownBooks.map(\.fileName))
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: booksDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where !known.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    static func fingerprint(for data: Data) -> String {
        // Hashing the head plus the length is enough to catch re-imports of the
        // same file without reading a 400MB scan end to end on the main actor.
        let head = data.prefix(1 << 20)
        var hasher = SHA256()
        hasher.update(data: head)
        withUnsafeBytes(of: UInt64(data.count).littleEndian) { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func renderCover(for url: URL, maxWidth: CGFloat = 480) -> Data? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let scale = min(1, maxWidth / bounds.width)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            cg.scaleBy(x: size.width / bounds.width, y: size.height / bounds.height)
            page.draw(with: .cropBox, to: cg)
        }
        return image.jpegData(compressionQuality: 0.8)
    }

    /// Content types the file importer should offer.
    static var importableTypes: [UTType] {
        [.pdf]
    }
}
