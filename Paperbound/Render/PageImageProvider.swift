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

    static func pixelSize(for displaySize: CGSize, displayScale: CGFloat, enchanted: Bool = false) -> CGSize {
        // Both leaves use the same cap before rasterization. The 36 bytes per
        // pigment pixel plus moisture/alignment fit two sessions inside 64 MB.
        let cap: CGFloat = enchanted ? 850_000 : maximumPixels
        let factor = max(1, min(scale(for: displaySize, displayScale: displayScale),
                                sqrt(cap / max(1, displaySize.width * displaySize.height))))
        let requested = CGSize(width: displaySize.width * factor, height: displaySize.height * factor)
        guard enchanted else { return requested }
        func size(_ scale: CGFloat) -> CGSize {
            bucketedPixelSize(CGSize(width: displaySize.width * scale, height: displaySize.height * scale))
        }
        func fits(_ scale: CGFloat) -> Bool {
            let pixels = size(scale)
            return InkTextureLayout(width: Int(pixels.width), height: Int(pixels.height)).fitsSpread
        }
        if fits(factor) { return size(factor) }
        // Choose the largest common scale that fits AFTER cache bucketing.
        // The one-pixel-per-point floor remains the minimum quality boundary.
        var lower: CGFloat = 1, upper = factor
        for _ in 0..<20 {
            let candidate = (lower + upper) / 2
            if fits(candidate) { lower = candidate } else { upper = candidate }
        }
        return size(lower)
    }

    static func bucketedPixelSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(8, (size.width / 8).rounded() * 8),
               height: max(8, (size.height / 8).rounded() * 8))
    }
}

/// All geometry that determines the page image. The same value is used for
/// display, cache lookup, and prefetch so those paths cannot diverge.
struct PageImageRequest: Sendable {
    let location: ReadingLocation
    let pixelSize: CGSize
    let spineShadowScale: Double
    let spine: PageEdge
    let safeFraction: CGRect
    let reservedRegions: [CGRect]
}

private struct InFlightPageRender {
    let id: UUID
    let task: Task<PageRenderResult, Error>
}

@MainActor
final class PageImageProvider {

    /// Number of cache-miss preparation jobs; overlay changes must leave this unchanged.
    private(set) var preparationCount = 0
    private let engine: any ReadingEngine
    private let bookID: UUID
    private let bookSeed: UInt64
    private let cache = PageRenderCache()
    private var inFlight: [String: InFlightPageRender] = [:]
    private var renderGeneration = 0
    private var prefetchTask: Task<Void, Never>?
    private var visibleDemand: [String: Int] = [:]
    private var consumers: [String: Set<UUID>] = [:]
    private var paperObservers: [String: [UUID: @MainActor (CGImage) -> Void]] = [:]
    private var pendingPaper: [String: CGImage] = [:]
    private var speculativeFlights: Set<String> = []

    init(engine: any ReadingEngine, bookID: UUID, bookSeed: UInt64) {
        self.engine = engine
        self.bookID = bookID
        self.bookSeed = bookSeed
    }

    // MARK: - Public surface

    /// Cached bitmap if one is ready right now. Lets SwiftUI draw the correct
    /// page on the very first frame after a swipe instead of flashing a
    /// placeholder for pages it has already built.
    func cachedPage(for request: PageImageRequest, environment: ReadingEnvironment) -> PageRenderResult? {
        cache.page(for: key(for: request, environment: environment))
    }

    func page(
        for request: PageImageRequest,
        environment: ReadingEnvironment,
        speculative: Bool = false,
        paperReady: (@MainActor (CGImage) -> Void)? = nil
    ) async throws -> PageRenderResult {
        let environment = environment.effectsOnly
        let renderKey = key(for: request, environment: environment)
        let generation = renderGeneration

        let identifier = renderKey.stringValue
        InkMetrics.trace("Page request \(renderKey.stablePageID) \(renderKey.pixelWidth)x\(renderKey.pixelHeight) speculative=\(speculative)")
        let observerID = UUID()
        consumers[identifier, default: []].insert(observerID)
        if !speculative {
            visibleDemand[identifier, default: 0] += 1
            for (key, flight) in inFlight where key != identifier && visibleDemand[key] == nil {
                flight.task.cancel()
            }
            speculativeFlights.remove(identifier)
        }
        if let paperReady {
            paperObservers[identifier, default: [:]][observerID] = paperReady
            if let paper = pendingPaper[identifier] { paperReady(paper) }
        }
        defer {
            releaseRequest(identifier, observerID: observerID, speculative: speculative)
        }

        if let cached = cache.page(for: renderKey, promote: !speculative) { return cached }

        if let existing = inFlight[identifier], !existing.task.isCancelled {
            let result = try await waitForRender(existing.task, identifier: identifier,
                                                observerID: observerID, speculative: speculative)
            guard generation == renderGeneration, !Task.isCancelled else {
                throw CancellationError()
            }
            cache.store(result, for: renderKey, speculative: speculative && visibleDemand[identifier] == nil)
            return result
        }

        // Everything the background task needs is resolved on the main actor
        // first, so the detached work touches no isolated state.
        let pixelWidth = CGFloat(renderKey.pixelWidth)
        let pixelHeight = CGFloat(renderKey.pixelHeight)
        let surface = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        let sheetRect = PageCompositor.sheetRect(in: surface, presentation: environment.presentation)
        let stablePageID = engine.stablePageID(for: request.location)
        // A caller drawing a spread says which edge is bound, because that
        // depends on which side of the gutter the leaf is on, not on its index.
        let spine = request.spine
        let pageAspectRatio = engine.aspectRatio(at: request.location)
        let contentRect = PageCompositor.contentRect(
            in: sheetRect,
            presentation: environment.presentation,
            pageAspectRatio: pageAspectRatio,
            safeFraction: request.safeFraction,
            contentMargin: 0
        )
        let condition = PageConditionData.pristine(
            documentID: bookID,
            stablePageID: stablePageID,
            environmentIdentity: environment.damageIdentity
        )
        let textureSeed = StableHash.combine(
            StableHash.hash(bookID),
            bookSeed,
            StableHash.hash(stablePageID)
        )
        let engineRef = engine
        let location = request.location
        let publish: @Sendable (CGImage) async -> Void = { [weak self] image in
            await self?.publishPaper(image, identifier: identifier, generation: generation)
        }
        preparationCount += 1
        let task = Task.detached(priority: speculative ? .utility : .userInitiated) { () throws -> PageRenderResult in
            // Rasterize at the text block's size, not the sheet's: the sheet
            // now fills a screen whose shape is not the document's.
            let rasterTiming = InkMetrics.begin("PDF rasterization")
            let content: CGImage
            do { content = try await engineRef.renderPage(at: location, pixelSize: contentRect.size) }
            catch { InkMetrics.end("PDF rasterization", rasterTiming); throw error }
            InkMetrics.end("PDF rasterization", rasterTiming)
            try Task.checkCancellation()

            let compositionRequest = PageCompositionRequest(
                content: content,
                pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
                environment: environment,
                condition: condition,
                marginalia: nil,
                spine: spine,
                textureSeed: textureSeed,
                pageAspectRatio: pageAspectRatio,
                safeFraction: request.safeFraction,
                reservedRegions: request.reservedRegions,
                spineShadowScale: request.spineShadowScale
            )
            let composed = try await PageCompositor.shared.compositeReaderPage(compositionRequest, paperReady: publish)
            try Task.checkCancellation()
            return composed
        }

        let flightID = UUID()
        inFlight[identifier] = InFlightPageRender(id: flightID, task: task)
        if speculative { speculativeFlights.insert(identifier) }
        defer {
            if inFlight[identifier]?.id == flightID {
                inFlight[identifier] = nil
                pendingPaper[identifier] = nil
                speculativeFlights.remove(identifier)
            }
        }

        let image = try await waitForRender(task, identifier: identifier,
                                           observerID: observerID, speculative: speculative)
        guard generation == renderGeneration, !Task.isCancelled else {
            throw CancellationError()
        }
        cache.store(image, for: renderKey, speculative: speculative && visibleDemand[identifier] == nil)
        return image
    }

    /// Warms only the next likely paging unit, after visible work has settled.
    func prefetch(_ requests: [PageImageRequest], environment: ReadingEnvironment) {
        prefetchTask?.cancel()
        let desired = Set(requests.map { key(for: $0, environment: environment).stringValue })
        for (key, flight) in inFlight where !desired.contains(key) && visibleDemand[key] == nil {
            flight.task.cancel()
        }
        prefetchTask = Task { [weak self] in
            // Coalesce startup geometry changes with the visible views before
            // spending CPU time on a speculative page at an obsolete size.
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            for request in requests {
                guard let self, !Task.isCancelled else { return }
                let renderKey = key(for: request, environment: environment)
                if cache.page(for: renderKey, promote: false) != nil { continue }
                let timing = InkMetrics.begin("Prefetch queue wait")
                do {
                    // A canceled geometry pass can leave a short gap before
                    // its replacement registers. Wait through that gap so a
                    // speculative render never overtakes the visible sheet.
                    repeat {
                        while !visibleDemand.isEmpty {
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        try await Task.sleep(for: .milliseconds(120))
                    } while !visibleDemand.isEmpty
                } catch {
                    InkMetrics.end("Prefetch queue wait", timing)
                    return
                }
                InkMetrics.end("Prefetch queue wait", timing)
                guard !Task.isCancelled else { return }
                if cache.page(for: renderKey, promote: false) != nil { continue }
                _ = try? await page(for: request, environment: environment, speculative: true)
            }
        }
    }

    private func publishPaper(_ image: CGImage, identifier: String, generation: Int) {
        guard generation == renderGeneration else { return }
        pendingPaper[identifier] = image
        for observer in paperObservers[identifier]?.values ?? [:].values { observer(image) }
    }

    private func waitForRender(_ task: Task<PageRenderResult, Error>, identifier: String,
                               observerID: UUID, speculative: Bool) async throws -> PageRenderResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.releaseRequest(identifier, observerID: observerID, speculative: speculative)
            }
        }
    }

    private func releaseRequest(_ identifier: String, observerID: UUID, speculative: Bool) {
        guard consumers[identifier]?.remove(observerID) != nil else { return }
        paperObservers[identifier]?[observerID] = nil
        if paperObservers[identifier]?.isEmpty == true { paperObservers[identifier] = nil }
        if consumers[identifier]?.isEmpty == true {
            consumers[identifier] = nil
            // Cancel a superseded layout/visit, but retain a shared render if
            // another visible view or prefetch consumer still needs it.
            inFlight[identifier]?.task.cancel()
        }
        if !speculative {
            visibleDemand[identifier, default: 1] -= 1
            if visibleDemand[identifier] == 0 { visibleDemand[identifier] = nil }
        }
    }

    func requestIdentifier(for request: PageImageRequest, environment: ReadingEnvironment) -> String {
        key(for: request, environment: environment).stringValue
    }

    /// Called when the environment changes so stale sheets are never shown.
    func invalidateAll() {
        renderGeneration += 1
        prefetchTask?.cancel()
        for flight in inFlight.values { flight.task.cancel() }
        inFlight.removeAll()
        pendingPaper.removeAll()
        speculativeFlights.removeAll()
        cache.removeAll()
    }

    /// The damage descriptors for one sheet, for inspection and tests.
    func conditionData(for location: ReadingLocation, environment: ReadingEnvironment) -> PageConditionData {
        PageConditionData.pristine(
            documentID: bookID,
            stablePageID: engine.stablePageID(for: location),
            environmentIdentity: environment.effectsOnly.damageIdentity
        )
    }

    // MARK: - Keys

    private func key(
        for request: PageImageRequest,
        environment: ReadingEnvironment
    ) -> PageRenderKey {
        let environment = environment.effectsOnly
        // Bucket to 8px: layout jitter of a point or two must not invalidate a
        // perfectly good bitmap.
        let pixels = PageRenderScale.bucketedPixelSize(request.pixelSize)
        let width = Int(pixels.width), height = Int(pixels.height)
        func milli(_ value: CGFloat) -> Int { Int((value * 1000).rounded()) }
        let safeToken = "\(milli(request.safeFraction.minX)),\(milli(request.safeFraction.minY)),\(milli(request.safeFraction.width)),\(milli(request.safeFraction.height))|\(request.reservedRegions.map { "\(milli($0.minX)),\(milli($0.minY)),\(milli($0.width)),\(milli($0.height))" }.joined(separator: ";"))"
        return PageRenderKey(
            stablePageID: engine.stablePageID(for: request.location),
            renderIdentity: environment.renderIdentity,
            pixelWidth: width,
            pixelHeight: height,
            // No spine decoration or lighting is baked into plain pages.
            spineShadowBucket: 0,
            spine: .left,
            safeToken: safeToken
        )
    }
}
