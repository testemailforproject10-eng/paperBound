//
//  DuoLayoutTests.swift
//  PaperboundTests
//
//  iPhone Duo behaviour, pinned to the geometry the device actually reports.
//
//  Measured on the iPhone Duo simulator (iOS 27.1) with the app's own debug
//  HUD, not guessed:
//
//      cover display   466 × 678 pt @3x
//      cover window    386 × 678 pt        (80pt reserved for the sensor strip)
//      safe insets     top 0, bottom 34
//      inner display   669 × 951 pt @3x    (from the device profile)
//
//  The simulator on this machine offers no fold control and there is no
//  Simulator.app, so the unfolded case cannot be exercised interactively. It is
//  covered here instead, at the exact reported geometry, through the same
//  coordinator the live app uses.
//

import CoreGraphics
import UIKit
import XCTest
@testable import Paperbound

final class DuoLayoutTests: XCTestCase {

    /// The sample book's page shape, 6 × 9 inches.
    private let bookAspect = 648.0 / 432.0

    /// What the app is really handed on the cover screen, controls showing.
    private let coverWindow = CGSize(width: 386, height: 678)
    private let coverSurface = CGSize(width: 386, height: 522)
    private let innerPortraitSurface = CGSize(width: 669, height: 860)
    private let innerLandscapeSurface = CGSize(width: 951, height: 590)

    private func snapshot(
        screen: CGSize,
        window: CGSize,
        insets: UIEdgeInsets = UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 0),
        screensSeen: Int,
        onLargest: Bool
    ) -> DisplaySnapshot {
        DisplaySnapshot(
            screenSize: screen,
            windowSize: window,
            safeAreaInsets: insets,
            scale: 3,
            distinctScreensSeen: screensSeen,
            isOnLargestSeenScreen: onLargest,
            largestSeenScreenSize: onLargest ? screen : DuoDisplayReference.innerScreen
        )
    }

    private func layout(
        surface: CGSize,
        snapshot: DisplaySnapshot,
        preference: SpreadPreference = .automatic,
        presentation: BookPresentation = .paperback,
        divisionRegions: [CGRect] = []
    ) -> ReadingSurfaceLayout {
        DeviceLayoutCoordinator.layout(
            surfaceSize: surface,
            pageAspectRatio: bookAspect,
            presentation: presentation,
            preference: preference,
            provider: DisplayPostureProvider(snapshot: snapshot),
            divisionRegions: divisionRegions
        )
    }

    // MARK: - Reference geometry

    func testReferenceGeometryMatchesTheDeviceProfile() {
        // 1398 × 2034 @3x and 2007 × 2853 @3x.
        XCTAssertEqual(DuoDisplayReference.coverScreen, CGSize(width: 466, height: 678))
        XCTAssertEqual(DuoDisplayReference.innerScreen, CGSize(width: 669, height: 951))
        XCTAssertEqual(DuoDisplayReference.innerScreenLandscape, CGSize(width: 951, height: 669))
        // The inner display really is the larger one.
        XCTAssertGreaterThan(
            DuoDisplayReference.innerScreen.width * DuoDisplayReference.innerScreen.height,
            DuoDisplayReference.coverScreen.width * DuoDisplayReference.coverScreen.height
        )
    }

    // MARK: - Folded, on the cover screen

    func testCoverScreenReadsAsASinglePage() {
        let folded = snapshot(
            screen: DuoDisplayReference.coverScreen,
            window: coverWindow,
            screensSeen: 2,
            onLargest: false
        )
        let result = layout(surface: coverSurface, snapshot: folded)
        XCTAssertEqual(result.mode, .single)
        XCTAssertEqual(result.posture, .folded)
        XCTAssertTrue(result.reportsRealPosture)
        XCTAssertEqual(result.spineFraction, 0)
    }

    func testAClosedDeviceRefusesASpreadEvenWhenAskedFor() {
        let folded = snapshot(
            screen: DuoDisplayReference.coverScreen,
            window: coverWindow,
            screensSeen: 2,
            onLargest: false
        )
        XCTAssertEqual(
            layout(surface: coverSurface, snapshot: folded, preference: .alwaysSpread).mode,
            .single,
            "Two pages across a 386pt cover screen is not a reading experience."
        )
    }

    func testTheCoverScreenGetsTheShallowestSpineShadow() {
        let folded = layout(
            surface: coverSurface,
            snapshot: snapshot(
                screen: DuoDisplayReference.coverScreen,
                window: coverWindow,
                screensSeen: 2,
                onLargest: false
            )
        )
        let open = layout(
            surface: innerLandscapeSurface,
            snapshot: snapshot(
                screen: DuoDisplayReference.innerScreenLandscape,
                window: DuoDisplayReference.innerScreenLandscape,
                screensSeen: 2,
                onLargest: true
            )
        )
        XCTAssertLessThan(folded.spineShadowScale, open.spineShadowScale)
    }

    func testTheReservedSensorStripBecomesAReservedRegion() {
        let folded = snapshot(
            screen: DuoDisplayReference.coverScreen,
            window: coverWindow,
            screensSeen: 2,
            onLargest: false
        )
        XCTAssertTrue(folded.windowIsInsetFromScreen, "80pt of the cover display is reserved.")
        let result = layout(surface: coverSurface, snapshot: folded)
        // Bottom home indicator, as measured.
        XCTAssertEqual(result.reservedRegions.count, 1)
        let region = try? XCTUnwrap(result.reservedRegions.first)
        XCTAssertEqual(region?.height, 34)
    }

    // MARK: - Unfolded, on the inner screen

    func testInnerScreenInLandscapeOpensToATwoPageSpread() {
        let open = snapshot(
            screen: DuoDisplayReference.innerScreenLandscape,
            window: DuoDisplayReference.innerScreenLandscape,
            screensSeen: 2,
            onLargest: true
        )
        let result = layout(surface: innerLandscapeSurface, snapshot: open)
        XCTAssertEqual(result.mode, .spread)
        XCTAssertEqual(result.posture, .bookLike)
        XCTAssertTrue(result.reportsRealPosture)
        XCTAssertGreaterThan(result.spineFraction, 0)
        XCTAssertEqual(result.spineShadowScale, 1.0, accuracy: 0.001)
    }

    func testTheSpreadGivesTwoReadablePages() {
        let open = snapshot(
            screen: DuoDisplayReference.innerScreenLandscape,
            window: DuoDisplayReference.innerScreenLandscape,
            screensSeen: 2,
            onLargest: true
        )
        let result = layout(surface: innerLandscapeSurface, snapshot: open)
        let rects = DeviceLayoutCoordinator.surfaceRects(
            in: innerLandscapeSurface,
            layout: result,
            pageAspectRatio: bookAspect
        )
        XCTAssertEqual(rects.count, 2)
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.width, DeviceLayoutCoordinator.minimumPageWidth)
            XCTAssertLessThanOrEqual(rect.height, innerLandscapeSurface.height + 0.001)
        }
        XCTAssertLessThanOrEqual(rects[0].maxX, rects[1].minX, "Pages must not overlap the gutter.")
    }

    func testInnerScreenInPortraitStaysOnOnePage() {
        let open = snapshot(
            screen: DuoDisplayReference.innerScreen,
            window: DuoDisplayReference.innerScreen,
            screensSeen: 2,
            onLargest: true
        )
        let result = layout(surface: innerPortraitSurface, snapshot: open)
        XCTAssertEqual(
            result.mode,
            .single,
            "Two 328pt columns on a 669pt-wide portrait surface read worse than one page."
        )
        XCTAssertEqual(result.posture, .bookLike)
    }

    func testActivePortraitFoldPlacesOnePageOnEachUsablePanel() throws {
        let open = snapshot(
            screen: DuoDisplayReference.innerScreen,
            window: DuoDisplayReference.innerScreen,
            screensSeen: 2,
            onLargest: true
        )
        let fold = CGRect(x: 329, y: 0, width: 11, height: innerPortraitSurface.height)
        let result = layout(
            surface: innerPortraitSurface,
            snapshot: open,
            divisionRegions: [fold]
        )

        XCTAssertEqual(result.mode, .spread)
        XCTAssertEqual(result.divisionRegion, fold)
        XCTAssertEqual(result.divisionAxis, .vertical)
        let rects = DeviceLayoutCoordinator.surfaceRects(
            in: innerPortraitSurface,
            layout: result,
            pageAspectRatio: bookAspect
        )
        XCTAssertEqual(rects.count, 2)
        XCTAssertEqual(rects[0].maxX, fold.minX, accuracy: 0.001)
        XCTAssertEqual(rects[1].minX, fold.maxX, accuracy: 0.001)
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.width, DeviceLayoutCoordinator.minimumPageWidth)
            XCTAssertEqual(rect.intersection(fold).width, 0)
        }
    }

    func testSinglePagePreferenceKeepsItsSheetInsideOneFoldPanel() throws {
        let open = snapshot(
            screen: DuoDisplayReference.innerScreen,
            window: DuoDisplayReference.innerScreen,
            screensSeen: 2,
            onLargest: true
        )
        let fold = CGRect(x: 329, y: 0, width: 11, height: innerPortraitSurface.height)
        let result = layout(
            surface: innerPortraitSurface,
            snapshot: open,
            preference: .alwaysSingle,
            divisionRegions: [fold]
        )
        let page = try XCTUnwrap(DeviceLayoutCoordinator.surfaceRects(
            in: innerPortraitSurface,
            layout: result,
            pageAspectRatio: bookAspect
        ).first)

        XCTAssertEqual(result.mode, .single)
        XCTAssertEqual(page.intersection(fold).width, 0)
    }

    func testLandscapeFoldKeepsSinglePageInOnePanel() throws {
        let landscape = DuoDisplayReference.innerScreenLandscape
        let open = snapshot(
            screen: landscape,
            window: innerLandscapeSurface,
            screensSeen: 2,
            onLargest: true
        )
        let fold = CGRect(x: 0, y: 289, width: innerLandscapeSurface.width, height: 12)
        let result = layout(
            surface: innerLandscapeSurface,
            snapshot: open,
            divisionRegions: [fold]
        )
        let page = try XCTUnwrap(DeviceLayoutCoordinator.surfaceRects(
            in: innerLandscapeSurface,
            layout: result,
            pageAspectRatio: bookAspect
        ).first)

        XCTAssertEqual(result.divisionAxis, .horizontal)
        XCTAssertEqual(result.mode, .single)
        XCTAssertTrue(page.intersection(fold).isNull || page.intersection(fold).isEmpty)
        XCTAssertTrue(page.maxY <= fold.minY || page.minY >= fold.maxY)
        XCTAssertEqual(
            DeviceLayoutCoordinator.spineEdge(position: 0, of: 2, pageIndex: 0, divisionAxis: .horizontal),
            .bottom
        )
        XCTAssertEqual(
            DeviceLayoutCoordinator.spineEdge(position: 1, of: 2, pageIndex: 1, divisionAxis: .horizontal),
            .top
        )
    }

    func testUnfoldedPortraitStillGivesABiggerPageThanTheCoverScreen() {
        func pageWidth(surface: CGSize, snapshot: DisplaySnapshot) -> CGFloat {
            let result = layout(surface: surface, snapshot: snapshot)
            return DeviceLayoutCoordinator
                .readableRects(in: surface, layout: result, pageAspectRatio: bookAspect)
                .first?.width ?? 0
        }

        let cover = pageWidth(
            surface: coverSurface,
            snapshot: snapshot(
                screen: DuoDisplayReference.coverScreen,
                window: coverWindow,
                screensSeen: 2,
                onLargest: false
            )
        )
        let inner = pageWidth(
            surface: innerPortraitSurface,
            snapshot: snapshot(
                screen: DuoDisplayReference.innerScreen,
                window: DuoDisplayReference.innerScreen,
                screensSeen: 2,
                onLargest: true
            )
        )
        XCTAssertGreaterThan(inner, cover, "Unfolding must actually buy the reader a larger page.")
    }

    // MARK: - The transition

    func testPositionIsPreservedAcrossAFold() {
        // Paging units are derived from the page index, so the same page must
        // map to a unit on both sides of the transition.
        func unit(forPageIndex index: Int, mode: ReadingSurfaceMode) -> Int {
            mode == .spread ? index / 2 : index
        }

        let pageIndex = 7
        let foldedUnit = unit(forPageIndex: pageIndex, mode: .single)
        let openUnit = unit(forPageIndex: pageIndex, mode: .spread)

        // Going back the other way must land on a unit containing page 7.
        let pagesInOpenUnit = [openUnit * 2, openUnit * 2 + 1]
        XCTAssertTrue(pagesInOpenUnit.contains(pageIndex))
        XCTAssertEqual(foldedUnit, pageIndex)
    }

    func testSpreadUnitsCoverEveryPageExactlyOnce() {
        let pageCount = 11
        var covered: Set<Int> = []
        for unit in 0..<((pageCount + 1) / 2) {
            for page in [unit * 2, unit * 2 + 1] where page < pageCount {
                XCTAssertFalse(covered.contains(page), "Page \(page) appears in two spreads.")
                covered.insert(page)
            }
        }
        XCTAssertEqual(covered, Set(0..<pageCount))
    }

    // MARK: - Honesty about what is known

    func testASingleDisplayDeviceNeverClaimsToKnowItsPosture() {
        // One display seen: this is an ordinary phone, or a Duo that has not
        // been folded yet. Either way the app must not assert a posture.
        let single = snapshot(
            screen: DuoDisplayReference.coverScreen,
            window: coverWindow,
            screensSeen: 1,
            onLargest: true
        )
        let result = layout(surface: coverSurface, snapshot: single)
        XCTAssertFalse(result.reportsRealPosture)
        XCTAssertEqual(result.postureEvidence, "from window size")
        XCTAssertEqual(result.mode, .single)
    }

    func testPostureBecomesReportedOnceASecondDisplayIsSeen() {
        let before = snapshot(
            screen: DuoDisplayReference.coverScreen,
            window: coverWindow,
            screensSeen: 1,
            onLargest: true
        )
        let after = snapshot(
            screen: DuoDisplayReference.coverScreen,
            window: coverWindow,
            screensSeen: 2,
            onLargest: false
        )
        XCTAssertFalse(layout(surface: coverSurface, snapshot: before).reportsRealPosture)

        let reported = layout(surface: coverSurface, snapshot: after)
        XCTAssertTrue(reported.reportsRealPosture)
        XCTAssertTrue(reported.postureEvidence.contains("cover display"))
    }

    func testDisplayDescriptionNamesTheScreenOnlyWhenItCan() {
        let lonely = snapshot(
            screen: DuoDisplayReference.coverScreen,
            window: coverWindow,
            screensSeen: 1,
            onLargest: true
        )
        XCTAssertEqual(lonely.displayDescription, "display 466×678")

        let cover = snapshot(
            screen: DuoDisplayReference.coverScreen,
            window: coverWindow,
            screensSeen: 2,
            onLargest: false
        )
        XCTAssertEqual(cover.displayDescription, "cover display 466×678")

        let inner = snapshot(
            screen: DuoDisplayReference.innerScreen,
            window: DuoDisplayReference.innerScreen,
            screensSeen: 2,
            onLargest: true
        )
        XCTAssertEqual(inner.displayDescription, "inner display 669×951")
    }

    func testAFullScreenWindowIsNotReportedAsInset() {
        let phone = snapshot(
            screen: CGSize(width: 393, height: 852),
            window: CGSize(width: 393, height: 852),
            screensSeen: 1,
            onLargest: true
        )
        XCTAssertFalse(phone.windowIsInsetFromScreen)
    }
}

final class ReadingSurfaceLayoutPlacementTests: XCTestCase {

    func testHingeShadingChangeDoesNotChangePagePlacement() {
        let previous = ReadingSurfaceLayout.singlePage
        var next = previous
        next.spineShadowScale = 0.9

        XCTAssertFalse(next.changesPagePlacement(comparedTo: previous))
    }

    func testFoldDivisionChangeChangesPagePlacement() {
        var previous = ReadingSurfaceLayout.singlePage
        previous.mode = .spread
        previous.divisionAxis = .vertical
        previous.divisionRegion = CGRect(x: 390, y: 0, width: 24, height: 800)
        var next = previous
        next.divisionAxis = .horizontal
        next.divisionRegion = CGRect(x: 0, y: 390, width: 800, height: 24)

        XCTAssertTrue(next.changesPagePlacement(comparedTo: previous))
    }
}

// MARK: - The observer itself

@MainActor
final class DisplayObserverTests: XCTestCase {

    func testAFreshObserverKnowsNothing() {
        let observer = DisplayObserver()
        XCTAssertEqual(observer.snapshot, .unknown)
        XCTAssertFalse(observer.snapshot.isUsable)
        XCTAssertFalse(observer.snapshot.hasMultipleDisplays)
    }

    func testRefreshReadsTheHostScreenAndCountsItOnce() {
        let observer = DisplayObserver()
        observer.refresh()
        // Running inside the test host there is exactly one display.
        guard observer.snapshot.isUsable else {
            return XCTFail("The observer could not read the host's display")
        }
        XCTAssertEqual(observer.snapshot.distinctScreensSeen, 1)
        XCTAssertTrue(observer.snapshot.isOnLargestSeenScreen)
        XCTAssertFalse(observer.snapshot.hasMultipleDisplays, "One display is not evidence of a fold.")

        // Refreshing again must not invent a second display.
        observer.refresh()
        XCTAssertEqual(observer.snapshot.distinctScreensSeen, 1)
    }

    func testResetClearsTheHistory() {
        let observer = DisplayObserver()
        observer.refresh()
        observer.resetHistory()
        XCTAssertEqual(observer.snapshot, .unknown)
    }
}
