//
//  Substrate.swift
//  Paperbound
//
//  What the page is physically made of, as distinct from what colour it is.
//
//  `PaperMaterial` answers "what does this stock look like": base colour,
//  grain, fibre. `Substrate` answers "how does it fail": paper tears and foxes,
//  stone chips and cracks, bronze pits and tarnishes, leather scuffs and dries.
//
//  The split exists for one specific reason. `damageIdentity` deliberately
//  excludes material so that changing cream to aged never moves a single tear,
//  and `DamageGeneratorTests` pins that. Substrate *must* move defects, because
//  a stone tablet cannot tear. So substrate enters the damage identity and
//  material stays out of it, and the tested invariant survives intact.
//
//  `.paper` is the identity case throughout: every palette, weight and scale it
//  returns is exactly what the app did before substrates existed, so an
//  environment that does not mention a substrate renders byte-for-byte as it
//  always has.
//

import Foundation

// MARK: - Palette

/// The four colours the compositor needs to draw a sheet, whatever it is made
/// of. Paper delegates these straight to `PaperMaterial`; every other substrate
/// supplies its own and uses the material only to pick a tone within it.
struct SubstratePalette: Hashable, Sendable {
    /// The sheet's surface before grain and fibre are composited.
    var base: RGBAColor
    /// The exposed cross-section at a tear, chip or burn-through.
    var core: RGBAColor
    /// The ragged halo just inside a cut: fibre on paper, dust on stone.
    var fiber: RGBAColor
    /// Discolouration: foxing on paper, verdigris on bronze, salt on stone.
    var stain: RGBAColor
}

// MARK: - Substrate

enum Substrate: String, Codable, CaseIterable, Identifiable, Sendable {
    case paper
    case vellum
    case stone
    case metal
    case leather
    case cloth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paper: return "Paper"
        case .vellum: return "Vellum"
        case .stone: return "Stone"
        case .metal: return "Metal"
        case .leather: return "Leather"
        case .cloth: return "Cloth"
        }
    }

    var summary: String {
        switch self {
        case .paper: return "Tears, foxes and creases. The default stock."
        case .vellum: return "Animal skin. Stretches and cockles rather than tearing cleanly."
        case .stone: return "Carved tablet. Chips and cracks; it cannot tear."
        case .metal: return "Beaten plate. Scratches and tarnishes; it cannot tear."
        case .leather: return "Tooled hide. Scuffs, dries and cracks at the folds."
        case .cloth: return "Woven bolt. Frays at the edge and takes a stain deeply."
        }
    }

    /// True when the sheet cannot bend. Rigid substrates get angular breaks
    /// instead of frayed ones, and their page turns should feel heavy.
    var isRigid: Bool {
        switch self {
        case .stone, .metal: return true
        case .paper, .vellum, .leather, .cloth: return false
        }
    }

    /// True when the substrate can be burned. Fire is the defining defect of
    /// the cursed-manuscript environment and is meaningless on stone.
    var canBurn: Bool {
        switch self {
        case .paper, .vellum, .leather, .cloth: return true
        case .stone, .metal: return false
        }
    }

    // MARK: Defect vocabulary

    /// Which defects this substrate can suffer, and how readily.
    ///
    /// The generator asks for this rather than testing the substrate case by
    /// case, so adding a substrate never means editing the generator.
    /// Weights are relative within a substrate, not across them.
    var vocabulary: [(kind: DamageKind, weight: Double)] {
        switch self {
        case .paper:
            return [
                (.edgeTear, 1.0), (.lostCorner, 1.0), (.hole, 1.0),
                (.stain, 1.0), (.crease, 1.0), (.foxing, 1.0)
            ]
        case .vellum:
            return [
                (.edgeTear, 0.55), (.lostCorner, 0.85), (.hole, 0.45),
                (.stain, 1.0), (.crease, 1.25), (.foxing, 0.7), (.scratch, 0.4)
            ]
        case .stone:
            return [
                (.chip, 1.0), (.crack, 1.0), (.scratch, 0.8),
                (.stain, 0.45), (.patina, 0.3)
            ]
        case .metal:
            return [
                (.scratch, 1.0), (.patina, 1.0), (.chip, 0.4),
                (.crack, 0.25), (.stain, 0.3)
            ]
        case .leather:
            return [
                (.scratch, 1.0), (.crack, 0.8), (.stain, 0.9),
                (.crease, 0.6), (.chip, 0.2)
            ]
        case .cloth:
            return [
                (.edgeTear, 0.8), (.stain, 1.1), (.crease, 1.0),
                (.foxing, 0.6), (.scratch, 0.3)
            ]
        }
    }

    /// True when this substrate can produce that defect at all.
    func allows(_ kind: DamageKind) -> Bool {
        if kind == .char { return canBurn }
        return vocabulary.contains { $0.kind == kind }
    }

    /// Relative readiness to suffer a given defect, 0 when it cannot.
    func weight(for kind: DamageKind) -> Double {
        if kind == .char { return canBurn ? 1.0 : 0.0 }
        return vocabulary.first { $0.kind == kind }?.weight ?? 0.0
    }

    // MARK: Surface

    /// Multiplier on the condition's `edgeSoftening`. Rigid substrates break
    /// sharply, so their cut edges stay angular however worn the book is.
    var edgeSofteningScale: Double {
        switch self {
        case .paper: return 1.0
        case .vellum: return 0.8
        case .stone: return 0.25
        case .metal: return 0.15
        case .leather: return 0.6
        case .cloth: return 1.3
        }
    }

    /// Multiplier on the material's `grainStrength`.
    var grainScale: Double {
        switch self {
        case .paper: return 1.0
        case .vellum: return 0.7
        case .stone: return 2.1
        case .metal: return 0.5
        case .leather: return 1.6
        case .cloth: return 1.4
        }
    }

    /// Multiplier on the material's `fiberStrength`. Stone has no fibre but it
    /// does have bedding planes, which read the same way at this scale.
    var fiberScale: Double {
        switch self {
        case .paper: return 1.0
        case .vellum: return 0.45
        case .stone: return 1.3
        case .metal: return 0.8
        case .leather: return 0.9
        case .cloth: return 2.2
        }
    }

    // MARK: Palette

    /// The colours for this substrate at the tone the material selects.
    ///
    /// Paper returns the material's own palette unchanged, so nothing about the
    /// original five stocks moves. Every other substrate uses the material only
    /// as a light-to-dark position within its own family.
    func palette(for material: PaperMaterial) -> SubstratePalette {
        guard self != .paper else {
            return SubstratePalette(
                base: material.baseColor,
                core: material.coreColor,
                fiber: material.fiberColor,
                stain: material.stainColor
            )
        }

        let tone = material.tone
        switch self {
        case .paper:
            // Unreachable: handled by the guard above.
            return SubstratePalette(
                base: material.baseColor,
                core: material.coreColor,
                fiber: material.fiberColor,
                stain: material.stainColor
            )

        case .vellum:
            return SubstratePalette(
                base: RGBAColor(hex: 0xEFE2C6).blended(with: RGBAColor(hex: 0xC4AC7E), amount: tone),
                core: RGBAColor(hex: 0xFBF3E2),
                fiber: RGBAColor(hex: 0xC9B48C),
                stain: RGBAColor(hex: 0x8F6B36)
            )

        case .stone:
            return SubstratePalette(
                base: RGBAColor(hex: 0xC9BFA8).blended(with: RGBAColor(hex: 0x6E6455), amount: tone),
                core: RGBAColor(hex: 0xE4DCC9),
                fiber: RGBAColor(hex: 0x9A8F7A),
                stain: RGBAColor(hex: 0x6B5F45)
            )

        case .metal:
            return SubstratePalette(
                // Kept bright across the whole tone range. Beaten gold that has
                // gone dark is indistinguishable from dirty paper, and at the
                // darker tones it also lands either side of the ink-inversion
                // threshold, which is how the plate first rendered as black
                // type on brown and could not be read at all.
                base: RGBAColor(hex: 0xE8C877).blended(with: RGBAColor(hex: 0xA8853A), amount: tone),
                // A scratch on tarnished gold exposes bright metal underneath.
                core: RGBAColor(hex: 0xF3DC9B),
                fiber: RGBAColor(hex: 0x8A6E2C),
                // Verdigris, not brown: this is what oxidising bronze does.
                stain: RGBAColor(hex: 0x4A7A5E)
            )

        case .leather:
            return SubstratePalette(
                base: RGBAColor(hex: 0x7A4B2C).blended(with: RGBAColor(hex: 0x2E1A0F), amount: tone),
                core: RGBAColor(hex: 0xC69A6B),
                fiber: RGBAColor(hex: 0x4A2C18),
                stain: RGBAColor(hex: 0x25150B)
            )

        case .cloth:
            return SubstratePalette(
                base: RGBAColor(hex: 0xD9CDB4).blended(with: RGBAColor(hex: 0x7E7059), amount: tone),
                core: RGBAColor(hex: 0xEDE4CF),
                fiber: RGBAColor(hex: 0xA8967A),
                stain: RGBAColor(hex: 0x6E5A38)
            )
        }
    }

    /// True when the document's black ink has to be inverted to stay legible on
    /// this substrate at this tone.
    ///
    /// The threshold is the contrast floor, not a taste call. Black type needs
    /// roughly a 4.5:1 contrast ratio to stay readable, which a surface reaches
    /// at about 0.36 relative luminance; below that the type has to flip to
    /// light. The margin above it is deliberate — a substrate also carries
    /// grain, stains and lighting on top, all of which darken it further.
    func invertsInk(for material: PaperMaterial) -> Bool {
        guard self != .paper else { return material.invertsInk }
        return palette(for: material).base.luminance < 0.42
    }
}

// MARK: - Material as a tone

extension PaperMaterial {
    /// Position of this stock from lightest (0) to darkest (1).
    ///
    /// On paper this is unused. On every other substrate it is how the five
    /// existing materials stay meaningful: they select a tone within the
    /// substrate's own family rather than naming a paper colour that a bronze
    /// plate could never have.
    var tone: Double {
        switch self {
        case .white: return 0.0
        case .cream: return 0.2
        case .aged: return 0.45
        case .parchment: return 0.65
        case .dark: return 1.0
        }
    }
}

// MARK: - Condition, described in the substrate's own terms

extension Substrate {

    /// How this condition reads on this substrate.
    ///
    /// `PageCondition.summary` describes paper, because when it was written
    /// paper was the only thing a page could be. Told it was "well-loved", a
    /// stone tablet reported "nicked edges, creases and spotting", which is
    /// language for a paperback and nonsense for a slab of rock. The condition
    /// axis still decides *how worn* the sheet is; the substrate decides what
    /// the words for that wear are.
    func conditionSummary(_ condition: PageCondition) -> String {
        guard self != .paper else { return condition.summary }
        guard condition != .pristine else {
            return "Nothing is removed. The document is shown exactly as imported."
        }

        switch self {
        case .paper:
            return condition.summary

        case .vellum:
            switch condition {
            case .pristine: return condition.summary
            case .lightWear: return "Softened edges and a slight cockle. No loss of content."
            case .wellLoved: return "Cockled and stained, with the odd split at a fold."
            case .damaged: return "Split, scorched and stained, with losses that cut through text."
            }

        case .stone:
            switch condition {
            case .pristine: return condition.summary
            case .lightWear: return "Scuffed surface and a few hairline fractures. Nothing lost."
            case .wellLoved: return "Chipped edges and cracks running across the face."
            case .damaged: return "Heavily chipped and fractured, with pieces missing from the carving."
            }

        case .metal:
            switch condition {
            case .pristine: return condition.summary
            case .lightWear: return "Faint scoring and the first bloom of tarnish."
            case .wellLoved: return "Scratched and oxidised, with verdigris spreading from the edges."
            case .damaged: return "Deeply scored, pitted and buckled, with metal lost at the edges."
            }

        case .leather:
            switch condition {
            case .pristine: return condition.summary
            case .lightWear: return "Scuffed grain and a faint sheen where it has been handled."
            case .wellLoved: return "Scored and darkened, cracking along the folds."
            case .damaged: return "Dried and split, with the grain flaking away."
            }

        case .cloth:
            switch condition {
            case .pristine: return condition.summary
            case .lightWear: return "A softened weave and faint marking. No loss of content."
            case .wellLoved: return "Fraying at the edges, with stains worked deep into the weave."
            case .damaged: return "Frayed through and heavily stained, with tears across the cloth."
            }
        }
    }
}

extension ReadingEnvironment {
    /// The condition, described in terms of what this sheet is made of.
    var conditionSummary: String {
        substrate.conditionSummary(condition)
    }
}
