//
//  MarginaliaGenerator.swift
//  Paperbound
//
//  Turns (book, sheet, style) into a fixed list of marks a previous owner left.
//
//  Three rules, the first two inherited from `DamageGenerator` and the third
//  the reason this is a separate file at all:
//
//  1. The random stream is consumed in a FIXED order. New kinds append.
//  2. Nothing here reads the clock, the device, or the document's contents.
//  3. It draws from its OWN stream, salted away from the damage stream. If the
//     two shared a seed, shipping marginalia would have moved every tear in
//     every book already on a shelf.
//
//  Placement obeys the frame/field rule by construction: `.margin` elements are
//  generated into the outer band of the sheet, and the compositor additionally
//  clips them away from the text block. Generation biases, clipping guarantees.
//

import CoreGraphics
import Foundation

enum MarginaliaGenerator {

    /// Salt that separates this stream from the damage stream for the same
    /// book, page and intensity. Never change it: it would rewrite every
    /// annotated page ever rendered.
    private static let streamSalt: UInt64 = 0x4D41_5247_494E_0001

    /// The frame a mark may occupy, as fractions of the sheet on each axis.
    ///
    /// Passed in rather than guessed. The frame's width and height are not the
    /// same fraction — a portrait sheet inset by a fixed physical margin has a
    /// proportionally thinner band top and bottom — and guessing one number for
    /// both is what put three quarters of every mark inside the text block,
    /// where the frame/field clip then removed it.
    struct Frame: Hashable, Sendable {
        /// Band width on the x axis, 0…0.5 of the sheet.
        var x: Double
        /// Band height on the y axis, 0…0.5 of the sheet.
        var y: Double

        /// Measured straight off the two rects the compositor already computes,
        /// so placement and clipping can never disagree.
        init(sheet: CGRect, content: CGRect) {
            guard sheet.width > 0, sheet.height > 0 else {
                self.x = 0
                self.y = 0
                return
            }
            self.x = Double((content.minX - sheet.minX) / sheet.width).clamped(to: 0...0.5)
            self.y = Double((content.minY - sheet.minY) / sheet.height).clamped(to: 0...0.5)
        }

        init(x: Double, y: Double) {
            self.x = x.clamped(to: 0...0.5)
            self.y = y.clamped(to: 0...0.5)
        }

        /// True when there is enough frame to put anything in at all.
        var isUsable: Bool { x > 0.012 || y > 0.012 }

        /// The widest band available, which is what a mark is sized against.
        var room: Double { max(x, y) }
    }

    static func generate(
        documentID: UUID,
        bookSeed: UInt64,
        stablePageID: String,
        environment: ReadingEnvironment,
        frame: Frame
    ) -> PageMarginalia {

        let identity = environment.marginaliaIdentity
        let style = environment.marginalia

        guard style.producesAnything, frame.isUsable else {
            return .empty(
                documentID: documentID,
                stablePageID: stablePageID,
                styleIdentity: identity
            )
        }

        let seed = StableHash.combine(
            StableHash.hash(documentID),
            bookSeed,
            StableHash.hash(stablePageID),
            StableHash.hash(identity),
            streamSalt
        )

        var rng = SplitMix64(seed: seed)
        let intensity = environment.intensity.clamped(to: 0...1)
        // A little marginalia at low intensity still reads as an annotated
        // book; scaling to zero would make the style vanish rather than soften.
        let countScale = 0.45 + 0.55 * intensity

        let sampled = rng.int(in: style.density)
        let count = max(style.density.lowerBound, Int((Double(sampled) * countScale).rounded()))
        guard count > 0 else {
            return .empty(
                documentID: documentID,
                stablePageID: stablePageID,
                styleIdentity: identity
            )
        }

        let vocabulary = style.vocabulary.map { ($0.kind, $0.weight) }
        var elements: [MarginaliaElement] = []
        elements.reserveCapacity(count)

        for _ in 0..<count {
            guard let kind = rng.pickWeighted(vocabulary) else { break }
            guard let element = make(kind: kind, intensity: intensity, frame: frame, rng: &rng)
            else { continue }
            elements.append(element)
        }

        return PageMarginalia(
            documentID: documentID,
            stablePageID: stablePageID,
            seed: seed,
            styleIdentity: identity,
            elements: elements
        )
    }

    // MARK: - Element builders

    private static func make(
        kind: MarginaliaKind,
        intensity: Double,
        frame: Frame,
        rng: inout SplitMix64
    ) -> MarginaliaElement? {
        switch kind {
        case .inkStroke: return makeInkStroke(frame: frame, rng: &rng)
        case .sketch: return makeSketch(frame: frame, rng: &rng)
        case .pressing: return makePressing(frame: frame, rng: &rng)
        case .stamp: return makeStamp(frame: frame, rng: &rng)
        case .sigil: return makeSigil(intensity: intensity, frame: frame, rng: &rng)
        case .footprint: return makeFootprint(rng: &rng)
        case .textMark: return makeTextMark(rng: &rng)
        }
    }

    private static func makeInkStroke(
        frame: Frame,
        rng: inout SplitMix64
    ) -> MarginaliaElement {
        let origin = marginPoint(frame: frame, rng: &rng)
        let room = frame.room
        return .inkStroke(InkStroke(
            origin: origin,
            // A note runs ALONG its margin, so it may be long; only its
            // x-height has to fit across the band.
            length: rng.double(in: 0.06...0.16),
            height: (rng.double(in: 0.09...0.15) * room).clamped(to: 0.008...0.024),
            // Marginal notes are written along whichever edge there was room
            // on, so a note in a side margin runs steeply.
            angle: (origin.x < frame.x || origin.x > 1 - frame.x)
                ? rng.double(in: -1.4...(-1.1))
                : rng.double(in: -0.12...0.12),
            words: rng.int(in: 2...6),
            pressure: rng.double(in: 0.45...1.0),
            tremor: rng.double(in: 0.15...0.8),
            seed: rng.branchSeed()
        ))
    }

    private static func makeSketch(
        frame: Frame,
        rng: inout SplitMix64
    ) -> MarginaliaElement {
        .sketch(Sketch(
            center: marginPoint(frame: frame, rng: &rng),
            radius: rng.double(in: 0.20...0.45) * frame.room,
            angle: rng.double(in: -0.35...0.35),
            complexity: rng.double(in: 0.35...1.0),
            pressure: rng.double(in: 0.4...0.9),
            hasLabel: rng.chance(0.55),
            seed: rng.branchSeed()
        ))
    }

    private static func makePressing(
        frame: Frame,
        rng: inout SplitMix64
    ) -> MarginaliaElement {
        .pressing(Pressing(
            center: marginPoint(frame: frame, rng: &rng),
            radius: rng.double(in: 0.22...0.48) * frame.room,
            angle: rng.double(in: 0...(2 * .pi)),
            age: rng.double(in: 0.3...1.0),
            lobes: rng.int(in: 3...9),
            seed: rng.branchSeed()
        ))
    }

    private static func makeStamp(
        frame: Frame,
        rng: inout SplitMix64
    ) -> MarginaliaElement {
        .stamp(Stamp(
            center: marginPoint(frame: frame, rng: &rng),
            radius: rng.double(in: 0.20...0.40) * frame.room,
            // A hand-pressed stamp is never square to the page.
            angle: rng.double(in: -0.30...0.30),
            coverage: rng.double(in: 0.45...0.95),
            sides: rng.chance(0.5) ? 0 : rng.int(in: 4...8),
            seed: rng.branchSeed()
        ))
    }

    private static func makeSigil(
        intensity: Double,
        frame: Frame,
        rng: inout SplitMix64
    ) -> MarginaliaElement {
        .sigil(Sigil(
            center: marginPoint(frame: frame, rng: &rng),
            radius: rng.double(in: 0.20...0.44) * frame.room,
            angle: rng.double(in: 0...(2 * .pi)),
            points: rng.int(in: 3...9),
            pressure: rng.double(in: 0.5...1.0),
            // Scored wards are the ones someone meant, and they turn up more
            // often the more damaged the book is.
            isScored: rng.chance(0.3 + 0.4 * intensity),
            seed: rng.branchSeed()
        ))
    }

    private static func makeFootprint(
        rng: inout SplitMix64
    ) -> MarginaliaElement {
        // A trail crosses the sheet, so it starts and ends off the edges.
        let vertical = rng.chance(0.5)
        let from: NormalizedPoint
        let to: NormalizedPoint
        if vertical {
            from = NormalizedPoint(rng.double(in: 0.05...0.95), -0.05)
            to = NormalizedPoint(rng.double(in: 0.05...0.95), 1.05)
        } else {
            from = NormalizedPoint(-0.05, rng.double(in: 0.05...0.95))
            to = NormalizedPoint(1.05, rng.double(in: 0.05...0.95))
        }
        return .footprint(Footprint(
            from: from,
            to: to,
            count: rng.int(in: 6...16),
            size: rng.double(in: 0.008...0.018),
            wander: rng.double(in: 0.1...0.5),
            pressure: rng.double(in: 0.35...0.85),
            seed: rng.branchSeed()
        ))
    }

    private static func makeTextMark(
        rng: inout SplitMix64
    ) -> MarginaliaElement {
        // Underlines run along a line of type, so they are horizontal and live
        // inside the block rather than in the margin.
        let y = rng.double(in: 0.18...0.86)
        let x0 = rng.double(in: 0.16...0.5)
        let width = rng.double(in: 0.12...0.34)
        return .textMark(TextMark(
            from: NormalizedPoint(x0, y),
            to: NormalizedPoint(min(0.88, x0 + width), y + rng.double(in: -0.004...0.004)),
            pressure: rng.double(in: 0.4...0.95),
            width: rng.double(in: 0.0012...0.0035),
            isDoubled: rng.chance(0.22),
            seed: rng.branchSeed()
        ))
    }

    // MARK: - Placement

    /// A point inside the real frame.
    ///
    /// Marks cluster where there was room to make them: the fore-edge margin
    /// and the foot take far more than the head, because that is where a hand
    /// resting on a book actually sits. Bands with no room are never chosen,
    /// so a tight page puts everything down the sides rather than producing
    /// marks that the clip will silently eat.
    private static func marginPoint(frame: Frame, rng: inout SplitMix64) -> NormalizedPoint {
        enum Band { case left, right, top, bottom }

        let horizontal = frame.x > 0.012
        let vertical = frame.y > 0.012
        let band = rng.pickWeighted([
            (Band.right, horizontal ? 1.0 : 0),
            (Band.bottom, vertical ? 0.8 : 0),
            (Band.left, horizontal ? 0.6 : 0),
            (Band.top, vertical ? 0.35 : 0)
        ]) ?? (horizontal ? .right : .bottom)

        // Keep the centre a little inside the band so a mark of ordinary size
        // sits within it rather than straddling the boundary.
        let insetX = frame.x * 0.5
        let insetY = frame.y * 0.5

        switch band {
        case .left:
            return NormalizedPoint(rng.double(in: insetX...(frame.x - insetX * 0.2)), rng.double(in: 0.06...0.94))
        case .right:
            return NormalizedPoint(rng.double(in: (1 - frame.x + insetX * 0.2)...(1 - insetX)), rng.double(in: 0.06...0.94))
        case .top:
            return NormalizedPoint(rng.double(in: 0.06...0.94), rng.double(in: insetY...(frame.y - insetY * 0.2)))
        case .bottom:
            return NormalizedPoint(rng.double(in: 0.06...0.94), rng.double(in: (1 - frame.y + insetY * 0.2)...(1 - insetY)))
        }
    }
}
