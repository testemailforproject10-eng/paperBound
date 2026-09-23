//
//  PDFReadingEngine.swift
//  Paperbound
//
//  PDFKit-backed engine. Fixed layout, real page indices, real zoom.
//

import CoreGraphics
import Foundation
import PDFKit

@MainActor
final class PDFReadingEngine: ReadingEngine {

    let documentID: UUID
    let fileURL: URL

    /// The document handed to the on-screen `PDFView` in pristine mode.
    /// Confined to the main actor; background work uses `worker` instead.
    private(set) var pdfDocument: PDFDocument?

    /// Serial, background-confined handle used for rasterizing and searching.
    private let worker: PDFDocumentWorker

    private var location: ReadingLocation
    private var cachedOutline: [OutlineItem]?

    var format: BookFormat { .pdf }
    var capabilities: ReaderCapabilities { .fixedLayout }
    var pageCount: Int { worker.pageCount }
    private(set) var isOpen = false

    init(documentID: UUID, fileURL: URL, initialLocation: ReadingLocation?) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ReadingEngineError.fileMissing(fileURL)
        }
        guard let worker = PDFDocumentWorker(url: fileURL) else {
            // PDFDocument refuses encrypted files we cannot unlock with an
            // empty password, which is the DRM / password case.
            if let probe = PDFDocument(url: fileURL), probe.isEncrypted {
                throw ReadingEngineError.encryptedDocument
            }
            throw ReadingEngineError.unreadableDocument(fileURL)
        }
        self.documentID = documentID
        self.fileURL = fileURL
        self.worker = worker
        self.location = initialLocation ?? .pdfPage(index: 0, yOffset: 0)
    }

    // MARK: - Lifecycle

    func open() async throws {
        guard !isOpen else { return }
        guard let document = PDFDocument(url: fileURL) else {
            throw ReadingEngineError.unreadableDocument(fileURL)
        }
        if document.isEncrypted, !document.unlock(withPassword: "") {
            throw ReadingEngineError.encryptedDocument
        }
        pdfDocument = document
        // Clamp a restored location that no longer exists (file replaced, etc.).
        if let index = location.pdfPageIndex, index >= worker.pageCount {
            location = .pdfPage(index: max(0, worker.pageCount - 1), yOffset: 0)
        }
        isOpen = true
    }

    func close() {
        pdfDocument = nil
        cachedOutline = nil
        isOpen = false
    }

    // MARK: - Navigation

    func currentLocation() -> ReadingLocation { location }

    func go(to location: ReadingLocation) async throws {
        guard let index = location.pdfPageIndex else {
            throw ReadingEngineError.locationOutOfBounds(location)
        }
        guard index >= 0, index < worker.pageCount else {
            throw ReadingEngineError.locationOutOfBounds(location)
        }
        self.location = location
    }

    func location(byAdvancing location: ReadingLocation, pages delta: Int) -> ReadingLocation? {
        let current = location.pdfPageIndex ?? 0
        let next = current + delta
        guard next >= 0, next < worker.pageCount else { return nil }
        return .pdfPage(index: next, yOffset: 0)
    }

    func normalizedProgress(for location: ReadingLocation) -> Double {
        guard worker.pageCount > 0, let index = location.pdfPageIndex else { return 0 }
        return Double(index + 1) / Double(worker.pageCount)
    }

    func orderKey(for location: ReadingLocation) -> Double {
        Double(location.pdfPageIndex ?? 0)
    }

    func firstLocation() -> ReadingLocation { .pdfPage(index: 0, yOffset: 0) }

    // MARK: - Content

    func search(_ text: String) async throws -> [ReadingSearchResult] {
        await worker.search(text)
    }

    func outline() -> [OutlineItem] {
        if let cachedOutline { return cachedOutline }
        guard let root = pdfDocument?.outlineRoot, let document = pdfDocument else {
            cachedOutline = []
            return []
        }
        var items: [OutlineItem] = []
        appendOutline(root, into: &items, depth: -1, document: document)
        cachedOutline = items
        return items
    }

    private func appendOutline(
        _ node: PDFOutline,
        into items: inout [OutlineItem],
        depth: Int,
        document: PDFDocument
    ) {
        if depth >= 0, let label = node.label, !label.isEmpty {
            let pageIndex: Int
            if let page = node.destination?.page {
                pageIndex = document.index(for: page)
            } else if let action = node.action as? PDFActionGoTo, let page = action.destination.page {
                pageIndex = document.index(for: page)
            } else {
                pageIndex = 0
            }
            items.append(
                OutlineItem(
                    title: label,
                    location: .pdfPage(index: max(0, pageIndex), yOffset: 0),
                    depth: depth
                )
            )
        }
        for childIndex in 0..<node.numberOfChildren {
            guard let child = node.child(at: childIndex) else { continue }
            appendOutline(child, into: &items, depth: depth + 1, document: document)
        }
    }

    func text(at location: ReadingLocation) -> String? {
        guard let index = location.pdfPageIndex else { return nil }
        return pdfDocument?.page(at: index)?.string
    }

    func label(for location: ReadingLocation) -> String {
        guard let index = location.pdfPageIndex else { return "—" }
        if let label = pdfDocument?.page(at: index)?.label, !label.isEmpty {
            return label
        }
        return "\(index + 1)"
    }

    // MARK: - Rendering

    func stablePageID(for location: ReadingLocation) -> String {
        guard let index = location.pdfPageIndex else { return "pdf:0" }
        return "pdf:\(index)"
    }

    func aspectRatio(at location: ReadingLocation) -> Double {
        let index = location.pdfPageIndex ?? 0
        guard index >= 0, index < worker.pageBoxes.count else { return 792.0 / 612.0 }
        let box = worker.pageBoxes[index]
        guard box.width > 0 else { return 792.0 / 612.0 }
        return Double(box.height / box.width)
    }

    nonisolated func renderPage(at location: ReadingLocation, pixelSize: CGSize) async throws -> CGImage {
        guard let index = location.pdfPageIndex else {
            throw ReadingEngineError.locationOutOfBounds(location)
        }
        return try await worker.renderPage(index: index, pixelSize: pixelSize)
    }

    // MARK: - Metadata helpers

    /// Title/author as recorded in the PDF's own dictionary, when present.
    static func metadata(for url: URL) -> (title: String?, author: String?, pageCount: Int) {
        guard let document = PDFDocument(url: url) else { return (nil, nil, 0) }
        let attributes = document.documentAttributes ?? [:]
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            (title?.isEmpty == false) ? title : nil,
            (author?.isEmpty == false) ? author : nil,
            document.pageCount
        )
    }
}
