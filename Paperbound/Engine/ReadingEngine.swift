//
//  ReadingEngine.swift
//  Paperbound
//
//  The seam between "what the document says" and "how the page looks".
//  Engines own content and navigation. They never own appearance, wear, or
//  the number of surfaces on screen.
//
//  Adding EPUB means adding a second conformance (backed by the Readium
//  navigator) — not changing the reader, the compositor or the cache.
//

import CoreGraphics
import Foundation

@MainActor
protocol ReadingEngine: AnyObject {

    // MARK: Identity

    var documentID: UUID { get }
    var format: BookFormat { get }
    var capabilities: ReaderCapabilities { get }

    /// Number of addressable sheets. For reflowable formats this is the count
    /// of content segments, not rendered screens.
    var pageCount: Int { get }
    var isOpen: Bool { get }

    // MARK: Lifecycle

    func open() async throws
    func close()

    // MARK: Navigation

    func currentLocation() -> ReadingLocation
    func go(to location: ReadingLocation) async throws

    /// Returns `nil` at the ends of the document.
    func location(byAdvancing location: ReadingLocation, pages delta: Int) -> ReadingLocation?

    /// 0…1 through the whole document, for progress UI.
    func normalizedProgress(for location: ReadingLocation) -> Double

    /// Monotonic sort key so bookmarks from any format order correctly.
    func orderKey(for location: ReadingLocation) -> Double

    /// The first addressable location in the document.
    func firstLocation() -> ReadingLocation

    // MARK: Content

    func search(_ text: String) async throws -> [ReadingSearchResult]
    func outline() -> [OutlineItem]
    func text(at location: ReadingLocation) -> String?
    func label(for location: ReadingLocation) -> String

    // MARK: Rendering

    /// Identity of the *sheet* that wear attaches to.
    ///
    /// For fixed layout this is the page index, which never moves.
    ///
    /// For reflowable content the rule Paperbound uses is: wear belongs to a
    /// stable content segment (the spine item plus a coarse progression
    /// bucket), *not* to a rendered screen. Changing the font size therefore
    /// reflows the text under the same tear rather than shuffling the tears.
    func stablePageID(for location: ReadingLocation) -> String

    /// height / width of the sheet at this location.
    func aspectRatio(at location: ReadingLocation) -> Double

    /// Rasterizes the document page. Runs off the main thread.
    nonisolated func renderPage(at location: ReadingLocation, pixelSize: CGSize) async throws -> CGImage
}

extension ReadingEngine {
    /// Convenience used by the reader's paging model.
    func locationsAround(_ location: ReadingLocation, radius: Int) -> [ReadingLocation] {
        var result: [ReadingLocation] = []
        for delta in -radius...radius {
            if delta == 0 {
                result.append(location)
            } else if let neighbour = self.location(byAdvancing: location, pages: delta) {
                result.append(neighbour)
            }
        }
        return result
    }
}
