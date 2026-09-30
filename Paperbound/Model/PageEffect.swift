import Foundation

/// Decorative overlays only; never part of a PDF raster request.
enum PageEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, footsteps, paperMessengers, marginCreatures, pixieDust
    case wanderingWisps, enchantedButterflies, fallingRosePetals
    case floatingLanterns, wonderlandCards, winterMargins, littleHearthSpirit

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .footsteps: "Footsteps"
        case .paperMessengers: "Paper Messengers"
        case .marginCreatures: "Margin Creatures"
        case .pixieDust: "Pixie Dust"
        case .wanderingWisps: "Wandering Wisps"
        case .enchantedButterflies: "Enchanted Butterflies"
        case .fallingRosePetals: "Falling Rose Petals"
        case .floatingLanterns: "Floating Lanterns"
        case .wonderlandCards: "Wonderland Cards"
        case .winterMargins: "Winter Margins"
        case .littleHearthSpirit: "Little Hearth Spirit"
        }
    }
    var detail: String {
        switch self {
        case .none: "Just your book, with no page decoration."
        case .footsteps: "Three trails of tiny shoeprints wander across the paper."
        case .paperMessengers: "Occasional flights of paper planes arrive, cross the book, and glide away."
        case .marginCreatures: "Curious visitors stop for a wordless chat, take turns speaking, then leave together."
        case .pixieDust: "An unseen fairy passes through, leaving a brief trail of gold flecks."
        case .wanderingWisps: "Blue spirits float in slowly, linger together, and drift away."
        case .enchantedButterflies: "Butterflies arrive in changing numbers, pause to rest, then fly away."
        case .fallingRosePetals: "Larger petals flutter on shifting breezes, with scattered arrivals and quiet spells."
        case .floatingLanterns: "Small groups of lanterns drift up from below and disappear beyond the top."
        case .wonderlandCards: "Card visitors pause for a chat, nod to one another, then march away."
        case .winterMargins: "Visible blue-white snowflakes drift in on loose, changing breezes."
        case .littleHearthSpirit: "Little flames drift in, settle with floating embers, then slip away."
        }
    }
    var isAnimated: Bool { self != .none }
    var hasSpriteArtwork: Bool { self != .none && self != .footsteps }
}
