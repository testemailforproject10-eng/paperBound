//
//  DamageGeneratorTests.swift
//  PaperboundTests
//
//  The wear system's contract, stated as tests:
//
//    · the same sheet is always damaged the same way
//    · different sheets, books and copies are damaged differently
//    · pristine removes nothing
//    · paper, binding and lighting do not move a single tear
//

import XCTest
@testable import Paperbound

final class DamageGeneratorTests: XCTestCase {

    private let documentID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let bookSeed: UInt64 = 0xDEAD_BEEF_CAFE_1234

    private func generate(
        page: String = "pdf:7",
        environment: ReadingEnvironment = .wellReadPaperback,
        documentID: UUID? = nil,
        bookSeed: UInt64? = nil,
        spine: PageEdge = .left
    ) -> PageConditionData {
        DamageGenerator.generate(
            documentID: documentID ?? self.documentID,
            bookSeed: bookSeed ?? self.bookSeed,
            stablePageID: page,
            environment: environment,
            spine: spine
        )
    }

    // MARK: - Determinism

    func testSameInputsProduceIdenticalDamage() {
        let first = generate()
        let second = generate()
        XCTAssertEqual(first, second, "A sheet must look identical every time it is visited.")
    }

    func testDamageSurvivesEncodingRoundTrip() throws {
        let original = generate()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PageConditionData.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testDifferentPagesDifferFromEachOther() {
        let page7 = generate(page: "pdf:7")
        let page8 = generate(page: "pdf:8")
        XCTAssertNotEqual(page7.damage, page8.damage)
        XCTAssertNotEqual(page7.seed, page8.seed)
    }

    func testDifferentCopiesOfTheSameBookWearDifferently() {
        let copyA = generate(bookSeed: 1)
        let copyB = generate(bookSeed: 2)
        XCTAssertNotEqual(copyA.damage, copyB.damage)
    }

    func testDifferentDocumentsWearDifferently() {
        let other = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        XCTAssertNotEqual(generate().damage, generate(documentID: other).damage)
    }

    // MARK: - Pristine

    func testPristineRemovesNothing() {
        let condition = generate(environment: .cleanPaper)
        XCTAssertTrue(condition.isPristine)
        XCTAssertTrue(condition.damage.isEmpty)
        XCTAssertTrue(condition.subtractiveDamage.isEmpty)
    }

    func testZeroIntensityRemovesNothing() {
        var environment = ReadingEnvironment.oldJournal
        environment.intensity = 0
        XCTAssertTrue(generate(environment: environment).isPristine)
    }

    func testPristineVariantOfADamagedEnvironmentIsClean() {
        let damaged = ReadingEnvironment.oldJournal
        XCTAssertFalse(generate(environment: damaged).isPristine)
        XCTAssertTrue(generate(environment: damaged.pristineVariant).isPristine)
    }

    // MARK: - Independence of the four dimensions

    func testMaterialDoesNotMoveDamage() {
        var cream = ReadingEnvironment.wellReadPaperback
        cream.material = .cream
        var dark = ReadingEnvironment.wellReadPaperback
        dark.material = .dark
        XCTAssertEqual(
            generate(environment: cream).damage,
            generate(environment: dark).damage,
            "Changing the paper stock must not shuffle the wear."
        )
    }

    func testPresentationAndLightingDoNotMoveDamage() {
        var journal = ReadingEnvironment.wellReadPaperback
        journal.presentation = .oldJournal
        journal.lighting = .flat
        var hardcover = ReadingEnvironment.wellReadPaperback
        hardcover.presentation = .hardcover
        hardcover.lighting = .directional
        XCTAssertEqual(generate(environment: journal).damage, generate(environment: hardcover).damage)
    }

    func testRenamingAPresetDoesNotMoveDamage() {
        var renamed = ReadingEnvironment.wellReadPaperback
        renamed.id = "custom.abcdef"
        renamed.name = "Custom"
        XCTAssertEqual(generate(environment: renamed).damage, generate().damage)
    }

    func testIntensityChangesDamage() {
        var gentle = ReadingEnvironment.wellReadPaperback
        gentle.intensity = 0.2
        var heavy = ReadingEnvironment.wellReadPaperback
        heavy.intensity = 0.95
        XCTAssertNotEqual(generate(environment: gentle).damage, generate(environment: heavy).damage)
    }

    // MARK: - Severity ordering

    func testHeavierConditionsRemoveMoreOfTheSheet() {
        func subtractiveCount(_ condition: PageCondition) -> Int {
            var environment = ReadingEnvironment.wellReadPaperback
            environment.condition = condition
            environment.intensity = 1.0
            // Average across many sheets: any one page may buck the trend.
            return (0..<40).reduce(0) { total, page in
                total + generate(page: "pdf:\(page)", environment: environment).subtractiveDamage.count
            }
        }

        let light = subtractiveCount(.lightWear)
        let loved = subtractiveCount(.wellLoved)
        let damaged = subtractiveCount(.damaged)

        XCTAssertGreaterThan(loved, light)
        XCTAssertGreaterThan(damaged, loved)
    }

    func testOnlyDamagedConditionPunchesHoles() {
        func holeCount(_ condition: PageCondition) -> Int {
            var environment = ReadingEnvironment.wellReadPaperback
            environment.condition = condition
            environment.intensity = 1.0
            return (0..<40).reduce(0) { total, page in
                total + generate(page: "pdf:\(page)", environment: environment).damage.filter {
                    if case .hole = $0 { return true }
                    return false
                }.count
            }
        }
        XCTAssertEqual(holeCount(.lightWear), 0)
        XCTAssertGreaterThan(holeCount(.damaged), 0)
    }

    // MARK: - Binding protects the spine

    func testTheBoundEdgeIsDamagedLeastOften() {
        var environment = ReadingEnvironment.oldJournal
        environment.intensity = 1.0

        var perEdge: [PageEdge: Int] = [:]
        for page in 0..<250 {
            let condition = generate(page: "pdf:\(page)", environment: environment, spine: .left)
            for element in condition.damage {
                if case let .edgeTear(tear) = element {
                    perEdge[tear.edge, default: 0] += 1
                }
            }
        }

        let spineTears = perEdge[.left] ?? 0
        let foreEdgeTears = perEdge[.right] ?? 0
        XCTAssertGreaterThan(foreEdgeTears, spineTears * 3,
                             "The fore-edge should take far more damage than the bound edge.")
    }

    func testSpineEdgeFollowsPageParity() {
        XCTAssertEqual(DamageGenerator.spineEdge(forPageIndex: 0), .left)
        XCTAssertEqual(DamageGenerator.spineEdge(forPageIndex: 1), .right)
        XCTAssertEqual(DamageGenerator.spineEdge(forPageIndex: 2), .left)
    }

    // MARK: - Geometry sanity

    func testEveryDefectStaysInReasonableNormalizedBounds() {
        var environment = ReadingEnvironment.oldJournal
        environment.intensity = 1.0

        for page in 0..<120 {
            let condition = generate(page: "pdf:\(page)", environment: environment)
            for element in condition.damage {
                switch element {
                case let .edgeTear(tear):
                    XCTAssertTrue((0...1).contains(tear.position))
                    XCTAssertGreaterThan(tear.depth, 0)
                    XCTAssertLessThan(tear.depth, 0.2)
                    XCTAssertLessThanOrEqual(tear.length, 0.55)
                case let .lostCorner(corner):
                    XCTAssertGreaterThan(corner.reach, 0)
                    XCTAssertLessThan(corner.reach, 0.25)
                case let .hole(hole):
                    XCTAssertGreaterThan(hole.radius, 0)
                    // Holes must never touch the sheet's edge.
                    XCTAssertGreaterThan(hole.center.x - hole.radius, 0)
                    XCTAssertLessThan(hole.center.x + hole.radius, 1)
                    XCTAssertGreaterThan(hole.center.y - hole.radius, 0)
                    XCTAssertLessThan(hole.center.y + hole.radius, 1)
                case let .stain(stain):
                    XCTAssertGreaterThan(stain.radius, 0)
                    XCTAssertLessThanOrEqual(stain.opacity, 0.4)
                case let .crease(crease):
                    XCTAssertNotEqual(crease.from, crease.to)
                case let .foxing(foxing):
                    XCTAssertGreaterThan(foxing.count, 0)
                case let .char(burn):
                    XCTAssertGreaterThan(burn.scorchRadius, 0)
                    XCTAssertLessThan(burn.scorchRadius, 0.35)
                    // The scorch always reaches past the hole it made, or the
                    // burn would read as a punch rather than as fire.
                    XCTAssertGreaterThan(burn.scorchRadius, burn.coreRadius)
                case let .chip(chip):
                    XCTAssertTrue((0...1).contains(chip.position))
                    XCTAssertGreaterThan(chip.depth, 0)
                    XCTAssertLessThan(chip.depth, 0.2)
                    XCTAssertLessThanOrEqual(chip.length, 0.55)
                case let .crack(crack):
                    XCTAssertNotEqual(crack.from, crack.to)
                    XCTAssertGreaterThanOrEqual(crack.branches, 0)
                case let .patina(patina):
                    XCTAssertGreaterThan(patina.radius, 0)
                    XCTAssertLessThanOrEqual(patina.opacity, 0.5)
                case let .scratch(scratch):
                    XCTAssertNotEqual(scratch.from, scratch.to)
                    XCTAssertGreaterThan(scratch.depth, 0)
                    XCTAssertLessThanOrEqual(scratch.depth, 1)
                }
            }
        }
    }

    func testSubtractiveClassificationIsCorrect() {
        let tear = DamageElement.edgeTear(
            EdgeTear(edge: .top, position: 0.5, length: 0.1, depth: 0.02, roughness: 0.5, seed: 1)
        )
        let stain = DamageElement.stain(
            Stain(center: NormalizedPoint(0.5, 0.5), radius: 0.1, opacity: 0.1, warmth: 0.5, softness: 0.5, seed: 1)
        )
        XCTAssertTrue(tear.isSubtractive)
        XCTAssertFalse(stain.isSubtractive)
    }
}
