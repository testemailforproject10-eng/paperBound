//
//  PageRenderCache.swift
//  Paperbound
//
//  Composited pages are expensive and large. They are cached by an identity
//  that includes the environment, so switching to Pristine and back is instant
//  and never risks showing the wrong wear on the wrong page.
//
//  NSCache does the eviction under memory pressure; the explicit memory-warning
//  hook drops everything, because a half-emptied page cache during a warning is
//  worse than a cold one.
//

import CoreGraphics
import Foundation
import UIKit

struct PageRenderKey: Hashable {
    var stablePageID: String
    var renderIdentity: String
    var pixelWidth: Int
    var pixelHeight: Int
    /// Bucketed spine shadow, so small posture jitter does not thrash the cache.
    var spineShadowBucket: Int
    /// Which edge is bound. The same page is bound on opposite edges depending
    /// on whether it is read alone or as the left leaf of a spread, and the two
    /// are different bitmaps, so this has to be part of the identity.
    var spine: PageEdge

    var stringValue: String {
        "\(stablePageID)|\(renderIdentity)|\(pixelWidth)x\(pixelHeight)|s\(spineShadowBucket)|b\(spine.rawValue)"
    }
}

final class PageRenderCache: @unchecked Sendable {

    private let cache = NSCache<NSString, CGImage>()
    private var observer: NSObjectProtocol?

    init(costLimitBytes: Int = 96 * 1024 * 1024) {
        cache.totalCostLimit = costLimitBytes
        cache.countLimit = 24
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.removeAll()
            PaperTextureFactory.shared.purge()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func image(for key: PageRenderKey) -> CGImage? {
        cache.object(forKey: key.stringValue as NSString)
    }

    func store(_ image: CGImage, for key: PageRenderKey) {
        let cost = image.bytesPerRow * image.height
        cache.setObject(image, forKey: key.stringValue as NSString, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
