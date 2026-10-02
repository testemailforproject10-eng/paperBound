//
//  SpineCreaseView.swift
//  Paperbound
//
//  The gutter of an open book: where two leaves meet, the paper curves down
//  into the binding and falls into shadow. Nothing separates the pages; the
//  shadow is the only sign of the spine.
//
//  Drawn over the seam of a spread, centred on it, so on the iPhone Duo the
//  crease sits exactly on the hinge. Depth follows the layout's
//  `spineShadowScale`, which the hinge angle already shapes: half open is the
//  deepest crease, pressed flat is the shallowest.
//

import SwiftUI

struct SpineCreaseView: View {
    let axis: ReadingDivisionAxis
    /// Width of the gutter or hardware fold the crease covers, in points.
    let foldWidth: CGFloat
    /// 0…1, from `ReadingSurfaceLayout.spineShadowScale`.
    let depth: Double
    /// Bound presentations carry a visible gutter; minimal keeps only a hint.
    let pronounced: Bool

    /// How far the shadow spreads across both leaves. A fold this narrow
    /// would read as a ruled line, so the shadow always reaches past it.
    static func reach(for foldWidth: CGFloat) -> CGFloat {
        max(foldWidth * 3, 36)
    }

    private var peak: Double {
        let base = pronounced ? 0.30 : 0.14
        return (base * depth).clamped(to: 0...0.5)
    }

    var body: some View {
        // Warm shadow rather than black: it is paper in shade, not a gap.
        let shade = Color(red: 0.16, green: 0.12, blue: 0.08)
        let falloff = Gradient(stops: [
            .init(color: shade.opacity(0), location: 0),
            .init(color: shade.opacity(peak * 0.18), location: 0.22),
            .init(color: shade.opacity(peak * 0.55), location: 0.40),
            .init(color: shade.opacity(peak), location: 0.5),
            .init(color: shade.opacity(peak * 0.55), location: 0.60),
            .init(color: shade.opacity(peak * 0.18), location: 0.78),
            .init(color: shade.opacity(0), location: 1)
        ])
        LinearGradient(
            gradient: falloff,
            startPoint: axis == .vertical ? .leading : .top,
            endPoint: axis == .vertical ? .trailing : .bottom
        )
    }
}
