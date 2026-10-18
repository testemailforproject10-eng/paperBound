//
//  EPUBReaderSurfaceTests.swift
//  PaperboundTests
//
//  The EPUB reading surface: where the navigator sits (single page, spread,
//  the Duo fold, cut-outs), tap zones, the navigator bridge, and — hosted in a
//  real window on the Sample.epub fixture — opening at the saved Locator,
//  saving as the reader moves, restoring on reopen, and staying on the same
//  text when the screen changes shape.
//

import ReadiumNavigator
import ReadiumShared
import SwiftData
import XCTest
@testable import Paperbound

// MARK: - Layout

final class EPUBSurfaceLayoutTests: XCTestCase {

    func testPhonePortraitIsOneColumnClearOfTheIsland() {
        let layout = EPUBSurfaceLayout.make(
            size: CGSize(width: 393, height: 852),
            safeAreaInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        )
        XCTAssertEqual(layout.columnCount, 1)
        XCTAssertEqual(layout.frame, CGRect(x: 0, y: 0, width: 393, height: 852))
        XCTAssertGreaterThanOrEqual(layout.topInset, 59 + EPUBSurfaceLayout.verticalPadding)
        XCTAssertGreaterThanOrEqual(layout.bottomInset, 34)
    }

    func testNothingReservedStillKeepsReadiumsMinimumMargins() {
        let layout = EPUBSurfaceLayout.make(size: CGSize(width: 820, height: 1180), safeAreaInsets: .zero)
        XCTAssertEqual(layout.topInset, EPUBSurfaceLayout.minimumTopInset)
        XCTAssertEqual(layout.bottomInset, EPUBSurfaceLayout.minimumBottomInset)
        XCTAssertEqual(layout.columnCount, 1, "a portrait tablet reads one column")
    }

    func testDuoCoverSensorStripNarrowsTheTextInsteadOfLoweringIt() {
        // Seen on the Duo cover screen: an 84 pt full-height strip on the right.
        let size = DuoDisplayReference.coverScreen
        let strip = CGRect(x: size.width - 84, y: 0, width: 84, height: size.height)
        let layout = EPUBSurfaceLayout.make(size: size, safeAreaInsets: .zero, reservedRegions: [strip])
        XCTAssertEqual(layout.frame, CGRect(x: 0, y: 0, width: size.width - 84, height: size.height))
        XCTAssertEqual(layout.topInset, EPUBSurfaceLayout.minimumTopInset)
        XCTAssertEqual(layout.columnCount, 1)
    }

    func testCameraHoleAtTheTopLowersTheText() {
        let hole = CGRect(x: 180, y: 10, width: 40, height: 40)
        let layout = EPUBSurfaceLayout.make(
            size: CGSize(width: 400, height: 860), safeAreaInsets: .zero, reservedRegions: [hole]
        )
        XCTAssertEqual(layout.frame.width, 400)
        XCTAssertEqual(layout.topInset, 50 + EPUBSurfaceLayout.verticalPadding)
    }

    func testLandscapeCutOutOnTheSideNarrowsTheFrame() {
        let layout = EPUBSurfaceLayout.make(
            size: CGSize(width: 852, height: 393),
            safeAreaInsets: UIEdgeInsets(top: 0, left: 59, bottom: 21, right: 59)
        )
        XCTAssertEqual(layout.frame, CGRect(x: 59, y: 0, width: 852 - 118, height: 393))
        XCTAssertEqual(layout.columnCount, 2, "a landscape phone wide enough for two columns gets a spread")
    }

    func testDuoInnerDisplayFoldGetsTwoColumnsCentredOnTheFold() {
        let size = DuoDisplayReference.innerScreen
        let fold = CGRect(x: size.width / 2 - 6, y: 0, width: 12, height: size.height)
        let layout = EPUBSurfaceLayout.make(
            size: size, safeAreaInsets: UIEdgeInsets(top: 24, left: 0, bottom: 20, right: 0),
            reservedRegions: [fold], divisionRegion: fold, divisionAxis: .vertical, posture: .bookLike
        )
        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertEqual(layout.frame.midX, fold.midX, accuracy: 1)
        XCTAssertEqual(layout.columnGap, 12)
        XCTAssertEqual(layout.topInset, 24 + EPUBSurfaceLayout.verticalPadding,
                       "the fold itself is not treated as a cut-out")
    }

    func testOffCentreFoldKeepsTheGapOnTheFold() {
        // A fold 40 pt right of centre: the frame shrinks symmetrically around it.
        let size = CGSize(width: 900, height: 700)
        let fold = CGRect(x: 480, y: 0, width: 10, height: 700)
        let layout = EPUBSurfaceLayout.make(
            size: size, safeAreaInsets: .zero, divisionRegion: fold, divisionAxis: .vertical, posture: .bookLike
        )
        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertEqual(layout.frame.midX, fold.midX, accuracy: 1)
        XCTAssertEqual(layout.frame.maxX, 900, accuracy: 1)
    }

    func testFoldTooCloseToTheEdgeReadsOnTheLargerPanel() {
        let size = CGSize(width: 700, height: 900)
        let fold = CGRect(x: 120, y: 0, width: 10, height: 900)
        let layout = EPUBSurfaceLayout.make(
            size: size, safeAreaInsets: .zero, divisionRegion: fold, divisionAxis: .vertical, posture: .bookLike
        )
        XCTAssertEqual(layout.columnCount, 1)
        XCTAssertEqual(layout.frame, CGRect(x: 130, y: 0, width: 570, height: 900))
    }

    func testHorizontalFoldUsesTheLargerPanel() {
        let size = DuoDisplayReference.innerScreenLandscape   // 951 × 669
        let fold = CGRect(x: 0, y: 300, width: size.width, height: 12)
        let layout = EPUBSurfaceLayout.make(
            size: size, safeAreaInsets: .zero, divisionRegion: fold, divisionAxis: .horizontal, posture: .bookLike
        )
        XCTAssertEqual(layout.columnCount, 1)
        // Lower panel (357) is larger than the upper (300): text starts below the fold.
        XCTAssertGreaterThanOrEqual(layout.topInset, fold.maxY)
    }

    func testOpenBookPostureWithoutAReportedFoldStillSpreads() {
        // Hinge says open, but no division region: two columns, gap in the middle.
        let layout = EPUBSurfaceLayout.make(
            size: DuoDisplayReference.innerScreen, safeAreaInsets: .zero, posture: .bookLike
        )
        XCTAssertEqual(layout.columnCount, 2)
        XCTAssertEqual(layout.frame.midX, DuoDisplayReference.innerScreen.width / 2, accuracy: 0.5)
    }

    func testFoldedDeviceNeverSpreads() {
        let layout = EPUBSurfaceLayout.make(
            size: CGSize(width: 900, height: 500), safeAreaInsets: .zero, posture: .folded
        )
        XCTAssertEqual(layout.columnCount, 1)
    }

    func testTapZonesMatchThePDFReader() {
        XCTAssertEqual(EPUBTapZone(x: 10, width: 400), .left)
        XCTAssertEqual(EPUBTapZone(x: 111, width: 400), .left)
        XCTAssertEqual(EPUBTapZone(x: 113, width: 400), .middle)
        XCTAssertEqual(EPUBTapZone(x: 200, width: 400), .middle)
        XCTAssertEqual(EPUBTapZone(x: 289, width: 400), .right)
        XCTAssertEqual(EPUBTapZone(x: 0, width: 0), .middle)
    }

    func testTwoColumnsAreForcedThroughReadiumCSS() {
        let two = EPUBNavigatorContainerController.rsProperties(for: 2, columnGap: 12).cssProperties()
        XCTAssertEqual(two["--RS__colCount"] ?? nil, "2")
        XCTAssertEqual(two["--RS__colGap"] ?? nil, "0.00000px", "a CSS gap would drift every page")
        XCTAssertEqual(two["--RS__pageGutter"] ?? nil, "30.00000px")
        let wideFold = EPUBNavigatorContainerController.rsProperties(for: 2, columnGap: 60).cssProperties()
        XCTAssertEqual(wideFold["--RS__pageGutter"] ?? nil, "42.00000px", "each side covers half the fold")
        XCTAssertNil(EPUBNavigatorContainerController.rsProperties(for: 2, columnGap: 0).cssProperties()["--RS__pageGutter"] ?? nil)
        let one = EPUBNavigatorContainerController.rsProperties(for: 1, columnGap: 0).cssProperties()
        XCTAssertEqual(one["--RS__colCount"] ?? nil, "1")
    }

    func testOnlyTheChapterStartOfAnUnscrolledOpenIsHeldBack() throws {
        func locator(_ href: String, _ progression: Double?) throws -> Locator {
            Locator(href: try XCTUnwrap(AnyURL(string: href)), mediaType: .xhtml,
                    locations: .init(progression: progression))
        }
        let isUnsettled = EPUBNavigatorContainerController.isUnsettledLoad
        let target = try locator("OEBPS/chapter3.xhtml", 1.0 / 3)
        XCTAssertTrue(isUnsettled(try locator("OEBPS/chapter3.xhtml", 0), target),
                      "the web view has not scrolled to the saved place yet")
        XCTAssertTrue(isUnsettled(try locator("OEBPS/chapter3.xhtml", nil), target))
        XCTAssertFalse(isUnsettled(try locator("OEBPS/chapter3.xhtml", 1.0 / 3), target), "arrived")
        XCTAssertFalse(isUnsettled(try locator("OEBPS/chapter3.xhtml", 2.0 / 3), target),
                       "any other place in the chapter is a real report")
        XCTAssertFalse(isUnsettled(try locator("OEBPS/chapter2.xhtml", 0), target), "another chapter")
        XCTAssertFalse(isUnsettled(try locator("OEBPS/chapter3.xhtml", 0), try locator("OEBPS/chapter3.xhtml", 0)),
                       "opening at a chapter's start holds nothing back")
    }
}

// MARK: - Bridge

@MainActor
final class EPUBNavigatorBridgeTests: XCTestCase {

    func testSurfaceLayoutKeysWinOverSubmittedPreferences() {
        let bridge = EPUBNavigatorBridge()
        bridge.submit(EPUBPreferences(columnCount: .two, fontSize: 1.4, scroll: true))
        XCTAssertEqual(bridge.submittedPreferences.fontSize, 1.4)
        XCTAssertEqual(bridge.effectivePreferences.fontSize, 1.4)
        XCTAssertEqual(bridge.effectivePreferences.scroll, false, "always paginated")
        XCTAssertEqual(bridge.effectivePreferences.columnCount, .one)

        var spread = EPUBSurfaceLayout.empty
        spread.columnCount = 2
        bridge.setSurfaceLayout(spread)
        XCTAssertTrue(bridge.isShowingSpread)
        XCTAssertEqual(bridge.effectivePreferences.columnCount, .two)
    }

    func testSubmitReplacesRatherThanMerges() {
        let bridge = EPUBNavigatorBridge()
        bridge.submit(EPUBPreferences(fontSize: 1.4, lineHeight: 1.6))
        bridge.submit(EPUBPreferences(fontSize: 1.2))
        XCTAssertEqual(bridge.effectivePreferences.fontSize, 1.2)
        XCTAssertNil(bridge.effectivePreferences.lineHeight)
    }

    func testCreationTimeSettingsBumpTheConfigurationVersion() {
        let bridge = EPUBNavigatorBridge()
        let start = bridge.configurationVersion
        bridge.editingActions = [.copy]
        bridge.decorationTemplates = [:]
        bridge.fontFamilyDeclarations = []
        XCTAssertEqual(bridge.configurationVersion, start + 3)
        let configuration = bridge.makeConfiguration()
        XCTAssertEqual(configuration.editingActions, [.copy])
        XCTAssertTrue(configuration.decorationTemplates.isEmpty)
    }

    func testDecorationsAreRememberedWithoutANavigator() throws {
        let bridge = EPUBNavigatorBridge()
        let locator = Locator(href: try XCTUnwrap(AnyURL(string: "OEBPS/chapter1.xhtml")), mediaType: .xhtml)
        let decoration = Decoration(id: "a", locator: locator, style: .highlight(tint: .yellow))
        bridge.apply([decoration], in: "highlights")
        XCTAssertEqual(bridge.decorations(in: "highlights").map(\.id), ["a"])
        bridge.apply([], in: "highlights")
        XCTAssertTrue(bridge.decorations(in: "highlights").isEmpty)
        XCTAssertFalse(bridge.isAttached)
        XCTAssertNil(bridge.settings)
    }
}

// MARK: - Hosted navigator

@MainActor
final class EPUBReaderSurfaceHostedTests: XCTestCase {

    private func sampleURL() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Sample", withExtension: "epub"))
    }

    private struct Harness {
        let container: ModelContainer
        let store: LibraryStore
        let book: Book
        let settings: AppSettings
        let cleanup: () -> Void

        @MainActor
        func makeModel() async throws -> ReaderViewModel {
            let model = ReaderViewModel(book: book, settings: settings, store: store, context: container.mainContext)
            await model.load()
            XCTAssertNil(model.loadError)
            XCTAssertNotNil(model.epubEngine)
            return model
        }
    }

    private func makeHarness() throws -> Harness {
        let container = try ModelContainer(for: Book.self, Bookmark.self, Highlight.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = LibraryStore.unavailable()
        let name = "surface-\(UUID()).epub"
        let book = Book(title: "Sample", fileName: name, format: .epub, contentFingerprint: name)
        let file = store.fileURL(for: book)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try sampleURL(), to: file)
        container.mainContext.insert(book)
        let suite = "surface-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        return Harness(container: container, store: store, book: book, settings: settings) {
            try? FileManager.default.removeItem(at: file)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private struct Hosted {
        let host: HostedTestWindow
        let controller: EPUBNavigatorContainerController
        var window: UIWindow { host.window }
        func close() async { await host.close() }
    }

    private func host(_ model: ReaderViewModel, size: CGSize) throws -> Hosted {
        let controller = EPUBNavigatorContainerController(
            publication: try XCTUnwrap(model.epubEngine?.publication),
            model: model,
            initialLocator: model.currentLocation.readiumLocator
        )
        let host = try HostedTestWindow(controller, size: size)
        // Torn down fully after the test: a hidden window keeps its web view
        // alive and stalls later full-reader tests (see HostedTestWindow).
        addTeardownBlock { await host.close() }
        return Hosted(host: host, controller: controller)
    }

    /// Waits until `condition` holds, polling the run loop.
    private func waitUntil(_ what: String, timeout: TimeInterval = 20,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("Timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func outlineLocation(_ prefix: String, in model: ReaderViewModel) throws -> ReadingLocation {
        try XCTUnwrap(model.epubEngine?.outline().first { $0.title.hasPrefix(prefix) }?.location)
    }

    func testOpensAtTheSavedLocatorSavesMovesAndRestoresOnReopen() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        // First session: jump to chapter III and read on two screens.
        let first = try await harness.makeModel()
        let chapter3 = try outlineLocation("III.", in: first)
        first.go(to: chapter3)
        let hosted = try host(first, size: CGSize(width: 390, height: 844))

        try await waitUntil("the navigator to attach and report") {
            first.epubBridge.isAttached && first.epubBridge.currentLocator != nil
        }
        XCTAssertEqual(first.epubBridge.attachCount, 1)
        XCTAssertEqual(first.currentLocation.epubHref, "OEBPS/chapter3.xhtml")

        let navigator = try XCTUnwrap(first.epubBridge.navigator)
        _ = await navigator.goForward(options: NavigatorGoOptions(animated: false))
        try await waitUntil("the next screen to be saved") {
            (first.currentLocation.readiumLocator?.locations.progression ?? 0) > 0
                || first.currentLocation.epubHref != "OEBPS/chapter3.xhtml"
        }
        let saved = first.currentLocation
        let savedIndex = first.currentPageIndex
        XCTAssertEqual(harness.book.savedLocation, saved, "every move is written to the book")
        first.unload()
        await hosted.close()

        // Second session, as after a relaunch: the engine opens at the save.
        let second = try await harness.makeModel()
        XCTAssertEqual(second.currentLocation.epubHref, saved.epubHref)
        XCTAssertEqual(second.currentPageIndex, savedIndex)
        // Every report is written to the book, so record them all: under load
        // Readium can report the chapter's start before it has scrolled to
        // the save, and that must never overwrite it.
        var reports: [Locator] = []
        second.epubBridge.addLocationObserver { reports.append($0) }
        _ = try host(second, size: CGSize(width: 390, height: 844))
        try await waitUntil("the reopened navigator to report") { second.epubBridge.currentLocator != nil }
        // Longer than the surface waits before sending an unscrolled load on.
        try await Task.sleep(for: .seconds(2))
        let wanted = saved.readiumLocator?.locations.progression ?? -2
        XCTAssertFalse(reports.isEmpty)
        for report in reports {
            XCTAssertEqual(report.href.string, saved.epubHref)
            XCTAssertEqual(report.locations.progression ?? -1, wanted, accuracy: 0.001,
                           "the reopened reader shows the same screen and saves nothing else")
        }
        XCTAssertEqual(harness.book.savedLocation?.readiumLocator?.locations.progression ?? -1,
                       wanted, accuracy: 0.001)
        second.unload()
    }

    func testNavigationRequestsMoveTheNavigatorAndAreSaved() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let model = try await harness.makeModel()
        let hosted = try host(model, size: CGSize(width: 390, height: 844))
        try await waitUntil("the navigator to report") { model.epubBridge.currentLocator != nil }

        // The slider path: a position index becomes a navigation request.
        let target = (model.epubEngine?.positions.count ?? 1) - 1
        model.go(toPageIndex: target, source: .slider)
        let request = try XCTUnwrap(model.epubNavigationRequest)
        hosted.controller.follow(request)
        try await waitUntil("the last position") { model.currentPageIndex == target }
        XCTAssertEqual(model.progress, 1, accuracy: 0.0001)
        model.unload()
    }

    func testPreferencesReachTheLiveNavigatorAndAreReplayedOnRebuild() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let model = try await harness.makeModel()
        // Submitted before the navigator exists.
        model.epubBridge.submit(EPUBPreferences(fontSize: 1.5))
        let hosted = try host(model, size: CGSize(width: 390, height: 844))
        try await waitUntil("the navigator to attach") { model.epubBridge.isAttached }
        XCTAssertEqual(model.epubBridge.settings?.fontSize, 1.5)
        XCTAssertEqual(model.epubBridge.settings?.columnCount, .one)

        model.epubBridge.submit(EPUBPreferences(fontSize: 1.2))
        XCTAssertEqual(model.epubBridge.settings?.fontSize, 1.2)

        var attached: [EPUBNavigatorViewController] = []
        model.epubBridge.whenAttached { attached.append($0) }
        XCTAssertEqual(attached.count, 1, "runs at once for the navigator on screen")
        model.epubBridge.editingActions = [.copy]   // creation-time: rebuild
        hosted.controller.configurationVersion = model.epubBridge.configurationVersion
        hosted.controller.view.layoutIfNeeded()
        try await waitUntil("the rebuilt navigator") { attached.count == 2 }
        XCTAssertEqual(model.epubBridge.settings?.fontSize, 1.2, "preferences survive a rebuild")
        model.unload()
    }

    func testRotatingToASpreadKeepsTheSameText() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let model = try await harness.makeModel()
        model.go(to: try outlineLocation("II.", in: model))
        let hosted = try host(model, size: DuoDisplayReference.innerScreen)
        try await waitUntil("the navigator to report") { model.epubBridge.currentLocator != nil }
        XCTAssertFalse(model.epubBridge.isShowingSpread, "669 pt portrait, no fold reported: one column")
        let before = model.currentLocation
        XCTAssertEqual(before.epubHref, "OEBPS/chapter2.xhtml")

        // The Duo turned to landscape: wide enough for two columns.
        hosted.window.frame = CGRect(origin: .zero, size: DuoDisplayReference.innerScreenLandscape)
        hosted.controller.view.frame = hosted.window.bounds
        hosted.controller.view.layoutIfNeeded()
        try await waitUntil("the spread") {
            model.epubBridge.isShowingSpread && model.epubBridge.attachCount == 2
        }
        try await waitUntil("the spread navigator to report") {
            model.epubBridge.navigator?.currentLocation != nil
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(model.epubBridge.settings?.columnCount, .two)
        XCTAssertEqual(model.currentLocation.epubHref, before.epubHref, "same chapter after the change")
        XCTAssertEqual(model.currentPageIndex, try XCTUnwrap(model.epubEngine?.positionIndex(for: before)),
                       "same Readium position after the change")
        model.unload()
    }
}
