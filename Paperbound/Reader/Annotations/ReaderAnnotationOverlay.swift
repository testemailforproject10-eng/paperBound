//
//  ReaderAnnotationOverlay.swift
//  Paperbound
//
//  The floating parts of annotating, drawn above the pages rather than on
//  them: the action bar next to the selection or the mark being edited, and
//  the loupe while a finger is down.
//
//  Coordinates are the reading surface's: the same space as the spread
//  rects, the Duo's fold and the safe-area insets.
//

import SwiftUI
import UIKit

struct ReaderAnnotationOverlay: View {

    struct Bar: Equatable {
        let mode: HighlightActionBar.Mode
        let style: HighlightStyle
        let color: HighlightColor
        /// What is already on the text, shown as chosen.
        let chosenStyles: Set<HighlightStyle>
        let chosenColors: Set<HighlightColor>
        /// Whether there is a mark to delete or clear.
        let canRemove: Bool
        /// Union of the selection's or mark's lines, surface coordinates.
        let anchor: CGRect
    }

    let bar: Bar?
    let loupePoint: CGPoint?
    let surfaceSize: CGSize
    /// Visible area the bar must stay inside: safe area, inset.
    let container: CGRect
    /// The fold and any camera cutouts.
    let avoiding: [CGRect]

    var onStyle: (HighlightStyle) -> Void
    var onColor: (HighlightColor) -> Void
    var onCopy: () -> Void
    var onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The cover screen and narrow panels get the single-row bar.
    private var compact: Bool { container.width < 520 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SelectionLoupe(point: loupePoint)
                .frame(width: surfaceSize.width, height: surfaceSize.height)
                .allowsHitTesting(false)

            if let bar {
                let size = HighlightActionBar.preferredSize(compact: compact)
                let placement = ActionBarPlacement.place(
                    barSize: size,
                    selection: bar.anchor,
                    container: container,
                    avoiding: avoiding
                )
                HighlightActionBar(
                    mode: bar.mode,
                    style: bar.style,
                    color: bar.color,
                    compact: compact,
                    chosenStyles: bar.chosenStyles,
                    chosenColors: bar.chosenColors,
                    onStyle: onStyle,
                    onColor: onColor,
                    onCopy: onCopy,
                    onDelete: bar.canRemove ? onDelete : nil
                )
                .frame(width: placement.frame.width, height: placement.frame.height)
                .position(x: placement.frame.midX, y: placement.frame.midY)
                .transition(reduceMotion
                    ? .opacity
                    : .scale(scale: 0.96, anchor: placement.isAbove ? .bottom : .top).combined(with: .opacity))
            }
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .topLeading)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.86),
                   value: bar)
    }
}
