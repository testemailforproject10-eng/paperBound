//
//  Motion.swift
//  Paperbound
//
//  The axis that moves, and the budget that keeps it from ruining the reading.
//
//  The rule this file exists to enforce: **effects may occupy the frame, they
//  may not occupy the field.** The field is the text block, `contentRect`; the
//  frame is the margin, the edges, the gutter and the space between chapters.
//  A butterfly crossing the page mid-sentence is why people uninstall an app
//  like this one.
//
//  `MotionPhase` is the second half of that rule. Motion runs while a page is
//  arriving, turning, or being left alone; in `.settled` the live layer draws
//  lighting and nothing else. Making it an enum rather than a per-theme
//  judgment means a new environment cannot get this wrong by accident.
//

import Foundation

// MARK: - When motion is allowed

enum MotionPhase: String, Codable, CaseIterable, Sendable {
    /// The book is being opened from the shelf.
    case opening
    /// A page turn is in flight.
    case pageTurn
    /// A chapter boundary was just crossed.
    case chapterTransition
    /// The reader has been still for a while.
    case idle
    /// A page at rest with someone reading it.
    case settled

    /// Whether any motion at all may run in this phase.
    ///
    /// `.settled` is the whole point: a page being read is never animated.
    var allowsMotion: Bool { self != .settled }

    var displayName: String {
        switch self {
        case .opening: return "Opening"
        case .pageTurn: return "Page turn"
        case .chapterTransition: return "Chapter change"
        case .idle: return "Idle"
        case .settled: return "Settled"
        }
    }
}

// MARK: - The axis

enum MotionStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Nothing moves. The default, and what every existing preset uses.
    case still
    /// Marks travel across the margins: tracks that walk, routes that draw in.
    case driftingMarks
    /// Illustrated matter leaves the page at a chapter boundary and settles back.
    case escapingInk
    /// Layers stand up out of the gutter as a folding device is opened.
    case risingPopup
    /// The whole leaf breathes very slightly, as though the book were alive.
    case breathing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .still: return "Still"
        case .driftingMarks: return "Drifting marks"
        case .escapingInk: return "Escaping ink"
        case .risingPopup: return "Rising pop-up"
        case .breathing: return "Breathing"
        }
    }

    var summary: String {
        switch self {
        case .still: return "Nothing moves. The page is a page."
        case .driftingMarks: return "Tracks and routes travel through the margins."
        case .escapingInk: return "Illustrations leave the page between chapters, then settle back."
        case .risingPopup: return "Paper layers stand up out of the gutter as the device opens."
        case .breathing: return "The leaf moves very slightly, as though the book were alive."
        }
    }

    /// The phases this style runs in. `.settled` never appears in any of them,
    /// by construction: nothing may animate under someone who is reading.
    var activePhases: Set<MotionPhase> {
        switch self {
        case .still:
            return []
        case .driftingMarks:
            return [.idle, .pageTurn]
        case .escapingInk:
            return [.chapterTransition, .opening]
        case .risingPopup:
            // Driven by the hinge, so it must also be live while a page rests:
            // the reader opens the device without turning a page. This is the
            // one style that runs in `.settled`, and it is allowed because the
            // motion is the reader's own hand on the hinge, not an autoplay.
            return [.opening, .pageTurn, .chapterTransition, .idle, .settled]
        case .breathing:
            return [.idle, .opening]
        }
    }

    func runs(in phase: MotionPhase) -> Bool {
        activePhases.contains(phase)
    }

    /// True when this style is driven by the device's hinge rather than a clock.
    var isPostureDriven: Bool { self == .risingPopup }

    /// How many drawn elements the live layer may spend per frame.
    ///
    /// A hard ceiling rather than a suggestion: the live layer draws over a
    /// cached 4.2-megapixel bitmap, and the whole reason the render split
    /// exists is that this layer stays cheap.
    var particleBudget: Int {
        switch self {
        case .still: return 0
        case .driftingMarks: return 24
        case .escapingInk: return 64
        case .risingPopup: return 12
        case .breathing: return 0
        }
    }

    /// Seconds for one full cycle of whatever this style does.
    var period: Double {
        switch self {
        case .still: return 0
        case .driftingMarks: return 9.0
        case .escapingInk: return 2.4
        case .risingPopup: return 0      // posture-driven, not periodic
        case .breathing: return 6.5
        }
    }

    /// True when this style needs a per-frame layer at all.
    var needsLiveLayer: Bool { self != .still }
}
