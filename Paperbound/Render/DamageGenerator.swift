//
//  DamageGenerator.swift
//  Paperbound
//
//  Turns (book, sheet, environment) into a fixed list of defects.
//
//  Two rules keep this trustworthy:
//
//  1. The random stream is consumed in a FIXED order. Adding a new defect kind
//     in the middle would reshuffle every existing page, so new kinds are
//     appended at the end and `ReadingEnvironment.generatorVersion` is bumped.
//  2. Nothing here reads the clock, the device, or the document's contents.
//     Same inputs, same output, on any machine.
//

import Foundation

enum DamageGenerator {

    /// Which edge is bound, derived from page parity so that it is a property
    /// of the *document* rather than of how many surfaces are on screen.
    /// Right-hand (recto) pages are bound on the left.
    static func spineEdge(forPageIndex index: Int) -> PageEdge {
        index.isMultiple(of: 2) ? .left : .right
    }

    static func generate(
        documentID: UUID,
        bookSeed: UInt64,
        stablePageID: String,
        environment: ReadingEnvironment,
        spine: PageEdge
    ) -> PageConditionData {

        let identity = environment.damageIdentity

        let seed = StableHash.pageSeed(
            documentID: documentID,
            bookSeed: bookSeed,
            stablePageID: stablePageID,
            environmentIdentity: identity
        )

        guard environment.condition != .pristine, environment.intensity > 0.001 else {
            return .pristine(
                documentID: documentID,
                stablePageID: stablePageID,
                environmentIdentity: identity
            )
        }

        var rng = SplitMix64(seed: seed)
        let budget = environment.condition.budget
        let substrate = environment.substrate
        let intensity = environment.intensity.clamped(to: 0...1)
        // Counts never collapse entirely at low intensity — a "well-loved" book
        // at 20% should still look handled, just gently.
        let countScale = 0.3 + 0.7 * intensity
        let sizeScale = 0.35 + 0.65 * intensity

        var damage: [DamageElement] = []

        // The substrate gates every kind, and each gate is checked BEFORE the
        // maker draws a single number. That ordering is the whole compatibility
        // story: paper allows all six original kinds, so an all-paper
        // environment consumes exactly the stream it consumed before substrates
        // existed and every book already on a shelf keeps its own wear.

        // 1 — Lost corners. Generated first because they are the most visible
        //     and their positions should not shift when other counts change.
        if substrate.allows(.lostCorner) {
            damage.append(contentsOf: makeLostCorners(
                budget: budget, spine: spine, countScale: countScale, sizeScale: sizeScale, rng: &rng
            ))
        }

        // 2 — Edge tears.
        if substrate.allows(.edgeTear) {
            damage.append(contentsOf: makeEdgeTears(
                budget: budget, spine: spine, countScale: countScale, sizeScale: sizeScale, rng: &rng
            ))
        }

        // 3 — Holes through the sheet.
        if substrate.allows(.hole) {
            damage.append(contentsOf: makeHoles(
                budget: budget, spine: spine, countScale: countScale, sizeScale: sizeScale, rng: &rng
            ))
        }

        // 4 — Creases.
        if substrate.allows(.crease) {
            damage.append(contentsOf: makeCreases(
                budget: budget, spine: spine, countScale: countScale, sizeScale: sizeScale, rng: &rng
            ))
        }

        // 5 — Stains.
        if substrate.allows(.stain) {
            damage.append(contentsOf: makeStains(
                budget: budget, countScale: countScale, sizeScale: sizeScale, rng: &rng
            ))
        }

        // 6 — Foxing clusters.
        if substrate.allows(.foxing) {
            damage.append(contentsOf: makeFoxing(
                budget: budget, countScale: countScale, sizeScale: sizeScale, rng: &rng
            ))
        }

        // Kinds 7 to 11 belong to the non-paper substrates and are appended
        // rather than interleaved, per the fixed-stream rule at the top of this
        // file. Paper allows none of them and so never reaches them.

        // 7 — Burns.
        if substrate.allows(.char) {
            damage.append(contentsOf: makeChars(
                budget: budget, spine: spine, countScale: countScale, sizeScale: sizeScale, rng: &rng
            ))
        }

        // 8 — Chips off a rigid edge.
        if substrate.allows(.chip) {
            damage.append(contentsOf: makeChips(
                budget: budget, spine: spine, substrate: substrate,
                countScale: countScale, sizeScale: sizeScale, rng: &rng
            ))
        }

        // 9 — Fractures.
        if substrate.allows(.crack) {
            damage.append(contentsOf: makeCracks(
                budget: budget, spine: spine, countScale: countScale, sizeScale: sizeScale, rng: &rng
            ))
        }

        // 10 — Oxidation.
        if substrate.allows(.patina) {
            damage.append(contentsOf: makePatina(
                budget: budget, countScale: countScale, sizeScale: sizeScale, rng: &rng
            ))
        }

        // 11 — Scored lines.
        if substrate.allows(.scratch) {
            damage.append(contentsOf: makeScratches(
                budget: budget, substrate: substrate,
                countScale: countScale, sizeScale: sizeScale, rng: &rng
            ))
        }

        return PageConditionData(
            documentID: documentID,
            stablePageID: stablePageID,
            seed: seed,
            intensity: intensity,
            environmentIdentity: identity,
            damage: damage
        )
    }

    // MARK: - Element builders

    private static func scaledCount(
        _ range: ClosedRange<Int>,
        scale: Double,
        rng: inout SplitMix64
    ) -> Int {
        guard range.upperBound > 0 else { return 0 }
        let sampled = rng.int(in: range)
        return max(range.lowerBound > 0 ? 1 : 0, Int((Double(sampled) * scale).rounded()))
    }

    private static func makeLostCorners(
        budget: DamageBudget,
        spine: PageEdge,
        countScale: Double,
        sizeScale: Double,
        rng: inout SplitMix64
    ) -> [DamageElement] {
        let count = scaledCount(budget.lostCorners, scale: countScale, rng: &rng)
        guard count > 0 else { return [] }

        var availableWeights = PageCorner.weights(spine: spine)
        var elements: [DamageElement] = []

        for _ in 0..<count {
            guard let corner = rng.pickWeighted(availableWeights) else { break }
            availableWeights.removeAll { $0.0 == corner }

            let reach = rng.double(in: budget.cornerReach) * sizeScale
            guard reach > 0.004 else { continue }
            elements.append(.lostCorner(LostCorner(
                corner: corner,
                reach: reach,
                skew: rng.double(in: -0.4...0.4),
                roughness: rng.double(in: 0.35...1.0) * budget.edgeSoftening,
                seed: rng.branchSeed()
            )))
        }
        return elements
    }

    private static func makeEdgeTears(
        budget: DamageBudget,
        spine: PageEdge,
        countScale: Double,
        sizeScale: Double,
        rng: inout SplitMix64
    ) -> [DamageElement] {
        let count = scaledCount(budget.edgeTears, scale: countScale, rng: &rng)
        guard count > 0 else { return [] }

        let weights = PageEdge.weights(spine: spine)
        var elements: [DamageElement] = []

        for _ in 0..<count {
            guard let edge = rng.pickWeighted(weights) else { break }
            let depth = rng.double(in: budget.tearDepth) * sizeScale
            guard depth > 0.002 else { continue }
            // Tears are wider than they are deep; otherwise they read as spikes.
            let length = depth * rng.double(in: 1.6...5.5)
            elements.append(.edgeTear(EdgeTear(
                edge: edge,
                position: rng.double(in: 0.06...0.94),
                length: min(length, 0.55),
                depth: depth,
                roughness: rng.double(in: 0.3...1.0) * budget.edgeSoftening,
                seed: rng.branchSeed()
            )))
        }
        return elements
    }

    private static func makeHoles(
        budget: DamageBudget,
        spine: PageEdge,
        countScale: Double,
        sizeScale: Double,
        rng: inout SplitMix64
    ) -> [DamageElement] {
        let count = scaledCount(budget.holes, scale: countScale, rng: &rng)
        guard count > 0 else { return [] }

        var elements: [DamageElement] = []
        for _ in 0..<count {
            let radius = rng.double(in: budget.holeRadius) * sizeScale
            guard radius > 0.006 else { continue }
            // Keep holes clear of the edges so they read as punctures rather
            // than as tears that failed to reach the boundary.
            let inset = radius + 0.06
            guard inset < 0.45 else { continue }
            // Bias away from the bound edge: that part of the sheet is protected.
            let xRange: ClosedRange<Double>
            switch spine {
            case .left: xRange = (inset + 0.08)...(1 - inset)
            case .right: xRange = inset...(1 - inset - 0.08)
            case .top, .bottom: xRange = inset...(1 - inset)
            }
            elements.append(.hole(Hole(
                center: NormalizedPoint(
                    rng.double(in: xRange),
                    rng.double(in: inset...(1 - inset))
                ),
                radius: radius,
                irregularity: rng.double(in: 0.25...0.8),
                seed: rng.branchSeed()
            )))
        }
        return elements
    }

    private static func makeCreases(
        budget: DamageBudget,
        spine: PageEdge,
        countScale: Double,
        sizeScale: Double,
        rng: inout SplitMix64
    ) -> [DamageElement] {
        let count = scaledCount(budget.creases, scale: countScale, rng: &rng)
        guard count > 0 else { return [] }

        var elements: [DamageElement] = []
        for _ in 0..<count {
            // A crease runs between two different edges of the sheet.
            let edges = PageEdge.allCases.filter { $0 != spine }
            guard let startEdge = rng.pick(edges) else { continue }
            guard let endEdge = rng.pick(edges.filter { $0 != startEdge }) else { continue }
            let from = pointOnEdge(startEdge, at: rng.double(in: 0.1...0.9))
            let to = pointOnEdge(endEdge, at: rng.double(in: 0.1...0.9))
            elements.append(.crease(Crease(
                from: from,
                to: to,
                // A fold catches the light; it is not a scratch. Keep it faint
                // and wide rather than dark and thin.
                strength: rng.double(in: 0.16...0.45) * sizeScale,
                width: rng.double(in: 0.006...0.020),
                seed: rng.branchSeed()
            )))
        }
        return elements
    }

    private static func makeStains(
        budget: DamageBudget,
        countScale: Double,
        sizeScale: Double,
        rng: inout SplitMix64
    ) -> [DamageElement] {
        let count = scaledCount(budget.stains, scale: countScale, rng: &rng)
        guard count > 0 else { return [] }

        var elements: [DamageElement] = []
        for _ in 0..<count {
            let radius = rng.double(in: budget.stainRadius) * sizeScale
            guard radius > 0.01 else { continue }
            // Stains may hang off the sheet; a tide line cut by the page edge
            // looks far more convincing than a blob floating in the margin.
            elements.append(.stain(Stain(
                center: NormalizedPoint(
                    rng.double(in: -0.12...1.12),
                    rng.double(in: -0.12...1.12)
                ),
                radius: radius,
                opacity: rng.double(in: budget.stainOpacity),
                warmth: rng.double(in: 0.35...1.0),
                softness: rng.double(in: 0.25...0.9),
                seed: rng.branchSeed()
            )))
        }
        return elements
    }

    private static func makeFoxing(
        budget: DamageBudget,
        countScale: Double,
        sizeScale: Double,
        rng: inout SplitMix64
    ) -> [DamageElement] {
        let count = scaledCount(budget.foxingClusters, scale: countScale, rng: &rng)
        guard count > 0 else { return [] }

        var elements: [DamageElement] = []
        for _ in 0..<count {
            elements.append(.foxing(Foxing(
                center: NormalizedPoint(
                    rng.double(in: 0.04...0.96),
                    rng.double(in: 0.04...0.96)
                ),
                radius: rng.double(in: 0.04...0.17) * sizeScale,
                count: rng.int(in: 4...16),
                opacity: rng.double(in: 0.10...0.30) * sizeScale,
                seed: rng.branchSeed()
            )))
        }
        return elements
    }

    // MARK: - Non-paper element builders

    /// Burns. Scaled off the hole budget, because a burn-through is the same
    /// kind of event: something that opens the sheet away from its edges.
    private static func makeChars(
        budget: DamageBudget,
        spine: PageEdge,
        countScale: Double,
        sizeScale: Double,
        rng: inout SplitMix64
    ) -> [DamageElement] {
        let count = scaledCount(budget.burns, scale: countScale, rng: &rng)
        guard count > 0 else { return [] }

        var elements: [DamageElement] = []
        for _ in 0..<count {
            let scorch = rng.double(in: budget.burnScorchRadius) * sizeScale
            guard scorch > 0.012 else { continue }

            // Most burns are scorches. Only the fiercest open a hole, and the
            // core is always a fraction of the scorch so the ring survives.
            let goesThrough = rng.chance(0.45 * sizeScale)
            let core = goesThrough ? scorch * rng.double(in: 0.22...0.5) : 0.0

            // Fire starts at an edge more often than in the middle of a sheet,
            // so bias toward the fore-edge and away from the binding.
            let inset = scorch * 0.5
            let xRange: ClosedRange<Double>
            switch spine {
            case .left: xRange = (inset + 0.12)...(1 - inset * 0.2)
            case .right: xRange = (inset * 0.2)...(1 - inset - 0.12)
            case .top, .bottom: xRange = (inset * 0.2)...(1 - inset * 0.2)
            }

            elements.append(.char(Char(
                center: NormalizedPoint(
                    rng.double(in: xRange),
                    rng.double(in: (inset * 0.2)...(1 - inset * 0.2))
                ),
                coreRadius: core,
                scorchRadius: scorch,
                irregularity: rng.double(in: 0.35...0.95),
                bleed: rng.double(in: 0.4...1.0),
                seed: rng.branchSeed()
            )))
        }
        return elements
    }

    /// Chips off a rigid edge. The rigid analogue of an edge tear, so it shares
    /// that budget and the same spine weighting: the bound edge is protected.
    private static func makeChips(
        budget: DamageBudget,
        spine: PageEdge,
        substrate: Substrate,
        countScale: Double,
        sizeScale: Double,
        rng: inout SplitMix64
    ) -> [DamageElement] {
        let count = scaledCount(budget.chips, scale: countScale, rng: &rng)
        guard count > 0 else { return [] }

        let weights = PageEdge.weights(spine: spine)
        var elements: [DamageElement] = []

        for _ in 0..<count {
            guard let edge = rng.pickWeighted(weights) else { break }
            let depth = rng.double(in: budget.chipDepth) * sizeScale
            guard depth > 0.002 else { continue }
            // Chips are squatter than tears: material breaks away in a wide
            // shallow flake rather than a deep split.
            let length = depth * rng.double(in: 2.2...6.0)
            elements.append(.chip(Chip(
                edge: edge,
                position: rng.double(in: 0.05...0.95),
                length: min(length, 0.55),
                depth: depth,
                // A worn substrate has had its sharp edges knocked off.
                angularity: rng.double(in: 0.35...1.0) * (2.0 - substrate.edgeSofteningScale).clamped(to: 0...1.5),
                seed: rng.branchSeed()
            )))
        }
        return elements
    }

    /// Fractures. Scaled off the crease budget: both are lines that cross the
    /// sheet, and a rigid sheet cracks where a soft one would fold.
    private static func makeCracks(
        budget: DamageBudget,
        spine: PageEdge,
        countScale: Double,
        sizeScale: Double,
        rng: inout SplitMix64
    ) -> [DamageElement] {
        let count = scaledCount(budget.cracks, scale: countScale, rng: &rng)
        guard count > 0 else { return [] }

        var elements: [DamageElement] = []
        for _ in 0..<count {
            let edges = PageEdge.allCases.filter { $0 != spine }
            guard let startEdge = rng.pick(edges) else { continue }
            guard let endEdge = rng.pick(edges.filter { $0 != startEdge }) else { continue }
            elements.append(.crack(Crack(
                from: pointOnEdge(startEdge, at: rng.double(in: 0.05...0.95)),
                to: pointOnEdge(endEdge, at: rng.double(in: 0.05...0.95)),
                deviation: rng.double(in: 0.10...0.38),
                depth: rng.double(in: 0.35...0.9) * sizeScale,
                width: rng.double(in: 0.0015...0.006),
                branches: rng.int(in: 0...3),
                seed: rng.branchSeed()
            )))
        }
        return elements
    }

    /// Oxidation fields. Scaled off the foxing budget but spread much wider:
    /// foxing is a cluster of spots, patina is a continent.
    private static func makePatina(
        budget: DamageBudget,
        countScale: Double,
        sizeScale: Double,
        rng: inout SplitMix64
    ) -> [DamageElement] {
        let count = scaledCount(budget.patinaFields, scale: countScale, rng: &rng)
        guard count > 0 else { return [] }

        var elements: [DamageElement] = []
        for _ in 0..<count {
            let radius = rng.double(in: 0.10...0.34) * sizeScale
            guard radius > 0.02 else { continue }
            elements.append(.patina(Patina(
                center: NormalizedPoint(
                    rng.double(in: -0.1...1.1),
                    rng.double(in: -0.1...1.1)
                ),
                radius: radius,
                opacity: rng.double(in: 0.10...0.34) * sizeScale,
                oxidation: rng.double(in: 0.45...1.0),
                softness: rng.double(in: 0.35...0.95),
                seed: rng.branchSeed()
            )))
        }
        return elements
    }

    /// Scored lines. Shorter and straighter than cracks, and they start
    /// anywhere rather than at an edge, because a hand made them.
    private static func makeScratches(
        budget: DamageBudget,
        substrate: Substrate,
        countScale: Double,
        sizeScale: Double,
        rng: inout SplitMix64
    ) -> [DamageElement] {
        let count = scaledCount(budget.scratches, scale: countScale, rng: &rng)
        guard count > 0 else { return [] }

        var elements: [DamageElement] = []
        for _ in 0..<count {
            let from = NormalizedPoint(rng.double(in: 0.04...0.96), rng.double(in: 0.04...0.96))
            let angle = rng.double(in: 0...(2 * .pi))
            let reach = rng.double(in: 0.08...0.42) * sizeScale
            let to = NormalizedPoint(
                (from.x + cos(angle) * reach).clamped(to: 0.02...0.98),
                (from.y + sin(angle) * reach).clamped(to: 0.02...0.98)
            )
            guard from != to else { continue }
            elements.append(.scratch(Scratch(
                from: from,
                to: to,
                depth: rng.double(in: 0.3...1.0) * sizeScale,
                width: rng.double(in: 0.0008...0.0035),
                // Only metal has a brighter layer under the tarnish.
                exposesCore: substrate == .metal ? rng.chance(0.75) : rng.chance(0.2),
                seed: rng.branchSeed()
            )))
        }
        return elements
    }

    // MARK: - Helpers

    private static func pointOnEdge(_ edge: PageEdge, at t: Double) -> NormalizedPoint {
        switch edge {
        case .top: return NormalizedPoint(t, 0)
        case .bottom: return NormalizedPoint(t, 1)
        case .left: return NormalizedPoint(0, t)
        case .right: return NormalizedPoint(1, t)
        }
    }
}
