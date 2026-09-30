//
//  ReadingEnvironment.swift
//  Paperbound
//
//  A reading environment is four independent dimensions plus an intensity.
//  It is *presentation only*: nothing here can alter the imported document.
//  Switching to `.pristine` condition restores the underlying page exactly.
//

import Foundation

// MARK: - Paper material

enum PaperMaterial: String, Codable, CaseIterable, Identifiable, Sendable {
    case white
    case cream
    case aged
    case parchment
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .white: return "White"
        case .cream: return "Cream"
        case .aged: return "Aged"
        case .parchment: return "Parchment"
        case .dark: return "Dark"
        }
    }

    /// Base sheet colour before grain and fibre are composited.
    var baseColor: RGBAColor {
        switch self {
        case .white: return RGBAColor(hex: 0xFAFAF8)
        case .cream: return RGBAColor(hex: 0xF3EADA)
        case .aged: return RGBAColor(hex: 0xE2D3B4)
        case .parchment: return RGBAColor(hex: 0xDCC9A2)
        case .dark: return RGBAColor(hex: 0x1C1A17)
        }
    }

    /// Colour of the exposed paper cross-section at a tear.
    var coreColor: RGBAColor {
        switch self {
        case .white: return RGBAColor(hex: 0xFFFFFF)
        case .cream: return RGBAColor(hex: 0xFBF5E9)
        case .aged: return RGBAColor(hex: 0xF0E4CB)
        case .parchment: return RGBAColor(hex: 0xEFDFBE)
        case .dark: return RGBAColor(hex: 0x3A352E)
        }
    }

    /// Colour of the ragged fibre halo just inside a cut.
    var fiberColor: RGBAColor {
        switch self {
        case .white: return RGBAColor(hex: 0xD9D6CE)
        case .cream: return RGBAColor(hex: 0xD6C7AC)
        case .aged: return RGBAColor(hex: 0xBFA97F)
        case .parchment: return RGBAColor(hex: 0xB59B6B)
        case .dark: return RGBAColor(hex: 0x564E42)
        }
    }

    /// Warm brown used for stains and foxing on this stock.
    var stainColor: RGBAColor {
        switch self {
        case .white: return RGBAColor(hex: 0xC8B68E)
        case .cream: return RGBAColor(hex: 0xB79A66)
        case .aged: return RGBAColor(hex: 0x96733C)
        case .parchment: return RGBAColor(hex: 0x8A6832)
        case .dark: return RGBAColor(hex: 0x6E5C3C)
        }
    }

    /// 0…1 strength of high-frequency grain noise.
    var grainStrength: Double {
        switch self {
        case .white: return 0.05
        case .cream: return 0.10
        case .aged: return 0.20
        case .parchment: return 0.26
        case .dark: return 0.13
        }
    }

    /// 0…1 strength of directional fibre streaks.
    var fiberStrength: Double {
        switch self {
        case .white: return 0.04
        case .cream: return 0.08
        case .aged: return 0.16
        case .parchment: return 0.22
        case .dark: return 0.09
        }
    }

    /// Dark stock needs the document's black ink inverted to stay legible.
    var invertsInk: Bool { self == .dark }
}

// MARK: - Page condition

enum PageCondition: String, Codable, CaseIterable, Identifiable, Sendable {
    case pristine
    case lightWear
    case wellLoved
    case damaged

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pristine: return "Pristine"
        case .lightWear: return "Light wear"
        case .wellLoved: return "Well-loved"
        case .damaged: return "Damaged"
        }
    }

    var summary: String {
        switch self {
        case .pristine: return "Nothing is removed. The document is shown exactly as imported."
        case .lightWear: return "Soft corners, faint handling marks, no loss of content."
        case .wellLoved: return "Nicked edges, creases and spotting. Occasional lost corner."
        case .damaged: return "Torn edges and holes that cut through text and artwork."
        }
    }

    /// Frequency and depth budget for each kind of defect, before intensity scaling.
    var budget: DamageBudget {
        switch self {
        case .pristine:
            return DamageBudget(
                edgeTears: 0...0, tearDepth: 0.0...0.0,
                lostCorners: 0...0, cornerReach: 0.0...0.0,
                holes: 0...0, holeRadius: 0.0...0.0,
                stains: 0...0, stainRadius: 0.0...0.0, stainOpacity: 0.0...0.0,
                creases: 0...0, foxingClusters: 0...0,
                edgeSoftening: 0.0
            )
        case .lightWear:
            return DamageBudget(
                edgeTears: 1...3, tearDepth: 0.004...0.016,
                lostCorners: 0...1, cornerReach: 0.015...0.035,
                holes: 0...0, holeRadius: 0.0...0.0,
                stains: 1...3, stainRadius: 0.05...0.13, stainOpacity: 0.04...0.09,
                creases: 0...1, foxingClusters: 0...1,
                edgeSoftening: 0.35
            )
        case .wellLoved:
            return DamageBudget(
                edgeTears: 3...7, tearDepth: 0.012...0.045,
                lostCorners: 1...2, cornerReach: 0.03...0.085,
                holes: 0...1, holeRadius: 0.012...0.03,
                stains: 2...5, stainRadius: 0.07...0.18, stainOpacity: 0.06...0.13,
                creases: 1...3, foxingClusters: 1...3,
                edgeSoftening: 0.7
            )
        case .damaged:
            return DamageBudget(
                edgeTears: 5...11, tearDepth: 0.03...0.13,
                lostCorners: 1...3, cornerReach: 0.06...0.19,
                holes: 1...3, holeRadius: 0.02...0.065,
                stains: 3...7, stainRadius: 0.09...0.24, stainOpacity: 0.08...0.17,
                creases: 2...5, foxingClusters: 2...5,
                edgeSoftening: 1.0
            )
        }
    }

    /// True when this condition can remove document content from the sheet.
    var removesContent: Bool { self != .pristine }
}

/// Ranges consumed by `DamageGenerator`. All distances are normalized page units.
struct DamageBudget: Sendable {
    var edgeTears: ClosedRange<Int>
    var tearDepth: ClosedRange<Double>
    var lostCorners: ClosedRange<Int>
    var cornerReach: ClosedRange<Double>
    var holes: ClosedRange<Int>
    var holeRadius: ClosedRange<Double>
    var stains: ClosedRange<Int>
    var stainRadius: ClosedRange<Double>
    var stainOpacity: ClosedRange<Double>
    var creases: ClosedRange<Int>
    var foxingClusters: ClosedRange<Int>
    var edgeSoftening: Double
}

// MARK: - Book presentation

enum BookPresentation: String, Codable, CaseIterable, Identifiable, Sendable {
    case minimal
    case paperback
    case hardcover
    case oldJournal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .paperback: return "Paperback"
        case .hardcover: return "Hardcover"
        case .oldJournal: return "Old journal"
        }
    }

    /// Margin around the sheet, as a fraction of the smaller surface dimension.
    var surfaceInset: Double {
        switch self {
        case .minimal: return 0.005
        case .paperback: return 0.030
        case .hardcover: return 0.045
        case .oldJournal: return 0.040
        }
    }

    /// Corner radius of the sheet, as a fraction of the sheet's smaller side.
    var sheetCornerRadius: Double {
        switch self {
        case .minimal: return 0.0
        case .paperback: return 0.012
        case .hardcover: return 0.008
        case .oldJournal: return 0.022
        }
    }

    /// How many neighbouring sheets peek out behind the current page.
    var visibleStackDepth: Int {
        switch self {
        case .minimal: return 0
        case .paperback: return 3
        case .hardcover: return 5
        case .oldJournal: return 4
        }
    }

    /// Colour behind the sheet — board, cover or desk.
    var surroundColor: RGBAColor {
        switch self {
        case .minimal: return RGBAColor(hex: 0x111111)
        case .paperback: return RGBAColor(hex: 0x2A2622)
        case .hardcover: return RGBAColor(hex: 0x3A2118)
        case .oldJournal: return RGBAColor(hex: 0x241A12)
        }
    }

    /// Width of the spine gutter in a two-page spread, as a fraction of the spread width.
    var spineFraction: Double {
        switch self {
        case .minimal: return 0.006
        case .paperback: return 0.020
        case .hardcover: return 0.032
        case .oldJournal: return 0.038
        }
    }

    var showsSpine: Bool { self != .minimal }
}

// MARK: - Lighting

enum LightingStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case flat
    case warm
    case directional
    case hingeReactive

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .flat: return "Flat"
        case .warm: return "Warm"
        case .directional: return "Directional"
        case .hingeReactive: return "Posture-reactive"
        }
    }

    /// 0…1 corner darkening applied over the sheet.
    var vignetteStrength: Double {
        switch self {
        case .flat: return 0.0
        case .warm: return 0.12
        case .directional: return 0.26
        case .hingeReactive: return 0.22
        }
    }

    /// Warm tint laid over the whole sheet.
    var tint: RGBAColor {
        switch self {
        case .flat: return RGBAColor(1, 1, 1, 0)
        case .warm: return RGBAColor(hex: 0xFFC98A, alpha: 0.10)
        case .directional: return RGBAColor(hex: 0xFFD9A8, alpha: 0.07)
        case .hingeReactive: return RGBAColor(hex: 0xFFD2A0, alpha: 0.08)
        }
    }

    /// Strength of the gradient sweep across the sheet.
    var gradientStrength: Double {
        switch self {
        case .flat: return 0.0
        case .warm: return 0.05
        case .directional: return 0.20
        case .hingeReactive: return 0.16
        }
    }

    /// When true the spine shadow responds to the device's posture / spread state.
    var respondsToPosture: Bool { self == .hingeReactive }
}

// MARK: - Environment

struct ReadingEnvironment: Codable, Hashable, Identifiable, Sendable {
    /// Stable identifier — also part of the damage seed, so renaming is safe
    /// but changing the id regenerates wear.
    var id: String
    var name: String
    var material: PaperMaterial
    var condition: PageCondition
    var presentation: BookPresentation
    var lighting: LightingStyle
    /// 0…1 multiplier over the condition's damage budget.
    var intensity: Double
    /// Bumped when the generator's rules change so old wear is recomputed.
    var generatorVersion: Int

    // MARK: Themed axes
    //
    // Every one of these defaults to the value that reproduces the app exactly
    // as it behaved before the axis existed, and every one is decoded with
    // `decodeIfPresent`. A book saved by an earlier build therefore reopens
    // worn precisely as its owner left it.

    /// What the sheet is made of. `.paper` is the identity case.
    var substrate: Substrate
    /// What a previous owner left on the page.
    var marginalia: MarginaliaStyle
    /// How the document's own pixels arrive.
    var ink: InkBehavior
    /// What moves, and in which phases.
    var motion: MotionStyle
    /// The book as an object on the shelf.
    var cover: CoverStyle
    /// A live overlay. It does not change composited page pixels.
    var pageEffect: PageEffect
    /// Compatibility with existing callers; saved pageEffect is authoritative.
    var footstepsEnabled: Bool {
        get { pageEffect == .footsteps }
        set { if newValue { pageEffect = .footsteps } else if pageEffect == .footsteps { pageEffect = .none } }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, material, condition, presentation, lighting, intensity, generatorVersion
        case substrate, marginalia, ink, motion, cover, footstepsEnabled, pageEffect
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(material, forKey: .material)
        try c.encode(condition, forKey: .condition)
        try c.encode(presentation, forKey: .presentation)
        try c.encode(lighting, forKey: .lighting)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(generatorVersion, forKey: .generatorVersion)
        try c.encode(substrate, forKey: .substrate)
        try c.encode(marginalia, forKey: .marginalia)
        try c.encode(ink, forKey: .ink)
        try c.encode(motion, forKey: .motion)
        try c.encode(cover, forKey: .cover)
        try c.encode(pageEffect, forKey: .pageEffect)
        try c.encode(footstepsEnabled, forKey: .footstepsEnabled)
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        material: PaperMaterial,
        condition: PageCondition,
        presentation: BookPresentation,
        lighting: LightingStyle,
        intensity: Double = 0.7,
        substrate: Substrate = .paper,
        marginalia: MarginaliaStyle = .none,
        ink: InkBehavior = .instant,
        motion: MotionStyle = .still,
        cover: CoverStyle = .plain,
        footstepsEnabled: Bool = false,
        pageEffect: PageEffect? = nil,
        generatorVersion: Int = ReadingEnvironment.currentGeneratorVersion
    ) {
        self.id = id
        self.name = name
        self.material = material
        self.condition = condition
        self.presentation = presentation
        self.lighting = lighting
        self.intensity = intensity.clamped(to: 0...1)
        self.substrate = substrate
        self.marginalia = marginalia
        self.ink = ink
        self.motion = motion
        self.cover = cover
        self.pageEffect = pageEffect ?? (footstepsEnabled ? .footsteps : .none)
        self.generatorVersion = generatorVersion
    }

    /// Decoding is written out rather than synthesized so that the five themed
    /// axes can be absent. Synthesized `Codable` would reject every environment
    /// written before they existed, which is every book already on a shelf.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.material = try container.decode(PaperMaterial.self, forKey: .material)
        self.condition = try container.decode(PageCondition.self, forKey: .condition)
        self.presentation = try container.decode(BookPresentation.self, forKey: .presentation)
        self.lighting = try container.decode(LightingStyle.self, forKey: .lighting)
        self.intensity = try container.decode(Double.self, forKey: .intensity).clamped(to: 0...1)
        self.generatorVersion = try container.decode(Int.self, forKey: .generatorVersion)
        self.substrate = try container.decodeIfPresent(Substrate.self, forKey: .substrate) ?? .paper
        self.marginalia = try container.decodeIfPresent(MarginaliaStyle.self, forKey: .marginalia) ?? .none
        self.ink = try container.decodeIfPresent(InkBehavior.self, forKey: .ink) ?? .instant
        self.motion = try container.decodeIfPresent(MotionStyle.self, forKey: .motion) ?? .still
        self.cover = try container.decodeIfPresent(CoverStyle.self, forKey: .cover) ?? .plain
        if container.contains(.pageEffect) {
            let raw = try container.decodeIfPresent(String.self, forKey: .pageEffect)
            self.pageEffect = raw.flatMap(PageEffect.init(rawValue:)) ?? .none
        } else {
            self.pageEffect = (try container.decodeIfPresent(Bool.self, forKey: .footstepsEnabled) ?? false) ? .footsteps : .none
        }
    }

    /// Bump whenever the generator's rules or budgets change, so books rendered
    /// by an older build are recomputed rather than silently mixed.
    ///   2 — softer stains and creases; two-clip masking.
    static let currentGeneratorVersion = 2

    /// Identity of everything that affects *where the damage is*.
    ///
    /// Deliberately excludes `id`, material, presentation and lighting: those
    /// dimensions have to be independent, so changing paper stock or turning
    /// the lamp warmer must not shuffle a single tear.
    ///
    /// Substrate is the one addition that *does* belong here, because a stone
    /// tablet cannot tear and a bronze plate cannot fox: changing what the
    /// sheet is made of has to change which defects it can suffer. Paper is
    /// spelled as the absence of a substrate rather than as `paper`, so an
    /// all-paper environment produces the exact string it produced before this
    /// axis existed and every book already on a shelf keeps its own wear.
    var damageIdentity: String {
        let base = "\(condition.rawValue)|\(String(format: "%.3f", intensity))"
        guard substrate != .paper else { return "\(base)|v\(generatorVersion)" }
        return "\(base)|\(substrate.rawValue)|v\(generatorVersion)"
    }

    /// Identity of everything that decides *where the marginalia is*.
    ///
    /// Separate from `damageIdentity` on purpose, and fed by its own seed
    /// stream in `MarginaliaGenerator`. Sharing one stream would mean that
    /// shipping marginalia reshuffled every existing reader's tears.
    var marginaliaIdentity: String {
        "\(marginalia.rawValue)|\(String(format: "%.3f", intensity))"
    }

    /// Identity of everything that affects the composited pixels.
    ///
    /// Motion and cover are absent deliberately: motion belongs to the live
    /// layer and never touches the baked bitmap, and the cover is a different
    /// surface entirely.
    var renderIdentity: String {
        [
            damageIdentity,
            marginaliaIdentity,
            material.rawValue,
            substrate.rawValue,
            presentation.rawValue,
            lighting.rawValue,
            ink.rawValue
        ].joined(separator: "|")
    }

    // MARK: Resolved appearance

    /// The colours the compositor draws with, resolved from substrate and tone.
    var palette: SubstratePalette {
        substrate.palette(for: material)
    }

    /// Whether the document's ink has to be inverted to stay legible here.
    var invertsInk: Bool {
        substrate.invertsInk(for: material)
    }

    /// True when this environment needs a per-frame layer at all. An
    /// environment that answers `false` keeps exactly today's single-bake path.
    var needsLiveLayer: Bool {
        motion.needsLiveLayer || ink.needsLiveLayer
    }

    /// Only the supported opt-in effects survive old saved appearances.
    /// Legacy fields remain decodable, but cannot style the live reader.
    var effectsOnly: ReadingEnvironment {
        var result = Self.cleanPaper
        result.id = "reader.effects"
        result.name = "Reading effects"
        result.ink = ink == .enchanted ? .enchanted : .instant
        result.pageEffect = pageEffect
        return result
    }

    /// The reversible override: same material and presentation, nothing removed.
    var pristineVariant: ReadingEnvironment {
        var copy = self
        copy.condition = .pristine
        return copy
    }
}

// MARK: - Presets

extension ReadingEnvironment {
    static let cleanPaper = ReadingEnvironment(
        id: "preset.clean",
        name: "Clean paper",
        material: .white,
        condition: .pristine,
        presentation: .minimal,
        lighting: .flat,
        intensity: 0.0
    )

    static let softCream = ReadingEnvironment(
        id: "preset.cream",
        name: "Soft cream",
        material: .cream,
        condition: .lightWear,
        presentation: .paperback,
        lighting: .warm,
        intensity: 0.45
    )

    static let wellReadPaperback = ReadingEnvironment(
        id: "preset.paperback",
        name: "Well-read paperback",
        material: .aged,
        condition: .wellLoved,
        presentation: .paperback,
        lighting: .directional,
        intensity: 0.7
    )

    static let oldJournal = ReadingEnvironment(
        id: "preset.journal",
        name: "Old journal",
        material: .parchment,
        condition: .damaged,
        presentation: .oldJournal,
        lighting: .directional,
        intensity: 0.85
    )

    static let libraryHardcover = ReadingEnvironment(
        id: "preset.hardcover",
        name: "Library hardcover",
        material: .cream,
        condition: .wellLoved,
        presentation: .hardcover,
        lighting: .hingeReactive,
        intensity: 0.55
    )

    static let nightPaper = ReadingEnvironment(
        id: "preset.night",
        name: "Night paper",
        material: .dark,
        condition: .lightWear,
        presentation: .minimal,
        lighting: .flat,
        intensity: 0.3
    )

    static let presets: [ReadingEnvironment] = [
        .cleanPaper,
        .softCream,
        .wellReadPaperback,
        .oldJournal,
        .libraryHardcover,
        .nightPaper
    ]

    static let `default` = ReadingEnvironment.cleanPaper.effectsOnly
}

// MARK: - Themed presets

/// The themed reading environments.
///
/// Every one of these is a *coordinate*, not an engine: a row of values across
/// the same nine axes the plain presets use. Nothing below adds a rendering
/// path — if a theme needs something the axes cannot express, the axis is what
/// gains a case, never this file.
///
/// The names are original. The concepts they draw on are old enough to be
/// nobody's property: ink that soaks into a page, a map that reveals itself, a
/// cover with an eye, a tablet of carved stone.
extension ReadingEnvironment {

    /// Ink sinks into the sheet when you stop reading and rises at a touch.
    static let absorbingJournal = ReadingEnvironment(
        id: "theme.absorbing",
        name: "Absorbing journal",
        material: .cream,
        condition: .lightWear,
        presentation: .oldJournal,
        lighting: .warm,
        intensity: 0.4,
        substrate: .paper,
        marginalia: .handwritten,
        ink: .recede,
        motion: .still,
        cover: .tooled
    )

    /// Hidden routes and tracks that travel through the margins.
    static let chartedParchment = ReadingEnvironment(
        id: "theme.charted",
        name: "Charted parchment",
        material: .parchment,
        condition: .wellLoved,
        presentation: .oldJournal,
        lighting: .directional,
        intensity: 0.6,
        substrate: .vellum,
        marginalia: .cartographic,
        ink: .emerge,
        motion: .driftingMarks,
        cover: .tooled
    )

    /// Paper layers that stand up out of the gutter as the device opens.
    static let paperTheatre = ReadingEnvironment(
        id: "theme.theatre",
        name: "Paper theatre",
        material: .white,
        condition: .lightWear,
        presentation: .hardcover,
        lighting: .hingeReactive,
        intensity: 0.25,
        substrate: .paper,
        marginalia: .none,
        ink: .instant,
        motion: .risingPopup,
        cover: .plain
    )

    /// Tooled leather, scored wards, and an eye set into the cover.
    static let watchingGrimoire = ReadingEnvironment(
        id: "theme.grimoire",
        name: "Watching grimoire",
        material: .aged,
        condition: .wellLoved,
        presentation: .hardcover,
        lighting: .directional,
        intensity: 0.7,
        substrate: .leather,
        marginalia: .occult,
        ink: .instant,
        motion: .still,
        cover: .watching
    )

    /// Burned, stained and scored. The heaviest condition in the set.
    static let cursedManuscript = ReadingEnvironment(
        id: "theme.cursed",
        name: "Cursed manuscript",
        material: .parchment,
        condition: .damaged,
        presentation: .oldJournal,
        lighting: .directional,
        intensity: 0.95,
        substrate: .vellum,
        marginalia: .occult,
        ink: .instant,
        motion: .still,
        cover: .clasped
    )

    /// Carved stone. It chips and cracks; it cannot tear.
    static let stoneTablet = ReadingEnvironment(
        id: "theme.stone",
        name: "Stone tablet",
        material: .aged,
        condition: .wellLoved,
        presentation: .minimal,
        lighting: .directional,
        intensity: 0.65,
        substrate: .stone,
        marginalia: .none,
        ink: .instant,
        motion: .still,
        cover: .plain
    )

    /// Beaten gold gone green at the edges.
    static let gildedPlate = ReadingEnvironment(
        id: "theme.gilded",
        name: "Gilded plate",
        material: .parchment,
        condition: .wellLoved,
        presentation: .minimal,
        lighting: .directional,
        intensity: 0.55,
        substrate: .metal,
        marginalia: .none,
        ink: .instant,
        motion: .still,
        cover: .clasped
    )

    /// Hide and teeth. It would rather stay shut.
    static let creatureBook = ReadingEnvironment(
        id: "theme.creature",
        name: "Creature book",
        material: .dark,
        condition: .wellLoved,
        presentation: .hardcover,
        lighting: .warm,
        intensity: 0.6,
        substrate: .leather,
        marginalia: .none,
        ink: .instant,
        motion: .breathing,
        cover: .creature
    )

    /// Illustrated matter leaves the page at a chapter boundary.
    static let escapingIllustrations = ReadingEnvironment(
        id: "theme.escaping",
        name: "Escaping illustrations",
        material: .cream,
        condition: .lightWear,
        presentation: .hardcover,
        lighting: .warm,
        intensity: 0.3,
        substrate: .paper,
        marginalia: .none,
        ink: .absorb,
        motion: .escapingInk,
        cover: .plain
    )

    /// Sketches, pressed specimens and a previous owner's observations.
    static let fieldGuide = ReadingEnvironment(
        id: "theme.fieldguide",
        name: "Field guide",
        material: .aged,
        condition: .wellLoved,
        presentation: .oldJournal,
        lighting: .warm,
        intensity: 0.55,
        substrate: .paper,
        marginalia: .naturalist,
        ink: .instant,
        motion: .still,
        cover: .tooled
    )

    /// Every defect paper can suffer, at whatever strength the reader chooses.
    /// The one theme with no styling of its own: it is the condition axis
    /// turned all the way up and handed over.
    static let wellHandled = ReadingEnvironment(
        id: "theme.handled",
        name: "Well-handled",
        material: .cream,
        condition: .damaged,
        presentation: .paperback,
        lighting: .directional,
        intensity: 0.8,
        substrate: .paper,
        marginalia: .scholarly,
        ink: .instant,
        motion: .still,
        cover: .plain
    )

    /// The themed set, in the order they should be offered.
    static let themedPresets: [ReadingEnvironment] = [
        .absorbingJournal,
        .chartedParchment,
        .paperTheatre,
        .watchingGrimoire,
        .cursedManuscript,
        .stoneTablet,
        .gildedPlate,
        .creatureBook,
        .escapingIllustrations,
        .fieldGuide,
        .wellHandled
    ]

    /// Plain presets first, themed ones after. What the picker shows.
    static let allPresets: [ReadingEnvironment] = presets + themedPresets
}
