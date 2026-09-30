//
//  ReaderViewModel.swift
//  Paperbound
//
//  Reading state for one open book.
//
//  Note what this type does *not* own: it does not composite pixels, it does
//  not generate wear, and it does not decide how many pages fit on screen. It
//  holds a position, an environment, and the panels that are open.
//

import Foundation
import Observation
import SwiftData
import SwiftUI

/// Which renderer is on screen. These are genuinely different views of the same
/// document, not two styles of one view.
enum ReadingMode: String, CaseIterable, Sendable {
    /// Composited physical page: paper, wear, lighting, book presentation.
    case physical
    /// PDFKit's own view: selectable, searchable, zoomable, nothing removed.
    case document

    var displayName: String {
        switch self {
        case .physical: return "Physical"
        case .document: return "Pristine"
        }
    }

    var systemImage: String {
        switch self {
        case .physical: return "book.closed"
        case .document: return "doc.plaintext"
        }
    }
}

enum ReaderPanel: String, Identifiable, Sendable {
    case environment
    case contents
    case search
    case bookmarks

    var id: String { rawValue }
}

@MainActor
@Observable
final class ReaderViewModel {

    // MARK: Inputs

    let book: Book
    private let settings: AppSettings
    private let store: LibraryStore
    private let context: ModelContext

    // MARK: Engine

    private(set) var engine: PDFReadingEngine?
    private(set) var provider: PageImageProvider?

    // MARK: State

    private(set) var isLoading = true
    var loadError: String?

    var mode: ReadingMode = .physical {
        didSet { if mode != oldValue { persist() } }
    }

    private var storedEnvironment: ReadingEnvironment
    var environment: ReadingEnvironment {
        get { storedEnvironment }
        set {
            let normalized = newValue.effectsOnly
            guard normalized != storedEnvironment else { return }
            if normalized.renderIdentity != storedEnvironment.renderIdentity {
                provider?.invalidateAll()
            }
            storedEnvironment = normalized
            book.savedEnvironment = normalized
            persist()
        }
    }

    private(set) var currentLocation: ReadingLocation = .start
    private(set) var pageCount: Int = 0
    private(set) var outline: [OutlineItem] = []
    private(set) var isLoadingOutline = false
    private var outlineLoaded = false
    private(set) var capabilities: ReaderCapabilities = []

    var layout: ReadingSurfaceLayout = .singlePage
    let paging = ReaderPagingCoordinator()
    private(set) var navigationRequest: ReaderNavigationRequest?
    var sliderSelection: Double?
    var isPanelPresented = false
    var activePanel: ReaderPanel? {
        didSet { if activePanel != nil { isPanelPresented = true } }
    }
    var showsControls = true

    /// Watches which display the scene is on, so folding a device is a
    /// reported fact rather than a guess from the window's shape.
    let display = DisplayObserver()

    /// Watches the hinge itself where the OS exposes one (iOS 27.1+). It
    /// outranks `display` when it reports, and is silent everywhere else.
    let hinge = HingeObserver()

    // Search
    var searchQuery: String = ""
    private(set) var searchResults: [ReadingSearchResult] = []
    private(set) var isSearching = false
    private var searchTask: Task<Void, Never>?

    // Speech
    let speech = SpeechController()

    // MARK: Init

    init(book: Book, settings: AppSettings, store: LibraryStore, context: ModelContext) {
        self.book = book
        self.settings = settings
        self.store = store
        self.context = context
        self.storedEnvironment = settings.environment(for: book)
        if book.environmentData != nil { book.savedEnvironment = storedEnvironment }

        #if DEBUG
        // `-paperbound-demo-mode document` opens straight into the PDFKit
        // renderer, so a screenshot can show that path without tapping.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-paperbound-demo-mode"),
           index + 1 < arguments.count,
           let requested = ReadingMode(rawValue: arguments[index + 1]) {
            self.mode = requested
        }
        // Reproduce ink startup without changing the default environment.
        if arguments.contains("-paperbound-demo-ink") {
            self.environment.ink = .enchanted
        }
        if arguments.contains("-paperbound-demo-footsteps") {
            self.environment.footstepsEnabled = true
        }
        #endif
    }

    // MARK: Lifecycle

    func load() async {
        let timing = InkMetrics.begin("Reader opening")
        defer { InkMetrics.end("Reader opening", timing) }
        isLoading = true
        loadError = nil
        if environment.ink == .enchanted { InkGPUResources.prewarm() }
        do {
            let url = store.fileURL(for: book)
            let engine = try PDFReadingEngine(
                documentID: book.id,
                fileURL: url,
                initialLocation: book.savedLocation
            )
            try await engine.open()

            self.engine = engine
            self.provider = PageImageProvider(engine: engine, bookID: book.id, bookSeed: book.wearSeed)
            self.pageCount = engine.pageCount
            self.capabilities = engine.capabilities
            self.currentLocation = engine.currentLocation()
            if book.pageCount != engine.pageCount {
                book.pageCount = engine.pageCount
            }
            book.lastOpenedAt = .now
            persist()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    func unload() {
        searchTask?.cancel()
        speech.stop()
        persist()
        engine?.close()
        provider?.invalidateAll()
    }

    func loadOutlineIfNeeded() async {
        guard !outlineLoaded, !isLoadingOutline, let engine else { return }
        isLoadingOutline = true
        // Let the contents sheet appear before PDFKit walks a large outline.
        await Task.yield()
        guard !Task.isCancelled, engine.isOpen else {
            isLoadingOutline = false
            return
        }
        outline = engine.outline()
        outlineLoaded = true
        isLoadingOutline = false
    }

    // MARK: Geometry

    var pageAspectRatio: Double {
        engine?.aspectRatio(at: currentLocation) ?? (792.0 / 612.0)
    }

    /// The most recent reading-surface size, in points. Kept so the layout can
    /// be re-derived after an environment change and so the debug HUD can show
    /// what the coordinator actually saw.
    private(set) var lastSurfaceSize: CGSize = .zero

    func updateLayout(
        for size: CGSize,
        hardwareReservedRegions: [CGRect] = [],
        divisionRegions: [CGRect] = []
    ) {
        lastSurfaceSize = size
        // A fold shows up as a layout change, so this is exactly the moment to
        // re-read the display.
        display.refresh()

        var next = DeviceLayoutCoordinator.layout(
            surfaceSize: size,
            pageAspectRatio: pageAspectRatio,
            presentation: environment.presentation,
            preference: .automatic,
            provider: HingePostureProvider(
                hinge: hinge.snapshot,
                display: display.snapshot
            ),
            divisionRegions: divisionRegions
        )
        for region in hardwareReservedRegions where !next.reservedRegions.contains(region) {
            next.reservedRegions.append(region)
        }
        if next != layout { layout = next }
    }

    // MARK: Navigation

    var currentPageIndex: Int {
        currentLocation.pdfPageIndex ?? 0
    }

    var progress: Double {
        engine?.normalizedProgress(for: currentLocation) ?? 0
    }

    var positionLabel: String {
        guard let engine else { return "—" }
        return "Page \(engine.label(for: currentLocation)) of \(max(1, engine.pageCount))"
    }

    func go(toPageIndex index: Int, source: ReaderNavigationRequest.Source = .destination) {
        guard let engine, index >= 0, index < engine.pageCount else { return }
        setLocation(.pdfPage(index: index, yOffset: 0), source: source)
    }

    func go(to location: ReadingLocation) {
        guard location.pdfPageIndex != nil else { return }
        setLocation(location)
    }

    func advance(by delta: Int, source: ReaderNavigationRequest.Source = .edgeTap) {
        guard let engine, let next = engine.location(byAdvancing: currentLocation, pages: delta) else { return }
        setLocation(next, source: source)
    }

    /// Called by the paging surface when the reader swipes.
    func reportVisible(pageIndex: Int) {
        guard pageIndex != currentPageIndex else { return }
        setLocation(.pdfPage(index: pageIndex, yOffset: 0), announce: false)
    }

    private func setLocation(_ location: ReadingLocation, announce: Bool = true,
                             source: ReaderNavigationRequest.Source = .destination) {
        if announce, location.pdfPageIndex != currentPageIndex {
            navigationRequest = ReaderNavigationRequest(pageIndex: location.pdfPageIndex ?? 0, source: source)
        }
        currentLocation = location
        Task { try? await engine?.go(to: location) }
        book.savedLocation = location
        book.progress = engine?.normalizedProgress(for: location) ?? book.progress
        if book.progress >= 0.995 { book.isFinished = true }
        persist()
        if announce, speech.isSpeaking {
            speakCurrentPage()
        }
    }

    func commitSlider() {
        guard let selection = sliderSelection else { return }
        sliderSelection = nil
        go(toPageIndex: Int(selection.rounded()), source: .slider)
    }

    // MARK: Environment

    func setAsGlobalDefault() {
        settings.defaultEnvironment = environment
    }

    func resetToGlobalDefault() {
        environment = settings.defaultEnvironment
        book.savedEnvironment = nil
        persist()
    }

    /// New wear pattern for this copy, same environment.
    func rerollWear() {
        book.wearSeed = UInt64.random(in: UInt64.min...UInt64.max)
        if let engine {
            provider = PageImageProvider(engine: engine, bookID: book.id, bookSeed: book.wearSeed)
        }
        persist()
    }

    func toggleMode() {
        mode = (mode == .physical) ? .document : .physical
    }

    // MARK: Bookmarks

    var currentPageIsBookmarked: Bool {
        guard let engine else { return false }
        let key = engine.orderKey(for: currentLocation)
        return book.bookmarks.contains { $0.orderKey == key }
    }

    func toggleBookmark() {
        guard let engine else { return }
        let key = engine.orderKey(for: currentLocation)
        if let existing = book.bookmarks.first(where: { $0.orderKey == key }) {
            context.delete(existing)
        } else {
            let bookmark = Bookmark(
                label: "Page \(engine.label(for: currentLocation))",
                location: currentLocation,
                orderKey: key
            )
            bookmark.book = book
            context.insert(bookmark)
        }
        persist()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        context.delete(bookmark)
        persist()
    }

    // MARK: Search

    func runSearch() {
        searchTask?.cancel()
        let query = searchQuery
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self, let engine = self.engine else { return }
            let results = (try? await engine.search(query)) ?? []
            if Task.isCancelled { return }
            self.searchResults = results
            self.isSearching = false
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchResults = []
        isSearching = false
    }

    // MARK: Speech

    func speakCurrentPage() {
        guard let engine, let text = engine.text(at: currentLocation), !text.isEmpty else {
            speech.stop()
            return
        }
        speech.speak(text, rate: settings.speechRate)
    }

    func toggleSpeech() {
        if speech.isSpeaking {
            speech.stop()
        } else {
            speakCurrentPage()
        }
    }

    // MARK: Persistence

    private func persist() {
        do {
            try context.save()
        } catch {
            // A failed metadata save must never take the reader down with it.
            loadError = "Progress could not be saved: \(error.localizedDescription)"
        }
    }
}
