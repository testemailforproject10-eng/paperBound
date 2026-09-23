//
//  LayoutAndModelTests.swift
//  PaperboundTests
//
//  Surface layout, and the small model types the rest of the app leans on.
//

import CoreGraphics
import XCTest
@testable import Paperbound

final class LayoutTests: XCTestCase {

    private let bookAspect = 648.0 / 432.0   // the sample book's 6 × 9 page

    private func layout(
        _ size: CGSize,
        preference: SpreadPreference = .automatic,
        presentation: BookPresentation = .paperback
    ) -> ReadingSurfaceLayout {
        DeviceLayoutCoordinator.layout(
            surfaceSize: size,
            pageAspectRatio: bookAspect,
            presentation: presentation,
            preference: preference
        )
    }

    // MARK: - Mode selection

    func testPhoneStaysSinglePage() {
        let portrait = layout(CGSize(width: 393, height: 852))
        XCTAssertEqual(portrait.mode, .single)
        XCTAssertEqual(portrait.spineFraction, 0)
    }

    func testPhoneLandscapeStaysSinglePageBecauseAPageWouldBeTooNarrow() {
        // 852 wide leaves ~417pt of box per page, but the fitted page is
        // capped by the 393pt height and comes out 262pt wide — under the
        // floor. One page on the same surface is 262pt too, so it is the
        // floor, not the no-shrink rule, that refuses this one.
        XCTAssertEqual(layout(CGSize(width: 852, height: 393)).mode, .single)
    }

    func testWideSurfaceOpensToASpread() {
        let wide = layout(CGSize(width: 1180, height: 820))
        XCTAssertEqual(wide.mode, .spread)
        XCTAssertGreaterThan(wide.spineFraction, 0)
    }

    func testPreferenceOverridesAutomatic() {
        let wide = CGSize(width: 1180, height: 820)
        XCTAssertEqual(layout(wide, preference: .alwaysSingle).mode, .single)
        XCTAssertEqual(layout(wide, preference: .alwaysSpread).mode, .spread)
    }

    func testAlwaysSpreadStillRefusesWhenPagesWouldBeUnreadable() {
        XCTAssertEqual(
            layout(CGSize(width: 393, height: 852), preference: .alwaysSpread).mode,
            .single,
            "Two 190pt columns are not a reading experience."
        )
    }

    func testASpreadIsRefusedWhenItWouldShrinkThePage() {
        // The Duo's inner display in portrait. Two 328pt columns clear the
        // 320pt floor, so the floor alone cannot decide this — but one page
        // on the same surface is 573pt, and the spread would hand two fifths
        // of the screen back as empty board.
        let portrait = CGSize(width: 669, height: 860)
        let result = layout(portrait)
        XCTAssertEqual(result.mode, .single)

        // The sheet fills the 669pt display; the readable text block inside it
        // is 573pt, and that is the number the rule is about.
        let sheetWidth = DeviceLayoutCoordinator
            .surfaceRects(in: portrait, layout: result, pageAspectRatio: bookAspect)
            .first?.width ?? 0
        XCTAssertEqual(sheetWidth, 669, accuracy: 0.5)

        let readableWidth = DeviceLayoutCoordinator
            .readableRects(in: portrait, layout: result, pageAspectRatio: bookAspect)
            .first?.width ?? 0
        XCTAssertEqual(readableWidth, 573.33, accuracy: 0.5)
    }

    func testASpreadIsOfferedWhenItCostsNothing() {
        // The same display in landscape. Each half is already capped by the
        // surface height, so two pages are drawn at exactly the size one page
        // would have been: the reader gets the second page for free.
        let landscape = CGSize(width: 951, height: 590)
        let spread = layout(landscape)
        XCTAssertEqual(spread.mode, .spread)

        func pageWidth(_ surfaceLayout: ReadingSurfaceLayout) -> CGFloat {
            DeviceLayoutCoordinator
                .readableRects(in: landscape, layout: surfaceLayout, pageAspectRatio: bookAspect)
                .first?.width ?? 0
        }

        XCTAssertEqual(
            pageWidth(spread),
            pageWidth(layout(landscape, preference: .alwaysSingle)),
            accuracy: 0.5,
            "A spread is only offered because it costs the reader no page width."
        )
    }

    func testMinimalPresentationHasNoSpineGutter() {
        let spread = layout(CGSize(width: 1180, height: 820), presentation: .minimal)
        let journal = layout(CGSize(width: 1180, height: 820), presentation: .oldJournal)
        XCTAssertLessThan(spread.spineFraction, journal.spineFraction)
    }

    // MARK: - Posture

    func testPostureIsInferredFromGeometryAndSaysSo() {
        let wide = layout(CGSize(width: 1180, height: 820))
        XCTAssertEqual(wide.posture, .bookLike)
        XCTAssertFalse(wide.reportsRealPosture, "No public hinge API exists in this SDK; the layout must admit it.")
        XCTAssertTrue(wide.reservedRegions.isEmpty)
    }

    func testBookPostureDeepensTheSpineShadow() {
        let flat = layout(CGSize(width: 393, height: 852))
        let open = layout(CGSize(width: 1180, height: 820))
        XCTAssertGreaterThan(open.spineShadowScale, flat.spineShadowScale)
    }

    func testDegenerateSizesFallBackToSinglePage() {
        XCTAssertEqual(layout(.zero).mode, .single)
        XCTAssertEqual(layout(CGSize(width: 0, height: 800)).mode, .single)
    }

    // MARK: - Rects

    func testSpreadProducesTwoNonOverlappingRects() {
        let size = CGSize(width: 1180, height: 820)
        let surfaceLayout = layout(size)
        let rects = DeviceLayoutCoordinator.surfaceRects(
            in: size, layout: surfaceLayout, pageAspectRatio: bookAspect
        )
        XCTAssertEqual(rects.count, 2)
        XCTAssertLessThanOrEqual(rects[0].maxX, rects[1].minX)
        XCTAssertEqual(rects[0].width, rects[1].width, accuracy: 0.5)
    }

    func testSinglePageProducesOneCentredRect() {
        let size = CGSize(width: 393, height: 852)
        let rects = DeviceLayoutCoordinator.surfaceRects(
            in: size, layout: layout(size), pageAspectRatio: bookAspect
        )
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].midX, size.width / 2, accuracy: 0.5)
    }

    func testFittedRectPreservesAspectRatioAndFitsInside() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let fitted = DeviceLayoutCoordinator.fittedRect(in: bounds, aspectRatio: 1.5)
        XCTAssertEqual(fitted.height / fitted.width, 1.5, accuracy: 0.001)
        XCTAssertLessThanOrEqual(fitted.width, bounds.width + 0.001)
        XCTAssertLessThanOrEqual(fitted.height, bounds.height + 0.001)
        XCTAssertEqual(fitted.midX, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(fitted.midY, bounds.midY, accuracy: 0.001)
    }

    func testFittedRectHandlesWideAspect() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let fitted = DeviceLayoutCoordinator.fittedRect(in: bounds, aspectRatio: 0.5)
        XCTAssertEqual(fitted.width, 400, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 200, accuracy: 0.001)
    }
}

final class ModelTests: XCTestCase {

    // MARK: - Locations

    func testReadingLocationRoundTripsThroughJSON() throws {
        let locations: [ReadingLocation] = [
            .start,
            .pdfPage(index: 41, yOffset: 0.25),
            .epubLocator(href: "chapter3.xhtml", progression: 0.4, totalProgression: 0.18)
        ]
        for location in locations {
            let data = try JSONEncoder().encode(location)
            XCTAssertEqual(try JSONDecoder().decode(ReadingLocation.self, from: data), location)
        }
    }

    func testPdfPageIndexIsOnlyReportedForFixedLayout() {
        XCTAssertEqual(ReadingLocation.pdfPage(index: 4, yOffset: 0).pdfPageIndex, 4)
        XCTAssertNil(ReadingLocation.start.pdfPageIndex)
        XCTAssertNil(
            ReadingLocation.epubLocator(href: "a.xhtml", progression: 0.1, totalProgression: nil).pdfPageIndex
        )
    }

    func testDisplayLabels() {
        XCTAssertEqual(
            ReadingLocation.pdfPage(index: 4, yOffset: 0).displayLabel(pageCount: 100),
            "Page 5 of 100"
        )
        XCTAssertEqual(ReadingLocation.start.displayLabel(pageCount: 10), "Beginning")
    }

    // MARK: - Environments

    func testPristineVariantOnlyChangesCondition() {
        let original = ReadingEnvironment.oldJournal
        let pristine = original.pristineVariant
        XCTAssertEqual(pristine.condition, .pristine)
        XCTAssertEqual(pristine.material, original.material)
        XCTAssertEqual(pristine.presentation, original.presentation)
        XCTAssertEqual(pristine.lighting, original.lighting)
    }

    func testDamageIdentityIgnoresAppearanceOnlyDimensions() {
        var a = ReadingEnvironment.wellReadPaperback
        var b = ReadingEnvironment.wellReadPaperback
        a.material = .white
        a.lighting = .flat
        a.presentation = .minimal
        a.id = "custom.1"
        b.material = .dark
        b.lighting = .directional
        b.presentation = .hardcover
        b.id = "custom.2"
        XCTAssertEqual(a.damageIdentity, b.damageIdentity)
        XCTAssertNotEqual(a.renderIdentity, b.renderIdentity)
    }

    func testEnvironmentRoundTripsThroughJSON() throws {
        let original = ReadingEnvironment.libraryHardcover
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(ReadingEnvironment.self, from: data), original)
    }

    func testIntensityIsClampedOnInit() {
        let high = ReadingEnvironment(
            name: "x", material: .cream, condition: .damaged,
            presentation: .minimal, lighting: .flat, intensity: 4.0
        )
        XCTAssertEqual(high.intensity, 1.0)
    }

    func testPresetsAreUniquelyIdentified() {
        let ids = ReadingEnvironment.presets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testOnlyPristinePresetsLeaveContentIntact() {
        XCTAssertFalse(ReadingEnvironment.cleanPaper.condition.removesContent)
        XCTAssertTrue(ReadingEnvironment.oldJournal.condition.removesContent)
    }

    // MARK: - Colour

    func testHexInitialiserMatchesComponents() {
        let color = RGBAColor(hex: 0x80_40_20)
        XCTAssertEqual(color.red, 128.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(color.green, 64.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(color.blue, 32.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(color.alpha, 1.0, accuracy: 0.0001)
    }

    func testScalingAndBlendingStayInRange() {
        let color = RGBAColor(0.8, 0.6, 0.4, 1)
        let dark = color.scaled(by: 0.5)
        XCTAssertEqual(dark.red, 0.4, accuracy: 0.0001)
        let over = color.scaled(by: 4)
        XCTAssertLessThanOrEqual(over.red, 1.0)

        let blended = RGBAColor(0, 0, 0, 1).blended(with: RGBAColor(1, 1, 1, 1), amount: 0.25)
        XCTAssertEqual(blended.red, 0.25, accuracy: 0.0001)
    }

    func testLuminanceOrdersLightAndDarkStock() {
        XCTAssertGreaterThan(PaperMaterial.white.baseColor.luminance, PaperMaterial.aged.baseColor.luminance)
        XCTAssertGreaterThan(PaperMaterial.aged.baseColor.luminance, PaperMaterial.dark.baseColor.luminance)
        XCTAssertTrue(PaperMaterial.dark.invertsInk)
        XCTAssertFalse(PaperMaterial.cream.invertsInk)
    }

    // MARK: - Book

    func testWearSeedSurvivesTheSignedIntegerRoundTrip() {
        let book = Book(
            title: "t", fileName: "f.pdf", format: .pdf,
            contentFingerprint: "abc", wearSeed: UInt64.max
        )
        XCTAssertEqual(book.wearSeed, UInt64.max)
        book.wearSeed = 0x8000_0000_0000_0001
        XCTAssertEqual(book.wearSeed, 0x8000_0000_0000_0001)
        book.wearSeed = 0
        XCTAssertEqual(book.wearSeed, 0)
    }

    func testSavedLocationAndEnvironmentAreOptional() {
        let book = Book(title: "t", fileName: "f.pdf", format: .pdf, contentFingerprint: "abc")
        XCTAssertNil(book.savedLocation)
        XCTAssertNil(book.savedEnvironment)
        book.savedLocation = .pdfPage(index: 9, yOffset: 0.5)
        book.savedEnvironment = .oldJournal
        XCTAssertEqual(book.savedLocation, .pdfPage(index: 9, yOffset: 0.5))
        XCTAssertEqual(book.savedEnvironment, .oldJournal)
    }

    func testFormatParsingIsCaseInsensitive() {
        XCTAssertEqual(BookFormat.from(fileExtension: "PDF"), .pdf)
        XCTAssertEqual(BookFormat.from(fileExtension: "epub"), .epub)
        XCTAssertNil(BookFormat.from(fileExtension: "mobi"))
    }

    func testCapabilitiesDescribeFixedLayout() {
        let fixed = ReaderCapabilities.fixedLayout
        XCTAssertTrue(fixed.contains(.textSelection))
        XCTAssertTrue(fixed.contains(.fullTextSearch))
        XCTAssertFalse(fixed.contains(.reflowTypography))
    }
}
