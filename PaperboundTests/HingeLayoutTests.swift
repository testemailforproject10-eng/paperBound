//
//  HingeLayoutTests.swift
//  PaperboundTests
//
//  The hinge path, added when the project moved to the iOS 27.1 SDK.
//
//  `UIHingeInteraction` cannot be driven from a test, and no simulator on this
//  machine can fold, so what is pinned here is everything between the reported
//  status and the layout: the mapping, the fallbacks, the honesty flags and the
//  angle's effect on shading. `HingeSnapshot` is a plain value precisely so
//  that this is possible without the API in the loop.
//

import CoreGraphics
import UIKit
import XCTest
@testable import Paperbound

final class HingeSnapshotTests: XCTestCase {

    func testOpennessRunsFromShutToFlat() {
        XCTAssertEqual(HingeSnapshot(status: .closed, angle: 0).openness, 0, accuracy: 0.001)
        XCTAssertEqual(
            HingeSnapshot(status: .partiallyOpen, angle: .pi / 2).openness,
            0.5,
            accuracy: 0.001,
            "90° is half open."
        )
        XCTAssertEqual(
            HingeSnapshot(status: .fullyOpen, angle: .pi).openness,
            1.0,
            accuracy: 0.001,
            "180° is flat."
        )
    }

    func testOpennessClampsRatherThanRunningOffTheEnd() {
        // The angle's precision is system policy, so a reading past flat or
        // below shut must not produce an out-of-range multiplier.
        XCTAssertEqual(HingeSnapshot(status: .fullyOpen, angle: .pi * 1.4).openness, 1.0, accuracy: 0.001)
        XCTAssertEqual(HingeSnapshot(status: .partiallyOpen, angle: -0.4).openness, 0.0, accuracy: 0.001)
    }

    func testAnUnreportedHingeHasNoOpennessAndSaysSo() {
        for snapshot in [HingeSnapshot.unavailable, HingeSnapshot(status: .unknown, angle: 1.2)] {
            XCTAssertFalse(snapshot.isReported)
            XCTAssertEqual(snapshot.openness, 0)
        }
        // An angle sent alongside "unknown" must not leak into the shading.
        XCTAssertEqual(HingeSnapshot(status: .unknown, angle: .pi).openness, 0)
    }

    func testDescriptionsNeverClaimMoreThanTheHingeSaid() {
        XCTAssertEqual(HingeSnapshot.unavailable.description, "no hinge")
        XCTAssertEqual(HingeSnapshot(status: .unknown, angle: 0).description, "hinge, position unknown")
        XCTAssertEqual(HingeSnapshot(status: .closed, angle: 0).description, "hinge closed")
        XCTAssertEqual(HingeSnapshot(status: .fullyOpen, angle: .pi).description, "hinge fully open")
        XCTAssertEqual(
            HingeSnapshot(status: .partiallyOpen, angle: .pi / 2).description,
            "hinge 90° open"
        )
    }
}

final class HingePostureTests: XCTestCase {

    private let bookAspect = 648.0 / 432.0
    private let innerLandscapeSurface = CGSize(width: 951, height: 590)
    private let coverSurface = CGSize(width: 386, height: 522)

    /// A device that has only ever been seen on one display — so display
    /// observation has nothing to offer and would fall back to geometry.
    private func unfoldedOnce(_ screen: CGSize) -> DisplaySnapshot {
        DisplaySnapshot(
            screenSize: screen,
            windowSize: screen,
            safeAreaInsets: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 0),
            scale: 3,
            distinctScreensSeen: 1,
            isOnLargestSeenScreen: true,
            largestSeenScreenSize: screen
        )
    }

    private func provider(_ status: HingeSnapshot.Status, angle: Double = 0, screen: CGSize) -> HingePostureProvider {
        HingePostureProvider(
            hinge: HingeSnapshot(status: status, angle: angle),
            display: unfoldedOnce(screen)
        )
    }

    // MARK: - Mapping

    func testClosedReadsAsFolded() {
        let posture = provider(.closed, screen: DuoDisplayReference.coverScreen)
            .posture(in: coverSurface)
        XCTAssertEqual(posture, .folded)
    }

    func testPartlyOpenIsTheBookPosture() {
        // The state display identity can never see: a device standing open at
        // an angle is neither its cover screen nor a flat slab.
        let posture = provider(.partiallyOpen, angle: .pi / 2, screen: DuoDisplayReference.innerScreen)
            .posture(in: innerLandscapeSurface)
        XCTAssertEqual(posture, .bookLike)
    }

    func testFullyOpenIsAlsoBookPosture() {
        let posture = provider(.fullyOpen, angle: .pi, screen: DuoDisplayReference.innerScreen)
            .posture(in: innerLandscapeSurface)
        XCTAssertEqual(posture, .bookLike)
    }

    // MARK: - What the hinge buys over display observation

    func testTheHingeKnowsBeforeTheDeviceHasEverBeenFolded() {
        // One display seen. Display observation cannot claim a posture here and
        // says so; the hinge can, and does.
        let display = DisplayPostureProvider(snapshot: unfoldedOnce(DuoDisplayReference.coverScreen))
        XCTAssertFalse(display.reportsRealPosture)
        XCTAssertEqual(display.posture(in: coverSurface), .flat)

        let hinge = provider(.closed, screen: DuoDisplayReference.coverScreen)
        XCTAssertTrue(hinge.reportsRealPosture)
        XCTAssertEqual(hinge.posture(in: coverSurface), .folded)
    }

    func testEvidenceNamesTheHingeWhenTheHingeAnswered() {
        let hinge = provider(.partiallyOpen, angle: .pi / 2, screen: DuoDisplayReference.innerScreen)
        XCTAssertEqual(hinge.postureEvidence, "from hinge 90° open")
    }

    // MARK: - Falling through

    func testAnUnknownHingeFallsThroughToDisplayObservation() {
        let folded = DisplaySnapshot(
            screenSize: DuoDisplayReference.coverScreen,
            windowSize: CGSize(width: 386, height: 678),
            safeAreaInsets: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 0),
            scale: 3,
            distinctScreensSeen: 2,
            isOnLargestSeenScreen: false,
            largestSeenScreenSize: DuoDisplayReference.innerScreen
        )
        let hinge = HingePostureProvider(hinge: HingeSnapshot(status: .unknown, angle: 0), display: folded)

        XCTAssertEqual(hinge.posture(in: coverSurface), .folded, "Two displays seen is still proof.")
        XCTAssertTrue(hinge.reportsRealPosture, "Display observation reported, even though the hinge did not.")
        XCTAssertTrue(hinge.postureEvidence.contains("cover display"))
    }

    func testNoHingeAndOneDisplayAdmitsItIsGuessing() {
        let hinge = HingePostureProvider(
            hinge: .unavailable,
            display: unfoldedOnce(CGSize(width: 393, height: 852))
        )
        XCTAssertFalse(hinge.reportsRealPosture)
        XCTAssertEqual(hinge.postureEvidence, "from window size")
        XCTAssertNil(hinge.hingeOpenness)
    }

    func testReservedRegionsStayAWindowFactNotAHingeOne() {
        // The hinge reports an angle; it never reports which strip of the
        // display is spoken for.
        let hinge = provider(.fullyOpen, angle: .pi, screen: DuoDisplayReference.coverScreen)
        let regions = hinge.reservedRegions(in: coverSurface)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.height, 34)
    }

    func testOnlyTheHingeReportsAnAngle() throws {
        XCTAssertNil(GeometryPostureProvider().hingeOpenness)
        XCTAssertNil(DisplayPostureProvider(snapshot: unfoldedOnce(.zero)).hingeOpenness)

        let reported = try XCTUnwrap(
            provider(.fullyOpen, angle: .pi, screen: DuoDisplayReference.innerScreen).hingeOpenness
        )
        XCTAssertEqual(reported, 1.0, accuracy: 0.001)
    }

    // MARK: - The angle, which only shades

    func testPressingTheBookFlatRelievesTheGutterShadow() {
        let halfOpen = DeviceLayoutCoordinator.shadowFlattenedByHinge(1.0, openness: 0.5)
        let flat = DeviceLayoutCoordinator.shadowFlattenedByHinge(1.0, openness: 1.0)
        XCTAssertEqual(halfOpen, 1.0, accuracy: 0.001, "Half open is the deepest crease.")
        XCTAssertLessThan(flat, halfOpen, "A book pressed flat has almost no gutter.")
        XCTAssertEqual(flat, 1.0 - DeviceLayoutCoordinator.flatGutterRelief, accuracy: 0.001)
    }

    func testWithNoAngleTheShadowIsUntouched() {
        for base in [0.4, 0.55, 0.7, 0.85, 1.0] {
            XCTAssertEqual(
                DeviceLayoutCoordinator.shadowFlattenedByHinge(base, openness: nil),
                base,
                accuracy: 0.0001
            )
        }
    }

    func testTheAngleNeverDecidesTheMode() {
        // Same surface, same everything but the angle. The page count must not
        // move, because `angle`'s precision is system policy.
        func mode(at angle: Double) -> ReadingSurfaceMode {
            DeviceLayoutCoordinator.layout(
                surfaceSize: innerLandscapeSurface,
                pageAspectRatio: bookAspect,
                presentation: .paperback,
                preference: .automatic,
                provider: provider(.partiallyOpen, angle: angle, screen: DuoDisplayReference.innerScreen)
            ).mode
        }
        XCTAssertEqual(mode(at: .pi / 3), .spread)
        XCTAssertEqual(mode(at: .pi / 2), .spread)
        XCTAssertEqual(mode(at: .pi), .spread)
    }

    func testAPartlyOpenDuoInLandscapeStillSpreadsAndShadesDeeper() {
        func layout(_ angle: Double) -> ReadingSurfaceLayout {
            DeviceLayoutCoordinator.layout(
                surfaceSize: innerLandscapeSurface,
                pageAspectRatio: bookAspect,
                presentation: .paperback,
                preference: .automatic,
                provider: provider(.partiallyOpen, angle: angle, screen: DuoDisplayReference.innerScreen)
            )
        }
        let halfOpen = layout(.pi / 2)
        let flat = layout(.pi)

        XCTAssertEqual(halfOpen.mode, .spread)
        XCTAssertEqual(flat.mode, .spread)
        XCTAssertGreaterThan(
            halfOpen.spineShadowScale,
            flat.spineShadowScale,
            "Opening the device further must flatten the spine, not deepen it."
        )
    }
}
