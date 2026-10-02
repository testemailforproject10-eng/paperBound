//
//  MarkerInkView.swift
//  Paperbound
//
//  Draws saved annotation marks and the live text selection over a page.
//
//  `MarkerInkView` paints every mark on a page into a single `Canvas`, so a
//  page full of highlights costs one layer. The canvas is composited with a
//  multiply blend on light paper (black text stays black under the ink) and a
//  screen blend on dark paper (ink lifts the dark ground instead of vanishing).
//  For those view-level blends to reach the page artwork, place this view in
//  the same compositing group as the page, directly above it.
//
//  `TextSelectionOverlay` is the system-style selection: a soft accent tint per
//  line and two handles. It is plain UI rather than ink, because a selection
//  is a temporary tool state, not something done to the paper.
//
//  Both overlays are decorative and ignore touches. The integrator hit-tests
//  handles with `TextSelectionOverlay.handle(at:lineRects:textBlock:)`.
//

import SwiftUI

struct MarkerInkView: View {
    let marks: [PageMark]
    /// The page's text block in this view's coordinates (from PageTextFrame.textBlock).
    let textBlock: CGRect
    /// The mark currently being edited: draw it slightly denser so the reader
    /// can see which one the edit menu refers to without a UI outline.
    var emphasizedMarkID: UUID? = nil
    var isDarkPaper: Bool = false

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            context.blendMode = MarkerInk.contextBlendMode(darkPaper: isDarkPaper)
            for mark in marks {
                Self.draw(mark, in: textBlock, emphasized: mark.id == emphasizedMarkID, darkPaper: isDarkPaper, into: &context)
            }
        }
        .blendMode(MarkerInk.blendMode(darkPaper: isDarkPaper))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Draws one mark. Exposed so other canvases (thumbnails, exports) can
    /// paint marks with exactly the same ink.
    static func draw(
        _ mark: PageMark,
        in textBlock: CGRect,
        emphasized: Bool,
        darkPaper: Bool,
        into context: inout GraphicsContext
    ) {
        let ink = MarkerInk.ink(for: mark.color, style: mark.style, darkPaper: darkPaper)
        let boost = emphasized ? 1.22 : 1.0
        let opacity = min(1, ink.opacity * boost)
        let shading = GraphicsContext.Shading.color(ink.color)
        for (line, unitRect) in mark.lineRects.enumerated() {
            let rect = PageTextFrame.viewRect(forUnit: unitRect, in: textBlock)
            guard rect.width > 0.5, rect.height > 0.5, rect.minX.isFinite, rect.minY.isFinite else { continue }
            let seed = MarkerInk.seed(for: mark.id, line: line)
            switch mark.style {
            case .highlight:
                // Felt bleeds a fraction of a point into the paper fibres, so
                // the band's edge is soft rather than vector-crisp.
                var felt = context
                felt.addFilter(.blur(radius: MarkerInk.highlightEdgeSoftness(forLineHeight: rect.height)))
                felt.opacity = opacity
                felt.fill(MarkerInk.highlightPath(for: rect, seed: seed), with: shading)
                // Uneven felt: a faint offset second pass and slightly
                // heavier edges where the tip drags more ink.
                context.opacity = opacity * (darkPaper ? 0.18 : 0.16)
                context.fill(MarkerInk.highlightSecondPassPath(for: rect, seed: seed), with: shading)
                context.opacity = opacity * (darkPaper ? 0.14 : 0.12)
                context.fill(MarkerInk.highlightEdgePath(for: rect, seed: seed), with: shading)
            case .underline, .strikethrough, .squiggly:
                context.opacity = opacity
                context.fill(MarkerInk.path(for: mark.style, lineRect: rect, seed: seed), with: shading)
            }
        }
        context.opacity = 1
    }
}

/// Which selection handle a touch grabbed.
enum SelectionHandle: Sendable { case start, end }

struct TextSelectionOverlay: View {
    let lineRects: [CGRect]   // unit page space
    let textBlock: CGRect
    var tint: Color = .accentColor

    @Environment(\.colorScheme) private var colorScheme

    /// Diameter of the round knob on each handle, matching iOS.
    static let knobDiameter: CGFloat = 10
    /// Width of the handle's vertical bar.
    static let barWidth: CGFloat = 2
    /// How far from a handle a touch still grabs it. Generous, because the
    /// knob is tiny and fingers are not.
    static let hitRadius: CGFloat = 24

    var body: some View {
        let rects = lineRects.map { PageTextFrame.viewRect(forUnit: $0, in: textBlock) }
        let dark = colorScheme == .dark
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            let fill = GraphicsContext.Shading.color(tint.opacity(dark ? 0.30 : 0.22))
            for rect in rects where rect.width > 0 && rect.height > 0 {
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: fill)
            }
            guard let first = rects.first, let last = rects.last else { return }
            var handles = context
            handles.addFilter(.shadow(color: .black.opacity(dark ? 0.55 : 0.28), radius: 1.5, x: 0, y: 0.5))
            let solid = GraphicsContext.Shading.color(tint)
            for path in [
                Self.handlePath(barTop: first.minY, barBottom: first.maxY, x: first.minX, knobAbove: true),
                Self.handlePath(barTop: last.minY, barBottom: last.maxY, x: last.maxX, knobAbove: false)
            ] {
                handles.fill(path, with: solid)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func handlePath(barTop: CGFloat, barBottom: CGFloat, x: CGFloat, knobAbove: Bool) -> Path {
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: x - barWidth / 2, y: barTop, width: barWidth, height: max(barBottom - barTop, 1)),
            cornerSize: CGSize(width: 1, height: 1)
        )
        path.addEllipse(in: knobRect(center: knobCenter(barTop: barTop, barBottom: barBottom, x: x, knobAbove: knobAbove)))
        return path
    }

    private static func knobCenter(barTop: CGFloat, barBottom: CGFloat, x: CGFloat, knobAbove: Bool) -> CGPoint {
        // The knob sits just past the bar's end and overlaps it slightly, as on iOS.
        let r = knobDiameter / 2
        return knobAbove ? CGPoint(x: x, y: barTop - r + 1) : CGPoint(x: x, y: barBottom + r - 1)
    }

    private static func knobRect(center: CGPoint) -> CGRect {
        CGRect(x: center.x - knobDiameter / 2, y: center.y - knobDiameter / 2, width: knobDiameter, height: knobDiameter)
    }

    /// Handle anchor points in view coordinates: start = top-left of first line, end = bottom-right of last line.
    static func handlePoints(lineRects: [CGRect], textBlock: CGRect) -> (start: CGPoint, end: CGPoint)? {
        guard let first = lineRects.first, let last = lineRects.last else { return nil }
        let a = PageTextFrame.viewRect(forUnit: first, in: textBlock)
        let b = PageTextFrame.viewRect(forUnit: last, in: textBlock)
        return (CGPoint(x: a.minX, y: a.minY), CGPoint(x: b.maxX, y: b.maxY))
    }

    /// Which handle (if any) a touch at `point` grabs. Generous hit radius (>= 22pt) so handles are easy to catch.
    ///
    /// Distance is measured to the whole handle (bar plus knob), so a touch on
    /// the knob or anywhere along the bar counts. When both handles are in
    /// reach, as on a one-word selection, the nearer one wins.
    static func handle(at point: CGPoint, lineRects: [CGRect], textBlock: CGRect) -> SelectionHandle? {
        guard let first = lineRects.first, let last = lineRects.last else { return nil }
        let a = PageTextFrame.viewRect(forUnit: first, in: textBlock)
        let b = PageTextFrame.viewRect(forUnit: last, in: textBlock)
        let startKnob = knobCenter(barTop: a.minY, barBottom: a.maxY, x: a.minX, knobAbove: true)
        let endKnob = knobCenter(barTop: b.minY, barBottom: b.maxY, x: b.maxX, knobAbove: false)
        let startDistance = distance(from: point, toSegment: startKnob, CGPoint(x: a.minX, y: a.maxY))
        let endDistance = distance(from: point, toSegment: CGPoint(x: b.maxX, y: b.minY), endKnob)
        let best = min(startDistance, endDistance)
        guard best <= hitRadius else { return nil }
        return startDistance <= endDistance ? .start : .end
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared).clamped(to: 0...1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
