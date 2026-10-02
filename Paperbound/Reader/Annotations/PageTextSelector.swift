//
//  PageTextSelector.swift
//  Paperbound
//
//  Text selection on a PDF page that the reader draws as a bitmap.
//
//  Physical mode composites each page as an image, so UIKit has no text to
//  select. This engine reads the page's text layer through PDFKit once, caches
//  where every character sits in unit page space (crop box, origin top-left,
//  y down, 0…1), and from then on answers "which character is under this
//  finger", "which word", "which sentence" and "which rects to paint" without
//  calling PDFKit again. Drag handlers call it on every touch event.
//
//  Why not `PDFPage.characterBounds(at:)` or `PDFPage.characterIndex(at:)`:
//  both drift out of step with `PDFPage.string` after every synthesized line
//  break (measured on the sample book: by the third paragraph the reported
//  bounds belong to a glyph several characters further on, with ink-tight and
//  sometimes zero heights). A one-character `PDFSelection` reports the correct
//  glyph with a line-tall box, and costs about a microsecond, so that is what
//  the cache is built from.
//

import CoreGraphics
import Foundation
import PDFKit

@MainActor
struct PageTextSelector {

    let pageIndex: Int

    /// The page's text exactly as `PDFPage.string` returns it. Every range this
    /// type accepts or returns indexes into this string (UTF-16 units).
    let pageText: String

    /// Clockwise display rotation applied when mapping to unit space: 0, 90,
    /// 180 or 270. See `init(page:pageIndex:appliesRotation:)`.
    let rotation: Int

    private let cropBox: CGRect
    private let string: NSString

    /// Which way the text runs in unit space. All line and hit-test geometry
    /// lives in a reading frame where text runs left to right and lines stack
    /// downwards, so the same "same line first, then by x" logic works for an
    /// upright page and for sideways text on a rotated one.
    private let reading: ReadingFrame

    /// Reading-frame box for every UTF-16 unit, `.null` for whitespace, line
    /// breaks and anything PDFKit gives no geometry for.
    private let characterRects: [CGRect]

    /// Index into `lines` for every UTF-16 unit, -1 when it has no geometry.
    private let lineOfCharacter: [Int32]

    /// Visual lines in reading (string) order.
    private let lines: [Line]

    /// `lines` indices ordered by vertical centre, for binary search by y.
    private let linesByMidY: [Int]
    private let lineMidYs: [CGFloat]

    /// Half the tallest line's height. Bounds how far from its centre a line
    /// can still be the closest one, which keeps the outward scan short.
    private let maxLineHalfHeight: CGFloat

    /// `pageText` with every intra-paragraph line break replaced by a space
    /// (same length, so ranges carry over). Word and sentence tokenizers treat
    /// a newline as a paragraph end, which would cut every sentence that wraps.
    private let tokenizableText: NSString

    /// True at each line-break unit that sits inside a paragraph.
    private let isSoftBreak: [Bool]

    /// Word and sentence ranges in `pageText`, sorted and non-overlapping.
    private let wordRanges: [NSRange]
    private let sentenceRanges: [NSRange]

    /// A quarter-turn mapping between unit space and the reading frame,
    /// named for the direction text runs in unit space.
    private enum ReadingFrame {
        case rightward, downward, leftward, upward

        func readingPoint(forUnit point: CGPoint) -> CGPoint {
            switch self {
            case .rightward: return point
            case .downward: return CGPoint(x: point.y, y: 1 - point.x)
            case .leftward: return CGPoint(x: 1 - point.x, y: 1 - point.y)
            case .upward: return CGPoint(x: 1 - point.y, y: point.x)
            }
        }

        func unitPoint(forReading point: CGPoint) -> CGPoint {
            switch self {
            case .rightward: return point
            case .downward: return CGPoint(x: 1 - point.y, y: point.x)
            case .leftward: return CGPoint(x: 1 - point.x, y: 1 - point.y)
            case .upward: return CGPoint(x: point.y, y: 1 - point.x)
            }
        }

        func readingRect(forUnit rect: CGRect) -> CGRect {
            Self.bounding(readingPoint(forUnit: CGPoint(x: rect.minX, y: rect.minY)),
                          readingPoint(forUnit: CGPoint(x: rect.maxX, y: rect.maxY)))
        }

        func unitRect(forReading rect: CGRect) -> CGRect {
            Self.bounding(unitPoint(forReading: CGPoint(x: rect.minX, y: rect.minY)),
                          unitPoint(forReading: CGPoint(x: rect.maxX, y: rect.maxY)))
        }

        private static func bounding(_ a: CGPoint, _ b: CGPoint) -> CGRect {
            CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }

        /// The dominant direction from each glyph to the next one in the text,
        /// counting only neighbours close enough to be on the same line.
        static func detect(in rects: [CGRect]) -> ReadingFrame {
            var dx: CGFloat = 0
            var dy: CGFloat = 0
            for index in rects.indices.dropLast() {
                let current = rects[index]
                let next = rects[index + 1]
                guard !current.isNull, !next.isNull else { continue }
                let stepX = next.midX - current.midX
                let stepY = next.midY - current.midY
                let reach = max(current.width, current.height, next.width, next.height) * 3
                guard abs(stepX) <= reach, abs(stepY) <= reach else { continue }
                dx += stepX
                dy += stepY
            }
            if abs(dx) >= abs(dy) { return dx >= 0 ? .rightward : .leftward }
            return dy > 0 ? .downward : .upward
        }
    }

    /// One visual line of glyphs.
    private struct Line {
        /// Union of the line's glyph boxes in the reading frame. Selections use its
        /// vertical extent for every piece of the line so a highlight has one
        /// height no matter which letters it covers.
        var rect: CGRect
        /// Glyph character indices sorted left to right.
        var glyphs: [Int]
        /// `minX` of each entry in `glyphs`, for binary search by x.
        var glyphMinXs: [CGFloat]
    }

    // MARK: - Init

    /// Reads the page's text layer and caches its geometry.
    ///
    /// Returns nil when the crop box is empty or the page has no character
    /// with geometry (a scan without OCR, a figure-only page, a blank page).
    ///
    /// Rotation: with `appliesRotation` (the default) unit space is the page as
    /// displayed, after `page.rotation` turns it clockwise, which is what a
    /// viewer and `PDFPage.draw(with:to:)` show. Pass false to map every page
    /// unrotated, matching code that sizes pages from the raw crop box. Either
    /// way the direction the text runs is detected from the glyphs, so a page
    /// whose text reads sideways in unit space still hit-tests line by line.
    /// `lineRects` are then ordered in reading order (top to bottom for
    /// upright text).
    init?(page: PDFPage, pageIndex: Int, appliesRotation: Bool = true) {
        let cropBox = page.bounds(for: .cropBox).standardized
        guard cropBox.width > 0, cropBox.height > 0, !cropBox.isInfinite else { return nil }
        guard let raw = page.string, !raw.isEmpty else { return nil }

        let string = raw as NSString
        let length = string.length
        let quarterTurns = appliesRotation ? Self.normalizedRotation(page.rotation) : 0

        self.pageIndex = pageIndex
        self.pageText = raw
        self.rotation = quarterTurns
        self.cropBox = cropBox
        self.string = string

        // Per-character boxes from one-character selections (see header).
        var rects = [CGRect](repeating: .null, count: length)
        var glyphCount = 0
        for index in 0..<length {
            let unit = string.character(at: index)
            if Self.isWhitespaceOrBreak(unit) || Self.isControl(unit) { continue }
            guard let selection = page.selection(for: NSRange(location: index, length: 1)) else { continue }
            let bounds = selection.bounds(for: page)
            guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0 || bounds.height > 0 else { continue }
            rects[index] = Self.unitRect(forPageRect: bounds, cropBox: cropBox, quarterTurns: quarterTurns)
            glyphCount += 1
        }
        guard glyphCount > 0 else { return nil }
        let reading = ReadingFrame.detect(in: rects)
        if reading != .rightward {
            for index in rects.indices where !rects[index].isNull {
                rects[index] = reading.readingRect(forUnit: rects[index])
            }
        }
        self.reading = reading
        self.characterRects = rects

        // Line grouping.
        let built = Self.buildLines(page: page, length: length, rects: rects)
        self.lines = built.lines
        self.lineOfCharacter = built.lineOfCharacter

        let order = built.lines.indices.sorted { built.lines[$0].rect.midY < built.lines[$1].rect.midY }
        self.linesByMidY = order
        self.lineMidYs = order.map { built.lines[$0].rect.midY }
        self.maxLineHalfHeight = (built.lines.map(\.rect.height).max() ?? 0) / 2

        // Paragraph-aware text for tokenizing and copying.
        let breaks = Self.classifyLineBreaks(string: string, lineOfCharacter: built.lineOfCharacter, lines: built.lines)
        self.isSoftBreak = breaks
        let tokenizable = NSMutableString(string: string)
        for index in 0..<length where breaks[index] {
            tokenizable.replaceCharacters(in: NSRange(location: index, length: 1), with: " ")
        }
        self.tokenizableText = tokenizable

        let full = NSRange(location: 0, length: length)
        var words: [NSRange] = []
        tokenizable.enumerateSubstrings(in: full, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            words.append(range)
        }
        var sentences: [NSRange] = []
        tokenizable.enumerateSubstrings(in: full, options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            sentences.append(range)
        }
        self.wordRanges = words
        self.sentenceRanges = sentences
    }

    // MARK: - Coordinates

    /// PDF page space (points, y up, crop box) to unit page space.
    func unitPoint(forPagePoint point: CGPoint) -> CGPoint {
        Self.unitPoint(forPagePoint: point, cropBox: cropBox, quarterTurns: rotation)
    }

    /// Unit page space to PDF page space (points, y up, crop box).
    func pagePoint(forUnitPoint point: CGPoint) -> CGPoint {
        let unrotated: CGPoint
        switch rotation {
        case 90: unrotated = CGPoint(x: point.y, y: 1 - point.x)
        case 180: unrotated = CGPoint(x: 1 - point.x, y: 1 - point.y)
        case 270: unrotated = CGPoint(x: 1 - point.y, y: point.x)
        default: unrotated = point
        }
        return CGPoint(
            x: cropBox.minX + unrotated.x * cropBox.width,
            y: cropBox.maxY - unrotated.y * cropBox.height
        )
    }

    /// A page-space rect as the unit-space rect that bounds it.
    func unitRect(forPageRect rect: CGRect) -> CGRect {
        Self.unitRect(forPageRect: rect, cropBox: cropBox, quarterTurns: rotation)
    }

    // MARK: - Hit testing

    /// Number of UTF-16 units in `pageText`.
    var characterCount: Int { string.length }

    /// The cached unit-space box of one character, nil for whitespace, line
    /// breaks and out-of-range indices. Useful for placing selection handles.
    func unitRect(forCharacterAt index: Int) -> CGRect? {
        guard index >= 0, index < characterRects.count else { return nil }
        let rect = characterRects[index]
        guard !rect.isNull, lineOfCharacter[index] >= 0 else { return nil }
        let line = lines[Int(lineOfCharacter[index])].rect
        return reading.unitRect(forReading: CGRect(x: rect.minX, y: line.minY, width: rect.width, height: line.height))
    }

    /// Index of the character under, or nearest to, a unit-space point.
    ///
    /// The line wins first: a finger in the margin beside a line, or in the
    /// leading between two lines, should pick that line rather than whichever
    /// glyph happens to be closest diagonally. So the closest line is chosen by
    /// vertical distance (zero when the point is inside it), ties broken by
    /// horizontal distance, then the closest glyph on that line by x. "Vertical"
    /// and "horizontal" are in the reading frame, so this holds for sideways
    /// text too.
    func characterIndex(nearestTo unitPoint: CGPoint) -> Int? {
        let point = reading.readingPoint(forUnit: unitPoint)
        guard let lineIndex = nearestLine(to: point) else { return nil }
        return nearestGlyph(in: lines[lineIndex], x: point.x)
    }

    // MARK: - Selections

    /// The word at a point (long-press). Punctuation attached to a word is
    /// excluded. When the point lands on punctuation or a space, the closer of
    /// the neighbouring words on the same line is chosen.
    func wordSelection(at unitPoint: CGPoint) -> PageTextSelection? {
        guard let index = characterIndex(nearestTo: unitPoint) else { return nil }
        if let word = wordRange(containing: index) {
            return selection(for: word)
        }
        let line = lineOfCharacter[index]
        let position = Self.lastRange(in: wordRanges, startingAtOrBefore: index)
        var candidates: [NSRange] = []
        if let position {
            candidates.append(wordRanges[position])
            if position + 1 < wordRanges.count { candidates.append(wordRanges[position + 1]) }
        } else if let first = wordRanges.first {
            candidates.append(first)
        }
        let onLine = candidates.filter { range in
            (range.location..<NSMaxRange(range)).contains { lineOfCharacter[$0] == line }
        }
        let x = reading.readingPoint(forUnit: unitPoint).x
        let best = onLine.min { lhs, rhs in
            horizontalDistance(from: x, toWord: lhs, line: line)
                < horizontalDistance(from: x, toWord: rhs, line: line)
        }
        return best.flatMap { selection(for: $0) }
    }

    /// The sentence (or sentences) overlapping a range. A second tap on a word
    /// selection expands to its sentence. Sentences come from the system
    /// tokenizer over paragraph-aware text, so a sentence that wraps across
    /// lines stays whole while a heading stays separate from the paragraph
    /// below it.
    func sentenceSelection(containing range: NSRange) -> PageTextSelection? {
        let clamped = clamp(range)
        guard clamped.location < string.length else { return nil }
        let start = clamped.location
        let end = max(start, NSMaxRange(clamped) - 1)
        var lower: Int?
        var upper: Int?
        for sentence in sentenceRanges where sentence.location <= end && NSMaxRange(sentence) > start {
            lower = min(lower ?? sentence.location, sentence.location)
            upper = max(upper ?? NSMaxRange(sentence), NSMaxRange(sentence))
        }
        guard let lower, let upper else { return selection(for: clamped) }
        return selection(for: NSRange(location: lower, length: upper - lower))
    }

    /// Selection between two character indices, inclusive, in either order
    /// (dragged handles can cross). With `snapToWords` each end grows to the
    /// boundary of the word it falls in; an end on a space or punctuation stays
    /// where it is.
    func selection(from first: Int, to second: Int, snapToWords: Bool) -> PageTextSelection? {
        let length = string.length
        guard length > 0 else { return nil }
        var lower = min(max(min(first, second), 0), length - 1)
        var upper = min(max(max(first, second), 0), length - 1)
        if snapToWords {
            if let word = wordRange(containing: lower) { lower = word.location }
            if let word = wordRange(containing: upper) { upper = NSMaxRange(word) - 1 }
        }
        return selection(for: NSRange(location: lower, length: upper - lower + 1))
    }

    /// Rebuilds a selection from a stored character range (redrawing a saved
    /// highlight). Leading and trailing whitespace is trimmed and partial
    /// composed characters are widened, so the result's `range` is canonical:
    /// feeding it back in yields an equal selection. Nil when nothing visible
    /// remains.
    func selection(for range: NSRange) -> PageTextSelection? {
        var clamped = clamp(range)
        guard clamped.length > 0 else { return nil }
        clamped = string.rangeOfComposedCharacterSequences(for: clamped)

        var lower = clamped.location
        var upper = NSMaxRange(clamped)
        while lower < upper, Self.isWhitespaceOrBreak(string.character(at: lower)) { lower += 1 }
        while upper > lower, Self.isWhitespaceOrBreak(string.character(at: upper - 1)) { upper -= 1 }
        guard upper > lower else { return nil }
        let trimmed = NSRange(location: lower, length: upper - lower)

        let rects = lineRects(for: trimmed)
        guard !rects.isEmpty else { return nil }
        return PageTextSelection(
            pageIndex: pageIndex,
            range: trimmed,
            text: copyText(for: trimmed),
            lineRects: rects
        )
    }

    // MARK: - Line rects

    /// One rect per visual line: horizontally tight to the selected glyphs,
    /// vertically the full line so every piece of a highlight on that line has
    /// the same height. Whitespace and line breaks contribute nothing, so a
    /// selection that ends on a newline cannot grow a stray box.
    private func lineRects(for range: NSRange) -> [CGRect] {
        var spans: [Int: (minX: CGFloat, maxX: CGFloat)] = [:]
        for index in range.location..<NSMaxRange(range) {
            let line = Int(lineOfCharacter[index])
            guard line >= 0 else { continue }
            let rect = characterRects[index]
            if let span = spans[line] {
                spans[line] = (min(span.minX, rect.minX), max(span.maxX, rect.maxX))
            } else {
                spans[line] = (rect.minX, rect.maxX)
            }
        }
        var rects = spans.map { line, span in
            let box = lines[line].rect
            return CGRect(x: span.minX, y: box.minY, width: span.maxX - span.minX, height: box.height)
        }
        rects.sort { lhs, rhs in
            abs(lhs.midY - rhs.midY) > 0.0001 ? lhs.midY < rhs.midY : lhs.minX < rhs.minX
        }

        // Tight leading or a tall glyph can make neighbouring lines overlap;
        // painted translucently that overlap shows as a darker band, so split
        // it down the middle.
        if rects.count > 1 {
            for index in 0..<(rects.count - 1) {
                let upperRect = rects[index]
                let lowerRect = rects[index + 1]
                let overlapsHorizontally = upperRect.minX < lowerRect.maxX && lowerRect.minX < upperRect.maxX
                guard overlapsHorizontally, upperRect.maxY > lowerRect.minY, upperRect.minY < lowerRect.minY else { continue }
                let split = (upperRect.maxY + lowerRect.minY) / 2
                rects[index] = CGRect(x: upperRect.minX, y: upperRect.minY, width: upperRect.width, height: split - upperRect.minY)
                rects[index + 1] = CGRect(x: lowerRect.minX, y: split, width: lowerRect.width, height: lowerRect.maxY - split)
            }
        }
        return rects.map { reading.unitRect(forReading: $0) }
    }

    // MARK: - Copy text

    /// The selected text with line breaks inside a paragraph turned into single
    /// spaces and paragraph breaks kept as one newline. A line that ends in a
    /// hyphen joins the next line directly, keeping the hyphen as printed:
    /// "fore-" + "edge" copies as "fore-edge", never "fore- edge".
    private func copyText(for range: NSRange) -> String {
        var output: [unichar] = []
        output.reserveCapacity(range.length)
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            let unit = string.character(at: index)
            guard Self.isLineBreak(unit) else {
                output.append(unit)
                index += 1
                continue
            }
            // Consume the whole run of breaks (\r\n, blank lines) as one.
            var soft = true
            while index < end, Self.isLineBreak(string.character(at: index)) {
                soft = soft && isSoftBreak[index]
                index += 1
            }
            while let last = output.last, last == 0x20 || last == 0x09 { output.removeLast() }
            while index < end, string.character(at: index) == 0x20 || string.character(at: index) == 0x09 { index += 1 }
            if !soft {
                output.append(0x0A)
            } else if let last = output.last, !Self.isHyphen(last) {
                output.append(0x20)
            }
        }
        return String(utf16CodeUnits: output, count: output.count)
    }

    // MARK: - Lookup helpers

    private func clamp(_ range: NSRange) -> NSRange {
        let length = string.length
        guard range.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let lower = min(max(range.location, 0), length)
        let upper = min(max(range.location + max(range.length, 0), lower), length)
        return NSRange(location: lower, length: upper - lower)
    }

    private func wordRange(containing index: Int) -> NSRange? {
        guard let position = Self.lastRange(in: wordRanges, startingAtOrBefore: index) else { return nil }
        let word = wordRanges[position]
        return index < NSMaxRange(word) ? word : nil
    }

    private func horizontalDistance(from x: CGFloat, toWord word: NSRange, line: Int32) -> CGFloat {
        var minX = CGFloat.infinity
        var maxX = -CGFloat.infinity
        for index in word.location..<NSMaxRange(word) where lineOfCharacter[index] == line {
            minX = min(minX, characterRects[index].minX)
            maxX = max(maxX, characterRects[index].maxX)
        }
        guard minX <= maxX else { return .infinity }
        return max(minX - x, x - maxX, 0)
    }

    /// The line closest to a point: least vertical distance, then least
    /// horizontal distance. Starts at the binary-search position of `y` among
    /// line centres and walks outwards only while a line could still beat the
    /// best found, so a drag costs O(log n) plus a handful of comparisons.
    private func nearestLine(to point: CGPoint) -> Int? {
        guard !linesByMidY.isEmpty else { return nil }
        var low = 0
        var high = lineMidYs.count
        while low < high {
            let mid = (low + high) / 2
            if lineMidYs[mid] < point.y { low = mid + 1 } else { high = mid }
        }

        let tolerance: CGFloat = 0.000_1
        var best: (line: Int, vertical: CGFloat, horizontal: CGFloat)?
        func consider(_ sortedPosition: Int) {
            let line = linesByMidY[sortedPosition]
            let rect = lines[line].rect
            let vertical = max(rect.minY - point.y, point.y - rect.maxY, 0)
            let horizontal = max(rect.minX - point.x, point.x - rect.maxX, 0)
            guard let current = best else {
                best = (line, vertical, horizontal)
                return
            }
            if vertical < current.vertical - tolerance
                || (abs(vertical - current.vertical) <= tolerance && horizontal < current.horizontal) {
                best = (line, vertical, horizontal)
            }
        }
        func canStillWin(_ sortedPosition: Int) -> Bool {
            guard let current = best else { return true }
            let lowestPossible = abs(lineMidYs[sortedPosition] - point.y) - maxLineHalfHeight
            return lowestPossible <= current.vertical + tolerance
        }

        var down = low
        var up = low - 1
        while down < lineMidYs.count || up >= 0 {
            var progressed = false
            if down < lineMidYs.count, canStillWin(down) {
                consider(down)
                down += 1
                progressed = true
            } else {
                down = lineMidYs.count
            }
            if up >= 0, canStillWin(up) {
                consider(up)
                up -= 1
                progressed = true
            } else {
                up = -1
            }
            if !progressed { break }
        }
        return best?.line
    }

    /// The glyph on a line closest to `x`: binary search for the last glyph
    /// starting at or before `x`, then compare it with its right neighbour.
    private func nearestGlyph(in line: Line, x: CGFloat) -> Int? {
        guard !line.glyphs.isEmpty else { return nil }
        var low = 0
        var high = line.glyphMinXs.count
        while low < high {
            let mid = (low + high) / 2
            if line.glyphMinXs[mid] <= x { low = mid + 1 } else { high = mid }
        }
        let candidates = [low - 1, low].filter { $0 >= 0 && $0 < line.glyphs.count }
        return candidates.map { line.glyphs[$0] }.min { lhs, rhs in
            let left = characterRects[lhs]
            let right = characterRects[rhs]
            return max(left.minX - x, x - left.maxX, 0) < max(right.minX - x, x - right.maxX, 0)
        }
    }

    /// Position of the last range whose location is at or before `index`, in a
    /// sorted, non-overlapping list.
    private static func lastRange(in ranges: [NSRange], startingAtOrBefore index: Int) -> Int? {
        var low = 0
        var high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].location <= index { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? low - 1 : nil
    }

    // MARK: - Building lines

    /// Groups glyphs into visual lines.
    ///
    /// PDFKit's `selectionsByLine()` already knows the page's lines and their
    /// reading order, so its character ranges are used first. Pieces it splits
    /// one line into (a justified line with a large gap, a run in another font)
    /// are merged when they sit side by side at the same height and follow one
    /// another in the text. Any glyph PDFKit leaves out is then clustered
    /// geometrically so nothing on the page becomes unselectable.
    private static func buildLines(page: PDFPage, length: Int, rects: [CGRect]) -> (lines: [Line], lineOfCharacter: [Int32]) {
        var assigned = [Bool](repeating: false, count: length)
        var groups: [[Int]] = []

        if let all = page.selection(for: NSRange(location: 0, length: length)) {
            for piece in all.selectionsByLine() {
                var glyphs: [Int] = []
                let rangeCount = piece.numberOfTextRanges(on: page)
                for rangeIndex in 0..<rangeCount {
                    let range = piece.range(at: rangeIndex, on: page)
                    guard range.location != NSNotFound, range.location < length else { continue }
                    let upper = min(NSMaxRange(range), length)
                    for index in range.location..<upper where !assigned[index] && !rects[index].isNull {
                        assigned[index] = true
                        glyphs.append(index)
                    }
                }
                guard !glyphs.isEmpty else { continue }
                if let previous = groups.last, continuesLine(previous, with: glyphs, rects: rects) {
                    groups[groups.count - 1].append(contentsOf: glyphs)
                } else {
                    groups.append(glyphs)
                }
            }
        }

        // Geometric fallback for glyphs PDFKit did not place on any line.
        var leftover: [Int] = []
        for index in 0..<length where !assigned[index] && !rects[index].isNull {
            if let lastIndex = leftover.last {
                let last = rects[lastIndex]
                let current = rects[index]
                let sameRow = verticalOverlapRatio(last, current) >= 0.5
                let movesForward = current.minX >= last.minX - min(last.height, current.height) * 0.5
                if !(sameRow && movesForward) {
                    groups.append(leftover)
                    leftover = []
                }
            }
            leftover.append(index)
        }
        if !leftover.isEmpty { groups.append(leftover) }

        var lines: [Line] = []
        var lineOfCharacter = [Int32](repeating: -1, count: length)
        for group in groups {
            let sorted = group.sorted { rects[$0].minX < rects[$1].minX }
            let bounds = sorted.dropFirst().reduce(rects[sorted[0]]) { $0.union(rects[$1]) }
            for index in sorted { lineOfCharacter[index] = Int32(lines.count) }
            lines.append(Line(rect: bounds, glyphs: sorted, glyphMinXs: sorted.map { rects[$0].minX }))
        }
        return (lines, lineOfCharacter)
    }

    /// Whether a new piece of text belongs to the same visual line as the
    /// previous one: mostly the same height band, and starting to its right.
    private static func continuesLine(_ previous: [Int], with next: [Int], rects: [CGRect]) -> Bool {
        let previousBox = previous.dropFirst().reduce(rects[previous[0]]) { $0.union(rects[$1]) }
        let nextBox = next.dropFirst().reduce(rects[next[0]]) { $0.union(rects[$1]) }
        guard verticalOverlapRatio(previousBox, nextBox) >= 0.5 else { return false }
        return nextBox.minX >= previousBox.maxX - min(previousBox.height, nextBox.height) * 0.25
    }

    private static func verticalOverlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        let smaller = min(lhs.height, rhs.height)
        guard smaller > 0 else { return overlap >= 0 ? 1 : 0 }
        return max(overlap, 0) / smaller
    }

    // MARK: - Paragraphs

    /// Marks each line-break unit as soft (inside a paragraph) or hard.
    ///
    /// PDF text has no paragraph markup, so this reads the layout the way a
    /// person would: a break is a paragraph end when the next line starts
    /// noticeably lower than the usual line spacing, when the type size
    /// changes (heading to body), or when the next line is indented relative
    /// to the previous one (a first-line indent). Everything else is a wrap.
    private static func classifyLineBreaks(string: NSString, lineOfCharacter: [Int32], lines: [Line]) -> [Bool] {
        let length = string.length
        var soft = [Bool](repeating: false, count: length)

        // Typical gap between consecutive lines that follow one another down
        // the page, measured relative to line height so mixed sizes compare.
        var relativeGaps: [CGFloat] = []
        if lines.count > 1 {
            for index in 1..<lines.count {
                let upper = lines[index - 1].rect
                let lower = lines[index].rect
                guard lower.minY >= upper.midY, upper.height > 0 else { continue }
                relativeGaps.append((lower.minY - upper.maxY) / upper.height)
            }
        }
        relativeGaps.sort()
        let typicalGap = relativeGaps.isEmpty ? 0 : relativeGaps[relativeGaps.count / 2]

        var previousLine: Int32 = -1
        var index = 0
        while index < length {
            let unit = string.character(at: index)
            if lineOfCharacter[index] >= 0 {
                previousLine = lineOfCharacter[index]
                index += 1
                continue
            }
            guard isLineBreak(unit) else {
                index += 1
                continue
            }
            // A run of breaks (\r\n or a blank line) is judged as one.
            let runStart = index
            var breakCount = 0
            var nextLine: Int32 = -1
            var scan = index
            while scan < length {
                let current = string.character(at: scan)
                if lineOfCharacter[scan] >= 0 { nextLine = lineOfCharacter[scan]; break }
                if isLineBreak(current) {
                    // \r\n is one break, not two.
                    if !(current == 0x0A && scan > 0 && string.character(at: scan - 1) == 0x0D) { breakCount += 1 }
                }
                scan += 1
            }
            var isSoft = false
            if breakCount == 1, previousLine >= 0, nextLine >= 0, previousLine != nextLine {
                isSoft = !isParagraphBreak(from: lines[Int(previousLine)].rect, to: lines[Int(nextLine)].rect, typicalGap: typicalGap)
            }
            for position in runStart..<scan where isLineBreak(string.character(at: position)) {
                soft[position] = isSoft
            }
            index = scan
        }
        return soft
    }

    private static func isParagraphBreak(from upper: CGRect, to lower: CGRect, typicalGap: CGFloat) -> Bool {
        let height = min(upper.height, lower.height)
        guard height > 0 else { return true }
        // Type size changed: a heading, caption or title is its own paragraph.
        if abs(upper.height - lower.height) > max(upper.height, lower.height) * 0.15 { return true }
        // The next line continues further down the same column.
        if lower.minY >= upper.midY {
            let gap = (lower.minY - upper.maxY) / upper.height
            if gap > typicalGap + 0.3 { return true }
            if lower.minX - upper.minX > height * 0.5 { return true }
        }
        return false
    }

    // MARK: - Characters

    private static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C
            || unit == 0x85 || unit == 0x2028 || unit == 0x2029
    }

    private static func isWhitespaceOrBreak(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func isControl(_ unit: unichar) -> Bool {
        unit < 0x20 || (unit >= 0x7F && unit < 0xA0)
    }

    /// Hyphen-minus, soft hyphen, hyphen and non-breaking hyphen.
    private static func isHyphen(_ unit: unichar) -> Bool {
        unit == 0x2D || unit == 0xAD || unit == 0x2010 || unit == 0x2011
    }

    // MARK: - Mapping

    /// Snaps `PDFPage.rotation` to 0, 90, 180 or 270.
    private static func normalizedRotation(_ degrees: Int) -> Int {
        let wrapped = ((degrees % 360) + 360) % 360
        return ((wrapped + 45) / 90 % 4) * 90
    }

    /// Unrotated unit space first (crop box, y flipped), then the page's
    /// clockwise display rotation.
    private static func unitPoint(forPagePoint point: CGPoint, cropBox: CGRect, quarterTurns: Int) -> CGPoint {
        let u = (point.x - cropBox.minX) / cropBox.width
        let v = (cropBox.maxY - point.y) / cropBox.height
        switch quarterTurns {
        case 90: return CGPoint(x: 1 - v, y: u)
        case 180: return CGPoint(x: 1 - u, y: 1 - v)
        case 270: return CGPoint(x: v, y: 1 - u)
        default: return CGPoint(x: u, y: v)
        }
    }

    private static func unitRect(forPageRect rect: CGRect, cropBox: CGRect, quarterTurns: Int) -> CGRect {
        let standard = rect.standardized
        let a = unitPoint(forPagePoint: CGPoint(x: standard.minX, y: standard.minY), cropBox: cropBox, quarterTurns: quarterTurns)
        let b = unitPoint(forPagePoint: CGPoint(x: standard.maxX, y: standard.maxY), cropBox: cropBox, quarterTurns: quarterTurns)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
