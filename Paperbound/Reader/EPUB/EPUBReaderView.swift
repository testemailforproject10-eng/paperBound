//
//  EPUBReaderView.swift
//  Paperbound
//
//  The EPUB reading surface: Readium's `EPUBNavigatorViewController` hosted in
//  SwiftUI.
//
//  * Paginated, opened at the saved Locator; every location Readium reports
//    is saved through `ReaderViewModel.reportVisible(epubLocation:)`.
//  * Swipes are Readium's. Taps on the outer 28% turn the page (through
//    Readium, so right-to-left books turn the right way); a tap in the middle
//    toggles the reader controls, as for PDFs. The slider, contents, search
//    and bookmarks arrive as `ReaderViewModel.epubNavigationRequest`.
//  * The navigator is placed by `EPUBSurfaceLayout`: one or two columns,
//    centred on a vertical fold, clear of camera cut-outs. The controls float
//    over the text rather than resizing it, so showing them never reflows.
//  * After a resize, rotation or fold the reader is put back on the text it
//    was showing, and a change of column count rebuilds the navigator at the
//    same Locator.
//  * External links ask before leaving for Safari.
//
//  Other features reach the navigator through `ReaderViewModel.epubBridge`
//  (`EPUBNavigatorBridge`), not through this file.
//

import ReadiumNavigator
import ReadiumShared
import SwiftUI
import UIKit

struct EPUBReaderView: View {

    let model: ReaderViewModel

    var body: some View {
        #if DEBUG
        if let publication = model.epubEngine?.publication, let surface = Self.simulatedSurface {
            simulatedSurfaceView(publication: publication, size: surface)
        } else {
            liveBody
        }
        #else
        liveBody
        #endif
    }

    #if DEBUG
    /// `PAPERBOUND_EPUB_SIMULATE_SURFACE=<w>x<h>` (DEBUG, via `SIMCTL_CHILD_`)
    /// lays the reader out for a screen of that size, with a 12 pt vertical
    /// fold down its middle, scaled to fit the real screen. It exists to
    /// capture the Duo inner-display spread from a simulator that cannot be
    /// unfolded by script; it is the same container and layout code, fed the
    /// geometry the inner display reports.
    static var simulatedSurface: CGSize? {
        guard let raw = ProcessInfo.processInfo.environment["PAPERBOUND_EPUB_SIMULATE_SURFACE"] else { return nil }
        let parts = raw.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    private func simulatedSurfaceView(publication: Publication, size: CGSize) -> some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            EPUBNavigatorHost(
                publication: publication,
                model: model,
                layoutInput: EPUBNavigatorHost.LayoutInput(
                    occlusionRegions: [],
                    divisionRegion: CGRect(x: size.width / 2 - 6, y: 0, width: 12, height: size.height),
                    divisionAxis: .vertical,
                    posture: .bookLike
                )
            )
            .frame(width: size.width, height: size.height)
            .overlay {
                // Where the fold is, for the capture.
                Rectangle().fill(Color.red.opacity(0.25)).frame(width: 12)
            }
            .scaleEffect(scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }
    #endif

    @ViewBuilder
    private var liveBody: some View {
        if let publication = model.epubEngine?.publication {
            GeometryReader { geometry in
                let division = hardwareDivisionRegions(using: geometry)
                let occlusion = hardwareOcclusionRegions(using: geometry)
                EPUBNavigatorHost(
                    publication: publication,
                    model: model,
                    layoutInput: EPUBNavigatorHost.LayoutInput(
                        occlusionRegions: occlusion + model.layout.reservedRegions,
                        divisionRegion: model.layout.divisionRegion,
                        divisionAxis: model.layout.divisionAxis,
                        posture: model.layout.posture
                    )
                )
                .onAppear {
                    model.updateLayout(for: geometry.size,
                                       hardwareReservedRegions: occlusion + division,
                                       divisionRegions: division)
                }
                .onChange(of: geometry.size) { _, size in
                    model.updateLayout(for: size,
                                       hardwareReservedRegions: occlusion + division,
                                       divisionRegions: division)
                }
                .onChange(of: occlusion + division) { _, _ in
                    model.updateLayout(for: geometry.size,
                                       hardwareReservedRegions: occlusion + division,
                                       divisionRegions: division)
                }
            }
            // The whole screen, always: the bars float over the text so
            // toggling them does not repaginate the book.
            .ignoresSafeArea()
            // Highlight action bar (engineer 5, EPUBAnnotationsOverlay.swift).
            .overlay { EPUBAnnotationsOverlay(model: model) }
        } else {
            // Only reached if the engine closed underneath the view.
            ContentUnavailableView(
                "This book is not open",
                systemImage: "book.closed",
                description: Text("Go back to the library and open it again.")
            )
        }
    }

    /// iOS 27.1 reports the Duo fold and active camera cut-outs in the view's
    /// coordinate space, as `PagedReaderView` reads them.
    private func hardwareDivisionRegions(using geometry: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        return geometry.reservedRegions(kind: .division).map(\.frame)
    }

    private func hardwareOcclusionRegions(using geometry: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        return geometry.reservedRegions(kind: .occlusion).map(\.frame)
    }
}

/// The `UIViewControllerRepresentable` around the navigator's container.
struct EPUBNavigatorHost: UIViewControllerRepresentable {

    struct LayoutInput: Equatable {
        var occlusionRegions: [CGRect]
        var divisionRegion: CGRect?
        var divisionAxis: ReadingDivisionAxis?
        var posture: DevicePosture
    }

    let publication: Publication
    let model: ReaderViewModel
    let layoutInput: LayoutInput

    func makeUIViewController(context: Context) -> EPUBNavigatorContainerController {
        let controller = EPUBNavigatorContainerController(
            publication: publication,
            model: model,
            initialLocator: model.currentLocation.readiumLocator
        )
        controller.layoutInput = layoutInput
        // A request made before the view existed is already satisfied by the
        // initial location; don't replay it on the first update.
        controller.handledRequestID = model.epubNavigationRequest?.id
        return controller
    }

    func updateUIViewController(_ controller: EPUBNavigatorContainerController, context: Context) {
        controller.model = model
        if controller.layoutInput != layoutInput {
            controller.layoutInput = layoutInput
        }
        // Reading these here makes SwiftUI call this again when they change.
        controller.configurationVersion = model.epubBridge.configurationVersion
        if let request = model.epubNavigationRequest, request.id != controller.handledRequestID {
            controller.handledRequestID = request.id
            controller.follow(request)
        }
    }

    static func dismantleUIViewController(_ controller: EPUBNavigatorContainerController, coordinator: ()) {
        controller.tearDown()
    }
}

/// Holds the Readium navigator as a child, places it with
/// `EPUBSurfaceLayout`, and is its delegate. Rebuilding the navigator (column
/// count or creation-time configuration changed) happens here too.
@MainActor
final class EPUBNavigatorContainerController: UIViewController, EPUBNavigatorDelegate {

    var model: ReaderViewModel
    private let publication: Publication
    private var initialLocator: Locator?
    var handledRequestID: UUID?

    private(set) var navigator: EPUBNavigatorViewController?
    private var tapToken: InputObservableToken?
    private var bridge: EPUBNavigatorBridge { model.epubBridge }

    /// What the current navigator was built for; a change rebuilds it.
    private struct BuildKey: Equatable {
        var columnCount: Int
        var columnGap: CGFloat
        var configurationVersion: Int
    }
    private var builtFor: BuildKey?

    var layoutInput = EPUBNavigatorHost.LayoutInput(
        occlusionRegions: [], divisionRegion: nil, divisionAxis: nil, posture: .flat
    ) {
        didSet { if layoutInput != oldValue { view.setNeedsLayout() } }
    }

    var configurationVersion = 0 {
        didSet { if configurationVersion != oldValue { view.setNeedsLayout() } }
    }

    private(set) var surfaceLayout: EPUBSurfaceLayout = .empty

    /// The last location the reader actually saw, before any layout change
    /// started moving the text around. Layout changes return to it.
    private var anchor: Locator?
    /// While true, locations Readium reports are drift from a relayout, not
    /// reading, and are not saved.
    private var isRestoringAnchor = false
    private var restoreTask: Task<Void, Never>?
    /// Where a freshly built navigator was asked to open, until it reports
    /// being there. Readium goes idle as soon as it starts loading a spread,
    /// so under load its first report can be the chapter's start, before the
    /// web view has scrolled to the saved progression; saving that would
    /// overwrite the reader's place (see `isUnsettledLoad`).
    private var pendingOpenLocator: Locator?
    private var settleTask: Task<Void, Never>?

    init(publication: Publication, model: ReaderViewModel, initialLocator: Locator?) {
        self.publication = publication
        self.model = model
        self.initialLocator = initialLocator
        self.anchor = initialLocator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let next = EPUBSurfaceLayout.make(
            size: view.bounds.size,
            safeAreaInsets: stableSafeAreaInsets(),
            reservedRegions: layoutInput.occlusionRegions,
            divisionRegion: layoutInput.divisionRegion,
            divisionAxis: layoutInput.divisionAxis,
            posture: layoutInput.posture
        )
        guard next.frame.width > 0, next.frame.height > 0 else { return }

        let key = BuildKey(columnCount: next.columnCount, columnGap: next.columnGap,
                           configurationVersion: configurationVersion)
        let previous = surfaceLayout
        surfaceLayout = next
        bridge.setSurfaceLayout(next)

        if navigator == nil || builtFor != key {
            buildNavigator(for: key, at: anchor ?? bridge.currentLocator ?? initialLocator)
            return
        }
        guard previous != next, let navigator else { return }
        let sizeChanged = previous.frame.size != next.frame.size
        navigator.view.frame = next.frame
        if sizeChanged {
            restoreAnchorAfterRelayout()
        } else if previous.topInset != next.topInset || previous.bottomInset != next.bottomInset {
            // Content insets are read when settings apply; resubmitting the
            // same preferences makes Readium re-read them.
            navigator.submitPreferences(bridge.effectivePreferences)
            restoreAnchorAfterRelayout()
        }
    }

    /// The window's safe area, but never shrinking for a given screen size:
    /// hiding the status bar with the controls must not repaginate the book,
    /// so the text keeps clear of where the status bar goes either way.
    private var safeAreaBySize: [String: UIEdgeInsets] = [:]

    private func stableSafeAreaInsets() -> UIEdgeInsets {
        let current = view.window?.safeAreaInsets ?? view.safeAreaInsets
        let key = "\(view.bounds.size.width)x\(view.bounds.size.height)"
        var stable = safeAreaBySize[key] ?? current
        stable.top = max(stable.top, current.top)
        stable.bottom = max(stable.bottom, current.bottom)
        stable.left = max(stable.left, current.left)
        stable.right = max(stable.right, current.right)
        safeAreaBySize[key] = stable
        return stable
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        // Pin the anchor before rotation starts moving text, and go back to
        // it once the rotation is over.
        isRestoringAnchor = true
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.restoreAnchorAfterRelayout()
        }
    }

    // MARK: - Building

    private func buildNavigator(for key: BuildKey, at locator: Locator?) {
        if let old = navigator {
            if let tapToken { old.removeObserver(tapToken) }
            bridge.detach(old)
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
            navigator = nil
        }

        var configuration = bridge.makeConfiguration()
        configuration.preferences = bridge.effectivePreferences
        configuration.readiumCSSRSProperties = Self.rsProperties(for: key)

        let created: EPUBNavigatorViewController
        do {
            created = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: locator,
                config: configuration
            )
        } catch {
            // Restricted (DRM) publications are refused by the engine before
            // they get here; this is the belt to that pair of braces.
            model.loadError = error.localizedDescription
            return
        }
        created.delegate = self
        addChild(created)
        created.view.frame = surfaceLayout.frame
        view.addSubview(created.view)
        created.didMove(toParent: self)
        navigator = created
        builtFor = key
        anchor = locator
        awaitSettling(at: locator)

        tapToken = created.addObserver(.tap { [weak self, weak created] event in
            guard let self, let created else { return false }
            return await self.handleTap(at: event.location, in: created)
        })

        bridge.attach(created)
        updateBackground()
        #if DEBUG
        runCaptureHooksOnce(on: created)
        #endif
    }

    #if DEBUG
    private var didRunCaptureHooks = false

    /// The simulator cannot tap, so captures drive the reader from the
    /// environment (pass with the `SIMCTL_CHILD_` prefix):
    ///   PAPERBOUND_EPUB_AUTO_TURN=<delay>[,<count>]  tap the right edge
    ///       <count> times (default 1), starting after <delay> seconds
    ///   PAPERBOUND_EPUB_HIDE_CONTROLS=1              start with controls hidden
    private func runCaptureHooksOnce(on navigator: EPUBNavigatorViewController) {
        guard !didRunCaptureHooks else { return }
        didRunCaptureHooks = true
        let environment = ProcessInfo.processInfo.environment
        if environment["PAPERBOUND_EPUB_HIDE_CONTROLS"] == "1" {
            model.showsControls = false
        }
        if let raw = environment["PAPERBOUND_EPUB_AUTO_TURN"] {
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            let delay = parts.first ?? 3
            let count = parts.count > 1 ? Int(parts[1]) : 1
            Task { @MainActor [weak self, weak navigator] in
                try? await Task.sleep(for: .seconds(delay))
                for _ in 0..<count {
                    guard let self, let navigator else { return }
                    let edge = CGPoint(x: navigator.view.bounds.width - 10, y: navigator.view.bounds.midY)
                    _ = await self.handleTap(at: edge, in: navigator)
                    try? await Task.sleep(for: .milliseconds(700))
                }
            }
        }
    }
    #endif

    /// Two columns are forced through Readium CSS's own variables, which
    /// apply at any width (its user `columnCount` setting only takes effect
    /// on screens 960 px and wider). The column *gap* stays 0 — Readium
    /// pages by whole screens, and a CSS column gap makes every later screen
    /// drift by the gap. The space between the columns is the body gutter on
    /// each side of the middle; across a fold wider than that, the gutter is
    /// widened instead.
    nonisolated static func rsProperties(for columnCount: Int, columnGap: CGFloat) -> CSSRSProperties {
        if columnCount == 2 {
            let gutter = columnGap > 0 ? max(30, Double(columnGap / 2 + 12)) : nil
            return CSSRSProperties(
                colWidth: CSSPxLength(200),
                colCount: .two,
                colGap: CSSPxLength(0),
                pageGutter: gutter.map { CSSPxLength($0) }
            )
        }
        return CSSRSProperties(colCount: .one)
    }

    private static func rsProperties(for key: BuildKey) -> CSSRSProperties {
        rsProperties(for: key.columnCount, columnGap: key.columnGap)
    }

    func tearDown() {
        restoreTask?.cancel()
        settleTask?.cancel()
        if let navigator {
            if let tapToken { navigator.removeObserver(tapToken) }
            bridge.detach(navigator)
        }
    }

    // MARK: - Moving

    func follow(_ request: EPUBNavigationRequest) {
        guard let locator = request.location.readiumLocator else { return }
        anchor = locator
        guard let navigator else { return }
        // A jump the app asked for replaces whatever the load was heading to.
        pendingOpenLocator = nil
        settleTask?.cancel()
        settleTask = nil
        Task { @MainActor in
            _ = await navigator.go(to: locator, options: NavigatorGoOptions(animated: false))
        }
    }

    private func handleTap(at point: CGPoint, in navigator: EPUBNavigatorViewController) async -> Bool {
        if bridge.tapInterceptor?(point) == true { return true }
        switch EPUBTapZone(x: point.x, width: navigator.view.bounds.width) {
        case .left:
            _ = await navigator.goLeft(options: NavigatorGoOptions(animated: true))
        case .right:
            _ = await navigator.goRight(options: NavigatorGoOptions(animated: true))
        case .middle:
            withAnimation(.easeInOut(duration: 0.2)) {
                model.showsControls.toggle()
            }
        }
        return true
    }

    /// Readium keeps its place across most size changes itself; this makes
    /// sure of it by returning to the location the reader last saw.
    private func restoreAnchorAfterRelayout() {
        isRestoringAnchor = true
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            // Let the web view finish reflowing before asking for a page.
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            if let anchor = self.anchor, let navigator = self.navigator {
                _ = await navigator.go(to: anchor, options: NavigatorGoOptions(animated: false))
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self.isRestoringAnchor = false
            self.restoreTask = nil
            if let current = self.navigator?.currentLocation {
                self.saveUnlessUnsettled(current)
            }
        }
    }

    /// Holds back a new navigator's not-yet-scrolled reports until it reports
    /// any other place. There is no time limit: how long the first report
    /// takes depends on the machine, and a late chapter-start report must
    /// still be held back.
    private func awaitSettling(at locator: Locator?) {
        settleTask?.cancel()
        settleTask = nil
        if let locator, (locator.locations.progression ?? 0) > Self.startTolerance {
            pendingOpenLocator = locator
        } else {
            pendingOpenLocator = nil
        }
    }

    /// The navigator reported the chapter's start instead of `pending`: ask
    /// again once the web view has had a moment to finish loading (a jump
    /// while Readium is still loading is ignored, and it reports each place
    /// only once, so this cannot loop).
    private func resendPendingOpen(_ pending: Locator) {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, let navigator = self.navigator,
                  self.pendingOpenLocator == pending else { return }
            self.settleTask = nil
            _ = await navigator.go(to: pending, options: NavigatorGoOptions(animated: false))
        }
    }

    private static let startTolerance = 0.0001

    /// True for a report that only means the navigator has not scrolled yet:
    /// the start of the resource it was asked to open further into.
    nonisolated static func isUnsettledLoad(_ reported: Locator, opening target: Locator) -> Bool {
        guard (target.locations.progression ?? 0) > startTolerance,
              reported.href.isEquivalentTo(target.href) else { return false }
        return (reported.locations.progression ?? 0) <= startTolerance
    }

    /// Saves `locator` unless it is a new navigator's not-yet-scrolled start
    /// (see `pendingOpenLocator`), in which case the open is sent again.
    private func saveUnlessUnsettled(_ locator: Locator) {
        if let pending = pendingOpenLocator {
            if Self.isUnsettledLoad(locator, opening: pending) {
                resendPendingOpen(pending)
                return
            }
            pendingOpenLocator = nil
            settleTask?.cancel()
            settleTask = nil
        }
        save(locator)
    }

    private func save(_ locator: Locator) {
        anchor = locator
        model.reportVisible(epubLocation: ReadingLocation(locator: locator))
        bridge.didReport(locator)
    }

    private func updateBackground() {
        guard let navigator else { return }
        view.backgroundColor = navigator.settings.effectiveBackgroundColor.uiColor
    }

    // MARK: - Responder chain (custom editing actions)

    override func target(forAction action: Selector, withSender sender: Any?) -> Any? {
        if let target = bridge.editingActionTarget, target.responds(to: action) {
            return target
        }
        return super.target(forAction: action, withSender: sender)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if let target = bridge.editingActionTarget, target.responds(to: action) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    // MARK: - NavigatorDelegate

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard navigator === self.navigator else { return }
        if isRestoringAnchor {
            // Rotation or resize in flight: remember nothing until the
            // anchor has been restored (see `restoreAnchorAfterRelayout`).
            return
        }
        saveUnlessUnsettled(locator)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        model.loadError = "\(error)"
    }

    func navigator(_ navigator: Navigator, presentExternalURL url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return }
        let destination = url.host() ?? url.absoluteString
        let alert = UIAlertController(
            title: "Leave the book?",
            message: "This link opens \(destination) in \(scheme == "mailto" ? "Mail" : "Safari").",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in
            UIApplication.shared.open(url)
        })
        present(alert, animated: true)
    }

    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
        UIEdgeInsets(top: surfaceLayout.topInset, left: 0, bottom: surfaceLayout.bottomInset, right: 0)
    }

    func navigator(_ navigator: VisualNavigator, presentationDidChange presentation: VisualNavigatorPresentation) {
        updateBackground()
    }

    // MARK: - SelectableNavigatorDelegate

    func navigator(_ navigator: SelectableNavigator, shouldShowMenuForSelection selection: Selection) -> Bool {
        bridge.onSelectionChange?(selection)
        return bridge.shouldShowMenuForSelection?(selection) ?? true
    }

    func navigator(_ navigator: SelectableNavigator, canPerformAction action: EditingAction, for selection: Selection) -> Bool {
        bridge.canPerformAction?(action, selection) ?? true
    }
}
