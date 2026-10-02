import XCTest
@testable import Paperbound

final class EnchantedInkRevealSequenceTests: XCTestCase {

    func testEnablingInkOnOpenSpreadCreatesReadyGatedVisit() throws {
        let now = Date(timeIntervalSince1970: 7_000)
        var previous = EnchantedInkRevealSequence(unit: 2, pageIdentities: ["left", "right"])
        previous.finish()
        var enabled = try XCTUnwrap(EnchantedInkRevealSequence.applyingInkChange(
            from: .instant, to: .enchanted, current: previous, unit: 2,
            pageIdentities: ["left", "right"], animationsAllowed: true, at: now
        ))
        XCTAssertNotEqual(enabled.visitID, previous.visitID)
        XCTAssertTrue(enabled.isEligible)
        XCTAssertEqual(enabled.activation(for: "left")?.state, .waiting)
        XCTAssertFalse(enabled.pageBecameReady("left", visitID: previous.visitID,
                                             revealSeed: 1, at: now))
        enabled.pageBecameReady("left", visitID: enabled.visitID, revealSeed: 1, at: now)
        XCTAssertEqual(enabled.phase, .waiting)
        enabled.pageBecameReady("right", visitID: enabled.visitID, revealSeed: 2, at: now)
        XCTAssertEqual(enabled.phase, .revealing)
        XCTAssertEqual(enabled.startDates["left"], enabled.startDates["right"])
        XCTAssertNil(EnchantedInkRevealSequence.applyingInkChange(
            from: .enchanted, to: .instant, current: enabled, unit: 2,
            pageIdentities: enabled.pageIdentities, animationsAllowed: true, at: now
        ))
    }

    func testOtherEffectChangesPreserveInkVisitAndAccessibilityFinishesEnable() throws {
        let now = Date(timeIntervalSince1970: 7_000)
        var active = EnchantedInkRevealSequence(unit: 0, pageIdentities: ["page"])
        active.updateVisibility(1, at: now)
        active.pageBecameReady("page", visitID: active.visitID, revealSeed: 1, at: now)
        XCTAssertEqual(EnchantedInkRevealSequence.applyingInkChange(
            from: .enchanted, to: .enchanted, current: active, unit: 0,
            pageIdentities: ["page"], animationsAllowed: true, at: now
        ), active)
        let suppressed = try XCTUnwrap(EnchantedInkRevealSequence.applyingInkChange(
            from: .instant, to: .enchanted, current: nil, unit: 0,
            pageIdentities: ["page"], animationsAllowed: false, at: now
        ))
        XCTAssertEqual(suppressed.activation(for: "page")?.state, .finished)
        XCTAssertEqual(suppressed.phase, .finished)
    }

    func testEnchantedPageDurationsAreStableAndVaryFromThreeToFourSeconds() {
        let quick = InkBehavior.enchanted.revealDurationSeconds(seed: 1)
        let slow = InkBehavior.enchanted.revealDurationSeconds(seed: .max)

        XCTAssertEqual(InkBehavior.enchanted.revealDuration, .milliseconds(3500), "The nominal pace is halfway through the range.")
        XCTAssertEqual(quick, InkBehavior.enchanted.revealDurationSeconds(seed: 1))
        XCTAssertGreaterThanOrEqual(quick, 3.0)
        XCTAssertLessThan(quick, 3.5)
        XCTAssertGreaterThan(slow, 3.5)
        XCTAssertLessThanOrEqual(slow, 4.0)
    }

    func testSpreadWaitsForBothImagesThenStartsBothPagesTogether() throws {
        let eligibleAt = Date(timeIntervalSince1970: 1_000)
        let readyAt = eligibleAt.addingTimeInterval(2)
        let quickDuration = InkBehavior.enchanted.revealDurationSeconds(seed: 1)
        var sequence = EnchantedInkRevealSequence(unit: 3, pageIdentities: ["left", "right"])

        sequence.updateVisibility(0.5, at: eligibleAt)
        XCTAssertTrue(sequence.pageBecameReady("left", visitID: sequence.visitID, revealSeed: 1, at: eligibleAt))
        sequence.updateVisibility(1, at: eligibleAt)
        XCTAssertEqual(sequence.phase, .waiting)
        XCTAssertEqual(try XCTUnwrap(sequence.activation(for: "left")).state, .waiting)

        XCTAssertTrue(sequence.pageBecameReady("right", visitID: sequence.visitID, revealSeed: .max, at: readyAt))
        let left = try XCTUnwrap(sequence.activation(for: "left"))
        let right = try XCTUnwrap(sequence.activation(for: "right"))
        XCTAssertEqual(sequence.phase, .revealing)
        XCTAssertEqual(left.state, .revealing(startDate: readyAt, durationSeconds: quickDuration))
        XCTAssertEqual(right.state, .revealing(
            startDate: readyAt,
            durationSeconds: InkBehavior.enchanted.revealDurationSeconds(seed: .max)
        ))
    }

    func testSpreadPagesFinishIndependentlyAfterTheirOwnDurations() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        let quickDuration = InkBehavior.enchanted.revealDurationSeconds(seed: 1)
        let slowDuration = InkBehavior.enchanted.revealDurationSeconds(seed: .max)
        var sequence = EnchantedInkRevealSequence(unit: 2, pageIdentities: ["left", "right"])
        sequence.pageBecameReady("left", visitID: sequence.visitID, revealSeed: 1, at: start)
        sequence.pageBecameReady("right", visitID: sequence.visitID, revealSeed: .max, at: start)
        sequence.updateVisibility(1, at: start)

        XCTAssertEqual(try XCTUnwrap(sequence.activation(for: "left")).state, .revealing(startDate: start, durationSeconds: quickDuration))
        XCTAssertEqual(try XCTUnwrap(sequence.activation(for: "right")).state, .revealing(
            startDate: start,
            durationSeconds: slowDuration
        ))

        XCTAssertTrue(sequence.pageDidFinish(
            "left",
            visitID: sequence.visitID,
            startedAt: start,
            at: start.addingTimeInterval(quickDuration)
        ))
        XCTAssertEqual(try XCTUnwrap(sequence.activation(for: "left")).state, .finished)
        XCTAssertEqual(try XCTUnwrap(sequence.activation(for: "right")).state, .revealing(
            startDate: start,
            durationSeconds: slowDuration
        ))
        XCTAssertEqual(sequence.phase, .revealing)

        XCTAssertTrue(sequence.pageDidFinish(
            "right",
            visitID: sequence.visitID,
            startedAt: start,
            at: start.addingTimeInterval(slowDuration)
        ))
        XCTAssertEqual(sequence.phase, .finished)
    }

    func testEachPageWaitsForItsImageAndForTheTurnToLand() throws {
        let start = Date(timeIntervalSince1970: 3_000)
        var sequence = EnchantedInkRevealSequence(unit: 1, pageIdentities: ["page"])

        sequence.updateVisibility(0.05, at: start)
        sequence.pageBecameReady("page", visitID: sequence.visitID, revealSeed: 123, at: start)
        XCTAssertEqual(sequence.phase, .waiting, "A page still turning stays blank.")
        sequence.updateVisibility(0.95, at: start.addingTimeInterval(0.5))
        XCTAssertEqual(sequence.phase, .waiting, "Nearly open is not open.")

        sequence.updateVisibility(1, at: start.addingTimeInterval(1))
        let activation = try XCTUnwrap(sequence.activation(for: "page"))
        XCTAssertEqual(activation.state, .revealing(
            startDate: start.addingTimeInterval(1),
            durationSeconds: InkBehavior.enchanted.revealDurationSeconds(seed: 123)
        ))
    }

    func testStaleReadinessAndCompletionAreRejected() {
        let start = Date(timeIntervalSince1970: 4_000)
        let duration = InkBehavior.enchanted.revealDurationSeconds(seed: 1)
        var sequence = EnchantedInkRevealSequence(unit: 0, pageIdentities: ["page"])
        XCTAssertFalse(sequence.pageBecameReady("page", visitID: UUID(), revealSeed: 1, at: start))
        XCTAssertEqual(sequence.phase, .waiting)

        sequence.pageBecameReady("page", visitID: sequence.visitID, revealSeed: 1, at: start)
        sequence.updateVisibility(1, at: start)
        XCTAssertFalse(sequence.pageDidFinish(
            "page",
            visitID: UUID(),
            startedAt: start,
            at: start.addingTimeInterval(duration)
        ))
        XCTAssertFalse(sequence.pageDidFinish(
            "page",
            visitID: sequence.visitID,
            startedAt: start.addingTimeInterval(-1),
            at: start.addingTimeInterval(duration)
        ))
        XCTAssertEqual(sequence.phase, .revealing)

        XCTAssertTrue(sequence.pageDidFinish(
            "page",
            visitID: sequence.visitID,
            startedAt: start,
            at: start.addingTimeInterval(duration)
        ))
        XCTAssertFalse(sequence.pageDidFinish(
            "page",
            visitID: sequence.visitID,
            startedAt: start,
            at: start.addingTimeInterval(4)
        ))
    }

    func testOddFinalPageUsesItsSeededDuration() throws {
        let start = Date(timeIntervalSince1970: 5_000)
        var sequence = EnchantedInkRevealSequence(unit: 4, pageIdentities: ["last-page"])
        sequence.pageBecameReady("last-page", visitID: sequence.visitID, revealSeed: 456, at: start)
        sequence.updateVisibility(1, at: start)

        let duration = InkBehavior.enchanted.revealDurationSeconds(seed: 456)
        XCTAssertTrue(sequence.pageDidFinish(
            "last-page",
            visitID: sequence.visitID,
            startedAt: start,
            at: start.addingTimeInterval(duration)
        ))
        XCTAssertEqual(sequence.phase, .finished)
    }

    func testLayoutOrAccessibilityCompletionFinishesEveryPage() throws {
        let start = Date(timeIntervalSince1970: 6_000)
        var sequence = EnchantedInkRevealSequence(unit: 0, pageIdentities: ["left", "right"])
        sequence.pageBecameReady("left", visitID: sequence.visitID, revealSeed: 1, at: start)
        sequence.pageBecameReady("right", visitID: sequence.visitID, revealSeed: 2, at: start)
        sequence.updateVisibility(1, at: start)

        sequence.finish()

        XCTAssertEqual(sequence.phase, .finished)
        XCTAssertEqual(try XCTUnwrap(sequence.activation(for: "left")).state, .finished)
        XCTAssertEqual(try XCTUnwrap(sequence.activation(for: "right")).state, .finished)
    }

    func testAStartDelayKeepsTheLandedPageBlankThenFinishesOnTheDelayedClock() throws {
        let landed = Date(timeIntervalSince1970: 5_000)
        let duration = InkBehavior.enchanted.revealDurationSeconds(seed: 7)
        var sequence = EnchantedInkRevealSequence(unit: 2, pageIdentities: ["page"], startDelay: 2.5)
        sequence.pageBecameReady("page", visitID: sequence.visitID, revealSeed: 7, at: landed)
        sequence.updateVisibility(1, at: landed)

        let start = landed.addingTimeInterval(2.5)
        XCTAssertEqual(try XCTUnwrap(sequence.activation(for: "page")).state,
                       .revealing(startDate: start, durationSeconds: duration))
        XCTAssertFalse(sequence.pageDidFinish("page", visitID: sequence.visitID, startedAt: start,
                                              at: landed.addingTimeInterval(duration)),
                       "The pause does not count towards the reveal.")
        XCTAssertTrue(sequence.pageDidFinish("page", visitID: sequence.visitID, startedAt: start,
                                             at: start.addingTimeInterval(duration)))
    }
}
