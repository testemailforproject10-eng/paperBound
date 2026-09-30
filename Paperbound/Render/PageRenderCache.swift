//
//  PageRenderCache.swift
//  Paperbound
//
//  Composited pages are expensive and large. They are cached by an identity
//  that includes the environment, so switching to Pristine and back is instant
//  and never risks showing the wrong wear on the wrong page.
//
//  Speculative entries are evicted before visited pages; the memory-warning
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
    /// Which normalized part of a sheet was usable for document content.
    var safeToken: String = ""

    var stringValue: String {
        "\(stablePageID)|\(renderIdentity)|\(pixelWidth)x\(pixelHeight)|s\(spineShadowBucket)|b\(spine.rawValue)|safe\(safeToken)"
    }
}

final class PageRenderCache: @unchecked Sendable {
    private struct Entry {
        let page: PageRenderResult
        var speculative: Bool
        var access: UInt64
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    private let limit: Int
    private var observer: NSObjectProtocol?

    init(costLimitBytes: Int = 96 * 1024 * 1024) {
        limit = costLimitBytes
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

    func page(for key: PageRenderKey, promote: Bool = true) -> PageRenderResult? {
        lock.withLock {
            guard var entry = entries[key.stringValue] else { return nil }
            clock &+= 1
            entry.access = clock
            if promote { entry.speculative = false }
            entries[key.stringValue] = entry
            return entry.page
        }
    }

    func image(for key: PageRenderKey) -> CGImage? {
        page(for: key)?.image
    }

    func store(_ page: PageRenderResult, for key: PageRenderKey, speculative: Bool = false) {
        lock.withLock {
            if let previous = entries.removeValue(forKey: key.stringValue) { bytes -= previous.page.memoryCost }
            guard page.memoryCost <= limit else { return }
            while bytes + page.memoryCost > limit || entries.count >= 24 {
                guard let victim = entries.min(by: {
                    if $0.value.speculative != $1.value.speculative { return $0.value.speculative }
                    return $0.value.access < $1.value.access
                }) else { break }
                bytes -= victim.value.page.memoryCost
                entries.removeValue(forKey: victim.key)
            }
            clock &+= 1
            entries[key.stringValue] = Entry(page: page, speculative: speculative, access: clock)
            bytes += page.memoryCost
        }
    }

    func store(_ image: CGImage, for key: PageRenderKey) {
        store(PageRenderResult(image: image, revealBackground: nil, revealSeed: 0), for: key)
    }

    func removeAll() {
        lock.withLock { entries.removeAll(); bytes = 0 }
    }
}
