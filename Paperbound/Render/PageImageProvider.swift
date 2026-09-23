//
//  PageImageProvider.swift
//  Paperbound
//
//  Orchestrates one page's journey:
//
//      engine rasterizes  →  generator produces damage  →  compositor builds
//      the physical sheet  →  cache keeps it  →  reader shows it
//
//  The rasterize-and-composite step always runs off the main thread. The main
//  actor only ever computes keys and hands back finished bitmaps.
//

import CoreGraphics
import Foundation

/// How many pixels a sheet is rendered at.
///
/// Shared by the page view and the prefetcher on purpose: if the two disagreed
/// by even one pixel bucket, every prefetch would warm a key the visible page
/// never looks up, and the cache would quietly do nothing.
enum PageRenderScale {

    /// Above roughly four megapixels the composite costs more than it shows,
    /// and on a 3× phone a full-bleed sheet would sail past it.
    static let maximumPixels: CGFloat = 4_200_000

    static func scale(for displaySize: CGSize, displayScale: CGFloat) -> CGFloat {
        let requested = max(1, displayScale)
        guard displaySize.width > 0, displaySize.height > 0 else { return requested }
        let pixels = displaySize.width * displaySize.height * requested * requested
        guard pixels > maximumPixels else { return requested }
        return max(1, sqrt(maximumPixels / (displaySize.width * displaySize.height)))
    }

    static func pixelSize(for displaySize: CGSize, displayScale: CGFloat) -> CGSize {
        let factor = scale(for: displaySize, displayScale: displayScale)
        return CGSize(width: displaySize.width * factor, height: displaySize.height * factor)
    }
}

@MainActor
final class PageImageProvider {

    private let engine: any ReadingEngine
    private let bookID: UUID
    private let bookSeed: UInt64
    private let cache = PageRenderCache()
    private var inFlight: [String: Task<CGImage, Error>] = [:]

    init(engine: any ReadingEngine, bookID: UUID, bookSeed: UInt64) {
        self.engine = engine
        self.bookID = bookID
        self.bookSeed = bookSeed
    }

    // MARK: - Public surface

    /// Cached bitmap if one is ready right now. Lets SwiftUI draw the correct
    /// page on the very first frame after a swipe instead of flashing a
    /// placeholder for pages it has already built.
    func cachedImage(
        for location: ReadingLocation,
        environment: ReadingEnvironment,
        pixelSize: CGSize,
        spineShadowScale: Double = 1.0,
        spine: PageEdge? = nil,
        safeFraction: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> CGImage? {
        cache.image(for: key(
            for: location,
            environment: environment,
            pixelSize: pixelSize,
            spineShadowScale: spineShadowScale,
            spine: spine
        ))
    }

    func image(
        for location: ReadingLocation,
        environment: ReadingEnvironment,
        pixelSize: CGSize,
        spineShadowScale: Double = 1.0,
        spine spineOverride: PageEdge? = nil,
        safeFraction: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) async throws -> CGImage {
        let renderKey = key(
            for: location,
            environment: environment,
            pixelSize: pixelSize,
            spineShadowScale: spineShadowScale,
            spine: spineOverride
        )

        if let cached = cache.image(for: renderKey) { return cached }

        let identifier = renderKey.stringValue
        if let existing = inFlight[identifier] {
            return try await existing.value
        }

        // Everything the background task needs is resolved on the main actor
        // first, so the detached work touches no isolated state.
        let pixelWidth = CGFloat(renderKey.pixelWidth)
        let pixelHeight = CGFloat(renderKey.pixelHeight)
        let surface = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        let sheetRect = PageCompositor.sheetRect(in: surface, presentation: environment.presentation)
        let stablePageID = engine.stablePageID(for: location)
        // A caller drawing a spread says which edge is bound, because that
        // depends on which side of the gutter the leaf is on, not on its index.
        let spine = spineOverride ?? DamageGenerator.spineEdge(forPageIndex: location.pdfPageIndex ?? 0)
        let pageAspectRatio = engine.aspectRatio(at: location)
        let contentRect = PageCompositor.contentRect(
            in: sheetRect,
            presentation: environment.presentation,
            pageAspectRatio: pageAspectRatio,
            safeFraction: safeFraction,
            extraInset: environment.marginalia.marginWidth
        )
        let condition = DamageGenerator.generate(
            documentID: bookID,
            bookSeed: bookSeed,
            stablePageID: stablePageID,
            environment: environment,
            spine: spine
        )
        // Its own generator on its own salted stream, so adding annotation to a
        // book never moves a tear that is already there.
        let marginalia = MarginaliaGenerator.generate(
            documentID: bookID,
            bookSeed: bookSeed,
            stablePageID: stablePageID,
            environment: environment,
            // Measured off the very rects the compositor will clip against, so
            // placement and clipping cannot disagree.
            frame: MarginaliaGenerator.Frame(sheet: sheetRect, content: contentRect)
        )
        let textureSeed = StableHash.combine(
            StableHash.hash(bookID),
            bookSeed,
            StableHash.hash(stablePageID)
        )
        let engineRef = engine

        let task = Task.detached(priority: .userInitiated) { () throws -> CGImage in
            // Rasterize at the text block's size, not the sheet's: the sheet
            // now fills a screen whose shape is not the document's.
            let content = try? await engineRef.renderPage(at: location, pixelSize: contentRect.size)
            try Task.checkCancellation()

            let request = PageCompositionRequest(
                content: content,
                pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
                environment: environment,
                condition: condition,
                marginalia: marginalia,
                spine: spine,
                textureSeed: textureSeed,
                pageAspectRatio: pageAspectRatio,
                safeFraction: safeFraction,
                spineShadowScale: spineShadowScale
            )
            guard let composed = PageCompositor.shared.composite(request) else {
                throw ReadingEngineError.renderFailed("compositor produced no image for \(stablePageID)")
            }
            return composed
        }

        inFlight[identifier] = task
        defer { inFlight[identifier] = nil }

        let image = try await task.value
        cache.store(image, for: renderKey)
        return image
    }

    /// Warms neighbouring sheets so a page turn never waits on a rasterizer.
    func prefetch(
        around location: ReadingLocation,
        radius: Int,
        environment: ReadingEnvironment,
        pixelSize: CGSize,
        spineShadowScale: Double = 1.0
    ) {
        for neighbour in engine.locationsAround(location, radius: radius) {
            let renderKey = key(
                for: neighbour,
                environment: environment,
                pixelSize: pixelSize,
                spineShadowScale: spineShadowScale
            )
            guard cache.image(for: renderKey) == nil,
                  inFlight[renderKey.stringValue] == nil
            else { continue }

            Task { [weak self] in
                _ = try? await self?.image(
                    for: neighbour,
                    environment: environment,
                    pixelSize: pixelSize,
                    spineShadowScale: spineShadowScale
                )
            }
        }
    }

    /// Called when the environment changes so stale sheets are never shown.
    func invalidateAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        cache.removeAll()
    }

    /// The damage descriptors for one sheet, for inspection and tests.
    func conditionData(for location: ReadingLocation, environment: ReadingEnvironment) -> PageConditionData {
        DamageGenerator.generate(
            documentID: bookID,
            bookSeed: bookSeed,
            stablePageID: engine.stablePageID(for: location),
            environment: environment,
            spine: DamageGenerator.spineEdge(forPageIndex: location.pdfPageIndex ?? 0)
        )
    }

    // MARK: - Keys

    private func key(
        for location: ReadingLocation,
        environment: ReadingEnvironment,
        pixelSize: CGSize,
        spineShadowScale: Double,
        spine: PageEdge? = nil
    ) -> PageRenderKey {
        // Bucket to 8px: layout jitter of a point or two must not invalidate a
        // perfectly good bitmap.
        let width = max(8, Int((pixelSize.width / 8).rounded()) * 8)
        let height = max(8, Int((pixelSize.height / 8).rounded()) * 8)
        return PageRenderKey(
            stablePageID: engine.stablePageID(for: location),
            renderIdentity: environment.renderIdentity,
            pixelWidth: width,
            pixelHeight: height,
            spineShadowBucket: Int((spineShadowScale * 10).rounded()),
            spine: spine ?? DamageGenerator.spineEdge(forPageIndex: location.pdfPageIndex ?? 0)
        )
    }
}
