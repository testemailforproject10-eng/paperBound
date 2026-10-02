//
//  ActionBarPlacement.swift
//  Paperbound
//
//  Pure geometry for the floating selection action bar: where it goes
//  relative to the selected text, inside the reader's visible bounds, and
//  clear of anything it must not cover or straddle (the Duo's fold, camera
//  cutouts). No views, no state; the same inputs always give the same frame.
//

import CoreGraphics

struct ActionBarPlacement: Equatable, Sendable {
    /// Where the bar goes, container coordinates.
    let frame: CGRect
    /// True when the bar sits above the selection (its centre is higher than
    /// the selection's), false when below.
    let isAbove: Bool

    /// Computes where the bar goes.
    ///
    /// Preference order: above the selection (leaving `handleClearance` for the
    /// selection handles), then below it, then pinned to the edge of the panel
    /// on whichever side of the selection has more room (overlapping the
    /// selection is accepted only then). Horizontally the bar is centred on the
    /// selection's midX and clamped.
    ///
    /// Avoid regions are respected at every step. Regions that span the whole
    /// container split it into panels: the bar stays in the panel that holds
    /// the selection when it fits there, then tries the other panels nearest
    /// the selection, and only then the whole container minus the avoid
    /// regions. Smaller regions (camera cutouts) nudge the bar sideways, or
    /// further from the selection when no sideways gap is wide enough.
    ///
    /// - Parameters:
    ///   - barSize: the bar's size, e.g. `HighlightActionBar.preferredSize(compact:)`.
    ///   - selection: union of the selection's line rects, container coordinates.
    ///   - container: the reader's visible bounds, already inset for safe area and chrome.
    ///   - avoiding: regions the bar must not overlap or straddle, container coordinates.
    ///   - handleClearance: room left for the selection handles' knobs.
    ///   - margin: gap kept from the container edges and from avoid regions,
    ///     reduced automatically when the container is too small for it.
    static func place(
        barSize: CGSize,
        selection: CGRect,
        container: CGRect,
        avoiding: [CGRect],
        handleClearance: CGFloat = 24,
        margin: CGFloat = 8
    ) -> ActionBarPlacement {
        let solver = Solver(
            size: CGSize(width: max(0, barSize.width), height: max(0, barSize.height)),
            selection: selection.standardized,
            container: container.standardized,
            avoiding: avoiding.map(\.standardized).filter { !$0.isNull && !$0.isInfinite },
            clearance: max(0, handleClearance),
            margin: max(0, margin)
        )
        return solver.solve()
    }
}

// MARK: - Solver

private struct Solver {
    let size: CGSize
    let selection: CGRect
    let container: CGRect
    let avoiding: [CGRect]
    let clearance: CGFloat
    let margin: CGFloat

    /// The container shrunk by the margin, or by as much of it as still lets the bar fit.
    var area: CGRect {
        let dx = min(margin, max(0, (container.width - size.width) / 2))
        let dy = min(margin, max(0, (container.height - size.height) / 2))
        return container.insetBy(dx: dx, dy: dy)
    }

    /// Avoid regions grown by the margin, so the bar keeps a little air from a fold.
    var padded: [CGRect] {
        avoiding.map { $0.insetBy(dx: -margin, dy: -margin) }
    }

    func solve() -> ActionBarPlacement {
        let area = area
        let midX = selection.midX

        // 1. The horizontal band (between full-width dividers) holding the selection.
        let bands = freeIntervals(
            in: area.minY...area.maxY,
            removing: padded
                .filter { $0.minX <= area.minX + 0.5 && $0.maxX >= area.maxX - 0.5 }
                .map { $0.minY...$0.maxY }
        )
        if let band = interval(containing: selection.midY, in: bands, length: 0),
           let found = place(withinY: band, xTarget: midX) {
            return found
        }

        // 2. The whole container minus the avoid regions.
        if let found = place(withinY: area.minY...area.maxY, xTarget: midX) {
            return found
        }

        // 3. Nothing is clear (the container is smaller than the bar, or avoid
        // regions leave no gap): stay inside the container and overlap as little as possible.
        return leastBadFallback(in: area)
    }

    /// Tries above, below, then the roomier edge, inside a vertical range.
    private func place(withinY range: ClosedRange<CGFloat>, xTarget: CGFloat) -> ActionBarPlacement? {
        let h = size.height
        guard range.upperBound - range.lowerBound >= h else { return nil }

        let aboveY = selection.minY - clearance - h
        if aboveY >= range.lowerBound, aboveY + h <= range.upperBound,
           let frame = resolve(startY: aboveY, step: .up, range: range, xTarget: xTarget) {
            return ActionBarPlacement(frame: frame, isAbove: true)
        }

        let belowY = selection.maxY + clearance
        if belowY >= range.lowerBound, belowY + h <= range.upperBound,
           let frame = resolve(startY: belowY, step: .down, range: range, xTarget: xTarget) {
            return ActionBarPlacement(frame: frame, isAbove: false)
        }

        // Neither fits cleanly: pin to the edge on the side with more room,
        // then the other edge, sliding towards the selection past any cutout.
        let roomAbove = selection.minY - range.lowerBound
        let roomBelow = range.upperBound - selection.maxY
        let top = (range.lowerBound, Step.down)
        let bottom = (range.upperBound - h, Step.up)
        for (startY, step) in roomAbove >= roomBelow ? [top, bottom] : [bottom, top] {
            if let frame = resolve(startY: startY, step: step, range: range, xTarget: xTarget) {
                return ActionBarPlacement(frame: frame, isAbove: frame.midY < selection.midY)
            }
        }
        return nil
    }

    private enum Step { case up, down }

    /// Finds an x for a bar at `startY`; if no gap is wide enough, moves the bar
    /// vertically past whatever blocks it and tries again.
    private func resolve(startY: CGFloat, step: Step, range: ClosedRange<CGFloat>, xTarget: CGFloat) -> CGRect? {
        var y = startY
        for _ in 0...avoiding.count {
            guard y >= range.lowerBound - 0.001, y + size.height <= range.upperBound + 0.001 else { return nil }
            let blockers = padded.filter { $0.minY < y + size.height && $0.maxY > y }
            if let x = bestX(target: xTarget, blockers: blockers) {
                return CGRect(x: x, y: y, width: size.width, height: size.height)
            }
            switch step {
            case .up: y = (blockers.map(\.minY).min() ?? y) - size.height
            case .down: y = blockers.map(\.maxY).max() ?? y
            }
        }
        return nil
    }

    /// The bar's x in the free gap nearest the target, centred on it when possible.
    private func bestX(target: CGFloat, blockers: [CGRect]) -> CGFloat? {
        let area = area
        let gaps = freeIntervals(in: area.minX...area.maxX, removing: blockers.map { $0.minX...$0.maxX })
        guard let gap = interval(containing: target, in: gaps, length: size.width) else { return nil }
        let centred = target - size.width / 2
        return min(max(centred, gap.lowerBound), gap.upperBound - size.width)
    }

    /// Prefers the interval holding `value` when at least `length` long, then the
    /// long-enough interval nearest to it (ties go to the longer one).
    private func interval(containing value: CGFloat, in intervals: [ClosedRange<CGFloat>], length: CGFloat) -> ClosedRange<CGFloat>? {
        let candidates = intervals.filter { $0.upperBound - $0.lowerBound >= length - 0.001 }
        if let home = candidates.first(where: { $0.contains(value) }) { return home }
        return candidates.min { a, b in
            let da = distance(from: value, to: a), db = distance(from: value, to: b)
            if abs(da - db) > 0.001 { return da < db }
            return (a.upperBound - a.lowerBound) > (b.upperBound - b.lowerBound)
        }
    }

    private func distance(from value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        if value < range.lowerBound { return range.lowerBound - value }
        if value > range.upperBound { return value - range.upperBound }
        return 0
    }

    /// `whole` minus every blocked range, as sorted disjoint intervals.
    private func freeIntervals(in whole: ClosedRange<CGFloat>, removing blocked: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = []
        var cursor = whole.lowerBound
        for block in blocked.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if block.upperBound <= cursor { continue }
            if block.lowerBound >= whole.upperBound { break }
            if block.lowerBound > cursor { result.append(cursor...block.lowerBound) }
            cursor = max(cursor, block.upperBound)
        }
        if cursor < whole.upperBound { result.append(cursor...whole.upperBound) }
        return result
    }

    /// Last resort: scan positions inside the container and keep the one that
    /// overlaps the avoid regions least, preferring ones near the selection.
    private func leastBadFallback(in area: CGRect) -> ActionBarPlacement {
        let w = size.width, h = size.height
        func axis(_ lo: CGFloat, _ hi: CGFloat, _ preferred: CGFloat) -> [CGFloat] {
            guard hi > lo else { return [(lo + hi) / 2] }
            var values = stride(from: lo, through: hi, by: max(1, (hi - lo) / 16)).map { $0 }
            values.append(hi)
            values.append(min(max(preferred, lo), hi))
            return values
        }
        let xs = axis(area.minX, area.maxX - w, selection.midX - w / 2)
        let ys = axis(area.minY, area.maxY - h, selection.minY - clearance - h)
        var best: (cost: CGFloat, distance: CGFloat, frame: CGRect)?
        for y in ys {
            for x in xs {
                let frame = CGRect(x: x, y: y, width: w, height: h)
                let cost = avoiding.reduce(CGFloat(0)) { sum, r in
                    let overlapX = max(0, min(frame.maxX, r.maxX) - max(frame.minX, r.minX))
                    let overlapY = max(0, min(frame.maxY, r.maxY) - max(frame.minY, r.minY))
                    // A zero-width fold still counts when the bar straddles it.
                    let straddles = overlapY > 0 && r.width == 0 && frame.minX < r.minX && frame.maxX > r.minX
                    return sum + overlapX * overlapY + (straddles ? overlapY : 0)
                }
                let d = hypot(frame.midX - selection.midX, frame.midY - selection.midY)
                if best == nil || cost < best!.cost - 0.001 || (abs(cost - best!.cost) <= 0.001 && d < best!.distance) {
                    best = (cost, d, frame)
                }
            }
        }
        let frame = best?.frame ?? CGRect(x: area.minX, y: area.minY, width: w, height: h)
        return ActionBarPlacement(frame: frame, isAbove: frame.midY < selection.midY)
    }
}
