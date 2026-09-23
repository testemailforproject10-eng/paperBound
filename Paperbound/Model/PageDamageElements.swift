//
//  PageDamageElements.swift
//  Paperbound
//
//  The defect vocabulary beyond paper.
//
//  `PageDamage.swift` holds the six defects a sheet of paper can suffer: tears,
//  lost corners, holes, stains, creases and foxing. Those describe paper and
//  nothing else. A stone tablet does not tear and a bronze plate does not fox,
//  so the substrates added for the themed environments need their own kinds.
//
//  Everything here obeys the same two rules as the original six: normalized
//  page space (0…1, origin top-left) so nothing drifts under zoom, and a
//  `seed` per element so sub-detail can be generated lazily without consuming
//  the parent stream out of order.
//

import Foundation

// MARK: - Burned and scorched

/// A scorch mark. Above `burnThrough` the centre is consumed and the element
/// becomes subtractive; below it the paper survives and only darkens.
///
/// Burning is the one defect that is both surface and subtractive depending on
/// its own severity, which is why it carries the threshold rather than the
/// generator deciding for it.
struct Char: Codable, Hashable, Sendable {
    var center: NormalizedPoint
    /// Radius of the consumed core, in normalized units. Zero for a pure scorch.
    var coreRadius: Double
    /// Radius of the darkened ring around the core.
    var scorchRadius: Double
    /// 0…1 deviation from a circle. Fire does not burn in circles.
    var irregularity: Double
    /// 0…1 how far the brown halo bleeds past the black rim.
    var bleed: Double
    var seed: UInt64

    /// True when the burn actually opened a hole.
    var burnsThrough: Bool { coreRadius > 0.004 }
}

// MARK: - Rigid substrates

/// A piece broken off the edge of a rigid sheet. The rigid analogue of an
/// `EdgeTear`: straighter, more angular, and it does not fray.
struct Chip: Codable, Hashable, Sendable {
    var edge: PageEdge
    /// Position of the chip's midpoint along the edge, 0…1.
    var position: Double
    /// Extent along the edge, in normalized units.
    var length: Double
    /// How far into the sheet the chip reaches.
    var depth: Double
    /// 0…1 angularity. Low values are worn and rounded, high values are fresh
    /// and sharp — the difference between weathered stone and a new break.
    var angularity: Double
    var seed: UInt64
}

/// A fracture running across a rigid sheet. Never subtractive on its own: a
/// cracked tablet is still one piece until a `Chip` takes part of it away.
struct Crack: Codable, Hashable, Sendable {
    var from: NormalizedPoint
    var to: NormalizedPoint
    /// 0…1 how far the fracture wanders from the straight line between ends.
    var deviation: Double
    /// 0…1 darkness of the fracture line.
    var depth: Double
    /// Width of the opening, in normalized units.
    var width: Double
    /// How many smaller fractures branch off the main line.
    var branches: Int
    var seed: UInt64
}

/// Oxidation on metal: verdigris on bronze, tarnish on silver, dulling on gold.
/// The metal analogue of `Foxing`, but it spreads in fields rather than spots.
struct Patina: Codable, Hashable, Sendable {
    var center: NormalizedPoint
    var radius: Double
    var opacity: Double
    /// 0…1 towards the substrate's oxide colour.
    var oxidation: Double
    /// 0…1 edge definition. Low values creep, high values have a tide line.
    var softness: Double
    var seed: UInt64
}

/// A scored line: a knife on leather, a nail on stone, a stylus on metal.
/// Cuts the surface without removing the sheet.
struct Scratch: Codable, Hashable, Sendable {
    var from: NormalizedPoint
    var to: NormalizedPoint
    /// 0…1 how deeply it is scored.
    var depth: Double
    var width: Double
    /// True when the scratch exposes a brighter layer underneath, which is what
    /// makes a scratch on tarnished metal read as fresh.
    var exposesCore: Bool
    var seed: UInt64
}

// MARK: - Kinds

/// The kind of a defect, independent of any instance.
///
/// Substrates declare which kinds they can produce, so the generator never has
/// to ask "is this stone?" — it asks the substrate for its vocabulary and
/// draws from that.
enum DamageKind: String, Codable, CaseIterable, Sendable {
    case edgeTear
    case lostCorner
    case hole
    case stain
    case crease
    case foxing
    case char
    case chip
    case crack
    case patina
    case scratch

    /// True when this kind can remove part of the sheet and erase content.
    ///
    /// `char` is absent deliberately: whether a burn opens a hole depends on
    /// the individual burn's `coreRadius`, so it is decided per element rather
    /// than per kind.
    var isAlwaysSubtractive: Bool {
        switch self {
        case .edgeTear, .lostCorner, .hole, .chip: return true
        case .stain, .crease, .foxing, .patina, .scratch, .crack, .char: return false
        }
    }

    var displayName: String {
        switch self {
        case .edgeTear: return "Torn edges"
        case .lostCorner: return "Lost corners"
        case .hole: return "Holes"
        case .stain: return "Stains"
        case .crease: return "Creases"
        case .foxing: return "Foxing"
        case .char: return "Burns"
        case .chip: return "Chips"
        case .crack: return "Cracks"
        case .patina: return "Patina"
        case .scratch: return "Scratches"
        }
    }
}

// MARK: - Derived budgets

/// Budgets for the non-paper defects, derived from the paper ones rather than
/// spelled out condition by condition.
///
/// This is deliberate. A well-loved stone tablet should be as worn as a
/// well-loved paperback — just worn differently. Deriving keeps `PageCondition`
/// as the single place that decides *how damaged* a book is, and leaves
/// `Substrate` to decide *what that damage looks like*. Adding a substrate
/// therefore never means editing four budget literals.
extension DamageBudget {

    /// A chip is what an edge tear becomes in rigid material.
    var chips: ClosedRange<Int> { edgeTears }
    var chipDepth: ClosedRange<Double> { tearDepth }

    /// A crack is where a rigid sheet would otherwise have creased.
    var cracks: ClosedRange<Int> { creases }

    /// Patina spreads where foxing would have spotted.
    var patinaFields: ClosedRange<Int> { foxingClusters }

    /// Scratches accumulate faster than creases, because they cost nothing to
    /// make: a stylus, a nail, a careless shelf.
    var scratches: ClosedRange<Int> {
        creases.lowerBound...(creases.upperBound * 2)
    }

    /// A burn opens the sheet the way a hole does, so it inherits that budget.
    var burns: ClosedRange<Int> { holes }

    /// The scorch ring is always several times the hole it may have opened.
    /// A burn with no ring reads as a punch, which is the failure this range
    /// exists to prevent.
    var burnScorchRadius: ClosedRange<Double> {
        (holeRadius.lowerBound * 2.4)...(holeRadius.upperBound * 3.6)
    }
}
