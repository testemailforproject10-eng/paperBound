//
//  EPUBLocator.swift
//  Paperbound
//
//  The bridge between Readium's `Locator` and Paperbound's `ReadingLocation`.
//
//  It lives in Engine rather than Model so the model layer (SwiftData records,
//  bookmarks, the progress bar) never has to import Readium. Everything that
//  crosses from the navigator into the app, or back, goes through here.
//

import Foundation
import ReadiumShared

extension ReadingLocation {

    /// Wraps a Readium locator. The JSON is Readium's own canonical form
    /// (sorted keys), so the same locator always produces the same string and
    /// `ReadingLocation`'s synthesized `Hashable` behaves.
    init(locator: Locator) {
        let json = (try? locator.jsonString()) ?? "{}"
        self = .epubLocator(
            href: locator.href.string,
            progression: locator.locations.progression ?? 0,
            totalProgression: locator.locations.totalProgression,
            locatorJSON: json
        )
    }

    /// The full Readium locator, for handing to the navigator.
    ///
    /// Falls back to a locator rebuilt from the denormalized fields when the
    /// JSON is missing or unreadable, so a damaged record still opens in the
    /// right chapter instead of at the start. `nil` for non-EPUB locations.
    var readiumLocator: Locator? {
        guard case let .epubLocator(href, progression, totalProgression, json) = self else {
            return nil
        }
        if let parsed = try? Locator(jsonString: json) {
            return parsed
        }
        guard let url = AnyURL(string: href) else { return nil }
        return Locator(
            href: url,
            mediaType: .xhtml,
            locations: .init(progression: progression, totalProgression: totalProgression)
        )
    }

    /// The resource part of an EPUB location, e.g. `OEBPS/chapter2.xhtml`.
    var epubHref: String? {
        if case let .epubLocator(href, _, _, _) = self { return href }
        return nil
    }

    /// Position 0…1 through the whole publication, when Readium reported one.
    var epubTotalProgression: Double? {
        if case let .epubLocator(_, _, totalProgression, _) = self { return totalProgression }
        return nil
    }
}
