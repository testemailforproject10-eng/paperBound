//
//  PageTurnStyle.swift
//  Paperbound
//
//  How a page leaves and the next one arrives.
//
//  Every style rides on the same horizontal pager: the scroll offset is the
//  single source of truth for how far a turn has got, so swipes, taps, the
//  slider and the enchanted-ink reveal all keep working unchanged. A style
//  only decides what each sheet *looks like* at a given point in the turn.
//
//  The lower-numbered unit is always the leaf being turned and the higher one
//  always lies beneath it, in both directions. Turning back is the same
//  motion played in reverse, exactly as it is with paper.
//

import CoreGraphics
import Foundation

enum PageTurnStyle: String, CaseIterable, Identifiable, Sendable {
    /// The leaf curls up from its outer edge and rolls over onto the spine.
    case curl
    /// The leaf swings over on its spine like a stiff board page.
    case flip
    /// The leaf slides away and the next page is already there beneath it.
    case cover
    /// Pages slide side by side. The original behaviour.
    case slide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .curl: return "Page curl"
        case .flip: return "Flip"
        case .cover: return "Cover"
        case .slide: return "Slide"
        }
    }

    var detail: String {
        switch self {
        case .curl: return "The page curls up from the corner and rolls over."
        case .flip: return "The page swings over on the spine."
        case .cover: return "The page slides off the one beneath it."
        case .slide: return "Pages slide past side by side."
        }
    }

    var systemImage: String {
        switch self {
        case .curl: return "book.pages"
        case .flip: return "rectangle.portrait.rotate"
        case .cover: return "square.stack"
        case .slide: return "arrow.left.and.right"
        }
    }

    /// A tap or a jump plays the turn at this length. A curl or a flip that
    /// lasts as long as a slide reads as a glitch rather than a page.
    var programmaticDuration: Double {
        switch self {
        case .slide: return 0.28
        case .cover: return 0.38
        case .curl, .flip: return 0.55
        }
    }
}

/// One paging unit's place in a turn, in page widths relative to the
/// viewport: 0 at rest, negative while it is lifted away to the left,
/// positive while it waits underneath to the right.
struct PageTurn: Equatable, Sendable {
    let style: PageTurnStyle
    let position: CGFloat

    /// Turns only exist between two adjacent units; anything at rest or
    /// further than one page away is left alone.
    init?(style: PageTurnStyle, position: CGFloat) {
        guard style != .slide, position.isFinite,
              abs(position) > 0.0005, abs(position) < 1 else { return nil }
        self.style = style
        self.position = position
    }

    /// The leaf on top, being turned away.
    var isLifting: Bool { position < 0 }
    /// 0 flat, 1 fully turned. Only meaningful while lifting.
    var lift: CGFloat { max(0, -position) }
    /// 1 fully covered, 0 fully revealed. Only meaningful while beneath.
    var covered: CGFloat { max(0, position) }

    /// Horizontal offset that keeps a sheet in place while the pager moves it.
    /// Only a cover turn lets the top leaf travel with the finger.
    func holdOffset(pageWidth: CGFloat) -> CGFloat {
        if style == .cover && isLifting { return 0 }
        return -position * pageWidth
    }

    /// Draw order between the two units in a turn. A curl or a cover always
    /// keeps the turning leaf on top. A flip hands over at the half-way
    /// point, where the leaf is edge-on and the next spread's page swings down.
    func zIndex(isSpread: Bool) -> Double {
        if style == .flip && isSpread { return abs(position) < 0.5 ? 1 : 0 }
        return isLifting ? 1 : 0
    }

    /// How much the page beneath is shaded by the leaf still over it.
    var beneathShade: Double {
        guard !isLifting else { return 0 }
        switch style {
        case .cover: return 0.16 * Double(covered)
        case .curl: return 0.08 * Double(covered)
        case .flip: return 0.12 * Double(covered)
        case .slide: return 0
        }
    }
}

/// A leaf curling over a cylinder lying across the page.
///
/// The leaf spans `pageMinX…pageMaxX`. Everything left of `foldX` is still
/// flat; from there the paper wraps around a cylinder of radius `radius` and
/// the part past half a turn lies back over the page, face down. When the
/// curl finishes, that face-down part lies exactly mirrored about `pageMinX`:
/// on the facing page in a spread, off-screen for a single page.
struct PageCurlGeometry: Equatable, Sendable {
    let foldX: CGFloat
    let radius: CGFloat

    init(lift: CGFloat, pageMinX: CGFloat, pageMaxX: CGFloat) {
        let width = max(1, pageMaxX - pageMinX)
        let lift = min(max(lift, 0), 1)
        // Tight at the very start and the very end, fullest mid-turn: a page
        // lifted by its edge, then pressed flat as it lands.
        let fullest = min(width * 0.16, 90)
        radius = fullest * (0.12 + 0.88 * sin(.pi * lift))
        foldX = pageMaxX - lift * (width + .pi * radius / 2)
    }

    /// Where the face-down part of the leaf ends, on the spine side. Left of
    /// this the page beneath is uncovered.
    func backEdge(pageMaxX: CGFloat) -> CGFloat {
        2 * foldX + .pi * radius - pageMaxX
    }
}

/// A leaf swinging on its spine, for the flip style.
enum PageFlipGeometry {
    /// Degrees about the vertical axis for the right-hand leaf of the lifting
    /// spread: 0 flat, -90 edge-on at the half-way point.
    static func liftingAngle(lift: CGFloat) -> Double { -180 * Double(lift) }

    /// Degrees for the left-hand leaf of the spread beneath, swinging down
    /// from edge-on (+90) to flat once the lifting leaf has passed half-way.
    static func landingAngle(covered: CGFloat) -> Double { 180 * Double(covered) }

    /// A single sheet has nothing to show on its back, so it only swings up
    /// to edge-on and the page beneath is revealed.
    static func singleAngle(lift: CGFloat) -> Double { -90 * Double(lift) }

    /// Light falls off as the leaf turns edge-on to the reader.
    static func shade(forAngle degrees: Double) -> Double {
        0.18 * abs(sin(degrees * .pi / 180))
    }
}
