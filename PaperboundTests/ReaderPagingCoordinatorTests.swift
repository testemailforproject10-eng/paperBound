import XCTest
@testable import Paperbound

@MainActor final class ReaderPagingCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)
    private func request(_ c: ReaderPagingCoordinator, _ unit: Int,
                         source: ReaderNavigationRequest.Source = .edgeTap, pages: [String] = ["page"],
                         force: Bool = false) {
        c.request(unit: unit, pages: pages, renders: Dictionary(uniqueKeysWithValues: pages.map { ($0, "render-\(unit)") }),
                  source: source, enchanted: true, animationsAllowed: true, force: force)
    }
    private func identity(_ c: ReaderPagingCoordinator, page: String = "page") throws -> InkPreparationIdentity {
        InkPreparationIdentity(page: page, render: try XCTUnwrap(c.renderIdentities[page]),
                               visit: try XCTUnwrap(c.sequence?.visitID))
    }
    func testProgrammaticJumpWaitsForDestinationAndBothGPUImages() throws {
        let c = ReaderPagingCoordinator(); c.relocate(unit: 0)
        request(c, 4, source: .slider, pages: ["left", "right"])
        let visit = c.sequence?.visitID
        c.readiness(try identity(c, page: "left"), seed: 1, at: now)
        c.readiness(try identity(c, page: "right"), seed: 2, at: now)
        XCTAssertEqual(c.sequence?.phase, .waiting)
        XCTAssertFalse(c.settle(unit: 2, at: now))
        c.observe(unit: 4, fraction: 0.049, at: now)
        XCTAssertEqual(c.sequence?.phase, .waiting)
        c.observe(unit: 4, fraction: 0.05, at: now)
        XCTAssertEqual(c.sequence?.phase, .revealing)
        XCTAssertEqual(c.sequence?.startDates["left"], c.sequence?.startDates["right"])
        XCTAssertTrue(c.settle(unit: 4, at: now))
        request(c, 4)
        XCTAssertEqual(c.sequence?.visitID, visit)
        XCTAssertEqual(c.visitCount, 1)
    }
    func testCancellationDoesNotReplayOriginalAndCachedBackwardVisitIsFresh() throws {
        let c = ReaderPagingCoordinator(); c.relocate(unit: 2)
        request(c, 3, source: .swipe)
        let canceled = try identity(c)
        c.observe(unit: 3, fraction: 0.2, at: now)
        XCTAssertTrue(c.settle(unit: 2, at: now))
        XCTAssertNil(c.sequence)
        c.readiness(canceled, seed: 1, at: now)
        XCTAssertNil(c.sequence)
        request(c, 1, source: .swipe)
        XCTAssertNotEqual(c.sequence?.visitID, canceled.visit)
        c.observe(unit: 1, fraction: 1, at: now)
        c.readiness(try identity(c), seed: 1, at: now)
        XCTAssertEqual(c.sequence?.phase, .revealing)
    }
    func testRapidRequestsRejectOldRenderAndVisitAndCompleteOddPage() throws {
        let c = ReaderPagingCoordinator(); c.relocate(unit: 0)
        request(c, 1); let old = try identity(c)
        request(c, 8, source: .slider); let current = try identity(c)
        c.observe(unit: 8, fraction: 1, at: now)
        c.readiness(old, seed: 1, at: now)
        c.readiness(InkPreparationIdentity(page: "page", render: "stale", visit: current.visit), seed: 1, at: now)
        XCTAssertEqual(c.sequence?.phase, .waiting)
        c.readiness(current, seed: 1, at: now)
        c.completed(old, startedAt: now, at: now.addingTimeInterval(4))
        XCTAssertEqual(c.sequence?.phase, .revealing)
        c.completed(current, startedAt: now, at: now.addingTimeInterval(4))
        XCTAssertEqual(c.sequence?.phase, .finished)
        XCTAssertEqual(c.completedVisits, 1)
    }
    func testDeferredSettingsReplayAndLifecycleCompletion() throws {
        let c = ReaderPagingCoordinator(); c.relocate(unit: 0)
        c.deferReplay()
        XCTAssertTrue(c.pendingReplay)
        XCTAssertNil(c.sequence)
        c.consumeReplay(); request(c, 0, source: .settings, force: true)
        c.observe(unit: 0, fraction: 1, at: now)
        c.readiness(try identity(c), seed: 1, at: now)
        c.finish(reason: "background")
        XCTAssertEqual(c.sequence?.phase, .finished)
        c.deferReplay(); c.disable()
        XCTAssertFalse(c.pendingReplay)
        XCTAssertNil(c.sequence)
    }
}
