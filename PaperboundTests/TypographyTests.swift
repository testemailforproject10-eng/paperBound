//
//  TypographyTests.swift
//  PaperboundTests
//
//  EPUB typography: the settings model, its mapping onto Readium's
//  `EPUBPreferences`, persistence (global and per book), the WCAG contrast
//  check, and — hosting the real navigator — that the preferences reach the
//  page's CSS and that changing them keeps the reader on the same text.
//

import ReadiumNavigator
import ReadiumShared
import XCTest
@testable import Paperbound

final class TypographyTests: XCTestCase {

    // MARK: - Model

    func testDefaultIsPublisherTypesettingOnPaperWithSnugMargin() {
        let d = TypographySettings.default
        XCTAssertEqual(d.font, .publisher)
        XCTAssertEqual(d.fontScale, 1.0)
        XCTAssertEqual(d.theme, .paper)
        XCTAssertNil(d.customTextColor)
        XCTAssertNil(d.lineHeight)
        XCTAssertEqual(d.justification, .publisher)
        XCTAssertTrue(d.usesPublisherTypesetting)
        XCTAssertFalse(d.overridesPublisherStyles)
        // A small gap: tighter than Readium's own 1.0, but not touching.
        XCTAssertEqual(d.pageMargins, 0.5)
        XCTAssertGreaterThan(d.pageMargins, 0)
        XCTAssertLessThan(d.pageMargins, 1.0)
    }

    func testInitClampsOutOfRangeValues() {
        let s = TypographySettings(fontScale: 9, pageMargins: -1, lineHeight: 0.2)
        XCTAssertEqual(s.fontScale, 2.5)
        XCTAssertEqual(s.pageMargins, 0.25)
        XCTAssertEqual(s.lineHeight, 1.0)
        XCTAssertEqual(TypographySettings(fontScale: 0.1).fontScale, 0.75)
    }

    func testStepsAreSortedAndInsideTheirRanges() {
        for (steps, range) in [
            (TypographySettings.fontScaleSteps, TypographySettings.fontScaleRange),
            (TypographySettings.pageMarginSteps, TypographySettings.pageMarginsRange),
            (TypographySettings.lineHeightSteps, TypographySettings.lineHeightRange),
        ] {
            XCTAssertEqual(steps, steps.sorted())
            XCTAssertTrue(steps.allSatisfy(range.contains))
        }
        XCTAssertEqual(TypographySettings.fontScaleSteps.first, 0.75)
        XCTAssertEqual(TypographySettings.fontScaleSteps.last, 2.5)
        XCTAssertTrue(TypographySettings.fontScaleSteps.contains(1.0))
        XCTAssertTrue(TypographySettings.pageMarginSteps.contains(TypographySettings.defaultPageMargins))
    }

    func testOnlySpacingAndAlignmentOverridePublisherStyles() {
        var s = TypographySettings(font: .georgia, fontScale: 1.5, theme: .night, pageMargins: 2)
        XCTAssertFalse(s.overridesPublisherStyles)
        s.lineHeight = 1.5
        XCTAssertTrue(s.overridesPublisherStyles)
        s.lineHeight = nil
        s.justification = .left
        XCTAssertTrue(s.overridesPublisherStyles)
    }

    // MARK: - Mapping to EPUBPreferences

    func testMappingOfDefaultsKeepsPublisherStyles() {
        let p = TypographyPreferences.preferences(for: .default)
        XCTAssertNil(p.fontFamily)
        XCTAssertEqual(p.fontSize, 1.0)
        XCTAssertEqual(p.publisherStyles, true)
        XCTAssertNil(p.lineHeight)
        XCTAssertNil(p.textAlign)
        XCTAssertEqual(p.pageMargins, 0.5)
        XCTAssertEqual(p.theme, .light)
        XCTAssertEqual(p.backgroundColor, ReadiumNavigator.Color(hex: "#FBF8F1"))
        XCTAssertEqual(p.textColor, ReadiumNavigator.Color(hex: "#1E1B17"))
        XCTAssertNil(p.imageFilter)
    }

    func testMappingLeavesLayoutKeysToTheReaderSurface() {
        let p = TypographyPreferences.preferences(for: TypographySettings(
            font: .palatino, fontScale: 2.5, theme: .night, lineHeight: 2, justification: .justified
        ))
        XCTAssertNil(p.columnCount)
        XCTAssertNil(p.spread)
        XCTAssertNil(p.scroll)
        XCTAssertNil(p.readingProgression)
        XCTAssertNil(p.offsetFirstPage)
        XCTAssertNil(p.verticalText)
        // So a layout merge in either order is the same.
        let layout = EPUBPreferences(columnCount: .two, spread: .never)
        XCTAssertEqual(layout.merging(p), p.merging(layout))
        XCTAssertEqual(layout.merging(p).columnCount, .two)
        XCTAssertEqual(layout.merging(p).fontFamily, FontFamily(rawValue: "Palatino"))
    }

    func testMappingOfEveryFont() {
        let expected: [TypographyFont: String?] = [
            .publisher: nil,
            .newYork: "ui-serif",
            .georgia: "Georgia",
            .palatino: "Palatino",
            .iowan: "Iowan Old Style",
            .avenirNext: "Avenir Next",
            .sfPro: "system-ui",
            .openDyslexic: "OpenDyslexic",
        ]
        XCTAssertEqual(Set(expected.keys), Set(TypographyFont.allCases))
        for font in TypographyFont.allCases {
            let p = TypographyPreferences.preferences(for: TypographySettings(font: font))
            XCTAssertEqual(p.fontFamily?.rawValue, expected[font]!, "\(font)")
        }
        // Readium declares OpenDyslexic's @font-face itself; the name must match.
        XCTAssertEqual(TypographyFont.openDyslexic.cssFamily, FontFamily.openDyslexic.rawValue)
    }

    func testMappingOfSizeMarginsSpacingAndAlignment() {
        let s = TypographySettings(fontScale: 1.3, pageMargins: 0.25, lineHeight: 1.65, justification: .justified)
        let p = TypographyPreferences.preferences(for: s)
        XCTAssertEqual(p.fontSize, 1.3)
        XCTAssertEqual(p.pageMargins, 0.25)
        XCTAssertEqual(p.lineHeight, 1.65)
        XCTAssertEqual(p.textAlign, .justify)
        XCTAssertEqual(p.publisherStyles, false)

        let left = TypographyPreferences.preferences(for: TypographySettings(justification: .left))
        XCTAssertEqual(left.textAlign, .left)
        XCTAssertEqual(left.publisherStyles, false)
        XCTAssertNil(left.lineHeight)
    }

    func testMappingOfThemes() {
        let cases: [(TypographyTheme, Theme, String, String, ImageFilter?)] = [
            (.paper, .light, "#FBF8F1", "#1E1B17", nil),
            (.sepia, .sepia, "#F2E6CE", "#3B2D1C", nil),
            (.grey, .dark, "#4A4A4D", "#F0EFEB", nil),
            (.night, .dark, "#121212", "#C9C4BA", .darken),
        ]
        for (theme, readiumTheme, background, text, filter) in cases {
            let p = TypographyPreferences.preferences(for: TypographySettings(theme: theme))
            XCTAssertEqual(p.theme, readiumTheme, "\(theme)")
            XCTAssertEqual(p.backgroundColor, ReadiumNavigator.Color(hex: background), "\(theme)")
            XCTAssertEqual(p.textColor, ReadiumNavigator.Color(hex: text), "\(theme)")
            XCTAssertEqual(p.imageFilter, filter, "\(theme)")
        }
    }

    func testCustomTextColourReplacesTheThemeInk() {
        let s = TypographySettings(theme: .sepia, customTextColor: RGBAColor(hex: 0x1D2B4A))
        let p = TypographyPreferences.preferences(for: s)
        XCTAssertEqual(p.textColor, ReadiumNavigator.Color(hex: "#1D2B4A"))
        XCTAssertEqual(p.backgroundColor, ReadiumNavigator.Color(hex: "#F2E6CE"))
    }

    func testColourPackingRoundsChannels() {
        XCTAssertEqual(TypographyPreferences.readiumColor(RGBAColor(1, 0, 0.5)).rawValue, 0xFF0080)
        XCTAssertEqual(TypographyPreferences.readiumColor(RGBAColor(2, -1, 0)).rawValue, 0xFF0000)
    }

    // MARK: - Contrast

    func testContrastRatioMatchesWCAGReferenceValues() {
        let black = RGBAColor(0, 0, 0), white = RGBAColor(1, 1, 1)
        XCTAssertEqual(ColorContrast.ratio(black, white), 21, accuracy: 0.001)
        XCTAssertEqual(ColorContrast.ratio(white, black), 21, accuracy: 0.001)
        XCTAssertEqual(ColorContrast.ratio(white, white), 1, accuracy: 0.001)
        // #777777 on white is the textbook "just fails AA" grey (4.48:1).
        XCTAssertEqual(ColorContrast.ratio(RGBAColor(hex: 0x777777), white), 4.48, accuracy: 0.01)
        // #767676 is the lightest grey that passes (4.54:1).
        XCTAssertEqual(ColorContrast.ratio(RGBAColor(hex: 0x767676), white), 4.54, accuracy: 0.01)
    }

    func testEveryThemeInkClearsAAA() {
        for theme in TypographyTheme.allCases {
            let s = TypographySettings(theme: theme)
            XCTAssertGreaterThanOrEqual(s.contrastRatio, 7, "\(theme): \(s.contrastRatio)")
            XCTAssertFalse(s.hasLowContrast)
        }
    }

    func testLowContrastCustomInkIsFlagged() {
        let pale = TypographySettings(theme: .paper, customTextColor: RGBAColor(hex: 0xBBBBBB))
        XCTAssertTrue(pale.hasLowContrast)
        XCTAssertLessThan(pale.contrastRatio, ColorContrast.aaMinimum)
        let nightNavy = TypographySettings(theme: .night, customTextColor: RGBAColor(hex: 0x1D2B4A))
        XCTAssertTrue(nightNavy.hasLowContrast)
        let fine = TypographySettings(theme: .night, customTextColor: RGBAColor(hex: 0xE3B266))
        XCTAssertFalse(fine.hasLowContrast)
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let s = TypographySettings(
            font: .iowan, fontScale: 1.45, theme: .grey,
            customTextColor: RGBAColor(hex: 0xE8E2D4), pageMargins: 1.5,
            lineHeight: 1.8, justification: .justified
        )
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(TypographySettings.self, from: data), s)
    }

    func testDecodingIsForgivingOfMissingAndUnknownValues() throws {
        let empty = try JSONDecoder().decode(TypographySettings.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, .default)

        let future = Data(#"{"font":"comicSans","fontScale":99,"theme":"ultraviolet","justification":"centre","pageMargins":1,"newKey":true}"#.utf8)
        let decoded = try JSONDecoder().decode(TypographySettings.self, from: future)
        XCTAssertEqual(decoded.font, .publisher)
        XCTAssertEqual(decoded.fontScale, 2.5)
        XCTAssertEqual(decoded.theme, .paper)
        XCTAssertEqual(decoded.justification, .publisher)
        XCTAssertEqual(decoded.pageMargins, 1)
    }

    #if DEBUG
    func testDemoLaunchSpecParses() {
        let s = TypographySettings.parseDemo("font=georgia,size=2.5,theme=night,margins=0.25,spacing=1.5,align=justified,ink=E3B266,bogus=1")
        XCTAssertEqual(s, TypographySettings(
            font: .georgia, fontScale: 2.5, theme: .night,
            customTextColor: RGBAColor(hex: 0xE3B266), pageMargins: 0.25,
            lineHeight: 1.5, justification: .justified
        ))
    }
    #endif

    // MARK: - Persistence

    @MainActor
    func testGlobalTypographyPersistsAcrossRelaunch() throws {
        let suite = "TypographyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppSettings(defaults: defaults).epubTypography, .default)
        let chosen = TypographySettings(font: .newYork, fontScale: 1.17, theme: .sepia, pageMargins: 0.25)
        AppSettings(defaults: defaults).epubTypography = chosen
        // A fresh AppSettings over the same defaults is a relaunch.
        XCTAssertEqual(AppSettings(defaults: defaults).epubTypography, chosen)
    }

    @MainActor
    func testPerBookOverrideRoundTripsAndFallsBackToGlobal() throws {
        let suite = "TypographyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookA = UUID(), bookB = UUID()

        let settings = AppSettings(defaults: defaults)
        settings.setTypography(TypographySettings(fontScale: 1.3), for: bookA)
        // No override yet: the edit went to the global default.
        XCTAssertEqual(settings.epubTypography.fontScale, 1.3)
        XCTAssertEqual(settings.typography(for: bookB).fontScale, 1.3)

        settings.setTypographyOverride(true, for: bookA)
        XCTAssertTrue(settings.hasTypographyOverride(for: bookA))
        // Turning the override on doesn't change what the book shows.
        XCTAssertEqual(settings.typography(for: bookA).fontScale, 1.3)
        settings.setTypography(TypographySettings(font: .openDyslexic, theme: .night), for: bookA)
        XCTAssertEqual(settings.typography(for: bookA).font, .openDyslexic)
        XCTAssertEqual(settings.typography(for: bookB).font, .publisher, "other books keep the global setting")
        XCTAssertEqual(settings.epubTypography.fontScale, 1.3)

        let relaunched = AppSettings(defaults: defaults)
        XCTAssertTrue(relaunched.hasTypographyOverride(for: bookA))
        XCTAssertFalse(relaunched.hasTypographyOverride(for: bookB))
        XCTAssertEqual(relaunched.typography(for: bookA), TypographySettings(font: .openDyslexic, theme: .night))
        XCTAssertEqual(relaunched.typography(for: bookB).fontScale, 1.3)

        relaunched.setTypographyOverride(false, for: bookA)
        XCTAssertEqual(AppSettings(defaults: defaults).typography(for: bookA).fontScale, 1.3)
        XCTAssertFalse(AppSettings(defaults: defaults).hasTypographyOverride(for: bookA))
    }

    func testDamagedOverrideEntriesAreDroppedNotFatal() {
        let good = UUID()
        let json = #"{"\#(good.uuidString)":{"fontScale":1.3},"not-a-uuid":{"fontScale":2},"\#(UUID().uuidString)":42}"#
        let decoded = TypographySettings.decodeOverrides(Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[good]?.fontScale, 1.3)
        XCTAssertTrue(TypographySettings.decodeOverrides(Data("garbage".utf8)).isEmpty)
        XCTAssertEqual(TypographySettings.decodeGlobal(Data("garbage".utf8)), .default)
    }
}

// MARK: - Live navigator

/// Hosts Readium's navigator on the fixture book to check that the mapped
/// preferences become the CSS the page is drawn with, and that changing them
/// keeps the reader on the same text.
@MainActor
final class TypographyNavigatorTests: XCTestCase, EPUBNavigatorDelegate {

    private var locations: [Locator] = []
    private var waiter: (count: Int, expectation: XCTestExpectation)?

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        locations.append(locator)
        if let waiter, locations.count >= waiter.count {
            waiter.expectation.fulfill()
            self.waiter = nil
        }
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        XCTFail("Navigator error: \(error)")
    }

    private func waitForLocation(number count: Int) async {
        guard locations.count < count else { return }
        let e = expectation(description: "location \(count)")
        waiter = (count, e)
        await fulfillment(of: [e], timeout: 20)
    }

    private func computed(_ navigator: EPUBNavigatorViewController, _ js: String) async throws -> String {
        let result = await navigator.evaluateJavaScript(js)
        return try XCTUnwrap(try result.get() as? String)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    func testPreferencesReachTheCSSAndKeepThePosition() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Sample", withExtension: "epub"))
        let engine = try EPUBReadingEngine(documentID: UUID(), fileURL: url, initialLocation: nil)
        try await engine.open()
        let publication = try XCTUnwrap(engine.publication)
        let target = try XCTUnwrap(engine.outline().first { $0.title.hasPrefix("III.") }?.location)

        let initial = TypographySettings(font: .georgia, fontScale: 2.5, theme: .sepia, pageMargins: 0.5)
        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: target.readiumLocator,
            config: .init(preferences: initial.epubPreferences)
        )
        navigator.delegate = self

        // A short window so a chapter spans several pages at a large size,
        // torn down fully after the test (see HostedTestWindow).
        let host = try HostedTestWindow(navigator, size: CGSize(width: 390, height: 420))
        addTeardownBlock { await host.close() }

        await waitForLocation(number: 1)
        XCTAssertEqual(locations.last?.href.string, "OEBPS/chapter3.xhtml")

        // The phone gutter is 20 px; a 0.5 factor leaves 10 px either side.
        let padding = try await computed(navigator, "getComputedStyle(document.body).paddingLeft")
        XCTAssertEqual(padding, "10px")
        let family = try await computed(navigator, "getComputedStyle(document.body).fontFamily")
        XCTAssertTrue(family.contains("Georgia"), family)
        let rootStyle = try await computed(navigator, "document.documentElement.getAttribute('style') || ''")
        XCTAssertTrue(rootStyle.contains("--USER__backgroundColor: #F2E6CE"), rootStyle)
        XCTAssertTrue(rootStyle.contains("--USER__textColor: #3B2D1C"), rootStyle)

        // Move into the chapter so keeping the position means something.
        _ = await navigator.goForward(options: NavigatorGoOptions(animated: false))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let before = try XCTUnwrap(navigator.currentLocation)
        XCTAssertEqual(before.href.string, "OEBPS/chapter3.xhtml", "chapter 3 should span several pages at 250%")
        let beforeProgression = try XCTUnwrap(before.locations.progression)
        XCTAssertGreaterThan(beforeProgression, 0)
        let beforeElement = try await XCTUnwrapAsync(await navigator.firstVisibleElementLocator())

        // Smaller, wider, justified and dark: everything re-flows.
        let changed = TypographySettings(
            font: .newYork, fontScale: 1.0, theme: .night,
            pageMargins: 2.0, lineHeight: 1.8, justification: .justified
        )
        let countBefore = locations.count
        // Through the app's path: the bridge, and the applier that restores
        // the position after the re-flow.
        let bridge = EPUBNavigatorBridge()
        bridge.attach(navigator)
        bridge.submit(initial.epubPreferences)
        let applier = TypographyLiveApplier()
        applier.apply(changed, through: bridge)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(navigator.settings.fontSize, 1.0)
        XCTAssertEqual(navigator.settings.textAlign, .justify)
        XCTAssertEqual(navigator.settings.publisherStyles, false)

        // Give the web view time to re-layout, re-locate and report.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let widerPadding = try await computed(navigator, "getComputedStyle(document.body).paddingLeft")
        XCTAssertEqual(widerPadding, "40px")
        let newFamily = try await computed(navigator, "getComputedStyle(document.body).fontFamily")
        XCTAssertTrue(newFamily.contains("ui-serif"), newFamily)
        let align = try await computed(navigator, "getComputedStyle(document.querySelector('p')).textAlign")
        XCTAssertEqual(align, "justify")

        // Same chapter, and the page now shown contains the text that was
        // at the top before: Readium re-locates by the chapter progression,
        // so the new page starts at or just before the old position.
        let after = try XCTUnwrap(navigator.currentLocation)
        XCTAssertEqual(after.href.string, "OEBPS/chapter3.xhtml")
        let afterProgression = try XCTUnwrap(after.locations.progression)
        XCTAssertLessThanOrEqual(afterProgression, beforeProgression + 0.001)
        // And the element that was first on screen is on screen again.
        let selector = try XCTUnwrap(beforeElement.locations.cssSelector)
        let visible = try await computed(navigator, """
            (function() {
              const el = document.querySelector(\(String(reflecting: selector)));
              if (!el) return 'missing';
              return Array.from(el.getClientRects())
                .some(r => r.right > 0 && r.left < window.innerWidth) ? 'visible' : 'offscreen';
            })()
            """)
        XCTAssertEqual(visible, "visible", "\(selector) after the change")
        XCTAssertGreaterThan(afterProgression, beforeProgression - 0.5,
            "moved from \(beforeProgression) to \(afterProgression); \(locations.count - countBefore) reports")
    }
}
