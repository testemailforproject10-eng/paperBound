//
//  MarkerInk.swift
//  Paperbound
//
//  Pure geometry and colour for annotation marks. Every mark is meant to read
//  as something a person did to the paper with a real tool: a chisel-tip
//  highlighter dragged along a line, or a fine pen pulled under or through it.
//
//  Nothing here is a view. The functions take a line rect already in view
//  points plus a seed and return a filled `Path`, so the same shapes can be
//  drawn by `MarkerInkView`, exported, or measured by tests.
//
//  Determinism: all variation comes from `SplitMix64` seeded by the mark's id
//  and line index through `StableHash`. A mark therefore looks identical every
//  time its page is drawn, on every launch and every device, the same promise
//  the wear system makes for torn corners and stains.
//
//  Containment: every generator keeps all points within 30% of the line
//  height outside its rect, so marks never wander into neighbouring lines.
//

import CoreGraphics
import Foundation
import SwiftUI

enum MarkerInk {

    // MARK: - Seeds

    /// Deterministic seed for a mark so it looks identical every time the page is drawn.
    ///
    /// The line index is mixed in so each line of a multi-line mark gets its own
    /// wobble; a real hand never repeats the same stroke twice.
    static func seed(for id: UUID, line: Int) -> UInt64 {
        StableHash.combine(StableHash.hash(id), UInt64(bitPattern: Int64(line)), 0x4D41_524B_494E_4B31)
    }

    // MARK: - Tunables

    /// How far the highlighter band reaches above and below the line, as a
    /// fraction of line height. Real highlighter tips are a little wider than
    /// the x-height plus descenders, so the band overshoots slightly.
    static let highlightOvershoot: CGFloat = 0.065

    /// Vertical position of the underline centre within the line rect.
    static let underlineCenter: CGFloat = 0.94
    /// Vertical position of the strikethrough centre within the line rect.
    static let strikethroughCenter: CGFloat = 0.54
    /// Vertical position of the squiggle's centre line within the line rect.
    static let squiggleCenter: CGFloat = 0.95
    /// Squiggle amplitude as a fraction of line height.
    static let squiggleAmplitude: CGFloat = 0.12
    /// Squiggle wavelength as a fraction of line height.
    static let squiggleWavelength: CGFloat = 0.5

    /// Pen nib width in points for a line of the given height: 1.3pt on tiny
    /// lines rising to 1.7pt on large ones, the range of a fine fineliner.
    static func penWidth(forLineHeight height: CGFloat) -> CGFloat {
        let t = ((height - 8) / 32).clamped(to: 0...1)
        return 1.3 + 0.4 * t
    }

    /// Blur radius for the highlighter's edge: felt ink wicks into paper by a
    /// fraction of a point, more on a broad tip than a narrow one.
    static func highlightEdgeSoftness(forLineHeight height: CGFloat) -> CGFloat {
        (height * 0.035).clamped(to: 0.35...0.9)
    }

    // MARK: - Highlighter

    /// Highlighter band for one line rect in view points.
    ///
    /// The band is a little taller than the line, its top and bottom edges
    /// wander gently (a hand never holds a perfectly level line) and its ends
    /// are slanted like the cut face of a chisel tip touching paper at an angle.
    static func highlightPath(for lineRect: CGRect, seed: UInt64) -> Path {
        highlightBand(for: lineRect, seed: seed, inset: 0, shift: .zero)
    }

    /// A faint second pass, slightly narrower and offset by a fraction of a
    /// point. Drawn at low opacity over the main band it gives the subtle
    /// density variation of felt that lays down ink unevenly.
    static func highlightSecondPassPath(for lineRect: CGRect, seed: UInt64) -> Path {
        var rng = SplitMix64(seed: seed ^ 0x5345_434F_4E44_5041)
        let h = lineRect.height
        let shift = CGSize(width: rng.double(in: -0.6...0.6), height: rng.double(in: 0.25...0.55) * (rng.chance(0.5) ? 1 : -1))
        return highlightBand(for: lineRect, seed: seed ^ 0x9E37_79B9, inset: h * 0.16, shift: shift)
    }

    /// Thin darker seams along the band's top and bottom edges, where felt
    /// tips deposit a little more ink as they drag. Very subtle by design.
    static func highlightEdgePath(for lineRect: CGRect, seed: UInt64) -> Path {
        let h = lineRect.height
        guard lineRect.width > 1, h > 1 else { return Path() }
        let band = bandGeometry(for: lineRect, seed: seed, inset: 0, shift: .zero)
        let seam = max(0.5, h * 0.05)
        var path = Path()
        for edge in [band.top, band.bottom] {
            let inward: CGFloat = edge.isTop ? 1 : -1
            var outer: [CGPoint] = []
            var inner: [CGPoint] = []
            for point in edge.points where point.x >= band.innerStart && point.x <= band.innerEnd {
                outer.append(point)
                inner.append(CGPoint(x: point.x, y: point.y + inward * seam))
            }
            guard outer.count > 1 else { continue }
            path.addLines(outer + inner.reversed())
            path.closeSubpath()
        }
        return path
    }

    private struct BandEdge {
        var points: [CGPoint]
        var isTop: Bool
    }

    private struct BandGeometry {
        var top: BandEdge
        var bottom: BandEdge
        /// The x range where both edges are fully inside the slanted ends.
        var innerStart: CGFloat
        var innerEnd: CGFloat
        var startTop: CGPoint
        var startBottom: CGPoint
        var endTop: CGPoint
        var endBottom: CGPoint
    }

    private static func bandGeometry(for rect: CGRect, seed: UInt64, inset: CGFloat, shift: CGSize) -> BandGeometry {
        var rng = SplitMix64(seed: seed)
        let h = rect.height
        let over = h * highlightOvershoot
        // A hand drifts slightly up or down across a line: a gentle tilt.
        let tilt = rng.double(in: -0.025...0.025) * h
        let topWave = LowFrequencyWave(rng: &rng, height: h, amplitude: h * 0.022)
        let bottomWave = LowFrequencyWave(rng: &rng, height: h, amplitude: h * 0.022)

        // Chisel tip: ends overshoot the text a touch and lean the same way, as
        // the cut face of the nib is held at a consistent angle.
        let reach = h * rng.double(in: 0.06...0.11)
        let slant = h * rng.double(in: 0.08...0.13)
        let startX = rect.minX - reach + shift.width + inset * 0.15
        let endX = rect.maxX + reach * 0.8 + shift.width - inset * 0.15
        let width = max(endX - startX, 1)

        func yTop(_ x: CGFloat) -> CGFloat {
            let t = (x - startX) / width
            return rect.minY - over + inset + tilt * (t - 0.5) + topWave.value(at: x - startX) + shift.height
        }
        func yBottom(_ x: CGFloat) -> CGFloat {
            let t = (x - startX) / width
            return rect.maxY + over - inset + tilt * (t - 0.5) + bottomWave.value(at: x - startX) + shift.height
        }

        // The top of each end leans forward of the bottom: a parallelogram end.
        let startTopX = startX + slant
        let startBottomX = startX
        let endTopX = endX
        let endBottomX = endX - slant

        let step = max(2, min(6, h * 0.35))
        func samples(from a: CGFloat, to b: CGFloat) -> [CGFloat] {
            guard b > a else { return [a] }
            let count = max(1, Int(((b - a) / step).rounded(.up)))
            return (0...count).map { a + (b - a) * CGFloat($0) / CGFloat(count) }
        }
        let topXs = samples(from: startTopX, to: max(startTopX, endTopX))
        let bottomXs = samples(from: startBottomX, to: max(startBottomX, endBottomX))
        let top = BandEdge(points: topXs.map { CGPoint(x: $0, y: yTop($0)) }, isTop: true)
        let bottom = BandEdge(points: bottomXs.map { CGPoint(x: $0, y: yBottom($0)) }, isTop: false)
        return BandGeometry(
            top: top,
            bottom: bottom,
            innerStart: startTopX,
            innerEnd: endBottomX,
            startTop: top.points.first ?? CGPoint(x: startTopX, y: yTop(startTopX)),
            startBottom: bottom.points.first ?? CGPoint(x: startBottomX, y: yBottom(startBottomX)),
            endTop: top.points.last ?? CGPoint(x: endTopX, y: yTop(endTopX)),
            endBottom: bottom.points.last ?? CGPoint(x: endBottomX, y: yBottom(endBottomX))
        )
    }

    private static func highlightBand(for rect: CGRect, seed: UInt64, inset: CGFloat, shift: CGSize) -> Path {
        guard rect.width > 0.5, rect.height > 0.5, rect.minX.isFinite, rect.minY.isFinite else { return Path() }
        let band = bandGeometry(for: rect, seed: seed, inset: inset, shift: shift)
        var path = Path()
        path.move(to: band.startBottom)
        // Chisel corner: a tiny rounding so the end does not look vector-sharp.
        let round = rect.height * 0.04
        path.addQuadCurve(
            to: band.startTop,
            control: CGPoint(x: (band.startBottom.x + band.startTop.x) / 2 - round, y: (band.startBottom.y + band.startTop.y) / 2)
        )
        // `addLine`, not `addLines`: the latter starts a new subpath and would
        // break the band into disconnected slivers.
        for point in band.top.points.dropFirst() { path.addLine(to: point) }
        path.addQuadCurve(
            to: band.endBottom,
            control: CGPoint(x: (band.endTop.x + band.endBottom.x) / 2 + round, y: (band.endTop.y + band.endBottom.y) / 2)
        )
        for point in band.bottom.points.reversed().dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    // MARK: - Pen strokes

    /// Underline: a fine pen stroke just under the glyphs, as a filled outline
    /// with tapered ends so it reads as a nib lifting off the page.
    static func underlinePath(for lineRect: CGRect, seed: UInt64) -> Path {
        penLine(for: lineRect, seed: seed, center: underlineCenter)
    }

    /// Strikethrough: the same pen stroke through the middle of the x-height.
    static func strikethroughPath(for lineRect: CGRect, seed: UInt64) -> Path {
        penLine(for: lineRect, seed: seed, center: strikethroughCenter)
    }

    /// Squiggly: a hand-drawn wave under the text. Each cycle varies a little in
    /// height and length, the way a looping hand never keeps perfect rhythm.
    static func squigglePath(for lineRect: CGRect, seed: UInt64) -> Path {
        let h = lineRect.height
        guard lineRect.width > 0.5, h > 0.5, lineRect.minX.isFinite, lineRect.minY.isFinite else { return Path() }
        var rng = SplitMix64(seed: seed ^ 0x5351_5549_4747_4C59)
        let width = penWidth(forLineHeight: h) * 0.92
        let baseY = lineRect.minY + h * squiggleCenter
        let drift = LowFrequencyWave(rng: &rng, height: h, amplitude: h * 0.015)
        let startX = lineRect.minX + rng.double(in: -0.04...0.04) * h
        let endX = lineRect.maxX + rng.double(in: -0.04...0.04) * h
        guard endX > startX else { return Path() }

        // Build the wave one half-cycle at a time with jittered length and
        // height, then sample it finely so the outline stays smooth.
        var points: [CGPoint] = []
        var x = startX
        var phaseSign: CGFloat = rng.chance(0.5) ? 1 : -1
        let baseHalf = h * squiggleWavelength / 2
        points.append(CGPoint(x: x, y: baseY + drift.value(at: 0)))
        while x < endX {
            let half = baseHalf * rng.double(in: 0.88...1.12)
            let amp = h * squiggleAmplitude * rng.double(in: 0.85...1.1)
            let segmentEnd = min(endX, x + half)
            let fraction = (segmentEnd - x) / half
            let steps = max(4, Int((8 * fraction).rounded(.up)))
            for i in 1...steps {
                let u = CGFloat(i) / CGFloat(steps) * fraction
                let px = x + half * u
                let py = baseY + phaseSign * amp * sin(.pi * u) + drift.value(at: px - startX)
                points.append(CGPoint(x: px, y: py))
            }
            x = segmentEnd
            phaseSign = -phaseSign
        }
        return strokeOutline(points: points, width: width, taper: min(h * 0.35, (endX - startX) * 0.2), rng: &rng)
    }

    private static func penLine(for rect: CGRect, seed: UInt64, center: CGFloat) -> Path {
        let h = rect.height
        guard rect.width > 0.5, h > 0.5, rect.minX.isFinite, rect.minY.isFinite else { return Path() }
        var rng = SplitMix64(seed: seed ^ (center > 0.75 ? 0x554E_4445_524C_494E : 0x5354_5249_4B45_4F55))
        let width = penWidth(forLineHeight: h) * rng.double(in: 0.94...1.04)
        let baseY = rect.minY + h * center
        let tilt = rng.double(in: -0.02...0.02) * h
        let wave = LowFrequencyWave(rng: &rng, height: h, amplitude: min(0.6, h * 0.02))
        let startX = rect.minX + rng.double(in: -0.06...0.03) * h
        let endX = rect.maxX + rng.double(in: -0.03...0.08) * h
        guard endX > startX else { return Path() }
        let length = endX - startX
        let count = max(4, Int((length / 2.5).rounded(.up)))
        let points: [CGPoint] = (0...count).map { i in
            let t = CGFloat(i) / CGFloat(count)
            let x = startX + length * t
            return CGPoint(x: x, y: baseY + tilt * (t - 0.5) + wave.value(at: x - startX))
        }
        return strokeOutline(points: points, width: width, taper: min(max(3, h * 0.3), length * 0.25), rng: &rng)
    }

    /// Turns a centre line into a filled stroke whose half-width swells and
    /// thins with simulated nib pressure and tapers to a point at both ends.
    private static func strokeOutline(points: [CGPoint], width: CGFloat, taper: CGFloat, rng: inout SplitMix64) -> Path {
        guard points.count > 1 else { return Path() }
        var arc: [CGFloat] = [0]
        for i in 1..<points.count {
            arc.append(arc[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        let total = max(arc.last ?? 0, 0.001)
        let pressurePhase = rng.double(in: 0...(2 * .pi))
        let pressurePeriod = rng.double(in: 40...90)
        // Pens start with a little more pressure than they finish with.
        let startWeight = rng.double(in: 1.0...1.08)
        let endWeight = rng.double(in: 0.86...0.96)

        var left: [CGPoint] = []
        var right: [CGPoint] = []
        for i in points.indices {
            let prev = points[max(0, i - 1)]
            let next = points[min(points.count - 1, i + 1)]
            var dx = next.x - prev.x
            var dy = next.y - prev.y
            let len = max(hypot(dx, dy), 0.0001)
            dx /= len
            dy /= len
            let s = arc[i]
            let taperIn = smoothstep((s / max(taper, 0.001)).clamped(to: 0...1))
            let taperOut = smoothstep(((total - s) / max(taper * 1.2, 0.001)).clamped(to: 0...1))
            let along = s / total
            let weight = startWeight + (endWeight - startWeight) * along
            let pressure = 1 + 0.06 * sin(pressurePhase + s / pressurePeriod * 2 * .pi)
            let half = width / 2 * weight * pressure * (0.18 + 0.82 * taperIn * taperOut)
            left.append(CGPoint(x: points[i].x - dy * half, y: points[i].y + dx * half))
            right.append(CGPoint(x: points[i].x + dy * half, y: points[i].y - dx * half))
        }
        var path = Path()
        path.addLines(left + right.reversed())
        path.closeSubpath()
        return path
    }

    private static func smoothstep(_ t: CGFloat) -> CGFloat {
        t * t * (3 - 2 * t)
    }

    /// Sum of two long sines. Wavelengths are several line heights long so an
    /// edge drifts rather than jitters: no high-frequency jaggies.
    private struct LowFrequencyWave {
        let a1: CGFloat, w1: CGFloat, p1: CGFloat
        let a2: CGFloat, w2: CGFloat, p2: CGFloat

        init(rng: inout SplitMix64, height: CGFloat, amplitude: CGFloat) {
            let h = max(height, 1)
            a1 = amplitude * rng.double(in: 0.6...1.0)
            w1 = 2 * .pi / (h * rng.double(in: 3.5...6))
            p1 = rng.double(in: 0...(2 * .pi))
            a2 = amplitude * rng.double(in: 0.25...0.5)
            w2 = 2 * .pi / (h * rng.double(in: 1.6...2.6))
            p2 = rng.double(in: 0...(2 * .pi))
        }

        func value(at x: CGFloat) -> CGFloat {
            a1 * sin(w1 * x + p1) + a2 * sin(w2 * x + p2)
        }
    }

    // MARK: - Path selection

    /// The primary filled path for a mark style.
    static func path(for style: HighlightStyle, lineRect: CGRect, seed: UInt64) -> Path {
        switch style {
        case .highlight: return highlightPath(for: lineRect, seed: seed)
        case .underline: return underlinePath(for: lineRect, seed: seed)
        case .strikethrough: return strikethroughPath(for: lineRect, seed: seed)
        case .squiggly: return squigglePath(for: lineRect, seed: seed)
        }
    }

    // MARK: - Ink colour

    /// Ink colour for a highlight colour on light or dark paper.
    ///
    /// Highlighter pigments are tuned for a multiply blend on light paper: the
    /// colour is what the dye looks like on white stock, so black text stays
    /// black underneath. On dark paper the same hue is drawn with a screen
    /// blend at lower strength, which lifts the paper toward the hue the way
    /// fluorescent ink glows under a reading lamp, and leaves light text legible.
    ///
    /// Pen styles use a darker shade of the hue so a line reads as ink rather
    /// than tint; pencil becomes graphite.
    static func ink(for color: HighlightColor, style: HighlightStyle, darkPaper: Bool) -> (color: Color, opacity: Double) {
        let rgba = inkRGBA(for: color, style: style, darkPaper: darkPaper)
        return (rgba.withAlpha(1).swiftUIColor, rgba.alpha)
    }

    /// The same ink as `ink(for:style:darkPaper:)`, as a portable colour whose
    /// alpha is the suggested opacity.
    static func inkRGBA(for color: HighlightColor, style: HighlightStyle, darkPaper: Bool) -> RGBAColor {
        let base = color.color
        if style == .highlight {
            if darkPaper {
                switch color {
                case .butter: return RGBAColor(hex: 0xF0D83A, alpha: 0.44)
                case .rose: return RGBAColor(hex: 0xF07A9A, alpha: 0.44)
                case .moss: return RGBAColor(hex: 0x8FD460, alpha: 0.42)
                case .sky: return RGBAColor(hex: 0x66B4EC, alpha: 0.46)
                case .pencil: return RGBAColor(hex: 0xA4A4A8, alpha: 0.3)
                }
            }
            switch color {
            case .butter: return RGBAColor(hex: 0xFFE93D, alpha: 0.78)
            case .rose: return RGBAColor(hex: 0xFF9DB6, alpha: 0.72)
            case .moss: return RGBAColor(hex: 0xA9E07E, alpha: 0.72)
            case .sky: return RGBAColor(hex: 0x8ACDF2, alpha: 0.72)
            case .pencil: return base.blended(with: RGBAColor(hex: 0x6E7076), amount: 0.6).withAlpha(0.42)
            }
        }
        if darkPaper {
            switch color {
            case .butter: return RGBAColor(hex: 0xEBCB55, alpha: 0.85)
            case .rose: return RGBAColor(hex: 0xEE8CA2, alpha: 0.85)
            case .moss: return RGBAColor(hex: 0x9CCF7C, alpha: 0.85)
            case .sky: return RGBAColor(hex: 0x86BCEB, alpha: 0.85)
            case .pencil: return RGBAColor(hex: 0xB4B4B8, alpha: 0.7)
            }
        }
        switch color {
        case .butter: return RGBAColor(hex: 0xC08A12, alpha: 0.9)
        case .rose: return RGBAColor(hex: 0xB8304F, alpha: 0.9)
        case .moss: return RGBAColor(hex: 0x3D7A2C, alpha: 0.9)
        case .sky: return RGBAColor(hex: 0x2A65AE, alpha: 0.9)
        case .pencil: return RGBAColor(hex: 0x4A4B50, alpha: 0.78)
        }
    }

    /// How marks composite with the page beneath. Multiply on light paper keeps
    /// black glyphs black under ink; screen on dark paper keeps ink visible
    /// against a dark ground without dimming the light text.
    static func blendMode(darkPaper: Bool) -> BlendMode {
        darkPaper ? .screen : .multiply
    }

    /// The equivalent blend inside a `GraphicsContext`, so overlapping marks in
    /// one canvas build up like layered ink instead of covering each other.
    static func contextBlendMode(darkPaper: Bool) -> GraphicsContext.BlendMode {
        darkPaper ? .screen : .multiply
    }
}
