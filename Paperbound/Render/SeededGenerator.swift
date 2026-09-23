//
//  SeededGenerator.swift
//  Paperbound
//
//  Determinism is the whole point of the wear system: the same book, page and
//  environment must produce byte-identical damage on every launch, on every
//  device, forever. That rules out `SystemRandomNumberGenerator`, hashValue
//  (seeded per process) and anything touching Foundation's `arc4random`.
//
//  SplitMix64 is used because it is tiny, has no warm-up requirement, and is
//  specified precisely enough to reimplement identically elsewhere.
//

import Foundation

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension SplitMix64 {

    /// Uniform double in `range`.
    mutating func double(in range: ClosedRange<Double>) -> Double {
        guard range.upperBound > range.lowerBound else { return range.lowerBound }
        let unit = Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) // 2^53
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    /// Uniform double in `0...1`.
    mutating func unit() -> Double {
        double(in: 0...1)
    }

    /// Signed noise in `-1...1`.
    mutating func signedUnit() -> Double {
        double(in: -1...1)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        guard range.upperBound > range.lowerBound else { return range.lowerBound }
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    mutating func chance(_ probability: Double) -> Bool {
        guard probability > 0 else { return false }
        guard probability < 1 else { return true }
        return unit() < probability
    }

    mutating func pick<T>(_ elements: [T]) -> T? {
        guard !elements.isEmpty else { return nil }
        return elements[int(in: 0...(elements.count - 1))]
    }

    /// Weighted choice. Weights must be non-negative; all-zero returns nil.
    mutating func pickWeighted<T>(_ choices: [(T, Double)]) -> T? {
        let total = choices.reduce(0.0) { $0 + max(0, $1.1) }
        guard total > 0 else { return nil }
        var threshold = unit() * total
        for (value, weight) in choices {
            threshold -= max(0, weight)
            if threshold <= 0 { return value }
        }
        return choices.last?.0
    }

    /// Derives an independent child seed, so sub-features can be generated
    /// lazily without consuming the parent's stream in a fixed order.
    mutating func branchSeed() -> UInt64 {
        next()
    }
}

// MARK: - Stable hashing

/// FNV-1a. Used instead of `Hasher` because Swift's standard hashing is
/// randomly seeded per process and would move every tear on every launch.
enum StableHash {
    private static let offsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01B3

    static func hash(_ string: String) -> UInt64 {
        var result = offsetBasis
        for byte in string.utf8 {
            result ^= UInt64(byte)
            result = result &* prime
        }
        return result
    }

    static func hash(_ uuid: UUID) -> UInt64 {
        let bytes = uuid.uuid
        var result = offsetBasis
        for byte in [
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15
        ] {
            result ^= UInt64(byte)
            result = result &* prime
        }
        return result
    }

    static func combine(_ values: UInt64...) -> UInt64 {
        combine(values)
    }

    static func combine(_ values: [UInt64]) -> UInt64 {
        var result = offsetBasis
        for value in values {
            var remaining = value
            for _ in 0..<8 {
                result ^= (remaining & 0xFF)
                result = result &* prime
                remaining >>= 8
            }
        }
        return result
    }

    /// The canonical page seed: book identity, the app-assigned per-copy seed,
    /// the sheet identity and the environment's damage identity.
    static func pageSeed(
        documentID: UUID,
        bookSeed: UInt64,
        stablePageID: String,
        environmentIdentity: String
    ) -> UInt64 {
        combine(
            hash(documentID),
            bookSeed,
            hash(stablePageID),
            hash(environmentIdentity)
        )
    }
}
