//
//  PageAnnotationLayer.swift
//  Paperbound
//
//  Everything drawn over one sheet's text: its saved marks and, when the
//  reader is selecting on this page, the selection and its handles.
//
//  It sits on the sheet itself, under the page-turn effect, so a mark curls
//  and swings with its paper instead of floating above it.
//

import SwiftUI

struct PageAnnotationLayer: View {
    let marks: [PageMark]
    /// The live selection, only when it is on this page.
    let selection: PageTextSelection?
    /// The page's text block in this sheet's coordinates.
    let textBlock: CGRect
    var emphasizedMarkID: UUID?
    var isDarkPaper = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !marks.isEmpty {
                MarkerInkView(
                    marks: marks,
                    textBlock: textBlock,
                    emphasizedMarkID: emphasizedMarkID,
                    isDarkPaper: isDarkPaper
                )
            }
            if let selection {
                TextSelectionOverlay(lineRects: selection.lineRects, textBlock: textBlock)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
