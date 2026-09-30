import CoreGraphics
import XCTest
@testable import Paperbound

@MainActor
final class PageImageProviderTests: XCTestCase {
    func testRemovedStylingAndSpineLightingDoNotChangeReaderCacheIdentity() {
        let provider = PageImageProvider(
            engine: ControlledReadingEngine(gate: ControlledPageRender()),
            bookID: UUID(), bookSeed: 17
        )
        let original = cancellationRequest
        let folded = PageImageRequest(
            location: original.location, pixelSize: original.pixelSize,
            spineShadowScale: 0.25, spine: .right,
            safeFraction: original.safeFraction, reservedRegions: original.reservedRegions
        )
        XCTAssertEqual(
            provider.requestIdentifier(for: original, environment: .cleanPaper),
            provider.requestIdentifier(for: folded, environment: .watchingGrimoire)
        )
    }

    func testPrefetchSelectsOnlyTheNextUnitInTravelDirection() {
        XCTAssertEqual(PagePrefetchPolicy.nextUnit(after: 2, count: 5, direction: 1), 3)
        XCTAssertEqual(PagePrefetchPolicy.nextUnit(after: 2, count: 5, direction: -1), 1)
        XCTAssertNil(PagePrefetchPolicy.nextUnit(after: 4, count: 5, direction: 1))
        XCTAssertNil(PagePrefetchPolicy.nextUnit(after: 0, count: 5, direction: -1))
        XCTAssertNil(PagePrefetchPolicy.nextUnit(after: 0, count: 0, direction: 1))
    }

    func testFootstepsUsesTheSamePreparedPage() async throws {
        let gate = ControlledPageRender()
        let provider = PageImageProvider(
            engine: ControlledReadingEngine(gate: gate), bookID: UUID(), bookSeed: 17
        )
        let request = cancellationRequest
        let plain = ReadingEnvironment.cleanPaper
        var walking = plain
        walking.footstepsEnabled = true
        XCTAssertEqual(provider.requestIdentifier(for: request, environment: plain),
                       provider.requestIdentifier(for: request, environment: walking))
        let first = Task { try await provider.page(for: request, environment: plain) }
        await gate.waitUntilRenderingStarts()
        await gate.finish(with: try makeImage())
        _ = try await first.value
        XCTAssertNotNil(provider.cachedPage(for: request, environment: walking))
    }

    func testCancelledViewStopsObsoleteComposition() async throws {
        let gate = ControlledPageRender()
        let provider = PageImageProvider(engine: ControlledReadingEngine(gate: gate), bookID: UUID(), bookSeed: 17)
        let request = cancellationRequest
        var environment = ReadingEnvironment.cleanPaper; environment.ink = .enchanted
        var publishedPaper = false
        let render = Task {
            try await provider.page(for: request, environment: environment) { _ in publishedPaper = true }
        }
        await gate.waitUntilRenderingStarts()
        render.cancel()
        // Let the cancellation handler remove this consumer while the PDF
        // worker is still held at its deterministic gate.
        try await Task.sleep(for: .milliseconds(20))
        await gate.finish(with: try makeImage())
        do { _ = try await render.value; XCTFail("Canceled view received a page") }
        catch is CancellationError {}
        XCTAssertFalse(publishedPaper)
        XCTAssertNil(provider.cachedPage(for: request, environment: environment))
    }

    func testCancelledConsumerDoesNotCancelSharedVisibleRender() async throws {
        let gate = ControlledPageRender()
        let provider = PageImageProvider(engine: ControlledReadingEngine(gate: gate), bookID: UUID(), bookSeed: 17)
        let request = cancellationRequest
        let first = Task { try await provider.page(for: request, environment: .cleanPaper) }
        await gate.waitUntilRenderingStarts()
        let joined = expectation(description: "second consumer joins")
        let second = Task {
            joined.fulfill()
            return try await provider.page(for: request, environment: .cleanPaper)
        }
        await fulfillment(of: [joined], timeout: 1)
        first.cancel()
        try await Task.sleep(for: .milliseconds(20))
        await gate.finish(with: try makeImage())
        _ = try await second.value
        do { _ = try await first.value; XCTFail("Canceled consumer accepted a page") }
        catch is CancellationError {}
        XCTAssertNotNil(provider.cachedPage(for: request, environment: .cleanPaper))
    }

    private var cancellationRequest: PageImageRequest {
        PageImageRequest(location: .pdfPage(index: 0, yOffset: 0), pixelSize: CGSize(width: 64, height: 96),
            spineShadowScale: 1, spine: .left, safeFraction: CGRect(x: 0, y: 0, width: 1, height: 1), reservedRegions: [])
    }

    func testStagedPaperAndNavigationPreparationBenchmark() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ink-provider-benchmark.pdf")
        try SampleLibrary.write(to: url)
        let id = UUID()
        let engine = try PDFReadingEngine(documentID: id, fileURL: url, initialLocation: nil)
        try await engine.open()
        defer { engine.close() }
        let provider = PageImageProvider(engine: engine, bookID: id, bookSeed: 731)
        var environment = ReadingEnvironment.cleanPaper; environment.ink = .enchanted
        func request(_ index: Int) -> PageImageRequest {
            PageImageRequest(location: .pdfPage(index: index, yOffset: 0),
                pixelSize: CGSize(width: 768, height: 1104), spineShadowScale: 1, spine: .left,
                safeFraction: CGRect(x: 0, y: 0, width: 1, height: 1), reservedRegions: [])
        }
        var preparation: [Double] = [], paperTimes: [Double] = []
        for index in 0..<min(4, engine.pageCount) {
            let start = ProcessInfo.processInfo.systemUptime
            var paperPublished = false
            _ = try await provider.page(for: request(index), environment: environment) { _ in
                XCTAssertFalse(paperPublished)
                paperPublished = true
                paperTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            }
            XCTAssertTrue(paperPublished, "Paper must publish before the finished preparation result.")
            preparation.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        var revisits: [Double] = []
        for index in [2, 1, 3, 0, 2, 3, 1, 0] {
            let start = ProcessInfo.processInfo.systemUptime
            _ = try await provider.page(for: request(index), environment: environment)
            revisits.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        print("INK_PROVIDER_PREPARATION_MS \(preparation) paperReadyMS=\(paperTimes)")
        print("INK_PROVIDER_CACHED_REVISIT_MS \(revisits)")
    }

    func testInvalidationRejectsAStaleRenderResult() async throws {
        let gate = ControlledPageRender()
        let engine = ControlledReadingEngine(gate: gate)
        let provider = PageImageProvider(engine: engine, bookID: UUID(), bookSeed: 17)
        let request = PageImageRequest(
            location: .pdfPage(index: 0, yOffset: 0),
            pixelSize: CGSize(width: 64, height: 96),
            spineShadowScale: 1,
            spine: .left,
            safeFraction: CGRect(x: 0, y: 0, width: 1, height: 1),
            reservedRegions: []
        )

        let render = Task { try await provider.page(for: request, environment: .cleanPaper) }
        await gate.waitUntilRenderingStarts()
        provider.invalidateAll()
        await gate.finish(with: try makeImage())

        do {
            _ = try await render.value
            XCTFail("A render from before cache invalidation must be rejected.")
        } catch is CancellationError {
            // Expected: invalidation cancels the detached render and advances
            // the generation checked before the result can enter the cache.
        }
        XCTAssertNil(provider.cachedPage(for: request, environment: .cleanPaper))
    }

    func testRenderingFailureIsPropagatedAndNotCached() async throws {
        let gate = ControlledPageRender()
        let engine = ControlledReadingEngine(gate: gate)
        let provider = PageImageProvider(engine: engine, bookID: UUID(), bookSeed: 17)
        let request = PageImageRequest(
            location: .pdfPage(index: 0, yOffset: 0),
            pixelSize: CGSize(width: 64, height: 96),
            spineShadowScale: 1,
            spine: .left,
            safeFraction: CGRect(x: 0, y: 0, width: 1, height: 1),
            reservedRegions: []
        )

        let render = Task { try await provider.page(for: request, environment: .cleanPaper) }
        await gate.waitUntilRenderingStarts()
        await gate.fail(with: TestPageRenderError.expected)

        do {
            _ = try await render.value
            XCTFail("The reader must receive document rendering failures.")
        } catch TestPageRenderError.expected {
            // Expected; an error must not be turned into a cached blank sheet.
        }
        XCTAssertNil(provider.cachedPage(for: request, environment: .cleanPaper))
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 64,
            height: 96,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        return try XCTUnwrap(context.makeImage())
    }
}

private actor ControlledPageRender {
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func render() async throws -> CGImage {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRenderingStarts() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish(with image: CGImage) {
        continuation?.resume(returning: image)
        continuation = nil
    }

    func fail(with error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

private enum TestPageRenderError: Error, Sendable {
    case expected
}

@MainActor
private final class ControlledReadingEngine: ReadingEngine {
    nonisolated let gate: ControlledPageRender

    let documentID = UUID()
    let format = BookFormat.pdf
    let capabilities: ReaderCapabilities = []
    let pageCount = 1
    let isOpen = true

    init(gate: ControlledPageRender) {
        self.gate = gate
    }

    func open() async throws {}
    func close() {}
    func currentLocation() -> ReadingLocation { .pdfPage(index: 0, yOffset: 0) }
    func go(to location: ReadingLocation) async throws {}
    func location(byAdvancing location: ReadingLocation, pages delta: Int) -> ReadingLocation? { nil }
    func normalizedProgress(for location: ReadingLocation) -> Double { 0 }
    func orderKey(for location: ReadingLocation) -> Double { 0 }
    func firstLocation() -> ReadingLocation { .pdfPage(index: 0, yOffset: 0) }
    func search(_ text: String) async throws -> [ReadingSearchResult] { [] }
    func outline() -> [OutlineItem] { [] }
    func text(at location: ReadingLocation) -> String? { nil }
    func label(for location: ReadingLocation) -> String { "1" }
    func stablePageID(for location: ReadingLocation) -> String { "test:page-0" }
    func aspectRatio(at location: ReadingLocation) -> Double { 1.5 }

    nonisolated func renderPage(at location: ReadingLocation, pixelSize: CGSize) async throws -> CGImage {
        try await gate.render()
    }
}
