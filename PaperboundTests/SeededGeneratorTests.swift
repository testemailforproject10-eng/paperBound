//
//  SeededGeneratorTests.swift
//  PaperboundTests
//
//  The randomness has to be boring: same seed, same numbers, forever, on any
//  machine. These tests pin the actual byte values so that an "optimisation"
//  to the generator cannot silently reshuffle everyone's books.
//

import XCTest
@testable import Paperbound

final class SeededGeneratorTests: XCTestCase {

    // MARK: - SplitMix64

    func testKnownSequenceForSeedZero() {
        var rng = SplitMix64(seed: 0)
        // Reference values for SplitMix64 with a zero seed.
        XCTAssertEqual(rng.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(rng.next(), 0x6E78_9E6A_A1B9_65F4)
        XCTAssertEqual(rng.next(), 0x06C4_5D18_8009_454F)
    }

    func testSameSeedProducesSameStream() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        for _ in 0..<64 {
            XCTAssertEqual(a.next(), b.next())
        }
    }

    func testDifferentSeedsDiverge() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 43)
        var differences = 0
        for _ in 0..<64 where a.next() != b.next() {
            differences += 1
        }
        XCTAssertGreaterThan(differences, 60)
    }

    // MARK: - Derived helpers

    func testDoubleStaysInRange() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<5_000 {
            let value = rng.double(in: -3.5...11.25)
            XCTAssertGreaterThanOrEqual(value, -3.5)
            XCTAssertLessThanOrEqual(value, 11.25)
        }
    }

    func testUnitIsWellDistributed() {
        var rng = SplitMix64(seed: 99)
        var buckets = [Int](repeating: 0, count: 10)
        for _ in 0..<20_000 {
            let value = rng.unit()
            buckets[min(9, Int(value * 10))] += 1
        }
        for count in buckets {
            // Each decile should hold roughly 2000; allow generous slack.
            XCTAssertGreaterThan(count, 1_600)
            XCTAssertLessThan(count, 2_400)
        }
    }

    func testIntCoversItsWholeRange() {
        var rng = SplitMix64(seed: 5)
        var seen = Set<Int>()
        for _ in 0..<2_000 {
            seen.insert(rng.int(in: 3...9))
        }
        XCTAssertEqual(seen, Set(3...9))
    }

    func testDegenerateRangesAreSafe() {
        var rng = SplitMix64(seed: 5)
        XCTAssertEqual(rng.int(in: 4...4), 4)
        XCTAssertEqual(rng.double(in: 2.0...2.0), 2.0)
        XCTAssertNil(rng.pick([Int]()))
        XCTAssertNil(rng.pickWeighted([(1, 0.0), (2, 0.0)]))
    }

    func testWeightedPickFavoursHeavyOptions() {
        var rng = SplitMix64(seed: 11)
        var heavy = 0
        for _ in 0..<10_000 {
            if rng.pickWeighted([("heavy", 9.0), ("light", 1.0)]) == "heavy" { heavy += 1 }
        }
        XCTAssertGreaterThan(heavy, 8_600)
        XCTAssertLessThan(heavy, 9_400)
    }

    func testChanceHonoursItsProbability() {
        var rng = SplitMix64(seed: 13)
        var hits = 0
        for _ in 0..<10_000 where rng.chance(0.25) { hits += 1 }
        XCTAssertGreaterThan(hits, 2_200)
        XCTAssertLessThan(hits, 2_800)
        XCTAssertTrue(rng.chance(1.0))
        XCTAssertFalse(rng.chance(0.0))
    }

    // MARK: - StableHash

    func testStringHashIsStableAndNotSwiftsRandomOne() {
        // FNV-1a of "pdf:7". Pinned so a refactor cannot change everyone's wear.
        XCTAssertEqual(StableHash.hash("pdf:7"), 0x111C_5F8F_B1CD_28DE)
        XCTAssertEqual(StableHash.hash(""), 0xCBF2_9CE4_8422_2325)
    }

    func testUUIDHashIsStable() {
        let id = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        XCTAssertEqual(StableHash.hash(id), StableHash.hash(id))
        let other = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3302")!
        XCTAssertNotEqual(StableHash.hash(id), StableHash.hash(other))
    }

    func testPageSeedIsSensitiveToEveryInput() {
        let id = UUID()
        let base = StableHash.pageSeed(documentID: id, bookSeed: 1, stablePageID: "pdf:1", environmentIdentity: "a")
        XCTAssertNotEqual(base, StableHash.pageSeed(documentID: UUID(), bookSeed: 1, stablePageID: "pdf:1", environmentIdentity: "a"))
        XCTAssertNotEqual(base, StableHash.pageSeed(documentID: id, bookSeed: 2, stablePageID: "pdf:1", environmentIdentity: "a"))
        XCTAssertNotEqual(base, StableHash.pageSeed(documentID: id, bookSeed: 1, stablePageID: "pdf:2", environmentIdentity: "a"))
        XCTAssertNotEqual(base, StableHash.pageSeed(documentID: id, bookSeed: 1, stablePageID: "pdf:1", environmentIdentity: "b"))
        XCTAssertEqual(base, StableHash.pageSeed(documentID: id, bookSeed: 1, stablePageID: "pdf:1", environmentIdentity: "a"))
    }
}
