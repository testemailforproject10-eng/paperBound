//
//  EPUBAnnotationsAnchor.swift
//  Paperbound
//
//  Where a piece of EPUB text sits inside its resource, as a character range,
//  so two marks (or a mark and a selection) can be compared.
//
//  Readium describes a selection with a text *quote*: the selected text plus
//  up to 200 characters before and after it, taken from the chapter's
//  `document.body.textContent` (see Readium's `selection.js`). It does not
//  give offsets. Decorations are drawn by anchoring that quote again in the
//  web view, which is why they survive font, size and margin changes.
//
//  To answer "is this selection already marked?" we do the same anchoring on
//  our side, against the resource's own text:
//
//    1. The chapter's XHTML is reduced to an approximation of
//       `body.textContent` (tags and comments dropped, entities decoded).
//    2. *All* whitespace is then removed, from that text and from every quote.
//       `Selection.toString()` and `textContent` disagree on line breaks and
//       runs of spaces; with no whitespace at all they agree on everything
//       else, and an overlap of a few spaces is never a meaningful overlap.
//    3. The quote's text is found in that canonical text. When it occurs more
//       than once, the occurrence whose surroundings best match the quote's
//       `before`/`after` wins; a progression hint breaks remaining ties.
//
//  The result is `EPUBTextRange`: the resource href plus a UTF-16 range in the
//  canonical text. Two ranges overlap when the hrefs match and the ranges
//  intersect. The quote stays the source of truth, so a range can always be
//  recomputed if this canonical form ever changes.
//

import Foundation

/// A span of text in one EPUB resource, in canonical (whitespace-free) UTF-16
/// offsets. See the file comment.
struct EPUBTextRange: Hashable, Sendable {
    let href: String
    let range: NSRange

    func overlaps(_ other: EPUBTextRange) -> Bool {
        EPUBTextAnchor.sameResource(href, other.href)
            && NSIntersectionRange(range, other.range).length > 0
    }
}

enum EPUBTextAnchor {

    // MARK: Canonical text

    /// An approximation of `document.body.textContent` for an XHTML resource,
    /// with all whitespace removed.
    static func canonicalText(fromHTML html: String) -> String {
        canonical(textContent(ofHTML: html))
    }

    /// The text of the `<body>`, tags and comments removed, entities decoded.
    static func textContent(ofHTML html: String) -> String {
        var body = Substring(html)
        if let open = html.range(of: "<body", options: .caseInsensitive),
           let close = html[open.upperBound...].range(of: ">") {
            body = html[close.upperBound...]
            if let end = body.range(of: "</body", options: [.caseInsensitive, .backwards]) {
                body = body[..<end.lowerBound]
            }
        }
        var text = String(body)
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        return decodingEntities(text)
    }

    /// The text with every whitespace character (and soft hyphens and
    /// zero-width characters, which never show) removed.
    static func canonical(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isIgnorable(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func isIgnorable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }
        switch scalar.value {
        case 0x00AD, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF: return true
        default: return false
        }
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "shy": "\u{00AD}", "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "middot": "\u{00B7}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}", "eacute": "\u{00E9}", "egrave": "\u{00E8}",
        "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
    ]

    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.utf16.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let name = text[text.index(after: index)..<semicolon]
            var decoded: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
            } else if name.hasPrefix("#") {
                decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
            } else {
                decoded = namedEntities[String(name)]
            }
            if let decoded {
                result += decoded
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    // MARK: Anchoring

    /// Finds a quote in a resource's canonical text.
    ///
    /// - Parameters:
    ///   - highlight: the quoted text itself.
    ///   - before / after: the quote's context, as Readium records it.
    ///   - canonicalText: `canonicalText(fromHTML:)` of the resource.
    ///   - progressionHint: 0…1 through the resource, used only to choose
    ///     between occurrences whose context matches equally well.
    /// - Returns: the UTF-16 range in `canonicalText`, or nil when the text is
    ///   not there at all.
    static func locate(
        highlight: String,
        before: String?,
        after: String?,
        in canonicalText: String,
        progressionHint: Double? = nil
    ) -> NSRange? {
        let needle = canonical(highlight)
        guard !needle.isEmpty else { return nil }
        let haystack = canonicalText as NSString
        var candidates: [NSRange] = []
        var searchFrom = 0
        while searchFrom < haystack.length, candidates.count < 1_000 {
            let found = haystack.range(
                of: needle, options: [.literal],
                range: NSRange(location: searchFrom, length: haystack.length - searchFrom)
            )
            guard found.location != NSNotFound else { break }
            candidates.append(found)
            searchFrom = found.location + 1
        }
        guard candidates.count > 1 else { return candidates.first }

        let prefix = canonical(before ?? "") as NSString
        let suffix = canonical(after ?? "") as NSString
        let hintOffset = progressionHint.map { Double(haystack.length) * min(max($0, 0), 1) }
        func score(_ range: NSRange) -> Int {
            commonSuffixLength(prefix, haystack, endingAt: range.location)
                + commonPrefixLength(suffix, haystack, startingAt: range.location + range.length)
        }
        return candidates.max { lhs, rhs in
            let (left, right) = (score(lhs), score(rhs))
            if left != right { return left < right }
            guard let hintOffset else { return lhs.location > rhs.location }
            return abs(Double(lhs.location) - hintOffset) > abs(Double(rhs.location) - hintOffset)
        }
    }

    /// How many UTF-16 units at the end of `context` match the text just
    /// before `end` in `text`.
    private static func commonSuffixLength(_ context: NSString, _ text: NSString, endingAt end: Int) -> Int {
        var count = 0
        while count < context.length, end - count - 1 >= 0,
              context.character(at: context.length - count - 1) == text.character(at: end - count - 1) {
            count += 1
        }
        return count
    }

    private static func commonPrefixLength(_ context: NSString, _ text: NSString, startingAt start: Int) -> Int {
        var count = 0
        while count < context.length, start + count < text.length,
              context.character(at: count) == text.character(at: start + count) {
            count += 1
        }
        return count
    }

    // MARK: Hrefs

    /// Readium hrefs from different sources can differ in a leading slash or
    /// percent-encoding; fragments never matter for a resource.
    static func sameResource(_ lhs: String, _ rhs: String) -> Bool {
        normalizedHref(lhs) == normalizedHref(rhs)
    }

    static func normalizedHref(_ href: String) -> String {
        var value = href
        if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]) }
        if let query = value.firstIndex(of: "?") { value = String(value[..<query]) }
        while value.hasPrefix("/") { value.removeFirst() }
        return value.removingPercentEncoding ?? value
    }
}
