//
//  EPUBReadingEngine.swift
//  Paperbound
//
//  Readium-backed engine for reflowable EPUB.
//
//  Unlike the PDF engine this one never draws a page: Readium's
//  `EPUBNavigatorViewController` lays the text out live in a web view, so the
//  engine's job is content and bookkeeping — opening the publication, the
//  positions list, the table of contents, search, and turning Readium
//  `Locator`s into `ReadingLocation`s the rest of the app can store and sort.
//
//  "Pages" here are Readium *positions*: stable ~1,024-character segments of
//  the reading order. They do not change with the font size, which is exactly
//  why bookmarks, progress and wear key off them instead of on-screen pages.
//

import CoreGraphics
import Foundation
import ReadiumShared
import ReadiumStreamer

@MainActor
final class EPUBReadingEngine: ReadingEngine {

    let documentID: UUID
    let fileURL: URL

    /// The opened publication, handed to `EPUBNavigatorViewController`.
    /// `nil` until `open()` succeeds and again after `close()`.
    private(set) var publication: Publication?

    /// Readium's positions list, in reading order. Loaded once on open; this
    /// is what `pageCount`, labels and `location(byAdvancing:)` are built on.
    private(set) var positions: [Locator] = []

    private var location: ReadingLocation
    private var cachedOutline: [OutlineItem] = []
    /// Text of positions already extracted for speech, keyed by position index.
    private var textCache: [Int: String] = [:]

    var format: BookFormat { .epub }
    var capabilities: ReaderCapabilities {
        [.reflowTypography, .textSelection, .fullTextSearch, .outline, .speech]
    }
    var pageCount: Int { positions.count }
    private(set) var isOpen = false

    /// Book title from the OPF metadata, once open.
    var title: String? { publication?.metadata.title }

    init(documentID: UUID, fileURL: URL, initialLocation: ReadingLocation?) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ReadingEngineError.fileMissing(fileURL)
        }
        self.documentID = documentID
        self.fileURL = fileURL
        // Only an EPUB position means anything here; a stray PDF location (or
        // `.start`) is replaced by the first position once the book is open.
        if let initialLocation, initialLocation.epubHref != nil {
            self.location = initialLocation
        } else {
            self.location = .start
        }
    }

    // MARK: - Lifecycle

    func open() async throws {
        guard !isOpen else { return }
        guard let url = FileURL(url: fileURL) else {
            throw ReadingEngineError.unreadableDocument(fileURL)
        }

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let asset: Asset
        switch await assetRetriever.retrieve(url: url) {
        case let .success(retrieved):
            asset = retrieved
        case .failure:
            throw ReadingEngineError.unreadableDocument(fileURL)
        }
        guard asset.format.conformsTo(.epub) else {
            throw ReadingEngineError.unreadableDocument(fileURL)
        }
        // Readium recognises Adobe ADEPT and LCP itself (below), but not Apple
        // FairPlay, whose marker is a `sinf.xml`. Without this check a FairPlay
        // book would "open" and render ciphertext.
        if case let .container(containerAsset) = asset,
           let sinf = AnyURL(path: "META-INF/sinf.xml"),
           containerAsset.container.entries.contains(sinf) {
            throw ReadingEngineError.encryptedDocument
        }

        let opener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
        // No user interaction: Paperbound has no DRM unlocking to prompt for.
        let publication: Publication
        switch await opener.open(asset: asset, allowUserInteraction: false) {
        case let .success(opened):
            publication = opened
        case .failure:
            throw ReadingEngineError.unreadableDocument(fileURL)
        }
        // A protected book (ADEPT, LCP) opens as a "restricted" publication
        // whose resources cannot be read. Refuse it rather than show nothing.
        if publication.isRestricted {
            publication.close()
            throw ReadingEngineError.encryptedDocument
        }

        let positions = (try? await publication.positions().get()) ?? []
        guard !positions.isEmpty else {
            publication.close()
            throw ReadingEngineError.unreadableDocument(fileURL)
        }

        self.publication = publication
        self.positions = positions
        self.cachedOutline = await Self.buildOutline(for: publication)
        if location.epubHref == nil {
            location = ReadingLocation(locator: positions[0])
        }
        isOpen = true
    }

    func close() {
        publication?.close()
        publication = nil
        positions = []
        cachedOutline = []
        textCache = [:]
        isOpen = false
    }

    // MARK: - Navigation

    func currentLocation() -> ReadingLocation { location }

    func go(to location: ReadingLocation) async throws {
        guard location.epubHref != nil else {
            throw ReadingEngineError.locationOutOfBounds(location)
        }
        self.location = location
    }

    func location(byAdvancing location: ReadingLocation, pages delta: Int) -> ReadingLocation? {
        guard let index = positionIndex(for: location) else { return nil }
        let next = index + delta
        guard next >= 0, next < positions.count else { return nil }
        return ReadingLocation(locator: positions[next])
    }

    func normalizedProgress(for location: ReadingLocation) -> Double {
        guard !positions.isEmpty, let index = positionIndex(for: location) else { return 0 }
        // Readium's totalProgression is where a position *starts*, so the last
        // position reports a little under 1. Snap it, so reaching the end of
        // the book counts as finishing it — the PDF engine does the same.
        if index == positions.count - 1 { return 1 }
        if let total = location.epubTotalProgression {
            return min(max(total, 0), 1)
        }
        return positions[index].locations.totalProgression ?? Double(index) / Double(positions.count)
    }

    /// Progression × 10⁶, as `Bookmark.orderKey` documents. Locators inside
    /// one position still sort correctly because the progression is exact.
    func orderKey(for location: ReadingLocation) -> Double {
        if let total = location.epubTotalProgression {
            return total * 1_000_000
        }
        guard let index = positionIndex(for: location) else { return 0 }
        let total = positions[index].locations.totalProgression
            ?? Double(index) / Double(max(1, positions.count))
        return total * 1_000_000
    }

    func firstLocation() -> ReadingLocation {
        if let first = positions.first {
            return ReadingLocation(locator: first)
        }
        return .start
    }

    /// The 0-based index in `positions` of the position containing `location`.
    ///
    /// Uses the locator's own position number when it has one, otherwise the
    /// last position in the same resource that starts at or before it.
    func positionIndex(for location: ReadingLocation) -> Int? {
        guard !positions.isEmpty else { return nil }
        guard let locator = location.readiumLocator else {
            return location == .start ? 0 : nil
        }
        if let position = locator.locations.position,
           position >= 1, position <= positions.count,
           positions[position - 1].href.isEquivalentTo(locator.href) {
            return position - 1
        }
        let progression = locator.locations.progression ?? 0
        var match: Int?
        for (index, candidate) in positions.enumerated()
        where candidate.href.isEquivalentTo(locator.href) {
            if match == nil || (candidate.locations.progression ?? 0) <= progression + 1e-9 {
                match = index
            } else {
                break
            }
        }
        return match
    }

    // MARK: - Content

    /// Full-text search through Readium's search service.
    func search(_ text: String) async throws -> [ReadingSearchResult] {
        try await search(text, limit: 500)
    }

    func search(_ text: String, limit: Int) async throws -> [ReadingSearchResult] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2, let publication else { return [] }
        let iterator: SearchIterator
        switch await publication.search(query: query) {
        case let .success(found):
            iterator = found
        case let .failure(error):
            throw ReadingEngineError.renderFailed("Search failed: \(error)")
        }
        // The iterator frees itself on deinit (`close()` is deprecated in 3.9).

        var results: [ReadingSearchResult] = []
        while results.count < limit, !Task.isCancelled {
            guard case let .success(page) = await iterator.next(), let page else { break }
            for locator in page.locators {
                let location = ReadingLocation(locator: locator)
                let before = Self.collapsingWhitespace(locator.text.before ?? "")
                let match = Self.collapsingWhitespace(locator.text.highlight ?? query)
                let after = Self.collapsingWhitespace(locator.text.after ?? "")
                let snippet = before + match + after
                results.append(
                    ReadingSearchResult(
                        location: location,
                        snippet: snippet,
                        matchRange: before.count..<(before.count + match.count),
                        pageLabel: label(for: location)
                    )
                )
                if results.count >= limit { break }
            }
        }
        return results
    }

    func outline() -> [OutlineItem] { cachedOutline }

    /// Text already extracted for this position by `loadText(at:)`.
    ///
    /// Readium reads resources asynchronously and this protocol method is
    /// synchronous, so it can only answer from the cache. Callers that need
    /// text now (read aloud) should `await loadText(at:)` instead.
    func text(at location: ReadingLocation) -> String? {
        guard let index = positionIndex(for: location) else { return nil }
        return textCache[index]
    }

    /// The text of the position containing `location`, read from the
    /// publication with Readium's content iterator.
    func loadText(at location: ReadingLocation) async -> String? {
        guard let publication, let index = positionIndex(for: location) else { return nil }
        if let cached = textCache[index] { return cached }

        let start = positions[index]
        let end = index + 1 < positions.count ? positions[index + 1] : nil
        guard let iterator = publication.content(from: start)?.iterator() else { return nil }

        var pieces: [String] = []
        while let element = try? await iterator.next() {
            // Stop at the next position: same resource, further along, or a
            // different resource altogether.
            if let end, Self.locator(element.locator, isAtOrAfter: end) { break }
            if !element.locator.href.isEquivalentTo(start.href) { break }
            if let text = (element as? TextualContentElement)?.text, !text.isEmpty {
                pieces.append(text)
            }
        }
        let text = pieces.joined(separator: "\n")
        guard !text.isEmpty else { return nil }
        textCache[index] = text
        return text
    }

    func label(for location: ReadingLocation) -> String {
        guard let index = positionIndex(for: location) else { return "—" }
        return "\(index + 1)"
    }

    // MARK: - Rendering

    /// Spine item plus a coarse progression bucket, per the rule in
    /// `ReadingEngine.stablePageID`: a font change reflows text under the same
    /// wear instead of shuffling it.
    func stablePageID(for location: ReadingLocation) -> String {
        guard case let .epubLocator(href, progression, _, _) = location else { return "epub:start" }
        let bucket = min(7, max(0, Int(progression * 8)))
        return "epub:\(href)#\(bucket)"
    }

    /// Reflowable text has no intrinsic page shape. The value is only used by
    /// the layout coordinator to choose single page versus spread, so report
    /// a portrait book page, the same fallback the PDF engine uses.
    func aspectRatio(at location: ReadingLocation) -> Double {
        792.0 / 612.0
    }

    /// EPUB is drawn live by the Readium navigator, so there is nothing to
    /// rasterize. Snapshotting the web view for page effects is Phase 6.
    nonisolated func renderPage(at location: ReadingLocation, pixelSize: CGSize) async throws -> CGImage {
        throw ReadingEngineError.renderFailed("EPUB pages are drawn live by the reader, not rendered as images.")
    }

    // MARK: - Helpers

    /// Flattens the nested TOC into `OutlineItem`s with depth, resolving each
    /// link to a locator so the contents panel can jump straight to it.
    private static func buildOutline(for publication: Publication) async -> [OutlineItem] {
        let toc = (try? await publication.tableOfContents().get()) ?? []
        var items: [OutlineItem] = []

        func append(_ links: [Link], depth: Int) async {
            for link in links {
                let title = link.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !title.isEmpty, let locator = await publication.locate(link) {
                    items.append(
                        OutlineItem(title: title, location: ReadingLocation(locator: locator), depth: depth)
                    )
                }
                await append(link.children, depth: depth + 1)
            }
        }
        await append(toc, depth: 0)
        return items
    }

    private static func locator(_ locator: Locator, isAtOrAfter other: Locator) -> Bool {
        guard locator.href.isEquivalentTo(other.href) else { return false }
        return (locator.locations.progression ?? 0) >= (other.locations.progression ?? 0)
    }

    private static func collapsingWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
