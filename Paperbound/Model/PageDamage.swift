//
//  PageDamage.swift
//  Paperbound
//
//  Deterministic descriptors for a single sheet's wear. Everything is stored
//  in *normalized page space* (0…1 on both axes, origin top-left) so that the
//  same descriptor survives zoom, viewport changes and re-rendering at any
//  resolution without drifting off the page.
//

import Foundation

// MARK: - Geometry primitives

struct NormalizedPoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

enum PageEdge: String, Codable, CaseIterable, Sendable {
    case top, right, bottom, left

    /// Outer edges take more damage than the bound edge.
    /// `spine` is the edge held by the binding for the page being drawn.
    static func weights(spine: PageEdge) -> [(PageEdge, Double)] {
        PageEdge.allCases.map { edge in
            (edge, edge == spine ? 0.12 : (edge == spine.opposite ? 1.0 : 0.55))
        }
    }

    var opposite: PageEdge {
        switch self {
        case .top: return .bottom
        case .bottom: return .top
        case .left: return .right
        case .right: return .left
        }
    }
}

enum PageCorner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var unitOrigin: NormalizedPoint {
        switch self {
        case .topLeft: return NormalizedPoint(0, 0)
        case .topRight: return NormalizedPoint(1, 0)
        case .bottomLeft: return NormalizedPoint(0, 1)
        case .bottomRight: return NormalizedPoint(1, 1)
        }
    }

    /// Corners away from the spine are handled most and wear first.
    static func weights(spine: PageEdge) -> [(PageCorner, Double)] {
        PageCorner.allCases.map { corner in
            let touchesSpine: Bool
            switch spine {
            case .left: touchesSpine = (corner == .topLeft || corner == .bottomLeft)
            case .right: touchesSpine = (corner == .topRight || corner == .bottomRight)
            case .top: touchesSpine = (corner == .topLeft || corner == .topRight)
            case .bottom: touchesSpine = (corner == .bottomLeft || corner == .bottomRight)
            }
            // Bottom-outer corner is the one a thumb actually turns.
            let isThumbCorner = (corner == .bottomRight && spine == .left)
                || (corner == .bottomLeft && spine == .right)
            if touchesSpine { return (corner, 0.15) }
            return (corner, isThumbCorner ? 1.0 : 0.6)
        }
    }
}

// MARK: - Damage elements

/// A bite taken out of one edge of the sheet.
struct EdgeTear: Codable, Hashable, Sendable {
    var edge: PageEdge
    /// Position of the tear's midpoint along the edge, 0…1.
    var position: Double
    /// Extent along the edge, in normalized units.
    var length: Double
    /// How far into the sheet the tear reaches, in normalized units.
    var depth: Double
    /// 0…1 jaggedness of the torn boundary.
    var roughness: Double
    var seed: UInt64
}

/// A missing corner — the classic dog-ear that finally came off.
struct LostCorner: Codable, Hashable, Sendable {
    var corner: PageCorner
    /// How far along each adjacent edge the loss extends, in normalized units.
    var reach: Double
    /// Slight asymmetry between the two edges, -0.5…0.5.
    var skew: Double
    var roughness: Double
    var seed: UInt64
}

/// A hole punched through the sheet; the sheet below shows through it.
struct Hole: Codable, Hashable, Sendable {
    var center: NormalizedPoint
    var radius: Double
    /// 0…1 deviation from a circle.
    var irregularity: Double
    var seed: UInt64
}

/// A soft discolouration. Never removes content, only tints it.
struct Stain: Codable, Hashable, Sendable {
    var center: NormalizedPoint
    var radius: Double
    var opacity: Double
    /// 0…1 towards the material's stain colour; low values read as damp marks.
    var warmth: Double
    /// 0…1 edge softness; low values produce a defined tide line.
    var softness: Double
    var seed: UInt64
}

/// A fold line with a bright ridge and a dark valley.
struct Crease: Codable, Hashable, Sendable {
    var from: NormalizedPoint
    var to: NormalizedPoint
    var strength: Double
    var width: Double
    var seed: UInt64
}

/// A cluster of small rust-coloured age spots.
struct Foxing: Codable, Hashable, Sendable {
    var center: NormalizedPoint
    var radius: Double
    var count: Int
    var opacity: Double
    var seed: UInt64
}

enum DamageElement: Codable, Hashable, Sendable {
    case edgeTear(EdgeTear)
    case lostCorner(LostCorner)
    case hole(Hole)
    case stain(Stain)
    case crease(Crease)
    case foxing(Foxing)
    // Non-paper substrates. Appended rather than interleaved so that the
    // synthesized Codable keys of the original six are untouched.
    case char(Char)
    case chip(Chip)
    case crack(Crack)
    case patina(Patina)
    case scratch(Scratch)

    var kind: DamageKind {
        switch self {
        case .edgeTear: return .edgeTear
        case .lostCorner: return .lostCorner
        case .hole: return .hole
        case .stain: return .stain
        case .crease: return .crease
        case .foxing: return .foxing
        case .char: return .char
        case .chip: return .chip
        case .crack: return .crack
        case .patina: return .patina
        case .scratch: return .scratch
        }
    }

    /// True when the element physically removes part of the sheet, i.e. it
    /// participates in the cut-out mask and can erase document content.
    ///
    /// A burn is the only defect that decides this per instance: a scorch
    /// that never went through leaves the sheet whole and merely darkens it,
    /// while one that did opens a real hole onto the leaf below.
    var isSubtractive: Bool {
        switch self {
        case .edgeTear, .lostCorner, .hole, .chip: return true
        case .stain, .crease, .foxing, .patina, .scratch, .crack: return false
        case let .char(burn): return burn.burnsThrough
        }
    }
}

// MARK: - Per-page condition record

/// Everything needed to reproduce one sheet's appearance, byte for byte.
struct PageConditionData: Codable, Hashable, Sendable {
    var documentID: UUID
    /// Identity of the sheet within the document. For PDF this is the page
    /// index; for a reflowable format it must be a *content* anchor, never a
    /// rendered screen number (see `ReadingEngine.stablePageID(for:)`).
    var stablePageID: String
    var seed: UInt64
    var intensity: Double
    var environmentIdentity: String
    var damage: [DamageElement]
    /// Defects the reader edited or deleted by hand; these win over generation.
    var userOverrides: [DamageElement]

    init(
        documentID: UUID,
        stablePageID: String,
        seed: UInt64,
        intensity: Double,
        environmentIdentity: String,
        damage: [DamageElement],
        userOverrides: [DamageElement] = []
    ) {
        self.documentID = documentID
        self.stablePageID = stablePageID
        self.seed = seed
        self.intensity = intensity
        self.environmentIdentity = environmentIdentity
        self.damage = damage
        self.userOverrides = userOverrides
    }

    /// Generated defects plus any the reader added.
    var effectiveDamage: [DamageElement] { damage + userOverrides }

    var subtractiveDamage: [DamageElement] { effectiveDamage.filter(\.isSubtractive) }
    var surfaceDamage: [DamageElement] { effectiveDamage.filter { !$0.isSubtractive } }

    var isPristine: Bool { effectiveDamage.isEmpty }

    static func pristine(documentID: UUID, stablePageID: String, environmentIdentity: String) -> PageConditionData {
        PageConditionData(
            documentID: documentID,
            stablePageID: stablePageID,
            seed: 0,
            intensity: 0,
            environmentIdentity: environmentIdentity,
            damage: []
        )
    }
}
