//
//  CoverStyle.swift
//  Paperbound
//
//  The book as an object, rather than the page as a surface.
//
//  Two of the themed environments are not page effects at all: a cover with an
//  eye, and a cover that behaves like a creature. Both live on the shelf tile
//  and in the open transition, and neither ever enters `PageCompositor`.
//  Treating them as page themes is the mistake this file exists to avoid — a
//  cover is on screen for two seconds and can afford detail that a sheet being
//  read at 60fps cannot.
//

import Foundation

enum CoverStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Boards and a spine. What the shelf shows today.
    case plain
    /// Tooled leather: blind-stamped borders and raised bands.
    case tooled
    /// Metal furniture: corner bosses, a clasp, a lock that has been forced.
    case clasped
    /// An eye set into the cover. It blinks, and it tracks.
    case watching
    /// Hide, teeth and a temper.
    case creature

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plain: return "Plain boards"
        case .tooled: return "Tooled"
        case .clasped: return "Clasped"
        case .watching: return "Watching"
        case .creature: return "Creature"
        }
    }

    var summary: String {
        switch self {
        case .plain: return "Boards and a spine."
        case .tooled: return "Blind-stamped leather with raised bands."
        case .clasped: return "Metal bosses and a clasp that has been forced open."
        case .watching: return "An eye set into the cover. It blinks, and it follows."
        case .creature: return "Hide and teeth. It would rather stay shut."
        }
    }

    /// True when the cover carries an eye that blinks and tracks.
    var hasEye: Bool {
        switch self {
        case .watching, .creature: return true
        case .plain, .tooled, .clasped: return false
        }
    }

    /// True when the cover has a mouth.
    var hasTeeth: Bool { self == .creature }

    /// True when metal furniture is drawn over the boards.
    var hasMetalFurniture: Bool { self == .clasped }

    /// True when the boards carry blind-stamped tooling.
    var hasTooling: Bool {
        switch self {
        case .tooled, .clasped: return true
        case .plain, .watching, .creature: return false
        }
    }

    /// True when the cover responds to being opened rather than simply opening.
    var reactsToOpening: Bool {
        switch self {
        case .watching, .creature: return true
        case .plain, .tooled, .clasped: return false
        }
    }

    /// How long the open transition should take.
    ///
    /// A creature resists, which costs the reader time on every single open.
    /// It is kept under a second deliberately: the effect has to read as
    /// character, not as the app being slow.
    var openDuration: Duration {
        switch self {
        case .plain: return .milliseconds(280)
        case .tooled, .clasped: return .milliseconds(380)
        case .watching: return .milliseconds(460)
        case .creature: return .milliseconds(760)
        }
    }

    /// True when this style needs a live layer on the shelf tile.
    var needsLiveLayer: Bool {
        switch self {
        case .watching, .creature: return true
        case .plain, .tooled, .clasped: return false
        }
    }
}
