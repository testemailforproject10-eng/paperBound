//
//  EPUBAnnotationsOverlay.swift
//  Paperbound
//
//  The highlight action bar over the EPUB surface: the same
//  `ReaderAnnotationOverlay` (and so the same `HighlightActionBar`) the PDF
//  reader uses, fed by `EPUBAnnotationsController`.
//
//  Place it over the whole reading surface. Selection and mark rects arrive in
//  window coordinates and are converted to this view's own space here, so it
//  does not matter where the navigator sits inside the surface (it is inset
//  around the Duo's fold and the camera).
//

import SwiftUI

struct EPUBAnnotationsOverlay: View {

    let model: ReaderViewModel

    var body: some View {
        let annotations = model.epubAnnotations
        GeometryReader { geometry in
            let global = geometry.frame(in: .global)
            let insets = geometry.safeAreaInsets
            let size = geometry.size
            let container = CGRect(
                x: insets.leading, y: insets.top,
                width: size.width - insets.leading - insets.trailing,
                height: size.height - insets.top - insets.bottom
            ).insetBy(dx: 8, dy: 8)
            // The fold and cut-outs, which the bar must not straddle. They are
            // in the full-screen surface's space, whose origin is the window's.
            let avoiding = model.layout.reservedRegions.map { $0.offsetBy(dx: -global.minX, dy: -global.minY) }
            ReaderAnnotationOverlay(
                bar: localBar(annotations.bar, origin: global.origin),
                loupePoint: nil,
                surfaceSize: size,
                container: container,
                avoiding: avoiding,
                onStyle: { style in annotations.applyMark(style: style) },
                onColor: { color in annotations.applyMark(color: color) },
                onCopy: { annotations.copyText() },
                onDelete: { annotations.removeMarks() }
            )
        }
        // The whole surface, like the navigator's host: the fold and cut-out
        // regions are in that space, and the safe area becomes the container.
        .ignoresSafeArea()
        .onChange(of: model.book.highlights.count) { _, _ in
            annotations.refreshDecorations()
        }
    }

    private func localBar(_ bar: ReaderAnnotationOverlay.Bar?, origin: CGPoint) -> ReaderAnnotationOverlay.Bar? {
        guard let bar else { return nil }
        return ReaderAnnotationOverlay.Bar(
            mode: bar.mode, style: bar.style, color: bar.color,
            chosenStyles: bar.chosenStyles, chosenColors: bar.chosenColors,
            canRemove: bar.canRemove,
            anchor: bar.anchor.offsetBy(dx: -origin.x, dy: -origin.y)
        )
    }
}
