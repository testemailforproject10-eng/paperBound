//
//  PageContentGeometry.swift
//  Paperbound
//
//  Finds a rectangular content area that stays inside safe bounds and avoids
//  reported hardware occlusions. Paper can still fill the whole sheet.
//

import CoreGraphics

enum PageContentGeometry {

    static func readableFraction(
        for pageRect: CGRect,
        within safeBounds: CGRect,
        excluding reservedRegions: [CGRect]
    ) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard pageRect.width > 0, pageRect.height > 0 else { return whole }
        let visible = pageRect.intersection(safeBounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return whole }

        var usableRects = [visible]
        for region in reservedRegions {
            usableRects = usableRects.flatMap { bounds -> [CGRect] in
                let blocked = bounds.intersection(region)
                guard !blocked.isNull, blocked.width > 0, blocked.height > 0 else { return [bounds] }
                return [
                    CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: blocked.minY - bounds.minY),
                    CGRect(x: bounds.minX, y: blocked.maxY, width: bounds.width, height: bounds.maxY - blocked.maxY),
                    CGRect(x: bounds.minX, y: blocked.minY, width: blocked.minX - bounds.minX, height: blocked.height),
                    CGRect(x: blocked.maxX, y: blocked.minY, width: bounds.maxX - blocked.maxX, height: blocked.height)
                ].filter { $0.width > 0 && $0.height > 0 }
            }
        }

        guard let readable = usableRects.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return whole
        }
        return CGRect(
            x: (readable.minX - pageRect.minX) / pageRect.width,
            y: (readable.minY - pageRect.minY) / pageRect.height,
            width: readable.width / pageRect.width,
            height: readable.height / pageRect.height
        )
    }
}
