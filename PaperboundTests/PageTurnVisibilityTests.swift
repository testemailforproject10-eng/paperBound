import XCTest
@testable import Paperbound

final class PageTurnVisibilityTests: XCTestCase {

    func testForwardTurnIdentifiesTheIncomingUnitAtFivePercent() throws {
        let visibility = try XCTUnwrap(PageTurnVisibility.incomingPage(
            offset: 105,
            direction: 5,
            pageWidth: 100,
            unitCount: 4
        ))

        XCTAssertEqual(visibility.unit, 2)
        XCTAssertEqual(visibility.fraction, 0.05, accuracy: 0.0001)
        XCTAssertTrue(visibility.qualifiesForReveal)
    }

    func testBackwardTurnMeasuresTheLowerUnitFromItsLeadingEdge() throws {
        let visibility = try XCTUnwrap(PageTurnVisibility.incomingPage(
            offset: 95,
            direction: -5,
            pageWidth: 100,
            unitCount: 4
        ))

        XCTAssertEqual(visibility.unit, 0)
        XCTAssertEqual(visibility.fraction, 0.05, accuracy: 0.0001)
        XCTAssertTrue(visibility.qualifiesForReveal)
    }

    func testTurnBelowFivePercentDoesNotStartTheReveal() throws {
        let visibility = try XCTUnwrap(PageTurnVisibility.incomingPage(
            offset: 104,
            direction: 4,
            pageWidth: 100,
            unitCount: 4
        ))

        XCTAssertEqual(visibility.unit, 2)
        XCTAssertFalse(visibility.qualifiesForReveal)
    }

    func testExactPagingBoundariesBelongToTheFullyVisiblePage() throws {
        let forward = try XCTUnwrap(PageTurnVisibility.incomingPage(
            offset: 200,
            direction: 1,
            pageWidth: 100,
            unitCount: 4
        ))
        let backward = try XCTUnwrap(PageTurnVisibility.incomingPage(
            offset: 200,
            direction: -1,
            pageWidth: 100,
            unitCount: 4
        ))

        XCTAssertEqual(forward, PageTurnVisibility(unit: 2, fraction: 1))
        XCTAssertEqual(backward, PageTurnVisibility(unit: 2, fraction: 1))
    }

    func testInvalidGeometryAndOutOfRangeUnitsAreIgnored() {
        XCTAssertNil(PageTurnVisibility.incomingPage(offset: 10, direction: 1, pageWidth: 0, unitCount: 4))
        XCTAssertNil(PageTurnVisibility.incomingPage(offset: 10, direction: 0, pageWidth: 100, unitCount: 4))
        XCTAssertEqual(PageTurnVisibility.incomingPage(offset: 0, direction: -1, pageWidth: 100, unitCount: 4),
                       PageTurnVisibility(unit: 0, fraction: 1))
        XCTAssertNil(PageTurnVisibility.incomingPage(offset: 400, direction: 1, pageWidth: 100, unitCount: 4))
    }
}
