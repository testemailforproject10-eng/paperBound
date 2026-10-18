//
//  EPUBNavigatorBridge.swift
//  Paperbound
//
//  The one door other features use to reach the live Readium navigator.
//
//  `EPUBReaderView` owns the `EPUBNavigatorViewController`: it creates it,
//  sizes it around the fold and cut-outs, turns its pages and saves its
//  position. Typography (engineer 4) and the reading tools (engineer 5) need
//  to act on that same navigator — submit preferences, draw decorations, read
//  the selection — without reaching into the view. They do it through this
//  bridge, which `ReaderViewModel.epubBridge` holds for the open book.
//
//  Everything here is safe to call before the navigator exists (the reader is
//  still loading) or while it is being replaced (a configuration change, see
//  below). Preferences, decorations and decoration observers are *remembered*
//  and replayed onto every navigator that attaches, so callers set them once
//  and do not have to track the navigator's lifetime.
//
//  The API is documented in Docs/EPUB_README.md ("Notes from Phase 3"). Keep
//  changes additive: other files are written against it.
//

import Observation
import ReadiumNavigator
import ReadiumShared
import UIKit

@MainActor
@Observable
final class EPUBNavigatorBridge {

    init() {}

    // MARK: - The live navigator

    /// The navigator on screen, or `nil` while the book loads, after it
    /// closes, or for the instant one navigator is being replaced by another.
    /// Weak: the view owns it. Prefer the bridge's own methods; use this only
    /// for something the bridge does not cover yet.
    @ObservationIgnored
    private(set) weak var navigator: EPUBNavigatorViewController?

    /// Bumped every time a navigator attaches. Observable, so SwiftUI views
    /// (or `withObservationTracking`) can react to a new navigator.
    private(set) var attachCount = 0

    /// Whether a navigator is on screen right now.
    var isAttached: Bool { navigator != nil }

    /// The last location the navigator reported (also saved to the book by
    /// `ReaderViewModel`). Observable.
    private(set) var currentLocator: Locator?

    /// Runs `body` with the navigator now if one is attached, and again with
    /// every navigator that attaches later, until the token is removed with
    /// `removeObserver(_:)`. Use it for things the bridge does not replay
    /// itself (e.g. an input observer).
    @discardableResult
    func whenAttached(_ body: @escaping @MainActor (EPUBNavigatorViewController) -> Void) -> UUID {
        let token = UUID()
        attachHandlers[token] = body
        if let navigator { body(navigator) }
        return token
    }

    /// Called with every location the navigator reports (page turns, swipes,
    /// link jumps, jumps the app asked for), after the model has saved it.
    @discardableResult
    func addLocationObserver(_ body: @escaping @MainActor (Locator) -> Void) -> UUID {
        let token = UUID()
        locationHandlers[token] = body
        return token
    }

    /// Removes a `whenAttached` or `addLocationObserver` registration.
    func removeObserver(_ token: UUID) {
        attachHandlers[token] = nil
        locationHandlers[token] = nil
    }

    // MARK: - Configuration (creation-time)
    //
    // Readium reads these only when the navigator is created. Changing one
    // after the reader is open makes `EPUBReaderView` build a fresh navigator
    // at the current location (the page may blink once). Set them early —
    // ideally before or right after `ReaderViewModel.load()`.

    /// Editing actions in the text-selection menu. Custom actions are
    /// `EditingAction(title:action:)` with a selector; implement the selector
    /// on `editingActionTarget` (below) — the surface forwards it there.
    var editingActions: [EditingAction] = EditingAction.defaultActions {
        didSet { configurationVersion += 1 }
    }

    /// The object that implements the selectors of custom `editingActions`
    /// (`@objc func highlight(_ sender: Any?)`). The navigator's container
    /// returns it from `target(forAction:withSender:)` whenever it responds
    /// to the action. Weak.
    @ObservationIgnored
    weak var editingActionTarget: NSObject?

    /// HTML decoration styles the navigator can draw. Add custom styles
    /// (`Decoration.Style.Id` → `HTMLDecorationTemplate`) here.
    var decorationTemplates: [Decoration.Style.Id: HTMLDecorationTemplate] =
        HTMLDecorationTemplate.defaultTemplates() {
        didSet { configurationVersion += 1 }
    }

    /// Extra font families offered to `EPUBPreferences.fontFamily`.
    var fontFamilyDeclarations: [AnyHTMLFontFamilyDeclaration] = [] {
        didSet { configurationVersion += 1 }
    }

    /// Bumped whenever a creation-time setting changes. The surface rebuilds
    /// the navigator when it moves.
    private(set) var configurationVersion = 0

    // MARK: - Preferences (typography)

    /// What typography last submitted. Empty until someone submits.
    private(set) var submittedPreferences: EPUBPreferences = .empty

    /// Preferences the reading surface owns and always wins on: `scroll`
    /// (always paginated), `columnCount` and `spread` (decided from the
    /// screen and the fold). Set by `EPUBReaderView` only.
    private(set) var layoutPreferences = EPUBPreferences(columnCount: .one, scroll: false)

    /// What the navigator is actually given: the submitted preferences with
    /// the surface's layout keys on top.
    var effectivePreferences: EPUBPreferences {
        submittedPreferences.merging(layoutPreferences)
    }

    /// Hands typography preferences to the navigator (now, and to every
    /// navigator created later). Submit the *whole* set each time — this
    /// replaces, it does not merge with, the previous submission. Readium
    /// keeps the reader on the same text across the change. `columnCount`,
    /// `spread` and `scroll` are ignored: the surface owns them.
    func submit(_ preferences: EPUBPreferences) {
        submittedPreferences = preferences
        pushPreferences()
    }

    /// The settings the navigator is currently applying (preferences resolved
    /// against the publication and defaults). `nil` with no navigator.
    var settings: EPUBSettings? { navigator?.settings }

    /// A Readium preferences editor for `preferences`, e.g. to read ranges and
    /// steps. `nil` with no navigator.
    func editor(of preferences: EPUBPreferences) -> EPUBPreferencesEditor? {
        navigator?.editor(of: preferences)
    }

    /// For the surface: sets the layout keys and pushes them if they changed.
    func setLayoutPreferences(_ preferences: EPUBPreferences) {
        guard preferences != layoutPreferences else { return }
        layoutPreferences = preferences
        pushPreferences()
    }

    private func pushPreferences() {
        navigator?.submitPreferences(effectivePreferences)
    }

    // MARK: - Selection

    /// Return `false` to stop the system edit menu appearing for a selection
    /// (e.g. to show the app's own highlight bar instead). Default: shown.
    @ObservationIgnored
    var shouldShowMenuForSelection: (@MainActor (Selection) -> Bool)?

    /// Return `false` to hide one editing action for a selection. Default:
    /// allowed.
    @ObservationIgnored
    var canPerformAction: (@MainActor (EditingAction, Selection) -> Bool)?

    /// Called when a selection appears (`Selection`) or goes away (`nil`).
    /// Readium reports selections through the menu callback, so a change is
    /// noticed when the menu would show; clearing is reported by
    /// `clearSelection()` and by page turns.
    @ObservationIgnored
    var onSelectionChange: (@MainActor (Selection?) -> Void)?

    /// The current text selection in the navigator, if any.
    var currentSelection: Selection? { navigator?.currentSelection }

    /// Clears the navigator's selection.
    func clearSelection() {
        navigator?.clearSelection()
        onSelectionChange?(nil)
    }

    // MARK: - Decorations (highlights, search results, read-aloud)

    /// Draws `decorations` in `group`, replacing whatever that group showed.
    /// Remembered and replayed on every navigator that attaches, so set it
    /// once per change. Pass `[]` to clear the group.
    func apply(_ decorations: [Decoration], in group: DecorationGroup) {
        decorationsByGroup[group] = decorations
        navigator?.apply(decorations: decorations, in: group)
    }

    /// The decorations last applied in `group`.
    func decorations(in group: DecorationGroup) -> [Decoration] {
        decorationsByGroup[group] ?? []
    }

    /// Calls `onActivated` when the reader taps a decoration in `group`.
    /// Registered on every navigator that attaches; register once per group.
    /// A tap on a decoration does not also turn the page or toggle controls.
    func observeDecorationInteractions(
        inGroup group: DecorationGroup,
        onActivated: @escaping DecorableNavigator.OnActivatedCallback
    ) {
        decorationObservers.append((group, onActivated))
        navigator?.observeDecorationInteractions(inGroup: group, onActivated: onActivated)
    }

    // MARK: - Taps

    /// Gets first look at every single tap on the page (point in the
    /// navigator's view). Return `true` to consume it, so it neither turns the
    /// page nor toggles the controls (e.g. to dismiss an open highlight bar).
    @ObservationIgnored
    var tapInterceptor: (@MainActor (CGPoint) -> Bool)?

    // MARK: - Navigation

    /// Moves the navigator to `locator`. Prefer `ReaderViewModel.go(to:)` for
    /// jumps the reader asked for (contents, search results, bookmarks): it
    /// saves the position and reaches the navigator through the same path.
    /// Use this only when the model must not be involved.
    @discardableResult
    func go(to locator: Locator, animated: Bool = false) async -> Bool {
        guard let navigator else { return false }
        return await navigator.go(to: locator, options: NavigatorGoOptions(animated: animated))
    }

    /// Runs JavaScript in the visible resource. Escape hatch; `nil` with no
    /// navigator.
    @discardableResult
    func evaluateJavaScript(_ script: String) async -> Result<Any, Error>? {
        await navigator?.evaluateJavaScript(script)
    }

    // MARK: - Layout (read-only)

    /// Where the surface placed the navigator and how many columns it shows.
    /// Observable. Set by `EPUBReaderView`.
    private(set) var surfaceLayout: EPUBSurfaceLayout = .empty

    /// Whether two columns (a spread) are on screen.
    var isShowingSpread: Bool { surfaceLayout.isSpread }

    // MARK: - Surface side (EPUBReaderView only)

    /// For the surface: records its layout and sets the column count.
    func setSurfaceLayout(_ layout: EPUBSurfaceLayout) {
        guard layout != surfaceLayout else { return }
        surfaceLayout = layout
        setLayoutPreferences(EPUBPreferences(
            columnCount: layout.columnCount == 2 ? .two : .one,
            scroll: false
        ))
    }

    @ObservationIgnored private var attachHandlers: [UUID: @MainActor (EPUBNavigatorViewController) -> Void] = [:]
    @ObservationIgnored private var locationHandlers: [UUID: @MainActor (Locator) -> Void] = [:]
    @ObservationIgnored private var decorationsByGroup: [DecorationGroup: [Decoration]] = [:]
    @ObservationIgnored private var decorationObservers: [(DecorationGroup, DecorableNavigator.OnActivatedCallback)] = []

    /// The configuration a new navigator is built with.
    func makeConfiguration() -> EPUBNavigatorViewController.Configuration {
        EPUBNavigatorViewController.Configuration(
            preferences: effectivePreferences,
            editingActions: editingActions,
            decorationTemplates: decorationTemplates,
            fontFamilyDeclarations: fontFamilyDeclarations
        )
    }

    /// Called by the surface once a navigator exists. Replays decorations,
    /// decoration observers and attach handlers.
    func attach(_ navigator: EPUBNavigatorViewController) {
        self.navigator = navigator
        for (group, callback) in decorationObservers {
            navigator.observeDecorationInteractions(inGroup: group, onActivated: callback)
        }
        for (group, decorations) in decorationsByGroup where !decorations.isEmpty {
            navigator.apply(decorations: decorations, in: group)
        }
        attachCount += 1
        for handler in attachHandlers.values { handler(navigator) }
    }

    /// Called by the surface when its navigator goes away.
    func detach(_ navigator: EPUBNavigatorViewController) {
        guard self.navigator === navigator else { return }
        self.navigator = nil
    }

    /// Called by the surface for every location the navigator reports.
    func didReport(_ locator: Locator) {
        currentLocator = locator
        for handler in locationHandlers.values { handler(locator) }
    }
}
