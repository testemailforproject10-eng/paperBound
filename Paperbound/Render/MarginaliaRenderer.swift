//
//  MarginaliaRenderer.swift
//  Paperbound
//
//  Draws what a previous owner left on the page.
//
//  Everything here is procedural vector work, for the same reason the paper
//  texture is: a packaged set of sketch PNGs would repeat visibly across a book
//  and could not be shipped without a licence. A seeded stroke set cannot
//  repeat, costs nothing to redistribute, and scales to any render size.
//
//  The frame/field rule is enforced here rather than trusted to the generator.
//  `drawMargin` is clipped to the sheet with the text block punched out of it,
//  so a mark cannot land on the type even if a future generator tries. Only
//  `drawField` is allowed inside the block, and only `TextMark` reaches it.
//

import CoreGraphics
import Foundation

enum MarginaliaRenderer {

    // MARK: - Entry points

    /// Marks confined to the frame: everything except underlines.
    ///
    /// `contentRect` is punched out with the even-odd rule, which is what makes
    /// the frame/field rule a geometric fact rather than a convention.
    static func drawMargin(
        _ ctx: CGContext,
        marginalia: PageMarginalia,
        style: MarginaliaStyle,
        sheetRect: CGRect,
        contentRect: CGRect,
        palette: SubstratePalette
    ) {
        let elements = marginalia.marginElements
        guard !elements.isEmpty, style.producesAnything else { return }

        ctx.saveGState()
        let frame = CGMutablePath()
        frame.addRect(sheetRect)
        frame.addRect(contentRect)
        ctx.addPath(frame)
        ctx.clip(using: .evenOdd)

        for element in elements {
            draw(ctx, element: element, rect: sheetRect, style: style, palette: palette)
        }
        ctx.restoreGState()
    }

    /// Marks allowed over the text block.
    static func drawField(
        _ ctx: CGContext,
        marginalia: PageMarginalia,
        style: MarginaliaStyle,
        sheetRect: CGRect,
        palette: SubstratePalette
    ) {
        let elements = marginalia.fieldElements
        guard !elements.isEmpty, style.producesAnything else { return }

        ctx.saveGState()
        for element in elements {
            draw(ctx, element: element, rect: sheetRect, style: style, palette: palette)
        }
        ctx.restoreGState()
    }

    // MARK: - Dispatch

    private static func draw(
        _ ctx: CGContext,
        element: MarginaliaElement,
        rect: CGRect,
        style: MarginaliaStyle,
        palette: SubstratePalette
    ) {
        switch element {
        case let .inkStroke(stroke):
            drawInkStroke(ctx, stroke: stroke, rect: rect, style: style)
        case let .sketch(sketch):
            drawSketch(ctx, sketch: sketch, rect: rect, style: style)
        case let .pressing(pressing):
            drawPressing(ctx, pressing: pressing, rect: rect, palette: palette)
        case let .stamp(stamp):
            drawStamp(ctx, stamp: stamp, rect: rect, style: style)
        case let .sigil(sigil):
            drawSigil(ctx, sigil: sigil, rect: rect, style: style, palette: palette)
        case let .footprint(footprint):
            drawFootprint(ctx, footprint: footprint, rect: rect, style: style)
        case let .textMark(mark):
            drawTextMark(ctx, mark: mark, rect: rect, style: style)
        }
    }

    // MARK: - Handwriting

    /// A run of writing.
    ///
    /// Not a font: each word is a single wandering polyline with occasional
    /// ascenders and descenders. At marginal size that is exactly what
    /// handwriting reads as, and it means no glyph set has to be licensed or
    /// localised.
    private static func drawInkStroke(
        _ ctx: CGContext,
        stroke: InkStroke,
        rect: CGRect,
        style: MarginaliaStyle
    ) {
        let unit = min(rect.width, rect.height)
        var rng = SplitMix64(seed: stroke.seed)

        let origin = CGPoint(
            x: rect.minX + CGFloat(stroke.origin.x) * rect.width,
            y: rect.minY + CGFloat(stroke.origin.y) * rect.height
        )
        let length = CGFloat(stroke.length) * unit
        let height = CGFloat(stroke.height) * unit
        guard length > 2, height > 1 else { return }

        ctx.saveGState()
        ctx.translateBy(x: origin.x, y: origin.y)
        ctx.rotate(by: CGFloat(stroke.angle))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setBlendMode(.multiply)
        ctx.setLineWidth(max(0.6, height * 0.11))
        ctx.setStrokeColor(style.inkColor.withAlpha(stroke.pressure * 0.82).cgColor)

        // Words are separated by a gap roughly one x-height wide.
        let gap = height * 0.55
        let wordCount = max(1, stroke.words)
        let totalGap = gap * CGFloat(wordCount - 1)
        let wordWidth = max(height, (length - totalGap) / CGFloat(wordCount))

        var penX: CGFloat = 0
        for _ in 0..<wordCount {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: penX, y: 0))

            // Six to ten strokes per word, riding a baseline with tremor.
            let steps = rng.int(in: 6...10)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let x = penX + wordWidth * t
                // The pen rides between the baseline and the x-height, and
                // occasionally throws an ascender or a descender.
                var y = -height * CGFloat(rng.double(in: 0.15...0.95))
                if rng.chance(0.16) { y = -height * CGFloat(rng.double(in: 1.3...1.9)) }
                if rng.chance(0.10) { y = height * CGFloat(rng.double(in: 0.3...0.8)) }
                y += CGFloat(rng.signedUnit()) * height * CGFloat(stroke.tremor) * 0.18
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: penX + wordWidth, y: 0))

            ctx.addPath(path)
            ctx.strokePath()
            penX += wordWidth + gap
        }

        ctx.restoreGState()
    }

    // MARK: - Sketches

    /// A line drawing. A closed organic outline with radiating detail: at
    /// marginal size this reads as a specimen, a creature or a map feature
    /// depending on the style's ink and what sits around it.
    private static func drawSketch(
        _ ctx: CGContext,
        sketch: Sketch,
        rect: CGRect,
        style: MarginaliaStyle
    ) {
        let unit = min(rect.width, rect.height)
        var rng = SplitMix64(seed: sketch.seed)
        let center = CGPoint(
            x: rect.minX + CGFloat(sketch.center.x) * rect.width,
            y: rect.minY + CGFloat(sketch.center.y) * rect.height
        )
        let radius = CGFloat(sketch.radius) * unit
        guard radius > 2 else { return }

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: CGFloat(sketch.angle))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setBlendMode(.multiply)
        ctx.setLineWidth(max(0.5, radius * 0.045))
        ctx.setStrokeColor(style.inkColor.withAlpha(sketch.pressure * 0.78).cgColor)

        // Outline: a closed loop with an irregular radius.
        let steps = 20
        var points: [CGPoint] = []
        points.reserveCapacity(steps)
        for index in 0..<steps {
            let angle = Double(index) / Double(steps) * 2 * .pi
            let wobble = 1 + rng.signedUnit() * 0.22 + sin(angle * 3) * 0.14
            points.append(CGPoint(
                x: CGFloat(cos(angle)) * radius * CGFloat(wobble),
                y: CGFloat(sin(angle)) * radius * CGFloat(wobble) * 0.78
            ))
        }
        ctx.addPath(RaggedPath.smoothClosedPath(through: points))
        ctx.strokePath()

        // Interior detail: ribs, veins, hatching. How much is `complexity`.
        let ribs = 2 + Int(sketch.complexity * 7)
        for index in 0..<ribs {
            let t = Double(index) / Double(max(1, ribs - 1))
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -radius * 0.7, y: CGFloat(t - 0.5) * radius * 0.9))
            path.addQuadCurve(
                to: CGPoint(x: radius * 0.7, y: CGFloat(t - 0.5) * radius * 1.1),
                control: CGPoint(
                    x: 0,
                    y: CGFloat(t - 0.5) * radius * 0.6 + CGFloat(rng.signedUnit()) * radius * 0.2
                )
            )
            ctx.addPath(path)
        }
        ctx.setLineWidth(max(0.4, radius * 0.028))
        ctx.strokePath()

        // A hand-lettered label underneath, drawn as a short ink run.
        if sketch.hasLabel {
            ctx.setLineWidth(max(0.4, radius * 0.05))
            let baseline = radius * 1.25
            let width = radius * 1.5
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -width / 2, y: baseline))
            let steps = rng.int(in: 7...12)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                path.addLine(to: CGPoint(
                    x: -width / 2 + width * t,
                    y: baseline - radius * 0.14 * CGFloat(rng.unit())
                ))
            }
            ctx.addPath(path)
            ctx.strokePath()
        }

        ctx.restoreGState()
    }

    // MARK: - Pressings

    /// A pressed specimen: a soft browned silhouette with a shadow under it,
    /// because a real pressing lifts the paper around its edge.
    private static func drawPressing(
        _ ctx: CGContext,
        pressing: Pressing,
        rect: CGRect,
        palette: SubstratePalette
    ) {
        let unit = min(rect.width, rect.height)
        var rng = SplitMix64(seed: pressing.seed)
        let center = CGPoint(
            x: rect.minX + CGFloat(pressing.center.x) * rect.width,
            y: rect.minY + CGFloat(pressing.center.y) * rect.height
        )
        let radius = CGFloat(pressing.radius) * unit
        guard radius > 2 else { return }

        // Older pressings are browner and more translucent.
        let fresh = RGBAColor(hex: 0x5B6B3A)
        let aged = RGBAColor(hex: 0x6E4A1E)
        let tint = fresh.blended(with: aged, amount: pressing.age)

        let lobes = max(3, pressing.lobes)
        let steps = lobes * 6
        var points: [CGPoint] = []
        points.reserveCapacity(steps)
        for index in 0..<steps {
            let angle = Double(index) / Double(steps) * 2 * .pi
            // Lobed outline: this is what separates a leaf from a blob.
            let lobe = 0.62 + 0.38 * abs(cos(angle * Double(lobes) / 2))
            let jitter = 1 + rng.signedUnit() * 0.07
            points.append(CGPoint(
                x: CGFloat(cos(angle)) * radius * CGFloat(lobe * jitter),
                y: CGFloat(sin(angle)) * radius * CGFloat(lobe * jitter) * 0.85
            ))
        }

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: CGFloat(pressing.angle))
        ctx.setBlendMode(.multiply)

        let silhouette = RaggedPath.smoothClosedPath(through: points)

        // The lift: a soft shadow just outside the specimen.
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: radius * 0.06, height: radius * 0.08),
            blur: radius * 0.28,
            color: RGBAColor(0, 0, 0, 0.30).cgColor
        )
        ctx.addPath(silhouette)
        ctx.setFillColor(tint.withAlpha(0.62).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // A central vein, which is what stops it reading as a stain.
        ctx.setLineCap(.round)
        ctx.setLineWidth(max(0.5, radius * 0.045))
        ctx.setStrokeColor(tint.blended(with: RGBAColor(0, 0, 0, 1), amount: 0.35).withAlpha(0.55).cgColor)
        let vein = CGMutablePath()
        vein.move(to: CGPoint(x: -radius * 0.85, y: 0))
        vein.addLine(to: CGPoint(x: radius * 0.85, y: 0))
        ctx.addPath(vein)
        ctx.strokePath()

        ctx.restoreGState()
    }

    // MARK: - Stamps

    /// An inked stamp. Unevenly covered and never square to the page, which is
    /// the whole difference between a stamp and a printed border.
    private static func drawStamp(
        _ ctx: CGContext,
        stamp: Stamp,
        rect: CGRect,
        style: MarginaliaStyle
    ) {
        let unit = min(rect.width, rect.height)
        var rng = SplitMix64(seed: stamp.seed)
        let center = CGPoint(
            x: rect.minX + CGFloat(stamp.center.x) * rect.width,
            y: rect.minY + CGFloat(stamp.center.y) * rect.height
        )
        let radius = CGFloat(stamp.radius) * unit
        guard radius > 2 else { return }

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: CGFloat(stamp.angle))
        ctx.setBlendMode(.multiply)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(max(0.6, radius * 0.08))
        ctx.setStrokeColor(style.inkColor.withAlpha(stamp.coverage * 0.75).cgColor)

        // Border: a circle or a regular polygon.
        let border = CGMutablePath()
        if stamp.sides < 3 {
            border.addEllipse(in: CGRect(x: -radius, y: -radius * 0.8, width: radius * 2, height: radius * 1.6))
        } else {
            for index in 0...stamp.sides {
                let angle = Double(index) / Double(stamp.sides) * 2 * .pi
                let point = CGPoint(
                    x: CGFloat(cos(angle)) * radius,
                    y: CGFloat(sin(angle)) * radius * 0.8
                )
                if index == 0 { border.move(to: point) } else { border.addLine(to: point) }
            }
            border.closeSubpath()
        }
        ctx.addPath(border)
        ctx.strokePath()

        // Lettering inside, as bars. Two or three lines, centred, ragged.
        let lines = rng.int(in: 2...3)
        ctx.setLineCap(.butt)
        for line in 0..<lines {
            let y = (CGFloat(line) - CGFloat(lines - 1) / 2) * radius * 0.36
            let width = radius * CGFloat(rng.double(in: 0.7...1.25))
            ctx.setLineWidth(max(0.8, radius * CGFloat(rng.double(in: 0.10...0.16))))
            ctx.setStrokeColor(style.inkColor.withAlpha(stamp.coverage * rng.double(in: 0.4...0.8)).cgColor)
            let bar = CGMutablePath()
            bar.move(to: CGPoint(x: -width / 2, y: y))
            bar.addLine(to: CGPoint(x: width / 2, y: y))
            ctx.addPath(bar)
            ctx.strokePath()
        }

        ctx.restoreGState()
    }

    // MARK: - Sigils

    /// A star figure inscribed in a circle. Drawn in ink, or scored into the
    /// substrate when someone meant it.
    private static func drawSigil(
        _ ctx: CGContext,
        sigil: Sigil,
        rect: CGRect,
        style: MarginaliaStyle,
        palette: SubstratePalette
    ) {
        let unit = min(rect.width, rect.height)
        let center = CGPoint(
            x: rect.minX + CGFloat(sigil.center.x) * rect.width,
            y: rect.minY + CGFloat(sigil.center.y) * rect.height
        )
        let radius = CGFloat(sigil.radius) * unit
        guard radius > 2, sigil.points >= 3 else { return }

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: CGFloat(sigil.angle))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.setLineWidth(max(0.5, radius * 0.055))

        // The enclosing circle plus a star polygon that skips vertices. A skip
        // of two gives the familiar unicursal figure; larger point counts give
        // denser ones, which is why `points` is allowed up to nine.
        let figure = CGMutablePath()
        figure.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))

        let skip = max(2, sigil.points / 2)
        var vertex = 0
        for step in 0...sigil.points {
            let angle = Double(vertex) / Double(sigil.points) * 2 * .pi - .pi / 2
            let point = CGPoint(x: CGFloat(cos(angle)) * radius, y: CGFloat(sin(angle)) * radius)
            if step == 0 { figure.move(to: point) } else { figure.addLine(to: point) }
            vertex = (vertex + skip) % sigil.points
        }
        figure.closeSubpath()

        if sigil.isScored {
            // Scored: a dark groove with a lit lip, the same two-pass trick a
            // crack uses. It sits *in* the surface rather than on it.
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(RGBAColor(0.12, 0.09, 0.07, sigil.pressure * 0.8).cgColor)
            ctx.addPath(figure)
            ctx.strokePath()

            ctx.setBlendMode(.screen)
            ctx.setLineWidth(max(0.4, radius * 0.035))
            ctx.setStrokeColor(palette.core.withAlpha(sigil.pressure * 0.45).cgColor)
            ctx.translateBy(x: -radius * 0.03, y: -radius * 0.03)
            ctx.addPath(figure)
            ctx.strokePath()
        } else {
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(style.inkColor.withAlpha(sigil.pressure * 0.85).cgColor)
            ctx.addPath(figure)
            ctx.strokePath()
        }

        ctx.restoreGState()
    }

    // MARK: - Tracks

    /// A trail of prints crossing the sheet. Paired left and right, wandering
    /// off the straight line, fading toward both ends so the trail reads as
    /// passing through rather than starting and stopping on the page.
    private static func drawFootprint(
        _ ctx: CGContext,
        footprint: Footprint,
        rect: CGRect,
        style: MarginaliaStyle
    ) {
        let unit = min(rect.width, rect.height)
        var rng = SplitMix64(seed: footprint.seed)
        let from = CGPoint(
            x: rect.minX + CGFloat(footprint.from.x) * rect.width,
            y: rect.minY + CGFloat(footprint.from.y) * rect.height
        )
        let to = CGPoint(
            x: rect.minX + CGFloat(footprint.to.x) * rect.width,
            y: rect.minY + CGFloat(footprint.to.y) * rect.height
        )
        let size = CGFloat(footprint.size) * unit
        guard size > 0.8, footprint.count > 0 else { return }

        let dx = to.x - from.x
        let dy = to.y - from.y
        let span = hypot(dx, dy)
        guard span > 1 else { return }
        let nx = -dy / span
        let ny = dx / span
        let heading = atan2(dy, dx)

        ctx.saveGState()
        ctx.setBlendMode(.multiply)

        for index in 0..<footprint.count {
            let t = Double(index) / Double(max(1, footprint.count - 1))
            // Wander, plus the left/right alternation of an actual gait.
            let drift = sin(t * .pi * 2.2) * footprint.wander * Double(unit) * 0.05
            let side: CGFloat = index.isMultiple(of: 2) ? 1 : -1
            let stride = size * 0.9 * side

            let px = from.x + dx * CGFloat(t) + nx * (CGFloat(drift) + stride)
            let py = from.y + dy * CGFloat(t) + ny * (CGFloat(drift) + stride)

            // Faded at both ends: the trail comes from somewhere and goes on.
            let fade = sin(t * .pi)
            let alpha = footprint.pressure * fade * rng.double(in: 0.6...1.0)
            guard alpha > 0.02 else { continue }

            ctx.saveGState()
            ctx.translateBy(x: px, y: py)
            ctx.rotate(by: heading + CGFloat(rng.signedUnit()) * 0.2)
            ctx.setFillColor(style.inkColor.withAlpha(alpha * 0.7).cgColor)

            // Pad plus toes: enough to read as a print at this size.
            ctx.fillEllipse(in: CGRect(
                x: -size * 0.5, y: -size * 0.35,
                width: size, height: size * 0.7
            ))
            for toe in 0..<3 {
                let offset = (CGFloat(toe) - 1) * size * 0.32
                ctx.fillEllipse(in: CGRect(
                    x: size * 0.42 + offset * 0.18, y: offset - size * 0.11,
                    width: size * 0.30, height: size * 0.22
                ))
            }
            ctx.restoreGState()
        }

        ctx.restoreGState()
    }

    // MARK: - Underlines

    /// A line under running text. The only mark allowed inside the text block,
    /// because an underline that avoided the words would not be an underline.
    private static func drawTextMark(
        _ ctx: CGContext,
        mark: TextMark,
        rect: CGRect,
        style: MarginaliaStyle
    ) {
        let unit = min(rect.width, rect.height)
        var rng = SplitMix64(seed: mark.seed)
        let from = CGPoint(
            x: rect.minX + CGFloat(mark.from.x) * rect.width,
            y: rect.minY + CGFloat(mark.from.y) * rect.height
        )
        let to = CGPoint(
            x: rect.minX + CGFloat(mark.to.x) * rect.width,
            y: rect.minY + CGFloat(mark.to.y) * rect.height
        )

        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setLineCap(.round)
        ctx.setLineWidth(max(0.6, CGFloat(mark.width) * unit))
        ctx.setStrokeColor(style.inkColor.withAlpha(mark.pressure * 0.7).cgColor)

        let passes = mark.isDoubled ? 2 : 1
        for pass in 0..<passes {
            let offset = CGFloat(pass) * max(1.2, CGFloat(mark.width) * unit * 2.2)
            let path = RaggedPath.scratchPath(
                Scratch(
                    from: NormalizedPoint(mark.from.x, mark.from.y),
                    to: NormalizedPoint(mark.to.x, mark.to.y),
                    depth: mark.pressure,
                    width: mark.width,
                    exposesCore: false,
                    seed: mark.seed &+ UInt64(pass)
                ),
                in: rect
            )
            ctx.saveGState()
            ctx.translateBy(x: 0, y: offset + CGFloat(rng.signedUnit()) * 0.4)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }

        _ = from
        _ = to
        ctx.restoreGState()
    }
}
