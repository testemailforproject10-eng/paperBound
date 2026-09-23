//
//  ReadingLocation.swift
//  Paperbound
//
//  A typed position inside a document. PDF page indices and reflowable
//  locators are genuinely different things, so the app never pretends every
//  format is a numbered screen.
//

import Foundation

enum ReadingLocation: Codable, Hashable, Sendable {
    /// Fixed-layout position. `yOffset` is 0…1 within the page, used to restore
    /// a scroll position inside a tall page.
    case pdfPage(index: Int, yOffset: Double)

    /// Reflowable position. The resource `href` plus progression inside it is
    /// preserved across font and margin changes; a rendered page number is not.
    case epubLocator(href: String, progression: Double, totalProgression: Double?)

    /// Used before a document has reported a real position.
    case start

    var pdfPageIndex: Int? {
        if case let .pdfPage(index, _) = self { return index }
        return nil
    }

    /// A short human label for the progress bar and bookmark rows.
    func displayLabel(pageCount: Int) -> String {
        switch self {
        case let .pdfPage(index, _):
            return pageCount > 0 ? "Page \(index + 1) of \(pageCount)" : "Page \(index + 1)"
        case let .epubLocator(href, progression, total):
            if let total {
                return "\(Int((total * 100).rounded()))% · \(href)"
            }
            return "\(Int((progression * 100).rounded()))% of \(href)"
        case .start:
            return "Beginning"
        }
    }
}

// MARK: - Search

struct ReadingSearchResult: Identifiable, Hashable, Sendable {
    let id: UUID
    var location: ReadingLocation
    /// The matched text with a little context on either side.
    var snippet: String
    /// Range of the match inside `snippet`, for highlighting.
    var matchRange: Range<Int>
    var pageLabel: String

    init(
        id: UUID = UUID(),
        location: ReadingLocation,
        snippet: String,
        matchRange: Range<Int>,
        pageLabel: String
    ) {
        self.id = id
        self.location = location
        self.snippet = snippet
        self.matchRange = matchRange
        self.pageLabel = pageLabel
    }
}

// MARK: - Outline

struct OutlineItem: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var location: ReadingLocation
    var depth: Int

    init(id: UUID = UUID(), title: String, location: ReadingLocation, depth: Int) {
        self.id = id
        self.title = title
        self.location = location
        self.depth = depth
    }
}

// MARK: - Capabilities

/// What the *current* engine can actually do. Reader UI hides controls that the
/// open document cannot honour rather than showing dead buttons.
struct ReaderCapabilities: OptionSet, Sendable {
    let rawValue: Int

    static let textSelection  = ReaderCapabilities(rawValue: 1 << 0)
    static let fullTextSearch = ReaderCapabilities(rawValue: 1 << 1)
    static let outline        = ReaderCapabilities(rawValue: 1 << 2)
    static let continuousZoom = ReaderCapabilities(rawValue: 1 << 3)
    static let reflowTypography = ReaderCapabilities(rawValue: 1 << 4)
    static let pageLabels     = ReaderCapabilities(rawValue: 1 << 5)
    static let speech         = ReaderCapabilities(rawValue: 1 << 6)

    static let fixedLayout: ReaderCapabilities = [
        .textSelection, .fullTextSearch, .outline, .continuousZoom, .pageLabels, .speech
    ]
}

// MARK: - Errors

enum ReadingEngineError: LocalizedError {
    case fileMissing(URL)
    case unreadableDocument(URL)
    case encryptedDocument
    case locationOutOfBounds(ReadingLocation)
    case renderFailed(String)
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case let .fileMissing(url):
            return "The file \(url.lastPathComponent) is no longer in the library folder."
        case let .unreadableDocument(url):
            return "\(url.lastPathComponent) could not be opened as a document."
        case .encryptedDocument:
            return "This document is password protected or uses DRM, which Paperbound cannot open."
        case .locationOutOfBounds:
            return "That position is outside the document."
        case let .renderFailed(reason):
            return "The page could not be drawn: \(reason)"
        case let .unsupportedFormat(ext):
            return "Paperbound has no reading engine for .\(ext) files yet."
        }
    }
}
