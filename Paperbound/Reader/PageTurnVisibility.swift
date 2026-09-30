//
//  PageTurnVisibility.swift
//  Paperbound
//
//  Resolves which page is arriving during a horizontal paging transition.
//

import CoreGraphics

struct PageTurnVisibility: Equatable {
    static let revealThreshold: CGFloat = 0.05

    let unit: Int
    let fraction: CGFloat

    var qualifiesForReveal: Bool { fraction >= Self.revealThreshold }

    static func incomingPage(
        offset: CGFloat,
        direction: CGFloat,
        pageWidth: CGFloat,
        unitCount: Int
    ) -> PageTurnVisibility? {
        guard offset.isFinite,
              direction.isFinite,
              pageWidth.isFinite,
              offset >= 0,
              pageWidth > 0,
              unitCount > 0,
              abs(direction) > 0.25
        else { return nil }
        let position = offset / pageWidth
        let lower = Int(floor(position))
        let remainder = position - CGFloat(lower)
        // Paging animations commonly finish at an exact page boundary. At
        // that point the page on the boundary is fully visible, regardless
        // of which direction the final geometry update reported.
        if remainder < 0.000_001 {
            guard lower >= 0,
                  lower < unitCount
            else { return nil }
            return PageTurnVisibility(unit: lower, fraction: 1)
        }
        let unit = direction > 0 ? lower + 1 : Int(ceil(position)) - 1
        guard unit >= 0, unit < unitCount else { return nil }
        let visible = direction > 0 ? remainder : CGFloat(unit + 1) - position
        return PageTurnVisibility(unit: unit, fraction: visible.clamped(to: 0...1))
    }
}
