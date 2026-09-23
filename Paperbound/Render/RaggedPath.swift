//
//  RaggedPath.swift
//  Paperbound
//
//  Geometry for torn paper.
//
//  Everything is built directly in the sheet's pixel rect, with sizes scaled by
//  the rect's *shorter* side. Using one physical unit for both axes is what
//  stops a tear from stretching when a landscape page is rendered, and stops
//  it from drifting when the same page is re-rendered at a different zoom.
//

import CoreGraphics
import Foundation

enum RaggedPath {

    // MARK: - Ragged polylines

    /// Midpoint displacement: subdivide the segment, push each new midpoint
    /// along the segment normal, halve the amplitude, repeat. Cheap, stable,
    /// and it reads as fibre tear rather than as a wobble.
    static func raggedPolyline(
        from start: CGPoint,
        to end: CGPoint,
        roughness: Double,
        subdivisions: Int,
        rng: inout SplitMix64
    ) -> [CGPoint] {
        var points = [start, end]
        let span = hypot(end.x - start.x, end.y - start.y)
        guard span > 0, subdivisions > 0 else { return points }

        var amplitude = span * 0.24 * max(0, roughness)

        for _ in 0..<subdivisions {
            var next: [CGPoint] = [points[0]]
            next.reserveCapacity(points.count * 2)
            for index in 0..<(points.count - 1) {
                let a = points[index]
                let b = points[index + 1]
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let dx = b.x - a.x
                let dy = b.y - a.y
                let length = hypot(dx, dy)
                if length > 0.0001 {
                    let nx = -dy / length
                    let ny = dx / length
                    let offset = CGFloat(rng.signedUnit() * amplitude)
                    next.append(CGPoint(x: mid.x + nx * offset, y: mid.y + ny * offset))
                } else {
                    next.append(mid)
                }
                next.append(b)
            }
            points = next
            amplitude *= 0.52
        }
        return points
    }

    // MARK: - Subtractive shapes

    /// The region removed by a bite out of one edge. Extends a little past the
    /// sheet boundary so the cut reliably clears the edge instead of leaving a
    /// one-pixel sliver of paper behind.
    static func edgeTearPath(_ tear: EdgeTear, in rect: CGRect) -> CGPath {
        let unit = min(rect.width, rect.height)
        let depth = CGFloat(tear.depth) * unit
        let half = CGFloat(tear.length) * unit / 2
        let overshoot = max(2, depth * 0.35)
        var rng = SplitMix64(seed: tear.seed)

        // Work out the two endpoints on the edge and the inward direction.
        let edgeStart: CGPoint
        let edgeEnd: CGPoint
        let inward: CGVector
        let outward: CGVector

        switch tear.edge {
        case .top:
            let cx = rect.minX + CGFloat(tear.position) * rect.width
            edgeStart = CGPoint(x: cx - half, y: rect.minY)
            edgeEnd = CGPoint(x: cx + half, y: rect.minY)
            inward = CGVector(dx: 0, dy: 1)
            outward = CGVector(dx: 0, dy: -1)
        case .bottom:
            let cx = rect.minX + CGFloat(tear.position) * rect.width
            edgeStart = CGPoint(x: cx + half, y: rect.maxY)
            edgeEnd = CGPoint(x: cx - half, y: rect.maxY)
            inward = CGVector(dx: 0, dy: -1)
            outward = CGVector(dx: 0, dy: 1)
        case .left:
            let cy = rect.minY + CGFloat(tear.position) * rect.height
            edgeStart = CGPoint(x: rect.minX, y: cy + half)
            edgeEnd = CGPoint(x: rect.minX, y: cy - half)
            inward = CGVector(dx: 1, dy: 0)
            outward = CGVector(dx: -1, dy: 0)
        case .right:
            let cy = rect.minY + CGFloat(tear.position) * rect.height
            edgeStart = CGPoint(x: rect.maxX, y: cy - half)
            edgeEnd = CGPoint(x: rect.maxX, y: cy + half)
            inward = CGVector(dx: -1, dy: 0)
            outward = CGVector(dx: 1, dy: 0)
        }

        // Apex sits off-centre so tears are not symmetrical wedges.
        let skew = CGFloat(rng.double(in: 0.3...0.7))
        let apex = CGPoint(
            x: edgeStart.x + (edgeEnd.x - edgeStart.x) * skew + inward.dx * depth,
            y: edgeStart.y + (edgeEnd.y - edgeStart.y) * skew + inward.dy * depth
        )

        let firstLeg = raggedPolyline(
            from: edgeStart, to: apex,
            roughness: tear.roughness, subdivisions: 4, rng: &rng
        )
        let secondLeg = raggedPolyline(
            from: apex, to: edgeEnd,
            roughness: tear.roughness * 0.85, subdivisions: 4, rng: &rng
        )

        let path = CGMutablePath()
        path.move(to: CGPoint(
            x: edgeStart.x + outward.dx * overshoot,
            y: edgeStart.y + outward.dy * overshoot
        ))
        path.addLine(to: edgeStart)
        for point in firstLeg.dropFirst() { path.addLine(to: point) }
        for point in secondLeg.dropFirst() { path.addLine(to: point) }
        path.addLine(to: CGPoint(
            x: edgeEnd.x + outward.dx * overshoot,
            y: edgeEnd.y + outward.dy * overshoot
        ))
        path.closeSubpath()
        return path
    }

    /// The wedge of sheet missing at a corner.
    static func lostCornerPath(_ loss: LostCorner, in rect: CGRect) -> CGPath {
        let unit = min(rect.width, rect.height)
        let reach = CGFloat(loss.reach) * unit
        let skew = CGFloat(loss.skew)
        let overshoot = max(2, reach * 0.3)
        var rng = SplitMix64(seed: loss.seed)

        let origin: CGPoint
        let alongX: CGVector
        let alongY: CGVector

        switch loss.corner {
        case .topLeft:
            origin = CGPoint(x: rect.minX, y: rect.minY)
            alongX = CGVector(dx: 1, dy: 0)
            alongY = CGVector(dx: 0, dy: 1)
        case .topRight:
            origin = CGPoint(x: rect.maxX, y: rect.minY)
            alongX = CGVector(dx: -1, dy: 0)
            alongY = CGVector(dx: 0, dy: 1)
        case .bottomLeft:
            origin = CGPoint(x: rect.minX, y: rect.maxY)
            alongX = CGVector(dx: 1, dy: 0)
            alongY = CGVector(dx: 0, dy: -1)
        case .bottomRight:
            origin = CGPoint(x: rect.maxX, y: rect.maxY)
            alongX = CGVector(dx: -1, dy: 0)
            alongY = CGVector(dx: 0, dy: -1)
        }

        let reachX = reach * (1 + skew * 0.6)
        let reachY = reach * (1 - skew * 0.6)
        let onEdgeX = CGPoint(x: origin.x + alongX.dx * reachX, y: origin.y + alongX.dy * reachX)
        let onEdgeY = CGPoint(x: origin.x + alongY.dx * reachY, y: origin.y + alongY.dy * reachY)

        let tornEdge = raggedPolyline(
            from: onEdgeX, to: onEdgeY,
            roughness: loss.roughness, subdivisions: 5, rng: &rng
        )

        // Push the closing corner outside the sheet so the removal is complete.
        let outerCorner = CGPoint(
            x: origin.x - alongX.dx * overshoot - alongY.dx * overshoot,
            y: origin.y - alongX.dy * overshoot - alongY.dy * overshoot
        )

        let path = CGMutablePath()
        path.move(to: outerCorner)
        path.addLine(to: CGPoint(
            x: onEdgeX.x - alongY.dx * overshoot,
            y: onEdgeX.y - alongY.dy * overshoot
        ))
        path.addLine(to: onEdgeX)
        for point in tornEdge.dropFirst() { path.addLine(to: point) }
        path.addLine(to: CGPoint(
            x: onEdgeY.x - alongX.dx * overshoot,
            y: onEdgeY.y - alongX.dy * overshoot
        ))
        path.closeSubpath()
        return path
    }

    /// An irregular puncture. Smoothed with quadratic curves so the opening
    /// reads as worn paper rather than as a polygon.
    static func holePath(_ hole: Hole, in rect: CGRect) -> CGPath {
        let unit = min(rect.width, rect.height)
        let radius = CGFloat(hole.radius) * unit
        let center = CGPoint(
            x: rect.minX + CGFloat(hole.center.x) * rect.width,
            y: rect.minY + CGFloat(hole.center.y) * rect.height
        )
        var rng = SplitMix64(seed: hole.seed)

        let vertexCount = 18
        var radii: [CGFloat] = (0..<vertexCount).map { _ in
            CGFloat(1.0 + rng.signedUnit() * hole.irregularity * 0.55)
        }
        // One pass of neighbour averaging removes single-vertex spikes while
        // keeping the overall lobed silhouette.
        radii = (0..<vertexCount).map { index in
            let previous = radii[(index + vertexCount - 1) % vertexCount]
            let current = radii[index]
            let next = radii[(index + 1) % vertexCount]
            return (previous + current * 2 + next) / 4
        }

        let points: [CGPoint] = (0..<vertexCount).map { index in
            let angle = CGFloat(index) / CGFloat(vertexCount) * 2 * .pi
            let r = radius * max(0.25, radii[index])
            return CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
        }
        return smoothClosedPath(through: points)
    }

    /// Quadratic curves through the midpoints of a closed polygon.
    static func smoothClosedPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 3 else {
            if let first = points.first {
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                path.closeSubpath()
            }
            return path
        }

        func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }

        let count = points.count
        path.move(to: midpoint(points[count - 1], points[0]))
        for index in 0..<count {
            let control = points[index]
            let end = midpoint(points[index], points[(index + 1) % count])
            path.addQuadCurve(to: end, control: control)
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Non-subtractive shapes

    /// The fold line itself, slightly wandering.
    static func creasePath(_ crease: Crease, in rect: CGRect) -> CGPath {
        var rng = SplitMix64(seed: crease.seed)
        let from = CGPoint(
            x: rect.minX + CGFloat(crease.from.x) * rect.width,
            y: rect.minY + CGFloat(crease.from.y) * rect.height
        )
        let to = CGPoint(
            x: rect.minX + CGFloat(crease.to.x) * rect.width,
            y: rect.minY + CGFloat(crease.to.y) * rect.height
        )
        let points = raggedPolyline(
            from: from, to: to,
            roughness: 0.06, subdivisions: 3, rng: &rng
        )
        let path = CGMutablePath()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    // MARK: - Rigid and burned shapes

    /// The region broken off the edge of a rigid sheet.
    ///
    /// A chip is an edge tear that cannot fray. Where `edgeTearPath` subdivides
    /// into fibre, this steps between a handful of straight facets meeting at
    /// sharp vertices, because that is what stone and metal do when they fail.
    /// `angularity` moves it from weathered and rounded to a fresh break.
    static func chipPath(_ chip: Chip, in rect: CGRect) -> CGPath {
        let unit = min(rect.width, rect.height)
        let depth = CGFloat(chip.depth) * unit
        let half = CGFloat(chip.length) * unit / 2
        guard depth > 0.5, half > 0.5 else { return CGMutablePath() }

        let overshoot = max(2, depth * 0.3)
        var rng = SplitMix64(seed: chip.seed)

        let edgeStart: CGPoint
        let edgeEnd: CGPoint
        let inward: CGVector
        let outward: CGVector

        switch chip.edge {
        case .top:
            let cx = rect.minX + CGFloat(chip.position) * rect.width
            edgeStart = CGPoint(x: cx - half, y: rect.minY)
            edgeEnd = CGPoint(x: cx + half, y: rect.minY)
            inward = CGVector(dx: 0, dy: 1)
            outward = CGVector(dx: 0, dy: -1)
        case .bottom:
            let cx = rect.minX + CGFloat(chip.position) * rect.width
            edgeStart = CGPoint(x: cx + half, y: rect.maxY)
            edgeEnd = CGPoint(x: cx - half, y: rect.maxY)
            inward = CGVector(dx: 0, dy: -1)
            outward = CGVector(dx: 0, dy: 1)
        case .left:
            let cy = rect.minY + CGFloat(chip.position) * rect.height
            edgeStart = CGPoint(x: rect.minX, y: cy + half)
            edgeEnd = CGPoint(x: rect.minX, y: cy - half)
            inward = CGVector(dx: 1, dy: 0)
            outward = CGVector(dx: -1, dy: 0)
        case .right:
            let cy = rect.minY + CGFloat(chip.position) * rect.height
            edgeStart = CGPoint(x: rect.maxX, y: cy - half)
            edgeEnd = CGPoint(x: rect.maxX, y: cy + half)
            inward = CGVector(dx: -1, dy: 0)
            outward = CGVector(dx: 1, dy: 0)
        }

        // Few facets and sharp ones: a break in rigid material is a small
        // number of flat planes, not a continuous curve.
        let facets = 2 + Int((chip.angularity * 3).rounded())
        let path = CGMutablePath()
        path.move(to: CGPoint(
            x: edgeStart.x + outward.dx * overshoot,
            y: edgeStart.y + outward.dy * overshoot
        ))
        path.addLine(to: edgeStart)

        for index in 1...facets {
            let t = CGFloat(index) / CGFloat(facets + 1)
            // Deepest near the middle, and never at a predictable fraction.
            let profile = sin(Double(t) * .pi)
            let bite = CGFloat(0.35 + 0.65 * profile * rng.double(in: 0.55...1.0))
            path.addLine(to: CGPoint(
                x: edgeStart.x + (edgeEnd.x - edgeStart.x) * t + inward.dx * depth * bite,
                y: edgeStart.y + (edgeEnd.y - edgeStart.y) * t + inward.dy * depth * bite
            ))
        }

        path.addLine(to: edgeEnd)
        path.addLine(to: CGPoint(
            x: edgeEnd.x + outward.dx * overshoot,
            y: edgeEnd.y + outward.dy * overshoot
        ))
        path.closeSubpath()
        return path
    }

    /// The hole a burn opened, for a `Char` that went through.
    ///
    /// Lobed rather than round: fire follows the fibre and eats outward in
    /// fingers, which is what separates a burn from a punched hole.
    static func charCorePath(_ burn: Char, in rect: CGRect) -> CGPath {
        guard burn.burnsThrough else { return CGMutablePath() }
        let unit = min(rect.width, rect.height)
        let radius = CGFloat(burn.coreRadius) * unit
        guard radius > 0.5 else { return CGMutablePath() }

        var rng = SplitMix64(seed: burn.seed &+ 0xB024_0001)
        let center = CGPoint(
            x: rect.minX + CGFloat(burn.center.x) * rect.width,
            y: rect.minY + CGFloat(burn.center.y) * rect.height
        )

        let steps = 22
        var points: [CGPoint] = []
        points.reserveCapacity(steps)
        for index in 0..<steps {
            let angle = Double(index) / Double(steps) * 2 * .pi
            // Two frequencies: a slow lobe and a fast flicker.
            let lobe = sin(angle * 3 + rng.unit()) * 0.25
            let flicker = rng.signedUnit() * 0.18
            let scale = 1 + (lobe + flicker) * burn.irregularity
            points.append(CGPoint(
                x: center.x + CGFloat(cos(angle) * Double(radius) * scale),
                y: center.y + CGFloat(sin(angle) * Double(radius) * scale)
            ))
        }
        return smoothClosedPath(through: points)
    }

    /// A fracture line across a rigid sheet, for stroking. Never subtractive:
    /// a cracked tablet is still one piece until a chip takes part of it away.
    static func crackPath(_ crack: Crack, in rect: CGRect) -> CGPath {
        var rng = SplitMix64(seed: crack.seed)
        let from = CGPoint(
            x: rect.minX + CGFloat(crack.from.x) * rect.width,
            y: rect.minY + CGFloat(crack.from.y) * rect.height
        )
        let to = CGPoint(
            x: rect.minX + CGFloat(crack.to.x) * rect.width,
            y: rect.minY + CGFloat(crack.to.y) * rect.height
        )

        let spine = raggedPolyline(
            from: from, to: to,
            roughness: crack.deviation, subdivisions: 5, rng: &rng
        )
        let path = CGMutablePath()
        guard let head = spine.first else { return path }
        path.move(to: head)
        for point in spine.dropFirst() { path.addLine(to: point) }

        // Branches leave the spine at a shallow angle and die out quickly,
        // which is how a fracture actually propagates.
        guard crack.branches > 0, spine.count > 4 else { return path }
        for _ in 0..<crack.branches {
            let index = rng.int(in: 1...(spine.count - 2))
            let origin = spine[index]
            let previous = spine[index - 1]
            let dx = origin.x - previous.x
            let dy = origin.y - previous.y
            let length = hypot(dx, dy)
            guard length > 0.001 else { continue }

            let lean = CGFloat(rng.double(in: 0.35...0.85)) * (rng.chance(0.5) ? 1 : -1)
            let reach = CGFloat(rng.double(in: 0.08...0.26)) * min(rect.width, rect.height)
            let tip = CGPoint(
                x: origin.x + (dx / length) * reach + (-dy / length) * reach * lean,
                y: origin.y + (dy / length) * reach + (dx / length) * reach * lean
            )
            let branch = raggedPolyline(
                from: origin, to: tip,
                roughness: crack.deviation * 0.7, subdivisions: 3, rng: &rng
            )
            path.move(to: origin)
            for point in branch.dropFirst() { path.addLine(to: point) }
        }
        return path
    }

    /// A scored line, for stroking. Straighter than a crack: a scratch is made
    /// by a hand in one pass, not by the material failing.
    static func scratchPath(_ scratch: Scratch, in rect: CGRect) -> CGPath {
        var rng = SplitMix64(seed: scratch.seed)
        let from = CGPoint(
            x: rect.minX + CGFloat(scratch.from.x) * rect.width,
            y: rect.minY + CGFloat(scratch.from.y) * rect.height
        )
        let to = CGPoint(
            x: rect.minX + CGFloat(scratch.to.x) * rect.width,
            y: rect.minY + CGFloat(scratch.to.y) * rect.height
        )
        let points = raggedPolyline(
            from: from, to: to,
            roughness: 0.12, subdivisions: 3, rng: &rng
        )
        let path = CGMutablePath()
        guard let head = points.first else { return path }
        path.move(to: head)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    /// The sheet outline before anything is removed from it.
    static func sheetPath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        guard cornerRadius > 0.5 else { return CGPath(rect: rect, transform: nil) }
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Sheet outline with every subtractive defect punched out of it.
    /// Filled or clipped with the even-odd rule.
    static func cutSheetPath(
        in rect: CGRect,
        cornerRadius: CGFloat,
        subtractive damage: [DamageElement]
    ) -> CGPath {
        let path = CGMutablePath()
        path.addPath(sheetPath(in: rect, cornerRadius: cornerRadius))
        for element in damage {
            switch element {
            case let .edgeTear(tear):
                path.addPath(edgeTearPath(tear, in: rect))
            case let .lostCorner(corner):
                path.addPath(lostCornerPath(corner, in: rect))
            case let .hole(hole):
                path.addPath(holePath(hole, in: rect))
            case let .chip(chip):
                path.addPath(chipPath(chip, in: rect))
            case let .char(burn):
                // Only a burn that went through removes anything. A scorch is
                // drawn as surface damage and leaves the sheet whole.
                if burn.burnsThrough { path.addPath(charCorePath(burn, in: rect)) }
            case .stain, .crease, .foxing, .crack, .patina, .scratch:
                continue
            }
        }
        return path
    }

    /// Just the cut-out shapes, used for drawing fibre halos along the cut.
    static func cutoutPaths(
        in rect: CGRect,
        subtractive damage: [DamageElement]
    ) -> [CGPath] {
        damage.compactMap { element in
            switch element {
            case let .edgeTear(tear): return edgeTearPath(tear, in: rect)
            case let .lostCorner(corner): return lostCornerPath(corner, in: rect)
            case let .hole(hole): return holePath(hole, in: rect)
            case let .chip(chip): return chipPath(chip, in: rect)
            case let .char(burn): return burn.burnsThrough ? charCorePath(burn, in: rect) : nil
            case .stain, .crease, .foxing, .crack, .patina, .scratch: return nil
            }
        }
    }
}
