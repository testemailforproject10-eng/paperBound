//
//  HighlightStyle.swift
//  Paperbound
//
//  Shared vocabulary for text selection and annotation marks.
//
//  Coordinates: every rect and point here is in the unit space of the PDF
//  page's crop box, origin top-left, y down, 0…1 on both axes. That is the
//  space `Highlight.normalizedRects` already stores, and it survives any
//  change of sheet size, safe area or spread layout. `PageTextFrame` maps it
//  to and from a sheet view's own points.
//

import CoreGraphics
import Foundation

/// How a mark is drawn over its text.
enum HighlightStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case highlight
    case underline
    case strikethrough
    case squiggly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikethrough: return "Strikethrough"
        case .squiggly: return "Squiggly"
        }
    }

    var systemImage: String {
        switch self {
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .squiggly: return "scribble"
        }
    }
}

/// What the reader has selected on one page.
struct PageTextSelection: Equatable, Sendable {
    let pageIndex: Int
    /// Character range in `PDFPage.string`.
    let range: NSRange
    let text: String
    /// One rect per line of text, top to bottom, in unit page space.
    let lineRects: [CGRect]
}

/// A saved mark, ready to draw on its page.
struct PageMark: Identifiable, Equatable, Sendable {
    let id: UUID
    let style: HighlightStyle
    let color: HighlightColor
    /// One rect per line of text, top to bottom, in unit page space.
    let lineRects: [CGRect]
    var hasNote: Bool = false
}

/// Where a page's text block sits inside its sheet view, and conversions
/// between that view's points and unit page space.
///
/// The reader composites the PDF page at `PageCompositor.contentRect` with the
/// minimal presentation and no margin (see `compositeReaderPage`), so the text
/// block is that same rect computed in points instead of pixels.
enum PageTextFrame {
    static func textBlock(in sheetSize: CGSize, pageAspectRatio: Double, safeFraction: CGRect) -> CGRect {
        PageCompositor.contentRect(
            in: CGRect(origin: .zero, size: sheetSize),
            presentation: .minimal,
            pageAspectRatio: pageAspectRatio,
            safeFraction: safeFraction,
            contentMargin: 0
        )
    }

    static func viewRect(forUnit rect: CGRect, in block: CGRect) -> CGRect {
        CGRect(
            x: block.minX + rect.minX * block.width,
            y: block.minY + rect.minY * block.height,
            width: rect.width * block.width,
            height: rect.height * block.height
        )
    }

    static func viewPoint(forUnit point: CGPoint, in block: CGRect) -> CGPoint {
        CGPoint(x: block.minX + point.x * block.width, y: block.minY + point.y * block.height)
    }

    static func unitPoint(forView point: CGPoint, in block: CGRect) -> CGPoint {
        guard block.width > 0, block.height > 0 else { return .zero }
        return CGPoint(x: (point.x - block.minX) / block.width, y: (point.y - block.minY) / block.height)
    }
}
