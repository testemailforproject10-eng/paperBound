//
//  InkBehavior.swift
//  Paperbound
//
//  How the document's own pixels arrive on the page.
//
//  This is the cheapest of the new axes by a wide margin: it touches exactly
//  one function, `PageCompositor.drawContent`, and needs only a 0…1 progress
//  value rather than a general animation system. Everything it does is
//  presentation — the imported file is never altered, and `.instant` is
//  byte-for-byte what the app did before this axis existed.
//

import Foundation

enum InkBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Type is simply there, the way it has always been.
    case instant
    /// Ink soaks into the sheet: it lands over-saturated and bleeding, then
    /// tightens to a clean impression as it dries.
    case absorb
    /// Type surfaces from nothing, as though rising through the fibres.
    case emerge
    /// Type sinks back into the page when the reader stops, and returns the
    /// moment they touch it.
    case recede

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .instant: return "Instant"
        case .absorb: return "Absorbing"
        case .emerge: return "Emerging"
        case .recede: return "Receding"
        }
    }

    var summary: String {
        switch self {
        case .instant: return "Type is on the page when the page is."
        case .absorb: return "Ink soaks into the sheet and tightens as it dries."
        case .emerge: return "Words surface out of the paper as the page settles."
        case .recede: return "Words sink into the page when you stop, and return at a touch."
        }
    }

    /// How long the arrival takes. Zero means there is no arrival to animate.
    var revealDuration: Duration {
        switch self {
        case .instant: return .zero
        case .absorb: return .milliseconds(420)
        case .emerge: return .milliseconds(650)
        case .recede: return .milliseconds(380)
        }
    }

    /// How far the ink spreads past its true edge at the start of the reveal,
    /// as a fraction of the sheet's shorter side. Drives a blur, not a smudge:
    /// the glyph shapes themselves are never altered.
    var maximumBleed: Double {
        switch self {
        case .instant: return 0.0
        case .absorb: return 0.0045
        case .emerge: return 0.0020
        case .recede: return 0.0030
        }
    }

    /// True when type fades once the reader has been still.
    var recedesWhenIdle: Bool { self == .recede }

    /// How long the reader must be still before type starts to sink.
    var idleDelay: Duration {
        switch self {
        case .recede: return .seconds(12)
        case .instant, .absorb, .emerge: return .seconds(0)
        }
    }

    /// True when this behaviour needs a live layer at all. `.instant` does not,
    /// so environments that use it keep exactly today's single-bake render path.
    var needsLiveLayer: Bool { self != .instant }

    /// Ink coverage at `progress` through the reveal, 0…1.
    ///
    /// Pure arithmetic with no clock of its own, so it is trivially testable
    /// and the live layer stays the only thing that knows what time it is.
    func opacity(atProgress progress: Double) -> Double {
        let t = progress.clamped(to: 0...1)
        switch self {
        case .instant:
            return 1.0
        case .absorb:
            // Lands strong, settles slightly back as it dries into the fibre.
            return t < 0.35 ? (t / 0.35) * 1.08 : 1.08 - (t - 0.35) / 0.65 * 0.08
        case .emerge:
            // Ease-out: slow to surface, then confident.
            return 1 - pow(1 - t, 2.2)
        case .recede:
            return t
        }
    }

    /// Ink spread at `progress`, in normalized units. Falls to zero as the
    /// impression dries.
    func bleed(atProgress progress: Double) -> Double {
        let t = progress.clamped(to: 0...1)
        return maximumBleed * (1 - t)
    }
}
