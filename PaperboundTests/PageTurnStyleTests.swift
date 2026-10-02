//
//  PageTurnStyleTests.swift
//  PaperboundTests
//

import CoreGraphics
import XCTest
@testable import Paperbound

final class PageTurnStyleTests: XCTestCase {

    // MARK: - Which units take part

    func testSlideAndRestingUnitsHaveNoTurn() {
        XCTAssertNil(PageTurn(style: .slide, position: -0.4))
        XCTAssertNil(PageTurn(style: .curl, position: 0))
        XCTAssertNil(PageTurn(style: .curl, position: 1))
        XCTAssertNil(PageTurn(style: .curl, position: -1))
        XCTAssertNotNil(PageTurn(style: .curl, position: 0.3))
    }

    func testLowerUnitLiftsAndHigherUnitWaitsBeneath() throws {
        let lifting = try XCTUnwrap(PageTurn(style: .curl, position: -0.3))
        let beneath = try XCTUnwrap(PageTurn(style: .curl, position: 0.7))
        XCTAssertTrue(lifting.isLifting)
        XCTAssertEqual(lifting.lift, 0.3, accuracy: 0.0001)
        XCTAssertFalse(beneath.isLifting)
        XCTAssertEqual(beneath.covered, 0.7, accuracy: 0.0001)
    }

    // MARK: - Holding sheets in place

    func testCurlAndFlipHoldBothSheetsWhereTheyAre() throws {
        let width: CGFloat = 900
        for style in [PageTurnStyle.curl, .flip] {
            let lifting = try XCTUnwrap(PageTurn(style: style, position: -0.3))
            let beneath = try XCTUnwrap(PageTurn(style: style, position: 0.7))
            // Natural place in the pager plus the hold lands on the screen.
            XCTAssertEqual(-0.3 * width + lifting.holdOffset(pageWidth: width), 0, accuracy: 0.001)
            XCTAssertEqual(0.7 * width + beneath.holdOffset(pageWidth: width), 0, accuracy: 0.001)
        }
    }

    func testCoverLetsTheTopSheetTravelAndHoldsTheOneBeneath() throws {
        let width: CGFloat = 900
        let lifting = try XCTUnwrap(PageTurn(style: .cover, position: -0.3))
        let beneath = try XCTUnwrap(PageTurn(style: .cover, position: 0.7))
        XCTAssertEqual(lifting.holdOffset(pageWidth: width), 0)
        XCTAssertEqual(0.7 * width + beneath.holdOffset(pageWidth: width), 0, accuracy: 0.001)
    }

    // MARK: - Draw order

    func testTurningLeafIsOnTopForCurlAndCover() throws {
        for style in [PageTurnStyle.curl, .cover] {
            for lift in [0.1, 0.5, 0.9] as [CGFloat] {
                let lifting = try XCTUnwrap(PageTurn(style: style, position: -lift))
                let beneath = try XCTUnwrap(PageTurn(style: style, position: 1 - lift))
                XCTAssertGreaterThan(lifting.zIndex(isSpread: true), beneath.zIndex(isSpread: true))
            }
        }
    }

    func testSpreadFlipHandsOverAtHalfWay() throws {
        let early = (try XCTUnwrap(PageTurn(style: .flip, position: -0.3)),
                     try XCTUnwrap(PageTurn(style: .flip, position: 0.7)))
        XCTAssertGreaterThan(early.0.zIndex(isSpread: true), early.1.zIndex(isSpread: true))
        let late = (try XCTUnwrap(PageTurn(style: .flip, position: -0.7)),
                    try XCTUnwrap(PageTurn(style: .flip, position: 0.3)))
        XCTAssertLessThan(late.0.zIndex(isSpread: true), late.1.zIndex(isSpread: true))
        // A single sheet has no second leaf to hand over to.
        XCTAssertGreaterThan(late.0.zIndex(isSpread: false), late.1.zIndex(isSpread: false))
    }

    // MARK: - Curl geometry

    func testCurlStartsFlatAtTheOuterEdge() {
        let geometry = PageCurlGeometry(lift: 0, pageMinX: 0, pageMaxX: 400)
        XCTAssertEqual(geometry.foldX, 400, accuracy: 0.001)
    }

    func testFinishedCurlLiesMirroredOntoTheFacingPage() {
        let spine: CGFloat = 480, outer: CGFloat = 951
        let geometry = PageCurlGeometry(lift: 1, pageMinX: spine, pageMaxX: outer)
        // The leaf's outer edge lands as far left of the spine as it was right.
        XCTAssertEqual(geometry.backEdge(pageMaxX: outer), spine - (outer - spine), accuracy: 0.001)
        XCTAssertLessThan(geometry.foldX + geometry.radius, spine,
                          "Nothing of the roll should be left over the page it came from.")
    }

    func testFinishedSingleCurlLeavesTheScreen() {
        let geometry = PageCurlGeometry(lift: 1, pageMinX: 0, pageMaxX: 466)
        XCTAssertLessThan(geometry.backEdge(pageMaxX: 466), 0)
        XCTAssertLessThan(geometry.foldX + geometry.radius, 0)
    }

    func testCurlAdvancesSteadily() {
        var previous = CGFloat.greatestFiniteMagnitude
        for step in 0...20 {
            let geometry = PageCurlGeometry(lift: CGFloat(step) / 20, pageMinX: 0, pageMaxX: 400)
            XCTAssertLessThan(geometry.foldX, previous + 0.001)
            previous = geometry.foldX
        }
    }

    func testBackOfTheLeafFadesOnlyAsItLands() {
        XCTAssertEqual(PageTurnLeafEffect.landingBackAlpha(lift: 0.2), 1, accuracy: 0.0001)
        XCTAssertEqual(PageTurnLeafEffect.landingBackAlpha(lift: 1), 0, accuracy: 0.0001)
        XCTAssertGreaterThan(PageTurnLeafEffect.landingBackAlpha(lift: 0.7), 0)
        XCTAssertLessThan(PageTurnLeafEffect.landingBackAlpha(lift: 0.7), 1)
    }

    // MARK: - Flip geometry

    func testFlipLeavesMeetEdgeOnAtHalfWay() {
        XCTAssertEqual(PageFlipGeometry.liftingAngle(lift: 0.5), -90, accuracy: 0.0001)
        XCTAssertEqual(PageFlipGeometry.landingAngle(covered: 0.5), 90, accuracy: 0.0001)
        XCTAssertEqual(PageFlipGeometry.landingAngle(covered: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(PageFlipGeometry.singleAngle(lift: 1), -90, accuracy: 0.0001)
    }

    // MARK: - Settings

    @MainActor
    func testPageTurnStyleDefaultsToCurlAndPersists() throws {
        let suite = "PageTurnStyleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppSettings(defaults: defaults).pageTurnStyle, .curl)
        AppSettings(defaults: defaults).pageTurnStyle = .flip
        XCTAssertEqual(AppSettings(defaults: defaults).pageTurnStyle, .flip)
    }
}
