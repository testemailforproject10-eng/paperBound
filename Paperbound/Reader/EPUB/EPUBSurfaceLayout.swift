//
//  EPUBSurfaceLayout.swift
//  Paperbound
//
//  Where the EPUB navigator sits on the screen, and how many columns it
//  shows. Pure geometry, so it can be tested without a web view.
//
//  The PDF reader draws pages itself and keeps text off the fold and the
//  camera cut-outs per page (`DeviceLayoutCoordinator`'s reserved regions).
//  Readium lays text out in a web view, so the same job is done by placing
//  that web view:
//
//  * Cut-outs and safe areas along the **left/right** edges narrow the
//    navigator's frame (Readium's paginated mode ignores horizontal insets).
//  * Cut-outs along the **top/bottom** become Readium's vertical content
//    insets.
//  * A **vertical fold** (Duo inner display, book posture) gives two columns
//    with the navigator centred on the fold, so the gap between the columns —
//    the body gutters plus `columnGap` — lies over the fold. Readium's two
//    columns are symmetric, so centring the frame is what keeps the fold clear.
//  * A **horizontal fold** cannot be bridged by columns; the text uses the
//    larger of the two panels.
//

import CoreGraphics
import Foundation
import UIKit

struct EPUBSurfaceLayout: Equatable {

    /// The navigator's frame in the surface's coordinates.
    var frame: CGRect
    /// Readium's top and bottom content insets, inside `frame`.
    var topInset: CGFloat
    var bottomInset: CGFloat
    /// 1 or 2.
    var columnCount: Int
    /// Extra gap between the two columns, in CSS px (= points), on top of the
    /// body gutters Readium already leaves. Non-zero only across a wide fold.
    var columnGap: CGFloat

    var isSpread: Bool { columnCount == 2 }

    /// A column narrower than this is not worth a second one.
    static let minimumColumnWidth: CGFloat = 300
    /// Breathing room between the top/bottom reserved strip and the text.
    static let verticalPadding: CGFloat = 12
    /// Readium's own defaults when nothing is reserved.
    static let minimumTopInset: CGFloat = 34
    static let minimumBottomInset: CGFloat = 34

    static let empty = EPUBSurfaceLayout(
        frame: .zero, topInset: minimumTopInset, bottomInset: minimumBottomInset,
        columnCount: 1, columnGap: 0
    )

    /// - Parameters:
    ///   - size: the whole reading surface (the screen, controls hidden).
    ///   - safeAreaInsets: the window's safe area: status bar, home indicator,
    ///     notch. Not the app's own bars, which float over the text.
    ///   - reservedRegions: occlusions (camera cut-outs, sensor strips) in
    ///     surface coordinates, e.g. `ReaderViewModel.layout.reservedRegions`.
    ///     Regions that are the fold itself may be included; they are skipped.
    ///   - divisionRegion / divisionAxis: the hardware fold, when one is active.
    ///   - posture: from `DeviceLayoutCoordinator`.
    static func make(
        size: CGSize,
        safeAreaInsets: UIEdgeInsets,
        reservedRegions: [CGRect] = [],
        divisionRegion: CGRect? = nil,
        divisionAxis: ReadingDivisionAxis? = nil,
        posture: DevicePosture = .flat
    ) -> EPUBSurfaceLayout {
        guard size.width > 0, size.height > 0 else { return .empty }
        let bounds = CGRect(origin: .zero, size: size)

        var left = safeAreaInsets.left
        var right = safeAreaInsets.right
        var top = safeAreaInsets.top
        var bottom = safeAreaInsets.bottom

        let fold = divisionRegion.map { $0.intersection(bounds) }.flatMap { $0.isNull ? nil : $0 }

        // Each cut-out pushes in from whichever edge gives up the smallest
        // share of the screen: a camera hole at the top lowers the text, a
        // full-height sensor strip down one side narrows it.
        for region in reservedRegions {
            let clipped = region.intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            if let fold, clipped == fold || fold.contains(clipped) { continue }
            let costs: [(UIRectEdge, CGFloat)] = [
                (.top, clipped.maxY / size.height),
                (.bottom, (size.height - clipped.minY) / size.height),
                (.left, clipped.maxX / size.width),
                (.right, (size.width - clipped.minX) / size.width),
            ]
            guard let nearest = costs.min(by: { $0.1 < $1.1 })?.0 else { continue }
            switch nearest {
            case .top: top = max(top, clipped.maxY)
            case .bottom: bottom = max(bottom, size.height - clipped.minY)
            case .left: left = max(left, clipped.maxX)
            default: right = max(right, size.width - clipped.minX)
            }
        }

        var frame = CGRect(x: left, y: 0, width: max(0, size.width - left - right), height: size.height)
        var columns = 1
        var gap: CGFloat = 0

        if let fold, divisionAxis == .vertical, fold.midX > frame.minX, fold.midX < frame.maxX {
            // Centre the navigator on the fold so the column gap covers it.
            let half = min(fold.midX - frame.minX, frame.maxX - fold.midX)
            let centred = CGRect(x: fold.midX - half, y: 0, width: half * 2, height: size.height)
            let column = (centred.width - fold.width) / 2
            if column >= minimumColumnWidth * 0.8 {
                frame = centred
                columns = 2
                gap = fold.width.rounded(.up)
            } else {
                // Too narrow for two columns: read on the larger panel.
                let leftPanel = CGRect(x: frame.minX, y: 0, width: fold.minX - frame.minX, height: size.height)
                let rightPanel = CGRect(x: fold.maxX, y: 0, width: frame.maxX - fold.maxX, height: size.height)
                frame = leftPanel.width >= rightPanel.width ? leftPanel : rightPanel
            }
        } else if let fold, divisionAxis == .horizontal, fold.midY > 0, fold.midY < size.height {
            // Columns cannot bridge a horizontal fold: use the larger panel.
            let upper = fold.minY
            let lower = size.height - fold.maxY
            if upper >= lower {
                bottom = max(bottom, size.height - fold.minY)
            } else {
                top = max(top, fold.maxY)
            }
        } else if posture != .folded {
            let wide = frame.width >= minimumColumnWidth * 2 && frame.width > size.height
            let openBook = posture == .bookLike && frame.width >= minimumColumnWidth * 2
            if wide || openBook { columns = 2 }
        }

        let topInset = max(top + (top > 0 ? verticalPadding : 0), minimumTopInset)
        let bottomInset = max(bottom + (bottom > 0 ? verticalPadding : 0), minimumBottomInset)

        return EPUBSurfaceLayout(
            frame: frame.integral,
            topInset: topInset,
            bottomInset: bottomInset,
            columnCount: columns,
            columnGap: gap
        )
    }
}

/// Where a tap lands on the page: the outer 28% on each side turns the page,
/// the middle toggles the controls — the same split as the PDF reader.
enum EPUBTapZone: Equatable {
    case left
    case middle
    case right

    static let edgeFraction: CGFloat = 0.28

    init(x: CGFloat, width: CGFloat) {
        guard width > 0 else { self = .middle; return }
        let edge = width * Self.edgeFraction
        if x < edge {
            self = .left
        } else if x > width - edge {
            self = .right
        } else {
            self = .middle
        }
    }
}
