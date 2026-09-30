import SwiftUI
import UIKit

/// A single decorative drawing surface for a whole visible paging unit. The
/// images are shared by every visit; the clock only controls sprite opacity.
struct FootstepOverlayView: View {
    let visit: FootstepVisit
    let seed: UInt64
    let surfaces: [CGRect]
    let reservedRegions: [CGRect]
    let size: CGSize
    let isDarkPaper: Bool
    let isPaused: Bool
    var artworkScale: CGFloat = 1

    @State private var ensemble: FootstepEnsemble?
    @State private var artworkFailed = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: isPaused || ensemble == nil || artworkFailed)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: true) { context, _ in
                guard let ensemble else { return }
                for sprite in ensemble.visibleStamps(at: timeline.date) {
                    let print = sprite.print
                    guard surfaces.indices.contains(print.pageIndex),
                          let image = FootstepArtwork.image(for: print.foot, darkPaper: isDarkPaper)
                    else { continue }
                    var stamp = context
                    var clipping = Path()
                    clipping.addRect(surfaces[print.pageIndex])
                    for region in reservedRegions {
                        let intersection = region.intersection(surfaces[print.pageIndex])
                        if !intersection.isNull { clipping.addRect(intersection) }
                    }
                    stamp.clip(to: clipping, style: FillStyle(eoFill: true))
                    stamp.opacity = sprite.opacity
                    stamp.translateBy(x: print.center.x, y: print.center.y)
                    // Artwork points upward. Rotate its toe toward the route.
                    stamp.rotate(by: .radians(Double(print.heading + .pi / 2)))
                    stamp.draw(image, in: CGRect(
                        x: -5 * artworkScale, y: -10 * artworkScale,
                        width: 10 * artworkScale, height: 20 * artworkScale
                    ))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: visit.visitID) {
            guard FootstepArtwork.available else {
                artworkFailed = true
                NSLog("Footsteps unavailable: shoe-print artwork could not be loaded")
                return
            }
            guard let startedAt = visit.startedAt else { return }
            let prepared = FootstepEnsemble(
                visitID: visit.visitID, seed: seed,
                surfaces: surfaces, reservedRegions: reservedRegions,
                startedAt: startedAt, spatialScale: artworkScale
            )
            prepared.prepare(through: 12)
            InkMetrics.trace("Footsteps overlay prepared \(prepared.walkers.map(\.plannedPrints.count).reduce(0, +)) prints")
            if isPaused { prepared.pause(at: Date()) }
            ensemble = prepared
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { break }
                prepared.prepare(through: prepared.elapsed(at: Date()) + 12)
            }
        }
        .onChange(of: isPaused) { _, paused in
            if paused { ensemble?.pause(at: Date()) }
            else { ensemble?.resume(at: Date()) }
        }
        .onDisappear { ensemble = nil }
    }
}

private enum FootstepArtwork {
    static let leftDark = UIImage(named: "FootstepLeftDark")?.cgImage
    static let rightDark = UIImage(named: "FootstepRightDark")?.cgImage
    static let leftLight = UIImage(named: "FootstepLeftLight")?.cgImage
    static let rightLight = UIImage(named: "FootstepRightLight")?.cgImage

    static var available: Bool {
        leftDark != nil && rightDark != nil && leftLight != nil && rightLight != nil
    }

    static func image(for foot: FootstepPrint.Foot, darkPaper: Bool) -> Image? {
        let source: CGImage?
        switch (foot, darkPaper) {
        case (.left, false): source = leftDark
        case (.right, false): source = rightDark
        case (.left, true): source = leftLight
        case (.right, true): source = rightLight
        }
        guard let source else { return nil }
        return Image(decorative: source, scale: 1)
    }
}
