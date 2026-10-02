//
//  TextSelectionSession.swift
//  Paperbound
//
//  The reader's selection state: what is selected, which mark is being
//  edited, which handle is under the finger and where the loupe is.
//
//  Gestures feed it unit-space points (see PageTextFrame); it asks the page's
//  PageTextSelector what text those points land on. Nothing here knows about
//  views, so the rules are testable without a screen:
//
//    long press            selects the word under the finger
//    keep dragging         extends by whole words from that first word
//    drag a handle         moves that end by character; the other end stays put
//    tap the selection     grows it to the sentence
//    tap a saved mark      opens it for editing
//    tap anywhere else     clears everything
//

import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class TextSelectionSession {

    private(set) var selection: PageTextSelection?
    /// A saved mark opened for restyling or deletion.
    private(set) var editingMarkID: UUID?
    private(set) var editingPageIndex: Int?
    private(set) var activeHandle: SelectionHandle?
    /// Where the loupe magnifies, in unit page space, while a finger is down.
    private(set) var loupe: (pageIndex: Int, point: CGPoint)?

    /// The word the long press first landed on: a long-press drag always
    /// keeps it, the way the system text views do.
    private var anchorRange: NSRange?
    /// The end of the selection that stays put while a handle is dragged.
    private var fixedIndex: Int?

    var isActive: Bool { selection != nil || editingMarkID != nil }
    var isDragging: Bool { loupe != nil }

    // MARK: Long press

    @discardableResult
    func beginLongPress(on selector: PageTextSelector, at point: CGPoint) -> Bool {
        editingMarkID = nil
        editingPageIndex = nil
        guard let word = selector.wordSelection(at: point) else {
            clear()
            return false
        }
        selection = word
        anchorRange = word.range
        activeHandle = nil
        loupe = (selector.pageIndex, point)
        return true
    }

    func continueLongPress(on selector: PageTextSelector, to point: CGPoint) {
        guard let anchorRange, selection?.pageIndex == selector.pageIndex,
              let index = selector.characterIndex(nearestTo: point) else { return }
        let anchorStart = anchorRange.location
        let anchorEnd = anchorRange.location + max(anchorRange.length, 1) - 1
        let extended = index < anchorStart
            ? selector.selection(from: index, to: anchorEnd, snapToWords: true)
            : selector.selection(from: anchorStart, to: max(index, anchorEnd), snapToWords: true)
        if let extended { selection = extended }
        loupe = (selector.pageIndex, point)
    }

    // MARK: Handles

    func beginHandleDrag(_ handle: SelectionHandle) {
        guard let selection else { return }
        activeHandle = handle
        let range = selection.range
        fixedIndex = handle == .start ? range.location + max(range.length, 1) - 1 : range.location
    }

    /// `point` is where the dragged end should land, already corrected for
    /// where the finger grabbed the knob.
    func dragHandle(on selector: PageTextSelector, to point: CGPoint) {
        guard let handle = activeHandle, let fixedIndex, selection?.pageIndex == selector.pageIndex,
              let index = selector.characterIndex(nearestTo: point) else { return }
        // Dragging one end past the other swaps which end is moving, so the
        // selection never collapses or inverts.
        if let moved = selector.selection(from: fixedIndex, to: index, snapToWords: false) {
            selection = moved
            let crossed = handle == .start ? index > fixedIndex : index < fixedIndex
            if crossed {
                activeHandle = handle == .start ? .end : .start
                self.fixedIndex = handle == .start
                    ? moved.range.location
                    : moved.range.location + max(moved.range.length, 1) - 1
            }
        }
        loupe = (selector.pageIndex, point)
    }

    /// Finger lifted, from a long press or a handle.
    func endDrag() {
        activeHandle = nil
        fixedIndex = nil
        loupe = nil
    }

    // MARK: Taps

    func expandToSentence(on selector: PageTextSelector) {
        guard let current = selection, current.pageIndex == selector.pageIndex,
              let sentence = selector.sentenceSelection(containing: current.range),
              sentence.range != current.range else { return }
        selection = sentence
        anchorRange = sentence.range
    }

    func edit(markID: UUID, onPage pageIndex: Int) {
        clearSelectionOnly()
        editingMarkID = markID
        editingPageIndex = pageIndex
    }

    func clear() {
        clearSelectionOnly()
        editingMarkID = nil
        editingPageIndex = nil
    }

    private func clearSelectionOnly() {
        selection = nil
        anchorRange = nil
        activeHandle = nil
        fixedIndex = nil
        loupe = nil
    }
}
