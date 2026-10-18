//
//  EPUBImportInspector.swift
//  Paperbound
//
//  Looks inside an EPUB before it is allowed onto the shelf: can it be
//  opened, is it DRM-protected, and what do its title, authors, language and
//  cover say.
//
//  It opens the book through `EPUBReadingEngine` rather than Readium directly,
//  so import and the reader agree exactly on what counts as protected or
//  unreadable — a book that passes here is a book the reader will open.
//

import Foundation
import ReadiumShared
import UIKit

struct EPUBImportMetadata {
    var title: String?
    var authors: [String]
    var language: String?
    /// Readium positions; what the reader calls pages for an EPUB.
    var positionCount: Int
    /// JPEG thumbnail of the publication's declared cover, if it has one.
    var coverJPEG: Data?

    /// "A, B and C" — the shelf has room for one line of credit.
    var authorLine: String? {
        let names = authors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return ListFormatter.localizedString(byJoining: names)
    }
}

@MainActor
enum EPUBImportInspector {

    /// Opens the EPUB at `url` and reads its metadata and cover.
    ///
    /// Throws `ReadingEngineError.encryptedDocument` for Adobe ADEPT, LCP and
    /// Apple FairPlay books, and `.unreadableDocument` for anything that is not
    /// a well-formed, zipped EPUB.
    static func inspect(_ url: URL, coverMaxWidth: CGFloat = 480) async throws -> EPUBImportMetadata {
        let engine = try EPUBReadingEngine(documentID: UUID(), fileURL: url, initialLocation: nil)
        try await engine.open()
        defer { engine.close() }

        guard let publication = engine.publication else {
            throw ReadingEngineError.unreadableDocument(url)
        }
        let metadata = publication.metadata

        // Readium decodes the cover at full size; the shelf needs a thumbnail
        // the size of a PDF first-page render, and the same JPEG encoding.
        var coverJPEG: Data?
        let maxSize = CGSize(width: coverMaxWidth, height: coverMaxWidth * 2)
        if case let .success(image?) = await publication.coverFitting(maxSize: maxSize) {
            coverJPEG = jpegThumbnail(of: image)
        }

        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EPUBImportMetadata(
            title: (title?.isEmpty ?? true) ? nil : title,
            authors: metadata.authors.map(\.name),
            language: metadata.languages.first,
            positionCount: engine.pageCount,
            coverJPEG: coverJPEG
        )
    }

    /// Redraws onto an opaque white canvas so transparent PNG covers do not
    /// turn black in JPEG.
    private static func jpegThumbnail(of image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: 0.8)
    }
}
