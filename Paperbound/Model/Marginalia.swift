//
//  Marginalia.swift
//  Paperbound
//
//  Everything a previous owner left on the page: notes, sketches, pressings,
//  stamps, routes, sigils.
//
//  Marginalia sits above the document's pixels and below the lighting, and it
//  is generated exactly the way damage is — deterministically, from a seed, in
//  normalized page space. Two rules make it safe to add to a shipped book:
//
//  1. It draws from its OWN seed stream, never the damage stream. Sharing one
//     would reshuffle every existing reader's tears the day marginalia ships.
//  2. Every element declares a `zone`. The compositor clips `.margin` elements
//     to the frame, so marginalia physically cannot land on the text block —
//     see `PageCompositor.contentRect`. Legibility is enforced by geometry
//     rather than by taste.
//

import Foundation

// MARK: - Where an element may land

/// The part of the sheet an element is allowed to occupy.
enum MarginaliaZone: String, Codable, CaseIterable, Sendable {
    /// Outside the text block only. The default, and the frame/field rule.
    case margin
    /// Over the text block, for elements that are *about* the words:
    /// underlines, marginal corrections, redactions.
    case field
    /// Either. Used only by elements too faint to compete with type.
    case anywhere
}

// MARK: - Elements

/// A run of handwriting. The glyphs are procedural strokes rather than a font,
/// so nothing here needs a licence and every book's hand is slightly different.
struct InkStroke: Codable, Hashable, Sendable {
    /// Start of the baseline, in normalized page space.
    var origin: NormalizedPoint
    /// Length along the baseline.
    var length: Double
    /// Height of the x-height band.
    var height: Double
    /// Rotation in radians. Marginal notes are rarely level.
    var angle: Double
    /// How many word-shaped groups this run contains.
    var words: Int
    /// 0…1 pressure. Drives both darkness and stroke width.
    var pressure: Double
    /// 0…1 how much the hand wobbles. High values read as hurried or old.
    var tremor: Double
    var seed: UInt64
}

/// A line drawing: a plant, a creature, a mechanism, a map feature.
///
/// `complexity` drives how many strokes the renderer spends, so the same
/// descriptor can be drawn cheaply in a thumbnail and fully on a page.
struct Sketch: Codable, Hashable, Sendable {
    var center: NormalizedPoint
    var radius: Double
    var angle: Double
    /// 0…1 how much detail to spend.
    var complexity: Double
    /// 0…1 ink darkness.
    var pressure: Double
    /// Whether a hand-lettered label sits beneath it.
    var hasLabel: Bool
    var seed: UInt64
}

/// A pressed specimen: a leaf, a petal, a feather. Drawn as a soft silhouette
/// with a slight shadow, because a real pressing lifts the paper around it.
struct Pressing: Codable, Hashable, Sendable {
    var center: NormalizedPoint
    var radius: Double
    var angle: Double
    /// 0…1 how far the silhouette has browned.
    var age: Double
    /// Number of lobes or barbs, which is what separates a leaf from a feather.
    var lobes: Int
    var seed: UInt64
}

/// An inked stamp: a library mark, a seal, a date block. Always slightly
/// rotated and unevenly inked, which is what makes a stamp read as pressed.
struct Stamp: Codable, Hashable, Sendable {
    var center: NormalizedPoint
    var radius: Double
    var angle: Double
    /// 0…1 coverage. Low values are a starved pad.
    var coverage: Double
    /// Number of sides; 0 means a circle.
    var sides: Int
    var seed: UInt64
}

/// A drawn or scratched mark with no lettering: a sigil, a ward, a tally.
/// The occult counterpart of a sketch, and the one element that is allowed to
/// be scored into the substrate rather than inked onto it.
struct Sigil: Codable, Hashable, Sendable {
    var center: NormalizedPoint
    var radius: Double
    var angle: Double
    /// Points on the enclosing figure, e.g. 5 for a pentacle.
    var points: Int
    /// 0…1 darkness.
    var pressure: Double
    /// True when it is scratched into the surface rather than drawn on it.
    var isScored: Bool
    var seed: UInt64
}

/// A track crossing the sheet. Static in the baked layer; the motion axis is
/// what makes it walk.
struct Footprint: Codable, Hashable, Sendable {
    /// Where the trail enters the sheet.
    var from: NormalizedPoint
    /// Where it leaves.
    var to: NormalizedPoint
    /// How many prints along the trail.
    var count: Int
    /// Size of one print.
    var size: Double
    /// 0…1 how far the trail wanders off the straight line.
    var wander: Double
    /// 0…1 ink darkness.
    var pressure: Double
    var seed: UInt64
}

/// A line drawn under or through running text: an underline, a strike, a
/// bracket down the margin. The one element that belongs in the field, because
/// it is meaningless anywhere else.
struct TextMark: Codable, Hashable, Sendable {
    var from: NormalizedPoint
    var to: NormalizedPoint
    /// 0…1 darkness.
    var pressure: Double
    var width: Double
    /// True for a double line, which is what an emphatic reader leaves.
    var isDoubled: Bool
    var seed: UInt64
}

// MARK: - The element union

enum MarginaliaElement: Codable, Hashable, Sendable {
    case inkStroke(InkStroke)
    case sketch(Sketch)
    case pressing(Pressing)
    case stamp(Stamp)
    case sigil(Sigil)
    case footprint(Footprint)
    case textMark(TextMark)

    var kind: MarginaliaKind {
        switch self {
        case .inkStroke: return .inkStroke
        case .sketch: return .sketch
        case .pressing: return .pressing
        case .stamp: return .stamp
        case .sigil: return .sigil
        case .footprint: return .footprint
        case .textMark: return .textMark
        }
    }

    var zone: MarginaliaZone { kind.zone }
}

enum MarginaliaKind: String, Codable, CaseIterable, Sendable {
    case inkStroke
    case sketch
    case pressing
    case stamp
    case sigil
    case footprint
    case textMark

    /// Where this kind is allowed to land.
    ///
    /// Only `textMark` may enter the text block, because an underline that
    /// avoided the words would not be an underline. Everything else is frame
    /// only, which is the frame/field rule expressed as data.
    var zone: MarginaliaZone {
        switch self {
        case .textMark: return .field
        case .footprint: return .anywhere
        case .inkStroke, .sketch, .pressing, .stamp, .sigil: return .margin
        }
    }

    var displayName: String {
        switch self {
        case .inkStroke: return "Handwriting"
        case .sketch: return "Sketches"
        case .pressing: return "Pressed specimens"
        case .stamp: return "Stamps"
        case .sigil: return "Sigils"
        case .footprint: return "Tracks"
        case .textMark: return "Underlines"
        }
    }
}

// MARK: - The axis

enum MarginaliaStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case handwritten
    case naturalist
    case cartographic
    case occult
    case scholarly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .handwritten: return "Handwritten"
        case .naturalist: return "Field notes"
        case .cartographic: return "Charted"
        case .occult: return "Warded"
        case .scholarly: return "Annotated"
        }
    }

    var summary: String {
        switch self {
        case .none: return "A clean page. Nobody has written on this copy."
        case .handwritten: return "Notes in the margin in a previous owner's hand."
        case .naturalist: return "Sketches, pressed specimens and labelled observations."
        case .cartographic: return "Routes, tracks and charted marks across the margins."
        case .occult: return "Sigils and scored wards, drawn by someone who meant them."
        case .scholarly: return "Library stamps, underlines and corrections."
        }
    }

    /// Which kinds this style draws from, and how readily.
    var vocabulary: [(kind: MarginaliaKind, weight: Double)] {
        switch self {
        case .none:
            return []
        case .handwritten:
            return [(.inkStroke, 1.0), (.textMark, 0.55)]
        case .naturalist:
            return [(.sketch, 1.0), (.pressing, 0.8), (.inkStroke, 0.9), (.textMark, 0.2)]
        case .cartographic:
            return [(.footprint, 1.0), (.sketch, 0.7), (.inkStroke, 0.5), (.stamp, 0.25)]
        case .occult:
            return [(.sigil, 1.0), (.inkStroke, 0.5), (.textMark, 0.3)]
        case .scholarly:
            return [(.stamp, 1.0), (.textMark, 1.0), (.inkStroke, 0.6)]
        }
    }

    /// How many elements a page carries at full intensity, before scaling.
    var density: ClosedRange<Int> {
        switch self {
        case .none: return 0...0
        case .handwritten: return 1...4
        case .naturalist: return 2...6
        case .cartographic: return 2...5
        case .occult: return 1...4
        case .scholarly: return 1...4
        }
    }

    /// Extra margin this style needs, as a fraction of the sheet's shorter
    /// side, added to the presentation's own inset.
    ///
    /// A book meant to be written in has wide margins — that is what makes it
    /// writable. Without this the text block reaches to within 4% of the sheet
    /// edge and there is physically nowhere for a mark to go: the frame/field
    /// clip then removes almost everything the generator produced, which is
    /// exactly the bug this property was added to fix.
    var marginWidth: Double {
        switch self {
        case .none: return 0.0
        case .handwritten: return 0.075
        case .naturalist: return 0.105
        case .cartographic: return 0.080
        case .occult: return 0.075
        case .scholarly: return 0.060
        }
    }

    /// The ink these marks are made in, before the substrate tints them.
    var inkColor: RGBAColor {
        switch self {
        case .none: return RGBAColor(0, 0, 0, 0)
        case .handwritten: return RGBAColor(hex: 0x3A3220)
        case .naturalist: return RGBAColor(hex: 0x2E2A1E)
        case .cartographic: return RGBAColor(hex: 0x4A2E18)
        case .occult: return RGBAColor(hex: 0x2A1410)
        case .scholarly: return RGBAColor(hex: 0x2A3A5A)
        }
    }

    var producesAnything: Bool { self != .none }
}

// MARK: - Per-page record

/// One sheet's marginalia, reproducible byte for byte from its seed.
struct PageMarginalia: Codable, Hashable, Sendable {
    var documentID: UUID
    var stablePageID: String
    var seed: UInt64
    var styleIdentity: String
    var elements: [MarginaliaElement]
    /// Marks the reader made by hand, which always survive regeneration.
    var userElements: [MarginaliaElement]

    init(
        documentID: UUID,
        stablePageID: String,
        seed: UInt64,
        styleIdentity: String,
        elements: [MarginaliaElement],
        userElements: [MarginaliaElement] = []
    ) {
        self.documentID = documentID
        self.stablePageID = stablePageID
        self.seed = seed
        self.styleIdentity = styleIdentity
        self.elements = elements
        self.userElements = userElements
    }

    var allElements: [MarginaliaElement] { elements + userElements }

    /// Elements confined to the frame, i.e. everything the compositor must clip
    /// away from the text block.
    var marginElements: [MarginaliaElement] {
        allElements.filter { $0.zone == .margin }
    }

    /// Elements allowed over the text block.
    var fieldElements: [MarginaliaElement] {
        allElements.filter { $0.zone == .field || $0.zone == .anywhere }
    }

    var isEmpty: Bool { allElements.isEmpty }

    static func empty(documentID: UUID, stablePageID: String, styleIdentity: String) -> PageMarginalia {
        PageMarginalia(
            documentID: documentID,
            stablePageID: stablePageID,
            seed: 0,
            styleIdentity: styleIdentity,
            elements: []
        )
    }
}
