import CoreGraphics
import Foundation
import XCTest
@testable import Paperbound

final class FootstepTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let visitID = UUID(uuidString: "DC45BD5B-A1E8-4B4F-83B2-402711D5AA13")!
    private let left = CGRect(x: 0, y: 0, width: 400, height: 700)
    private let right = CGRect(x: 420, y: 0, width: 400, height: 700)

    private func walker(seed: UInt64 = 7, surfaces: [CGRect]? = nil,
                        reserved: [CGRect] = []) -> FootstepController {
        FootstepController(
            visitID: visitID, seed: seed,
            surfaces: surfaces ?? [left], reservedRegions: reserved,
            startedAt: start
        )
    }

    func testDeterministicRoutesAndDistinctSeeds() {
        let first = walker()
        let second = walker()
        let other = walker(seed: 8)
        for controller in [first, second, other] { controller.prepare(through: 25) }
        XCTAssertEqual(first.plannedPrints, second.plannedPrints)
        XCTAssertNotEqual(first.plannedPrints, other.plannedPrints)
        XCTAssertFalse(first.plannedPrints.isEmpty)
    }

    func testThreeIndependentTrailsReplayDeterministically() {
        func group(seed: UInt64 = 19, surfaces: [CGRect] = [left]) -> FootstepEnsemble {
            FootstepEnsemble(
                visitID: visitID, seed: seed, surfaces: surfaces,
                reservedRegions: [], startedAt: start
            )
        }
        let first = group()
        let replay = group()
        let anotherVisit = group(seed: 20)
        for ensemble in [first, replay, anotherVisit] { ensemble.prepare(through: 45) }
        XCTAssertEqual(first.walkers.count, 3)
        for index in 0..<3 {
            XCTAssertEqual(first.walkers[index].plannedPrints,
                           replay.walkers[index].plannedPrints)
            XCTAssertNotEqual(first.walkers[index].plannedPrints,
                              anotherVisit.walkers[index].plannedPrints)
            XCTAssertFalse(first.walkers[index].plannedPrints.isEmpty)
        }
        XCTAssertNotEqual(first.walkers[0].plannedPrints,
                          first.walkers[1].plannedPrints)
        XCTAssertNotEqual(first.walkers[1].plannedPrints,
                          first.walkers[2].plannedPrints)

        let seen = Set((0...20).flatMap { second in
            first.visibleStamps(at: start.addingTimeInterval(Double(second)))
                .map(\.walkerIndex)
        })
        XCTAssertEqual(seen, Set(0..<3))
        XCTAssertTrue((0...20).contains { second in
            Set(first.visibleStamps(at: start.addingTimeInterval(Double(second)))
                .map(\.walkerIndex)).count == 3
        })
        for second in 0...45 {
            XCTAssertLessThanOrEqual(
                first.visibleStamps(at: start.addingTimeInterval(Double(second))).count,
                FootstepEnsemble.maximumVisiblePrints
            )
        }
    }

    func testThreeTrailsUseBothPagesAndPauseTogether() {
        let ensemble = FootstepEnsemble(
            visitID: visitID, seed: 31,
            surfaces: [left, right], reservedRegions: [], startedAt: start
        )
        ensemble.prepare(through: 8)
        XCTAssertEqual(ensemble.walkers[0].plannedPrints.first?.pageIndex, 0)
        XCTAssertEqual(ensemble.walkers[1].plannedPrints.first?.pageIndex, 1)
        XCTAssertEqual(ensemble.walkers[2].plannedPrints.first?.pageIndex, 0)
        ensemble.prepare(through: 75)
        for walker in ensemble.walkers {
            XCTAssertTrue(walker.plannedPrints.contains { $0.pageIndex == 0 })
            XCTAssertTrue(walker.plannedPrints.contains { $0.pageIndex == 1 })
        }
        ensemble.pause(at: start.addingTimeInterval(2))
        let stopped = ensemble.walkers.map { $0.elapsed(at: start.addingTimeInterval(9)) }
        for (actual, expected) in zip(stopped, [2.0, 1.78, 1.56]) {
            XCTAssertEqual(actual, expected, accuracy: 0.001)
        }
        ensemble.resume(at: start.addingTimeInterval(9))
        for (index, walker) in ensemble.walkers.enumerated() {
            XCTAssertEqual(walker.elapsed(at: start.addingTimeInterval(10)),
                           stopped[index] + 1, accuracy: 0.001)
        }
    }

    func testAlternatingFeetCadenceAndStride() {
        let controller = walker()
        controller.prepare(through: 15)
        let prints = controller.plannedPrints
        XCTAssertGreaterThan(prints.count, 8)
        for pair in zip(prints, prints.dropFirst()) {
            XCTAssertNotEqual(pair.0.foot, pair.1.foot)
        }
        let walkingPairs = zip(prints, prints.dropFirst()).filter { pair in
            pair.0.segmentIndex == pair.1.segmentIndex
                && (0.40...0.55).contains(pair.1.placedAt - pair.0.placedAt)
        }
        XCTAssertGreaterThan(walkingPairs.count, 4)
        for (a, b) in walkingPairs {
            let distance = hypot(b.center.x - a.center.x, b.center.y - a.center.y)
            XCTAssertGreaterThan(distance, 20)
            XCTAssertLessThan(distance, 36)
            let headingChange = atan2(sin(b.heading - a.heading), cos(b.heading - a.heading))
            XCTAssertLessThan(abs(headingChange), 1.4,
                              "segment \(a.segmentIndex), from \(a.center) to \(b.center)")
        }
    }

    func testCrossesVerticalAndStackedGuttersWithoutStampingInThem() {
        for surfaces in [
            [left, right],
            [CGRect(x: 0, y: 0, width: 400, height: 320),
             CGRect(x: 0, y: 350, width: 400, height: 320)]
        ] {
            let controller = walker(surfaces: surfaces)
            controller.prepare(through: 75)
            XCTAssertGreaterThanOrEqual(controller.segmentDestinations.count, 2)
            XCTAssertEqual(controller.segmentDestinations[1], 1)
            XCTAssertTrue(controller.plannedPrints.contains { $0.pageIndex == 1 })
            for print in controller.plannedPrints {
                XCTAssertTrue(surfaces[print.pageIndex].contains(print.center))
            }
        }
    }

    func testReservedRegionIsKeptEmpty() {
        let blocked = CGRect(x: 140, y: 0, width: 70, height: 700)
        let controller = walker(reserved: [blocked])
        controller.prepare(through: 30)
        XCTAssertFalse(controller.plannedPrints.contains { blocked.contains($0.center) })
    }

    func testPrintSettlingFadeAndLiveCount() {
        let print = FootstepPrint(foot: .left, center: .zero, heading: 0,
                                  pageIndex: 0, placedAt: 2, segmentIndex: 0)
        XCTAssertEqual(print.opacity(at: 1.99), 0)
        XCTAssertEqual(print.opacity(at: 2), 0)
        XCTAssertGreaterThan(print.opacity(at: 2.06), 0)
        XCTAssertEqual(print.opacity(at: 2.12), 0.35, accuracy: 0.001)
        XCTAssertLessThan(print.opacity(at: 4), 0.35)
        XCTAssertEqual(print.opacity(at: 5.5), 0)

        let controller = walker()
        controller.prepare(through: 90)
        for second in 0...90 {
            XCTAssertLessThanOrEqual(
                controller.visiblePrints(at: start.addingTimeInterval(Double(second))).count, 16
            )
        }
    }

    func testInjectedClockAndGesturePause() {
        var date = start
        let controller = FootstepController(
            visitID: visitID, seed: 9, surfaces: [left], reservedRegions: [],
            startedAt: start, clock: FootstepClock(now: { date })
        )
        controller.prepare(through: 10)
        date = start.addingTimeInterval(2)
        controller.pause()
        date = start.addingTimeInterval(9)
        XCTAssertEqual(controller.elapsed(at: date), 2, accuracy: 0.001)
        controller.resume()
        date = start.addingTimeInterval(10)
        XCTAssertEqual(controller.elapsed(at: date), 3, accuracy: 0.001)
        XCTAssertEqual(controller.visiblePrints(), controller.visiblePrints(at: date))
    }

    func testPaperReadinessRejectsStaleRenderAndVisit() {
        var visit = FootstepVisit(
            unit: 2, visitID: visitID,
            pageRenderTokens: ["a": "render-a", "b": "render-b"]
        )
        visit.setVisibleFraction(0.04, at: start)
        XCTAssertTrue(visit.paperReady(pageIdentity: "a", renderToken: "render-a",
                                       visitID: visitID, at: start))
        XCTAssertFalse(visit.paperReady(pageIdentity: "b", renderToken: "old",
                                        visitID: visitID, at: start))
        XCTAssertFalse(visit.paperReady(pageIdentity: "b", renderToken: "render-b",
                                        visitID: UUID(), at: start))
        XCTAssertNil(visit.startedAt)
        visit.setVisibleFraction(0.05, at: start)
        XCTAssertNil(visit.startedAt)
        XCTAssertTrue(visit.paperReady(pageIdentity: "b", renderToken: "render-b",
                                       visitID: visitID, at: start.addingTimeInterval(3)))
        XCTAssertEqual(visit.startedAt, start.addingTimeInterval(3))
    }

    func testEnvironmentDefaultsOffAndDoesNotChangeRenderIdentity() throws {
        var environment = ReadingEnvironment.cleanPaper
        XCTAssertFalse(environment.footstepsEnabled)
        let identity = environment.renderIdentity
        environment.footstepsEnabled = true
        XCTAssertEqual(environment.renderIdentity, identity)
        XCTAssertTrue(try JSONDecoder().decode(
            ReadingEnvironment.self, from: JSONEncoder().encode(environment)
        ).footstepsEnabled)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(environment)
        ) as? [String: Any])
        old.removeValue(forKey: "footstepsEnabled")
        XCTAssertFalse(try JSONDecoder().decode(
            ReadingEnvironment.self,
            from: JSONSerialization.data(withJSONObject: old)
        ).footstepsEnabled)
    }
}
