//
//  PDFDocumentWorker.swift
//  Paperbound
//
//  Background rasterization and text search for a PDF.
//
//  This holds its *own* PDFDocument instance for the same file, separate from
//  the one the on-screen PDFView uses. PDFKit objects are not documented as
//  thread-safe, so rather than sharing one document across threads we pay for
//  a second lazy handle and confine it to a single serial queue. That removes
//  the entire class of "page rendered while PDFView was scrolling" crashes.
//

import CoreGraphics
// PDFKit predates Sendable and marks nothing. The confinement this file relies
// on — one document, one serial queue, never touched anywhere else — is real
// but invisible to the compiler, so the checking is turned off here
// deliberately rather than left to produce noise that would hide a genuine
// warning later.
@preconcurrency import PDFKit
import UIKit

/// The PDFKit queue is serial, so an obsolete request may wait behind another
/// page. Its task's cancellation state does not propagate into a GCD block.
private final class PDFRenderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Safe to hand across actors: every access to `document` after initialization
/// happens on `queue`.
final class PDFDocumentWorker: @unchecked Sendable {

    private let queue: DispatchQueue
    private let document: PDFDocument
    private let url: URL

    /// Page count is cheap to read and does not enumerate every page. Geometry
    /// is requested only for pages entering the reader.
    let pageCount: Int

    init?(url: URL) {
        guard let document = PDFDocument(url: url) else { return nil }
        guard !document.isEncrypted || document.unlock(withPassword: "") else { return nil }
        self.url = url
        self.document = document
        self.queue = DispatchQueue(
            label: "com.paperbound.pdfworker.\(url.lastPathComponent)",
            qos: .userInitiated
        )
        self.pageCount = document.pageCount
    }

    // MARK: - Rasterizing

    /// Renders one page into a transparent bitmap at exactly `pixelSize`.
    ///
    /// The background is left transparent on purpose: the compositor draws the
    /// result over paper texture with a multiply (or screen) blend, so unprinted
    /// areas show the paper rather than a flat white rectangle.
    func renderPage(index: Int, pixelSize: CGSize) async throws -> CGImage {
        let cancellation = PDFRenderCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let document = self.document
                    guard index >= 0, index < document.pageCount, let page = document.page(at: index) else {
                        continuation.resume(throwing: ReadingEngineError.locationOutOfBounds(.pdfPage(index: index, yOffset: 0)))
                        return
                    }
                    let width = max(1, Int(pixelSize.width.rounded()))
                    let height = max(1, Int(pixelSize.height.rounded()))
                    let pageRect = page.bounds(for: .cropBox)
                    guard pageRect.width > 0, pageRect.height > 0 else {
                        continuation.resume(throwing: ReadingEngineError.renderFailed("page \(index) has an empty crop box"))
                        return
                    }

                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    format.opaque = false
                    format.preferredRange = .standard

                    let renderer = UIGraphicsImageRenderer(
                        size: CGSize(width: width, height: height),
                        format: format
                    )
                    let image = renderer.image { context in
                        let cg = context.cgContext
                        cg.interpolationQuality = .high
                        // UIGraphicsImageRenderer hands us a flipped (y-down) context;
                        // PDF pages draw in y-up space, so undo the flip first.
                        cg.translateBy(x: 0, y: CGFloat(height))
                        cg.scaleBy(x: 1, y: -1)
                        cg.scaleBy(
                            x: CGFloat(width) / pageRect.width,
                            y: CGFloat(height) / pageRect.height
                        )
                        page.draw(with: .cropBox, to: cg)
                    }

                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    guard let cgImage = image.cgImage else {
                        continuation.resume(throwing: ReadingEngineError.renderFailed("no bitmap produced for page \(index)"))
                        return
                    }
                    continuation.resume(returning: cgImage)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    // MARK: - Text

    func pageText(index: Int) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                let document = self.document
                continuation.resume(returning: document.page(at: index)?.string)
            }
        }
    }

    // MARK: - Search

    /// Case- and diacritic-insensitive search performed against each page's
    /// extracted text, which gives us exact character ranges for snippet
    /// highlighting (PDFSelection alone does not).
    func search(_ needle: String, contextRadius: Int = 48, limit: Int = 500) async -> [ReadingSearchResult] {
        await withCheckedContinuation { continuation in
            queue.async {
                let document = self.document
                let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2 else {
                    continuation.resume(returning: [])
                    return
                }

                var results: [ReadingSearchResult] = []
                let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

                for index in 0..<document.pageCount {
                    if results.count >= limit { break }
                    guard let raw = document.page(at: index)?.string else { continue }
                    let flattened = raw.replacingOccurrences(of: "\n", with: " ")
                    let chars = Array(flattened)
                    var searchStart = flattened.startIndex

                    while let found = flattened.range(of: trimmed, options: options, range: searchStart..<flattened.endIndex) {
                        let matchStart = flattened.distance(from: flattened.startIndex, to: found.lowerBound)
                        let matchEnd = flattened.distance(from: flattened.startIndex, to: found.upperBound)

                        // Build the snippet from the flattened character array so
                        // offsets stay exact — no trimming, no re-alignment guesswork.
                        let snippetStart = max(0, matchStart - contextRadius)
                        let snippetEnd = min(chars.count, matchEnd + contextRadius)
                        let leadingEllipsis = snippetStart > 0 ? "…" : ""
                        let trailingEllipsis = snippetEnd < chars.count ? "…" : ""
                        let snippet = leadingEllipsis
                            + String(chars[snippetStart..<snippetEnd])
                            + trailingEllipsis
                        let localStart = (matchStart - snippetStart) + leadingEllipsis.count
                        let localEnd = localStart + (matchEnd - matchStart)

                        results.append(
                            ReadingSearchResult(
                                location: .pdfPage(index: index, yOffset: 0),
                                snippet: snippet,
                                matchRange: localStart..<min(localEnd, snippet.count),
                                pageLabel: document.page(at: index)?.label ?? "\(index + 1)"
                            )
                        )

                        if results.count >= limit { break }
                        searchStart = found.upperBound
                        if searchStart >= flattened.endIndex { break }
                    }
                }
                continuation.resume(returning: results)
            }
        }
    }

    // MARK: - Metadata

    /// Reads document attributes on the worker queue.
    func attributes() async -> [AnyHashable: Any] {
        await withCheckedContinuation { continuation in
            queue.async {
                let document = self.document
                continuation.resume(returning: document.documentAttributes ?? [:])
            }
        }
    }
}
