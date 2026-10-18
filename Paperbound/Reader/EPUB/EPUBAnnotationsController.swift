//
//  EPUBAnnotationsController.swift
//  Paperbound
//
//  Highlights on EPUB, with the PDF reader's action bar and rules.
//
//  The text selection itself is Readium's: the web view's native selection,
//  handles and all. Readium reports it through `EPUBNavigatorBridge` as a
//  `Locator` carrying a text quote and a frame; we suppress the system edit
//  menu and show `HighlightActionBar` at that frame instead.
//
//  The rules are the ones `PagedReaderView.applyMark` implements for PDFs:
//
//    on a selection   a style already under it comes off; a new style goes on
//                     in the colour already there; a colour recolours the marks
//                     under it, or marks it fresh. Marks under the selection
//                     show as chosen. Clear removes every mark it overlaps. The
//                     selection stays open after a tap.
//    on a mark        tapping a mark (a decoration) opens it in edit mode with
//                     Delete; its own style again removes it.
//    elsewhere        tapping outside closes the bar.
//
//  "Under the selection" is answered with `EPUBTextRange`s (resource href +
//  range in the chapter's canonical text, EPUBAnnotationsAnchor.swift), never
//  with screen rects, so it holds at any font size.
//
//  Marks are stored as `Highlight`s whose `locatorJSON` is the Readium
//  locator Readium draws the decoration from.
//

import Foundation
import Observation
import ReadiumNavigator
import ReadiumShared
import SwiftData
import UIKit

/// What the reader has selected in the EPUB navigator.
struct EPUBTextSelection: Equatable {
    /// Readium's locator for the selection: href plus the text quote.
    var locator: Locator
    /// Bounding rect of the selection, in window coordinates.
    var frame: CGRect?
    /// Where the quote sits in its resource, once anchored.
    var range: EPUBTextRange?

    var text: String { locator.text.highlight ?? "" }
}

@MainActor
@Observable
final class EPUBAnnotationsController {

    private(set) var selection: EPUBTextSelection?
    /// A saved mark opened for restyling or deletion.
    private(set) var editingMarkID: UUID?
    /// The open mark's rect, window coordinates, from the tap that opened it.
    private(set) var editingFrame: CGRect?
    /// The search result currently flashed, if any.
    private(set) var flashedSearchResultID: UUID?

    @ObservationIgnored private weak var model: ReaderViewModel?
    /// Canonical text per resource (normalized href), read on demand.
    @ObservationIgnored private var resourceTexts: [String: String] = [:]
    @ObservationIgnored private var selectionWatch: Task<Void, Never>?
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var copyTask: Task<Void, Never>?
    @ObservationIgnored private var isInstalled = false

    init() {}

    private var bridge: EPUBNavigatorBridge? { model?.epubBridge }

    // MARK: - Setup

    /// Wires the controller to the open book's navigator bridge. Call once,
    /// before the first navigator is created: decoration templates are
    /// creation-time configuration.
    func install(model: ReaderViewModel) {
        guard !isInstalled else { return }
        isInstalled = true
        self.model = model
        let bridge = model.epubBridge
        bridge.decorationTemplates = EPUBAnnotationDecorations.templates()
        bridge.shouldShowMenuForSelection = { [weak self] selection in
            self?.selectionDidChange(locator: selection.locator, frame: selection.frame)
            return false
        }
        bridge.onSelectionChange = { [weak self] selection in
            if let selection {
                self?.selectionDidChange(locator: selection.locator, frame: selection.frame)
            } else {
                self?.selectionDidClear()
            }
        }
        bridge.observeDecorationInteractions(inGroup: EPUBAnnotationDecorations.highlightsGroup) { [weak self] event in
            self?.markActivated(id: event.decoration.id, rect: event.rect)
        }
        bridge.tapInterceptor = { [weak self] _ in
            self?.dismissForTap() ?? false
        }
        bridge.addLocationObserver { [weak self] _ in
            // The open mark's rect belongs to the page that just went away.
            if self?.editingMarkID != nil { self?.closeEditing() }
        }
        refreshDecorations()
        #if DEBUG
        bridge.whenAttached { [weak self] _ in self?.runDemoIfRequested() }
        #endif
    }

    // MARK: - Selection

    func selectionDidChange(locator: Locator, frame: CGRect?) {
        guard !(locator.text.highlight ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            selectionDidClear()
            return
        }
        if editingMarkID != nil { closeEditing() }
        copyTask?.cancel()
        var next = EPUBTextSelection(locator: locator, frame: frame.map(windowRect(fromNavigator:)), range: nil)
        if let (range, resolved) = anchorFromCache(locator) {
            next.range = range
            next.locator = resolved
        }
        guard next != selection else { return }
        selection = next
        if next.range == nil {
            Task { [weak self] in
                guard let self else { return }
                await self.loadTexts(around: locator.href.string)
                guard var current = self.selection, current.locator == locator,
                      let (range, resolved) = self.anchorFromCache(locator) else { return }
                current.range = range
                current.locator = resolved
                self.selection = current
            }
        }
        watchSelection()
    }

    func selectionDidClear() {
        selectionWatch?.cancel()
        selectionWatch = nil
        if selection != nil { selection = nil }
    }

    /// Readium reports a selection appearing, but not the web view dropping
    /// it after a tap elsewhere. Poll the navigator while one is open.
    private func watchSelection() {
        guard selectionWatch == nil else { return }
        selectionWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                guard self.selection != nil else { break }
                if let bridge = self.bridge, bridge.isAttached, bridge.currentSelection == nil {
                    self.selection = nil
                    break
                }
            }
            self?.selectionWatch = nil
        }
    }

    /// Clears our selection and the web view's.
    func clearSelection() {
        selectionDidClear()
        bridge?.navigator?.clearSelection()
    }

    // MARK: - Editing a saved mark

    func markActivated(id: String, rect: CGRect?) {
        guard let uuid = UUID(uuidString: id), model?.highlight(withID: uuid) != nil else { return }
        clearSelection()
        editingMarkID = uuid
        editingFrame = rect.map(windowRect(fromNavigator:))
        refreshDecorations()
    }

    /// Readium reports rects in the navigator view's coordinates; the overlay
    /// sits over the whole reader, so rects are kept in window coordinates.
    private func windowRect(fromNavigator rect: CGRect) -> CGRect {
        guard let view = bridge?.navigator?.view, view.window != nil else { return rect }
        return view.convert(rect, to: nil)
    }

    func closeEditing() {
        guard editingMarkID != nil else { return }
        editingMarkID = nil
        editingFrame = nil
        refreshDecorations()
    }

    /// A tap on the page: closes an open bar and swallows the tap, so closing
    /// the bar does not also turn the page or toggle the controls.
    func dismissForTap() -> Bool {
        if editingMarkID != nil {
            closeEditing()
            return true
        }
        if selection != nil {
            clearSelection()
            return true
        }
        return false
    }

    /// Closes everything, e.g. when the reader leaves.
    func clearAll() {
        clearSelection()
        closeEditing()
    }

    // MARK: - The action bar

    /// The bar's contents, or nil when there is nothing to show. `anchor` is
    /// in window coordinates.
    var bar: ReaderAnnotationOverlay.Bar? {
        guard let model else { return nil }
        if let selection, let frame = selection.frame, !frame.isEmpty {
            let covered = highlights(overlapping: selection)
            return ReaderAnnotationOverlay.Bar(
                mode: .create,
                style: covered.last?.style ?? model.lastHighlightStyle,
                color: covered.last?.color ?? model.lastHighlightColor,
                chosenStyles: Set(covered.map(\.style)),
                chosenColors: Set(covered.map(\.color)),
                canRemove: !covered.isEmpty,
                anchor: frame
            )
        }
        if let id = editingMarkID, let highlight = model.highlight(withID: id), let frame = editingFrame {
            return ReaderAnnotationOverlay.Bar(
                mode: .edit, style: highlight.style, color: highlight.color,
                chosenStyles: [highlight.style], chosenColors: [highlight.color], canRemove: true,
                anchor: frame
            )
        }
        return nil
    }

    /// Style and colour taps, with exactly the PDF reader's rules (see the
    /// file comment and `PagedReaderView.applyMark`).
    func applyMark(style: HighlightStyle? = nil, color: HighlightColor? = nil) {
        guard let model else { return }
        if let id = editingMarkID {
            if let style, model.highlight(withID: id)?.style == style {
                model.deleteHighlight(id)
                editingMarkID = nil
                editingFrame = nil
            } else {
                model.restyleHighlight(id, style: style, color: color)
            }
            refreshDecorations()
            return
        }
        guard let selection = currentSelectionAnchored() else { return }
        let covered = highlights(overlapping: selection)
        if let style {
            let matching = covered.filter { $0.style == style }
            if matching.isEmpty {
                addHighlight(selection, style: style, color: covered.last?.color ?? model.lastHighlightColor)
            } else {
                model.deleteHighlights(matching.map(\.id))
            }
        } else if let color {
            if covered.isEmpty {
                addHighlight(selection, style: model.lastHighlightStyle, color: color)
            } else {
                covered.forEach { model.restyleHighlight($0.id, color: color) }
            }
        }
        refreshDecorations()
    }

    func copyText() {
        let text = selection.map { EPUBAnnotationsController.cleanQuote($0.text) }
            ?? editingMarkID.flatMap { model?.highlight(withID: $0)?.quotedText }
        if let text, !text.isEmpty { UIPasteboard.general.string = text }
        // Long enough to read the bar's "Copied" before it goes.
        let selected = selection?.locator
        let editing = editingMarkID
        copyTask?.cancel()
        copyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard let self, !Task.isCancelled,
                  self.selection?.locator == selected, self.editingMarkID == editing else { return }
            self.clearSelection()
            self.closeEditing()
        }
    }

    /// Delete on an open mark; Clear on a selection (which stays, so the text
    /// can be marked afresh).
    func removeMarks() {
        guard let model else { return }
        if let id = editingMarkID {
            model.deleteHighlight(id)
            editingMarkID = nil
            editingFrame = nil
        } else if let selection = currentSelectionAnchored() {
            model.deleteHighlights(highlights(overlapping: selection).map(\.id))
        }
        refreshDecorations()
    }

    // MARK: - Marks

    /// The book's EPUB marks.
    var epubHighlights: [Highlight] {
        model?.book.highlights.filter { $0.locatorJSON != nil } ?? []
    }

    /// Saved marks under a selection, oldest first.
    func highlights(overlapping selection: EPUBTextSelection) -> [Highlight] {
        Self.highlights(
            overlapping: selection.range,
            href: selection.locator.href.string,
            quote: selection.text,
            in: epubHighlights,
            anchor: { [weak self] highlight in self?.range(of: highlight) }
        )
    }

    /// The overlap rule, kept pure for tests.
    ///
    /// Same resource, and the canonical ranges intersect. Only when a range is
    /// unknown on either side (the chapter text could not be read) does it
    /// fall back to the quotes: one containing the other.
    static func highlights(
        overlapping range: EPUBTextRange?,
        href: String,
        quote: String,
        in highlights: [Highlight],
        anchor: (Highlight) -> EPUBTextRange?
    ) -> [Highlight] {
        let selectedQuote = EPUBTextAnchor.canonical(quote)
        return highlights
            .filter { highlight in
                guard let markHref = highlight.location.epubHref,
                      EPUBTextAnchor.sameResource(markHref, href) else { return false }
                if let range, let markRange = anchor(highlight) {
                    return range.overlaps(markRange)
                }
                let markQuote = EPUBTextAnchor.canonical(highlight.epubLocator?.text.highlight ?? highlight.quotedText)
                guard !selectedQuote.isEmpty, !markQuote.isEmpty else { return false }
                return markQuote.contains(selectedQuote) || selectedQuote.contains(markQuote)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// A mark's range: the stored one, or anchored now from cached text.
    private func range(of highlight: Highlight) -> EPUBTextRange? {
        if let stored = highlight.epubTextRange { return stored }
        guard let locator = highlight.epubLocator else { return nil }
        return anchorFromCache(locator)?.0
    }

    @discardableResult
    private func addHighlight(_ selection: EPUBTextSelection, style: HighlightStyle, color: HighlightColor) -> Highlight? {
        guard let model, let context = model.book.modelContext else { return nil }
        let highlight = Self.makeHighlight(
            from: selection, style: style, color: color,
            engine: model.epubEngine,
            resourceTextLength: selection.range.flatMap { resourceTexts[EPUBTextAnchor.normalizedHref($0.href)] }
                .map { ($0 as NSString).length }
        )
        highlight.book = model.book
        context.insert(highlight)
        // Remembers the style and colour for next time, and saves.
        model.restyleHighlight(highlight.id, style: style, color: color)
        return highlight
    }

    /// Builds the record for a selection. The stored locator keeps Readium's
    /// quote (what the decoration is anchored on) but drops any CSS selector
    /// from the page it was made on, and carries a progression computed from
    /// where the quote sits in its chapter, so marks sort in reading order.
    static func makeHighlight(
        from selection: EPUBTextSelection,
        style: HighlightStyle,
        color: HighlightColor,
        engine: EPUBReadingEngine?,
        resourceTextLength: Int?
    ) -> Highlight {
        var locator = storedLocator(for: selection, engine: engine, resourceTextLength: resourceTextLength)
        // Go through JSON once, so the location and `locatorJSON` hold the
        // very same numbers (a double can shift in its last digit).
        if let json = try? locator.jsonString(), let parsed = try? Locator(jsonString: json) {
            locator = parsed
        }
        let location = ReadingLocation(locator: locator)
        let highlight = Highlight(
            quotedText: cleanQuote(selection.text),
            color: color,
            style: style,
            location: location,
            normalizedRects: [],
            characterRange: selection.range?.range,
            orderKey: engine?.orderKey(for: location) ?? (locator.locations.totalProgression ?? 0) * 1_000_000
        )
        highlight.locatorJSON = (try? locator.jsonString()) ?? location.locatorJSONString
        return highlight
    }

    static func storedLocator(
        for selection: EPUBTextSelection, engine: EPUBReadingEngine?, resourceTextLength: Int?
    ) -> Locator {
        let source = selection.locator
        var progression = source.locations.progression
        if let range = selection.range, let length = resourceTextLength, length > 0 {
            progression = min(max(Double(range.range.location) / Double(length), 0), 1)
        }
        var totalProgression = source.locations.totalProgression
        var position = source.locations.position
        if let engine, let progression,
           let span = engine.totalProgressionSpan(ofResource: source.href.string) {
            totalProgression = span.lowerBound + (span.upperBound - span.lowerBound) * progression
            let probe = Locator(href: source.href, mediaType: source.mediaType,
                                locations: .init(progression: progression))
            position = engine.positionIndex(for: ReadingLocation(locator: probe)).map { $0 + 1 }
        }
        return Locator(
            href: source.href,
            mediaType: source.mediaType,
            title: source.title,
            locations: .init(progression: progression, totalProgression: totalProgression, position: position),
            text: source.text
        )
    }

    /// The quote as a reader would copy it: line breaks and runs of spaces
    /// collapsed, ends trimmed.
    static func cleanQuote(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Redraws every saved mark. Cheap: Readium diffs by decoration id.
    func refreshDecorations() {
        bridge?.apply(
            EPUBAnnotationDecorations.decorations(for: epubHighlights, activeID: editingMarkID),
            in: EPUBAnnotationDecorations.highlightsGroup
        )
    }

    // MARK: - Search

    /// Marks a search result for a few seconds after jumping to it.
    func flash(_ result: ReadingSearchResult, for duration: Duration = .seconds(3)) {
        guard let decoration = EPUBAnnotationDecorations.searchDecoration(for: result) else { return }
        flashTask?.cancel()
        flashedSearchResultID = result.id
        bridge?.apply([decoration], in: EPUBAnnotationDecorations.searchGroup)
        var seconds = duration
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["PAPERBOUND_DEMO_EPUB_FLASH_SECONDS"].flatMap(Double.init) {
            seconds = .milliseconds(Int(override * 1000))
        }
        #endif
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: seconds)
            guard let self, !Task.isCancelled else { return }
            self.bridge?.apply([], in: EPUBAnnotationDecorations.searchGroup)
            self.flashedSearchResultID = nil
        }
    }

    // MARK: - Anchoring

    /// The selection, anchored now if its chapter text has arrived since.
    private func currentSelectionAnchored() -> EPUBTextSelection? {
        guard var selection else { return nil }
        if selection.range == nil, let (range, resolved) = anchorFromCache(selection.locator) {
            selection.range = range
            selection.locator = resolved
            self.selection = selection
        }
        return selection
    }

    /// Anchors a quote in already-loaded chapter text. Tries the locator's own
    /// resource first, then its neighbours in the reading order: on a
    /// two-page spread Readium labels a selection with the spread's current
    /// location, which may be the other chapter. Returns the range and the
    /// locator with its href corrected.
    func anchorFromCache(_ locator: Locator) -> (EPUBTextRange, Locator)? {
        guard let highlight = locator.text.highlight, !highlight.isEmpty else { return nil }
        for href in candidateHrefs(around: locator.href.string) {
            guard let text = resourceTexts[EPUBTextAnchor.normalizedHref(href)] else { continue }
            let sameAsLocator = EPUBTextAnchor.sameResource(href, locator.href.string)
            guard let range = EPUBTextAnchor.locate(
                highlight: highlight, before: locator.text.before, after: locator.text.after,
                in: text, progressionHint: sameAsLocator ? locator.locations.progression : nil
            ) else { continue }
            var resolved = locator
            if !sameAsLocator, let url = AnyURL(string: href) {
                resolved = Locator(href: url, mediaType: locator.mediaType, title: locator.title,
                                   locations: .init(), text: locator.text)
            }
            return (EPUBTextRange(href: resolved.href.string, range: range), resolved)
        }
        return nil
    }

    private func candidateHrefs(around href: String) -> [String] {
        guard let links = model?.epubEngine?.publication?.readingOrder else { return [href] }
        let hrefs = links.map(\.href)
        guard let index = hrefs.firstIndex(where: { EPUBTextAnchor.sameResource($0, href) }) else { return [href] }
        return [index, index + 1, index - 1].filter { hrefs.indices.contains($0) }.map { hrefs[$0] }
    }

    /// Reads and canonicalizes a resource and its neighbours, once each.
    func loadTexts(around href: String) async {
        for candidate in candidateHrefs(around: href) {
            await loadText(ofResource: candidate)
        }
    }

    func loadText(ofResource href: String) async {
        let key = EPUBTextAnchor.normalizedHref(href)
        guard resourceTexts[key] == nil,
              let publication = model?.epubEngine?.publication,
              let url = AnyURL(string: href),
              let resource = publication.get(url) else { return }
        guard case let .success(data) = await resource.read() else { return }
        let html = String(decoding: data, as: UTF8.self)
        resourceTexts[key] = EPUBTextAnchor.canonicalText(fromHTML: html)
    }

    /// For tests and the demo: chapter text already read.
    func cachedText(ofResource href: String) -> String? {
        resourceTexts[EPUBTextAnchor.normalizedHref(href)]
    }

    // MARK: - Demo staging

    #if DEBUG
    /// Stages marks and a selection for screenshots: the simulator cannot
    /// long-press a web view.
    ///
    ///   PAPERBOUND_DEMO_EPUB_PAGE=n     first go to position n (1-based)
    ///   PAPERBOUND_DEMO_EPUB_MARKS=1    one mark per style on the first
    ///                                   paragraph on screen, one sentence each
    ///   PAPERBOUND_DEMO_EPUB_SELECT=1   select the paragraph's second sentence
    ///                                   in the web view (a real selection,
    ///                                   reported through Readium)
    ///   PAPERBOUND_DEMO_EPUB_EDIT=1     open the first mark on screen
    ///   PAPERBOUND_DEMO_EPUB_SEARCH=q   search for q and jump to the first result
    @ObservationIgnored private var demoStarted = false

    private func runDemoIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        let keys = ["PAPERBOUND_DEMO_EPUB_MARKS", "PAPERBOUND_DEMO_EPUB_SELECT",
                    "PAPERBOUND_DEMO_EPUB_EDIT", "PAPERBOUND_DEMO_EPUB_SEARCH", "PAPERBOUND_DEMO_EPUB_PAGE"]
        guard !demoStarted, keys.contains(where: { environment[$0] != nil }) else { return }
        demoStarted = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, let model = self.model else { return }
            if let page = environment["PAPERBOUND_DEMO_EPUB_PAGE"].flatMap(Int.init) {
                model.go(toPageIndex: page - 1)
            }
            try? await Task.sleep(for: .seconds(2))
            if let query = environment["PAPERBOUND_DEMO_EPUB_SEARCH"] {
                model.searchQuery = query
                model.runSearch()
                while model.isSearching { try? await Task.sleep(for: .milliseconds(100)) }
                if let first = model.searchResults.first {
                    self.flash(first)
                    model.go(to: first.location)
                }
                return
            }
            let sentences = await self.demoSentences()
            if environment["PAPERBOUND_DEMO_EPUB_MARKS"] == "1", self.epubHighlights.isEmpty {
                for (index, style) in HighlightStyle.allCases.enumerated() where index < sentences.count {
                    let color = HighlightColor.allCases[index % HighlightColor.allCases.count]
                    var selection = EPUBTextSelection(locator: sentences[index], frame: nil, range: nil)
                    await self.loadTexts(around: selection.locator.href.string)
                    if let (range, resolved) = self.anchorFromCache(selection.locator) {
                        selection.range = range
                        selection.locator = resolved
                    }
                    self.addHighlight(selection, style: style, color: color)
                }
                self.refreshDecorations()
            }
            if environment["PAPERBOUND_DEMO_EPUB_SELECT"] == "1" {
                try? await Task.sleep(for: .seconds(1))
                await self.selectInWebView(sentenceIndex: 1)
            } else if environment["PAPERBOUND_DEMO_EPUB_EDIT"] == "1",
                      let first = self.epubHighlights.min(by: { $0.createdAt < $1.createdAt }) {
                try? await Task.sleep(for: .seconds(1))
                // Readium reports the rect on a tap; ask the page for it here.
                let rect = await self.demoRect(of: first)
                self.markActivated(id: first.id.uuidString, rect: rect)
            }
        }
    }

    /// The first sentences on screen, as quotes (up to four, across paragraphs).
    private func demoSentences() async -> [Locator] {
        guard let navigator = bridge?.navigator,
              let start = await navigator.firstVisibleElementLocator(),
              let publication = model?.epubEngine?.publication,
              let iterator = publication.content(from: start)?.iterator() else { return [] }
        var quotes: [Locator] = []
        while quotes.count < 4, let element = try? await iterator.next() {
            guard let text = (element as? TextualContentElement)?.text,
                  text.count > 120, element.locator.href.isEquivalentTo(start.href) else { continue }
            text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, range, _, stop in
                guard let substring else { return }
                let sentence = substring.trimmingCharacters(in: .whitespaces)
                guard !sentence.isEmpty else { return }
                let before = String(text[..<range.lowerBound].suffix(60))
                let after = String(text[range.upperBound...].prefix(60))
                quotes.append(Locator(href: element.locator.href, mediaType: element.locator.mediaType,
                                      locations: element.locator.locations,
                                      text: .init(after: after, before: before, highlight: sentence)))
                if quotes.count >= 4 { stop = true }
            }
        }
        return quotes
    }

    /// Selects one sentence of the first visible paragraph with the DOM
    /// selection API, which Readium reports exactly like a finger would.
    private func selectInWebView(sentenceIndex: Int) async {
        let script = """
        (function() {
          const width = window.innerWidth;
          const paragraphs = Array.from(document.querySelectorAll('p'));
          for (const p of paragraphs) {
            const r = p.getBoundingClientRect();
            if (r.width === 0 || r.left < -1 || r.left >= width) continue;
            const node = Array.from(p.childNodes).find(n => n.nodeType === 3 && n.textContent.length > 80);
            if (!node) continue;
            const text = node.textContent;
            const ends = [];
            const re = /[.!?]["”’]?\\s+/g;
            let m;
            while ((m = re.exec(text)) !== null) ends.push(m.index + m[0].length);
            const starts = [0].concat(ends);
            const i = Math.min(\(sentenceIndex), starts.length - 1);
            const start = starts[i];
            let end = i + 1 < starts.length ? starts[i + 1] : text.length;
            while (end > start && /\\s/.test(text[end - 1])) end--;
            const range = document.createRange();
            range.setStart(node, start);
            range.setEnd(node, end);
            const sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
            return text.slice(start, end);
          }
          return null;
        })();
        """
        _ = await bridge?.evaluateJavaScript(script)
    }

    /// The on-screen rect of a mark's decoration, for opening it in the demo.
    private func demoRect(of highlight: Highlight) async -> CGRect? {
        let script = """
        (function() {
          // Readium names decoration elements by group, not by id; the first
          // item of the group is the oldest mark, which is the one opened.
          const el = document.querySelector('[data-group="\(EPUBAnnotationDecorations.highlightsGroup)"] > div > *');
          if (!el) return null;
          const r = el.getBoundingClientRect();
          return [r.left, r.top, r.width, r.height];
        })();
        """
        guard case let .success(value)? = await bridge?.evaluateJavaScript(script),
              let numbers = value as? [Double], numbers.count == 4,
              let webView = bridge?.navigator?.view else { return nil }
        // The web view's viewport coordinates: close enough to the
        // navigator's for a screenshot.
        _ = webView
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }
    #endif
}

// MARK: - Highlight ↔ Locator

extension Highlight {

    /// The Readium locator an EPUB mark is drawn from. nil for PDF marks.
    var epubLocator: Locator? {
        if let locatorJSON, let locator = try? Locator(jsonString: locatorJSON) {
            return locator
        }
        return locatorJSON == nil ? nil : location.readiumLocator
    }

    /// Where the mark sits in its chapter, when that was worked out when the
    /// mark was made.
    var epubTextRange: EPUBTextRange? {
        guard locatorJSON != nil, let href = location.epubHref, let range = characterRange else { return nil }
        return EPUBTextRange(href: href, range: range)
    }
}

extension ReadingLocation {
    /// The raw locator JSON of an EPUB location, if any.
    var locatorJSONString: String? {
        if case let .epubLocator(_, _, _, json) = self { return json }
        return nil
    }
}

extension EPUBReadingEngine {
    /// The part of the whole book's progression one resource covers: from its
    /// first position to the next resource's first position (or the end).
    func totalProgressionSpan(ofResource href: String) -> ClosedRange<Double>? {
        guard let first = positions.firstIndex(where: { EPUBTextAnchor.sameResource($0.href.string, href) }) else {
            return nil
        }
        let start = positions[first].locations.totalProgression ?? Double(first) / Double(max(1, positions.count))
        let next = positions[first...].firstIndex { !EPUBTextAnchor.sameResource($0.href.string, href) }
        let end = next.flatMap { positions[$0].locations.totalProgression } ?? 1
        return start...max(start, end)
    }
}
