import CoreGraphics
import Foundation

/// Time is supplied by the caller so walking, pauses and fading can be tested
/// without a display link. Route preparation happens ahead of drawing.
struct FootstepClock {
    var now: () -> Date = Date.init
}

struct FootstepPrint: Equatable {
    enum Foot: Equatable { case left, right }

    let foot: Foot
    let center: CGPoint
    let heading: CGFloat
    let pageIndex: Int
    let placedAt: TimeInterval
    let segmentIndex: Int

    func opacity(at elapsed: TimeInterval) -> Double {
        let age = elapsed - placedAt
        guard age >= 0, age < 3.5 else { return 0 }
        if age < 0.12 { return Double(age / 0.12) * 0.35 }
        if age < 0.7 { return 0.35 }
        return 0.35 * Double((3.5 - age) / 2.8)
    }
}

/// One route through the visible page rectangles. The walker continues across
/// gaps in time, but stamps are emitted only over unobscured paper.
final class FootstepController {
    let visitID: UUID
    let surfaces: [CGRect]
    let reservedRegions: [CGRect]
    let clock: FootstepClock
    let spatialScale: CGFloat

    private var rng: SplitMix64
    private(set) var plannedPrints: [FootstepPrint] = []
    private(set) var segmentDestinations: [Int] = []
    private var position: CGPoint
    private var heading: CGFloat
    private var pageIndex = 0
    private var nextSegmentAt: TimeInterval = 0
    private var segmentIndex = 0
    private var nextFoot: FootstepPrint.Foot = .left
    private var pausedAt: Date?
    private var pausedDuration: TimeInterval = 0
    private let startedAt: Date

    init(
        visitID: UUID,
        seed: UInt64,
        surfaces: [CGRect],
        reservedRegions: [CGRect],
        startedAt: Date,
        spatialScale: CGFloat = 1,
        walkerIndex: Int = 0,
        walkerCount: Int = 1,
        clock: FootstepClock = FootstepClock()
    ) {
        self.visitID = visitID
        self.surfaces = surfaces.filter { $0.width > 0 && $0.height > 0 }
        self.reservedRegions = reservedRegions
        self.startedAt = startedAt
        self.spatialScale = spatialScale
        self.clock = clock
        rng = SplitMix64(seed: seed)
        let firstPage = self.surfaces.isEmpty ? 0 : walkerIndex % self.surfaces.count
        pageIndex = firstPage
        let first = self.surfaces.isEmpty ? .zero : self.surfaces[firstPage]
        position = CGPoint(x: first.midX, y: first.midY)
        heading = -.pi / 2
        if !self.surfaces.isEmpty {
            // Distribute starting points even when only one page is visible.
            let bands = max(1, walkerCount)
            let bandWidth = first.width / CGFloat(bands)
            let band = min(max(0, walkerIndex), bands - 1)
            let startRegion = CGRect(
                x: first.minX + CGFloat(band) * bandWidth,
                y: first.minY,
                width: bandWidth,
                height: first.height
            )
            position = randomPoint(in: startRegion)
            let focus = self.surfaces.count > 1
                ? self.surfaces[(firstPage + 1) % self.surfaces.count] : first
            heading = atan2(focus.midY - position.y, focus.midX - position.x)
                + CGFloat(rng.double(in: -0.6...0.6))
        }
    }

    func pause(at date: Date) {
        if pausedAt == nil { pausedAt = date }
    }

    func pause() { pause(at: clock.now()) }

    func resume(at date: Date) {
        if let pausedAt {
            pausedDuration += max(0, date.timeIntervalSince(pausedAt))
            self.pausedAt = nil
        }
    }

    func resume() { resume(at: clock.now()) }

    func elapsed(at date: Date) -> TimeInterval {
        max(0, (pausedAt ?? date).timeIntervalSince(startedAt) - pausedDuration)
    }

    func visiblePrints(at date: Date) -> [FootstepPrint] {
        let time = elapsed(at: date)
        return Array(plannedPrints.lazy.filter { $0.opacity(at: time) > 0 }.suffix(16))
    }

    func visiblePrints() -> [FootstepPrint] { visiblePrints(at: clock.now()) }

    /// Called when the visit starts and periodically off the Canvas drawing
    /// closure. At 30 Hz the frame path only evaluates opacity and draws images.
    func prepare(through horizon: TimeInterval) {
        guard !surfaces.isEmpty else { return }
        while nextSegmentAt < horizon {
            appendSegment()
        }
        let cutoff = max(0, horizon - 65)
        plannedPrints.removeAll { $0.placedAt < cutoff }
    }

    private func appendSegment() {
        segmentIndex += 1
        let destinationPage: Int
        if surfaces.count > 1 && segmentIndex.isMultiple(of: 2) {
            destinationPage = pageIndex == 0 ? 1 : 0
        } else {
            destinationPage = pageIndex
        }
        segmentDestinations.append(destinationPage)
        if segmentDestinations.count > 64 { segmentDestinations.removeFirst(segmentDestinations.count - 64) }
        let destination = chooseDestination(in: surfaces[destinationPage])
        let delta = CGPoint(x: destination.x - position.x, y: destination.y - position.y)
        let distance = max(1, hypot(delta.x, delta.y))
        let outgoing = CGPoint(x: cos(heading), y: sin(heading))
        let travelAngle = atan2(delta.y, delta.x)
        let nextFocus = surfaces.count > 1 && !segmentIndex.isMultiple(of: 2)
            ? surfaces[destinationPage == 0 ? 1 : 0]
            : surfaces[destinationPage]
        let inwardAngle = atan2(nextFocus.midY - destination.y,
                                nextFocus.midX - destination.x)
        let inwardTurn = Self.angleDifference(from: travelAngle, to: inwardAngle)
        let destinationAngle = travelAngle
            + min(max(inwardTurn, -1.45), 1.45)
            + CGFloat(rng.double(in: -0.18...0.18))
        let controlLength = min(distance * 0.34, 145 * spatialScale)
        var a = CGPoint(x: position.x + outgoing.x * controlLength,
                        y: position.y + outgoing.y * controlLength)
        var b = CGPoint(x: destination.x - cos(destinationAngle) * controlLength,
                        y: destination.y - sin(destinationAngle) * controlLength)
        if destinationPage == pageIndex {
            let interior = surfaces[pageIndex].insetBy(
                dx: 8 * spatialScale, dy: 8 * spatialScale
            )
            a = Self.clamped(a, to: interior)
            b = Self.clamped(b, to: interior)
        }
        let sampled = Self.sampleCubic(
            position, a, b, destination,
            count: max(32, Int(distance / max(0.5, 3 * spatialScale)))
        )
        let totalLength = sampled.last?.distance ?? 0
        let stride = CGFloat(rng.double(in: 24...32)) * spatialScale
        let cadence = rng.double(in: 0.40...0.55)
        var traveled = stride * 0.5
        var step = 0
        while traveled <= totalLength {
            let location = Self.location(along: sampled, at: traveled)
            let side: CGFloat = (nextFoot == .left ? -3.5 : 3.5) * spatialScale
            let normal = CGPoint(x: -sin(location.angle), y: cos(location.angle))
            let center = CGPoint(x: location.point.x + normal.x * side,
                                 y: location.point.y + normal.y * side)
            if let sheet = surfaceIndex(containing: center) {
                plannedPrints.append(FootstepPrint(
                    foot: nextFoot, center: center,
                    heading: location.angle, pageIndex: sheet,
                    placedAt: nextSegmentAt + Double(step) * cadence,
                    segmentIndex: segmentIndex
                ))
                nextFoot = nextFoot == .left ? .right : .left
            } else if surfaces.count > 1 {
                // The walker keeps stepping while crossing a fold or gutter.
                nextFoot = nextFoot == .left ? .right : .left
            }
            traveled += stride
            step += 1
        }
        let walkEnd = nextSegmentAt + Double(step) * cadence
        nextSegmentAt = walkEnd + rng.double(in: 0.5...1.5)
        position = destination
        heading = destinationAngle
        pageIndex = destinationPage
    }

    private func surfaceIndex(containing point: CGPoint) -> Int? {
        guard !reservedRegions.contains(where: {
            $0.insetBy(dx: -6 * spatialScale, dy: -6 * spatialScale).contains(point)
        }) else { return nil }
        return surfaces.firstIndex { $0.contains(point) }
    }

    private func randomPoint(in rect: CGRect) -> CGPoint {
        let inset = rect.insetBy(dx: min(30 * spatialScale, rect.width * 0.12),
                                 dy: min(30 * spatialScale, rect.height * 0.12))
        for _ in 0..<24 {
            let point = CGPoint(x: rng.double(in: Double(inset.minX)...Double(inset.maxX)),
                                y: rng.double(in: Double(inset.minY)...Double(inset.maxY)))
            if !reservedRegions.contains(where: {
                $0.insetBy(dx: -15 * spatialScale, dy: -15 * spatialScale).contains(point)
            }) {
                return point
            }
        }
        return CGPoint(x: inset.midX, y: inset.midY)
    }

    private func chooseDestination(in rect: CGRect) -> CGPoint {
        var best = randomPoint(in: rect)
        var bestScore = CGFloat.greatestFiniteMagnitude
        for _ in 0..<24 {
            let candidate = randomPoint(in: rect)
            let dx = candidate.x - position.x
            let dy = candidate.y - position.y
            let distance = hypot(dx, dy)
            let turn = abs(Self.angleDifference(from: heading, to: atan2(dy, dx)))
            let score = turn * 100 + max(0, 120 * spatialScale - distance)
            if score < bestScore { best = candidate; bestScore = score }
            if distance >= 120 * spatialScale && turn <= 1.1 { return candidate }
        }
        return best
    }

    private static func angleDifference(from a: CGFloat, to b: CGFloat) -> CGFloat {
        atan2(sin(b - a), cos(b - a))
    }

    private static func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX),
                y: min(max(point.y, rect.minY), rect.maxY))
    }

    private struct Sample { let point: CGPoint; let distance: CGFloat }

    private static func sampleCubic(
        _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, count: Int
    ) -> [Sample] {
        var result = [Sample(point: p0, distance: 0)]
        var distance: CGFloat = 0
        for index in 1...count {
            let t = CGFloat(index) / CGFloat(count)
            let s = 1 - t
            let point = CGPoint(
                x: s*s*s*p0.x + 3*s*s*t*p1.x + 3*s*t*t*p2.x + t*t*t*p3.x,
                y: s*s*s*p0.y + 3*s*s*t*p1.y + 3*s*t*t*p2.y + t*t*t*p3.y
            )
            distance += hypot(point.x - result[result.count - 1].point.x,
                              point.y - result[result.count - 1].point.y)
            result.append(Sample(point: point, distance: distance))
        }
        return result
    }

    private static func location(along samples: [Sample], at distance: CGFloat) -> (point: CGPoint, angle: CGFloat) {
        guard samples.count > 1 else { return (.zero, 0) }
        let index = samples.firstIndex { $0.distance >= distance } ?? (samples.count - 1)
        let upper = samples[max(1, index)]
        let lower = samples[max(0, index - 1)]
        let span = max(0.001, upper.distance - lower.distance)
        let fraction = (distance - lower.distance) / span
        return (
            CGPoint(x: lower.point.x + (upper.point.x - lower.point.x) * fraction,
                    y: lower.point.y + (upper.point.y - lower.point.y) * fraction),
            atan2(upper.point.y - lower.point.y, upper.point.x - lower.point.x)
        )
    }
}

struct FootstepStamp {
    let walkerIndex: Int
    let print: FootstepPrint
    let opacity: Double
    let age: TimeInterval
}

/// Three independent walkers share a drawing surface and a bounded sprite
/// budget. Each owns its own route, cadence, pause and alternating feet.
final class FootstepEnsemble {
    static let walkerCount = 3
    static let maximumVisiblePrints = 32

    let walkers: [FootstepController]

    init(
        visitID: UUID,
        seed: UInt64,
        surfaces: [CGRect],
        reservedRegions: [CGRect],
        startedAt: Date,
        spatialScale: CGFloat = 1,
        clock: FootstepClock = FootstepClock()
    ) {
        walkers = (0..<Self.walkerCount).map { index in
            FootstepController(
                visitID: visitID,
                seed: StableHash.combine(seed, 0xF007_5EED, UInt64(index)),
                surfaces: surfaces,
                reservedRegions: reservedRegions,
                startedAt: startedAt.addingTimeInterval(Double(index) * 0.22),
                spatialScale: spatialScale,
                walkerIndex: index,
                walkerCount: Self.walkerCount,
                clock: clock
            )
        }
    }

    func prepare(through horizon: TimeInterval) {
        for walker in walkers { walker.prepare(through: horizon) }
    }

    func elapsed(at date: Date) -> TimeInterval {
        walkers.first?.elapsed(at: date) ?? 0
    }

    func visibleStamps(at date: Date) -> [FootstepStamp] {
        let stamps = walkers.enumerated().flatMap { index, walker in
            let elapsed = walker.elapsed(at: date)
            return walker.visiblePrints(at: date).map { print in
                FootstepStamp(
                    walkerIndex: index,
                    print: print,
                    opacity: print.opacity(at: elapsed),
                    age: elapsed - print.placedAt
                )
            }
        }
        // Draw older impressions first while retaining the newest 32 overall.
        return Array(stamps.sorted { $0.age < $1.age }
            .prefix(Self.maximumVisiblePrints).reversed())
    }

    func pause(at date: Date) {
        for walker in walkers { walker.pause(at: date) }
    }

    func resume(at date: Date) {
        for walker in walkers { walker.resume(at: date) }
    }
}

/// Readiness is independent from the ink GPU session. Render and visit tokens
/// prevent an old page task from starting a newer walk.
struct FootstepVisit: Equatable {
    let unit: Int
    let visitID: UUID
    let pageRenderTokens: [String: String]
    var eligible = false
    private(set) var readyPages: Set<String> = []
    private(set) var startedAt: Date?

    mutating func setVisibleFraction(_ fraction: CGFloat, at date: Date) {
        if fraction >= 0.05 { eligible = true }
        startIfReady(at: date)
    }

    @discardableResult
    mutating func paperReady(pageIdentity: String, renderToken: String, visitID: UUID, at date: Date) -> Bool {
        guard visitID == self.visitID,
              pageRenderTokens[pageIdentity] == renderToken else { return false }
        readyPages.insert(pageIdentity)
        startIfReady(at: date)
        return true
    }

    private mutating func startIfReady(at date: Date) {
        guard startedAt == nil, eligible,
              !pageRenderTokens.isEmpty,
              readyPages.count == pageRenderTokens.count else { return }
        startedAt = date
    }
}
