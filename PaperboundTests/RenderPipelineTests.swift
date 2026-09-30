//
//  RenderPipelineTests.swift
//  PaperboundTests
//
//  Exercises the geometry and the compositor without a document: a nil content
//  image still has to produce a believable sheet, and the same sheet has to
//  come out pixel-identical twice running.
//

import CoreGraphics
import XCTest
@testable import Paperbound

final class RenderPipelineTests: XCTestCase {

    private let documentID = UUID(uuidString: "9A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9")!
    private let sheet = CGRect(x: 0, y: 0, width: 600, height: 800)

    private func condition(
        _ environment: ReadingEnvironment,
        page: String = "pdf:3"
    ) -> PageConditionData {
        DamageGenerator.generate(
            documentID: documentID,
            bookSeed: 0xABCD_1234_5678_9F00,
            stablePageID: page,
            environment: environment,
            spine: .left
        )
    }

    private func request(
        _ environment: ReadingEnvironment,
        page: String = "pdf:3",
        size: CGSize = CGSize(width: 600, height: 800)
    ) -> PageCompositionRequest {
        PageCompositionRequest(
            content: nil,
            pixelSize: size,
            environment: environment,
            condition: condition(environment, page: page),
            spine: .left,
            textureSeed: 0x1111_2222_3333_4444,
            spineShadowScale: 1.0
        )
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    // MARK: - Geometry

    func testTheSheetFillsItsSurface() {
        // Paper reaches the edge of the space it is given, so on screen it
        // reaches the bezel and the display's own corners clip it.
        let surface = CGRect(x: 0, y: 0, width: 400, height: 600)
        for presentation in BookPresentation.allCases {
            XCTAssertEqual(
                PageCompositor.sheetRect(in: surface, presentation: presentation),
                surface,
                "\(presentation) held the sheet away from the edge."
            )
        }
    }

    func testTheMarginAroundTheTextBlockMatchesPresentation() {
        // `surfaceInset` now sets the paper margin inside the sheet rather than
        // dead board around it, so a hardcover still reads wider-margined.
        let sheet = CGRect(x: 0, y: 0, width: 400, height: 600)
        let aspect = 648.0 / 432.0
        let minimal = PageCompositor.contentRect(in: sheet, presentation: .minimal, pageAspectRatio: aspect)
        let hardcover = PageCompositor.contentRect(in: sheet, presentation: .hardcover, pageAspectRatio: aspect)

        XCTAssertGreaterThan(minimal.width, hardcover.width)
        XCTAssertTrue(sheet.insetBy(dx: -0.001, dy: -0.001).contains(hardcover))
    }

    func testTheTextBlockKeepsTheDocumentProportionsInAnyShapeOfSheet() {
        // The whole point of separating sheet from content: a sheet shaped like
        // the screen must not stretch the type.
        let aspect = 648.0 / 432.0
        for sheet in [
            CGRect(x: 0, y: 0, width: 386, height: 522),   // Duo cover
            CGRect(x: 0, y: 0, width: 425, height: 635),   // Duo inner, one leaf
            CGRect(x: 0, y: 0, width: 900, height: 400)    // absurdly wide
        ] {
            let content = PageCompositor.contentRect(
                in: sheet,
                presentation: .paperback,
                pageAspectRatio: aspect
            )
            XCTAssertEqual(
                content.height / content.width,
                CGFloat(aspect),
                accuracy: 0.01,
                "Type was stretched inside a \(Int(sheet.width))×\(Int(sheet.height)) sheet."
            )
            XCTAssertTrue(sheet.insetBy(dx: -0.001, dy: -0.001).contains(content))
        }
    }

    func testTearsOvershootTheSheetBoundary() {
        var environment = ReadingEnvironment.oldJournal
        environment.intensity = 1.0
        let damage = condition(environment).subtractiveDamage
        XCTAssertFalse(damage.isEmpty)

        let uncut = RaggedPath.sheetPath(in: sheet, cornerRadius: 0)
        let cut = RaggedPath.cutSheetPath(in: sheet, cornerRadius: 0, subtractive: damage)
        XCTAssertEqual(uncut.boundingBox.width, sheet.width, accuracy: 0.001)
        // Edge cut-outs deliberately extend past the boundary so no one-pixel
        // sliver of paper survives along a torn edge.
        XCTAssertGreaterThanOrEqual(cut.boundingBox.width, sheet.width)
    }

    /// Area actually covered by a path, by rasterizing it.
    private func coveredPixels(of path: CGPath, in size: CGSize, evenOdd: Bool) -> Int {
        let width = Int(size.width)
        let height = Int(size.height)
        var buffer = [UInt8](repeating: 0, count: width * height)
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(path)
            ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
        }
        return buffer.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }
    }

    func testTheCutMaskRemovesRealAreaFromTheSheet() {
        var heavy = ReadingEnvironment.oldJournal
        heavy.intensity = 1.0
        let damage = condition(heavy, page: "pdf:11").subtractiveDamage
        XCTAssertFalse(damage.isEmpty)

        let uncut = RaggedPath.sheetPath(in: sheet, cornerRadius: 0)
        let cut = RaggedPath.cutSheetPath(in: sheet, cornerRadius: 0, subtractive: damage)

        let whole = coveredPixels(of: uncut, in: sheet.size, evenOdd: false)
        let surviving = coveredPixels(of: cut, in: sheet.size, evenOdd: true)

        XCTAssertLessThan(surviving, whole, "Damage must remove area from the sheet.")
        // Sanity: a page should be damaged, not destroyed.
        XCTAssertGreaterThan(Double(surviving) / Double(whole), 0.5)
    }

    func testHeavierConditionsRemoveMoreArea() {
        func survivingFraction(_ condition: PageCondition) -> Double {
            var environment = ReadingEnvironment.oldJournal
            environment.condition = condition
            environment.intensity = 1.0
            let uncut = RaggedPath.sheetPath(in: sheet, cornerRadius: 0)
            let whole = Double(coveredPixels(of: uncut, in: sheet.size, evenOdd: false))
            var total = 0.0
            for page in 0..<8 {
                let damage = self.condition(environment, page: "pdf:\(page)").subtractiveDamage
                let cut = RaggedPath.cutSheetPath(in: sheet, cornerRadius: 0, subtractive: damage)
                total += Double(coveredPixels(of: cut, in: sheet.size, evenOdd: true)) / whole
            }
            return total / 8
        }

        let pristine = survivingFraction(.pristine)
        let light = survivingFraction(.lightWear)
        let damaged = survivingFraction(.damaged)

        XCTAssertEqual(pristine, 1.0, accuracy: 0.001)
        XCTAssertLessThan(light, pristine)
        XCTAssertLessThan(damaged, light)
    }

    func testATearActuallyErasesDocumentContent() throws {
        // A fully-inked page: anywhere the sheet survives, the composite is dark.
        let inkSize = CGSize(width: 600, height: 800)
        let black: CGImage = {
            let ctx = CGContext(
                data: nil,
                width: Int(inkSize.width),
                height: Int(inkSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(origin: .zero, size: inkSize))
            return ctx.makeImage()!
        }()

        func darkPixelCount(_ environment: ReadingEnvironment) throws -> Int {
            var request = self.request(environment, page: "pdf:11")
            request.content = black
            let image = try XCTUnwrap(PageCompositor.shared.composite(request))
            let data = pixels(image)
            return stride(from: 0, to: data.count, by: 4).reduce(0) { total, index in
                total + (data[index] < 40 && data[index + 3] > 200 ? 1 : 0)
            }
        }

        var heavy = ReadingEnvironment.oldJournal
        heavy.intensity = 1.0
        heavy.presentation = .minimal

        var pristine = heavy
        pristine.condition = .pristine

        let intact = try darkPixelCount(pristine)
        let torn = try darkPixelCount(heavy)

        XCTAssertGreaterThan(intact, 100_000, "A fully inked pristine page should be mostly dark.")
        XCTAssertLessThan(torn, intact, "Where the sheet is torn away, the ink must go with it.")
    }

    func testCutoutPathsAreProducedOnlyForSubtractiveDamage() {
        var environment = ReadingEnvironment.oldJournal
        environment.intensity = 1.0
        let all = condition(environment).effectiveDamage
        let subtractive = all.filter(\.isSubtractive)
        XCTAssertLessThan(subtractive.count, all.count, "There should be stains too.")
        XCTAssertEqual(
            RaggedPath.cutoutPaths(in: sheet, subtractive: subtractive).count,
            subtractive.count
        )
    }

    func testRaggedPolylineIsDeterministicAndSubdivides() {
        var a = SplitMix64(seed: 77)
        var b = SplitMix64(seed: 77)
        let first = RaggedPath.raggedPolyline(
            from: .zero, to: CGPoint(x: 100, y: 0), roughness: 0.8, subdivisions: 4, rng: &a
        )
        let second = RaggedPath.raggedPolyline(
            from: .zero, to: CGPoint(x: 100, y: 0), roughness: 0.8, subdivisions: 4, rng: &b
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 17) // 2 endpoints, four rounds of midpoints.
        XCTAssertEqual(first.first, .zero)
        XCTAssertEqual(first.last, CGPoint(x: 100, y: 0))
    }

    func testStraightLineStaysStraightWithZeroRoughness() {
        var rng = SplitMix64(seed: 3)
        let points = RaggedPath.raggedPolyline(
            from: .zero, to: CGPoint(x: 80, y: 0), roughness: 0, subdivisions: 3, rng: &rng
        )
        for point in points {
            XCTAssertEqual(point.y, 0, accuracy: 0.0001)
        }
    }

    func testHolePathIsClosedAndRoughlyCentred() {
        let hole = Hole(center: NormalizedPoint(0.5, 0.5), radius: 0.1, irregularity: 0.5, seed: 21)
        let path = RaggedPath.holePath(hole, in: sheet)
        let box = path.boundingBox
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(box.midX, sheet.midX, accuracy: sheet.width * 0.05)
        XCTAssertEqual(box.midY, sheet.midY, accuracy: sheet.height * 0.05)
        // radius is scaled by the shorter side (600), so the blob is ~120 wide.
        XCTAssertGreaterThan(box.width, 60)
        XCTAssertLessThan(box.width, 220)
    }

    // MARK: - Compositor

    func testCompositorProducesTheRequestedPixelSize() throws {
        let image = try XCTUnwrap(PageCompositor.shared.composite(request(.wellReadPaperback)))
        XCTAssertEqual(image.width, 600)
        XCTAssertEqual(image.height, 800)
    }

    func testCompositorIsDeterministic() throws {
        let first = try XCTUnwrap(PageCompositor.shared.composite(request(.oldJournal)))
        let second = try XCTUnwrap(PageCompositor.shared.composite(request(.oldJournal)))
        XCTAssertEqual(pixels(first), pixels(second), "The same sheet must render to the same pixels.")
    }

    func testEnchantedInkBuildsDeterministicSimulationInputs() async throws {
        var environment = ReadingEnvironment.cleanPaper
        environment.ink = .enchanted
        var composition = request(environment)
        let contentContext = CGContext(
            data: nil,
            width: 600,
            height: 800,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        contentContext.setFillColor(gray: 0, alpha: 1)
        contentContext.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        composition.content = try XCTUnwrap(contentContext.makeImage())

        let first = try await PageCompositor.shared.compositePage(composition)
        let second = try await PageCompositor.shared.compositePage(composition)
        let finishedPixels = pixels(first.image)
        let backgroundPixels = pixels(try XCTUnwrap(first.revealBackground))

        XCTAssertEqual(first.image.width, first.revealBackground?.width)
        XCTAssertEqual(first.image.height, first.revealBackground?.height)
        XCTAssertEqual(finishedPixels, pixels(second.image))
        XCTAssertEqual(backgroundPixels, pixels(try XCTUnwrap(second.revealBackground)))
        XCTAssertEqual(first.revealSeed, second.revealSeed)
        XCTAssertNotEqual(finishedPixels, backgroundPixels)
        // A corner outside the document's fitted content rectangle is identical
        // in both passes: the paper, wear, and lighting stay visible.
        XCTAssertEqual(Array(finishedPixels.prefix(4)), Array(backgroundPixels.prefix(4)))
        XCTAssertEqual(
            first.memoryCost,
            first.image.bytesPerRow * first.image.height
                + first.revealBackground!.bytesPerRow * first.revealBackground!.height
        )
    }

    func testDuoReservedRegionClipsOnlyForegroundDocumentPixels() throws {
        var composition = request(.cleanPaper)
        let contentContext = CGContext(
            data: nil,
            width: 600,
            height: 800,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        contentContext.setFillColor(gray: 0, alpha: 1)
        contentContext.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        composition.content = try XCTUnwrap(contentContext.makeImage())
        let unrestricted = try XCTUnwrap(PageCompositor.shared.composite(composition))

        composition.reservedRegions = [CGRect(x: 0.45, y: 0, width: 0.1, height: 1)]
        let reserved = try XCTUnwrap(PageCompositor.shared.composite(composition))
        let clearPixels = pixels(reserved)
        let fullPixels = pixels(unrestricted)

        func rgba(_ data: [UInt8], x: Int, y: Int) -> ArraySlice<UInt8> {
            let offset = (y * 600 + x) * 4
            return data[offset..<(offset + 4)]
        }
        XCTAssertNotEqual(rgba(clearPixels, x: 300, y: 400), rgba(fullPixels, x: 300, y: 400))
        XCTAssertEqual(rgba(clearPixels, x: 100, y: 400), rgba(fullPixels, x: 100, y: 400))
    }

    func testDamagedSheetDiffersFromPristineSheet() throws {
        var pristine = ReadingEnvironment.oldJournal
        pristine.condition = .pristine
        let damagedImage = try XCTUnwrap(PageCompositor.shared.composite(request(.oldJournal)))
        let pristineImage = try XCTUnwrap(PageCompositor.shared.composite(request(pristine)))
        XCTAssertNotEqual(pixels(damagedImage), pixels(pristineImage))
    }

    /// The compositor works in a y-down space while CoreGraphics orients images
    /// along +y. Get that wrong and every page renders mirrored, so pin it.
    func testContentIsNotFlippedVertically() throws {
        let inkSize = CGSize(width: 600, height: 800)
        // Top half inked, bottom half blank.
        let topHeavy: CGImage = {
            let ctx = CGContext(
                data: nil,
                width: Int(inkSize.width),
                height: Int(inkSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            // Row 0 of the bitmap is the image's top row.
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: inkSize.height / 2, width: inkSize.width, height: inkSize.height / 2))
            return ctx.makeImage()!
        }()

        var environment = ReadingEnvironment.cleanPaper
        environment.presentation = .minimal
        var composition = request(environment)
        composition.content = topHeavy

        let image = try XCTUnwrap(PageCompositor.shared.composite(composition))
        let data = pixels(image)
        let width = image.width
        let height = image.height

        func averageBrightness(rows: Range<Int>) -> Double {
            var total = 0.0
            var count = 0
            for row in rows {
                for column in stride(from: 0, to: width, by: 4) {
                    total += Double(data[(row * width + column) * 4])
                    count += 1
                }
            }
            return count > 0 ? total / Double(count) : 0
        }

        let top = averageBrightness(rows: 10..<(height / 2 - 10))
        let bottom = averageBrightness(rows: (height / 2 + 10)..<(height - 10))
        XCTAssertLessThan(top, bottom - 40, "The inked half of the page must stay on top.")
    }

    func testMaterialChangesPixelsButNotDamage() throws {
        var cream = ReadingEnvironment.wellReadPaperback
        cream.material = .cream
        var parchment = ReadingEnvironment.wellReadPaperback
        parchment.material = .parchment

        XCTAssertEqual(condition(cream).damage, condition(parchment).damage)

        let creamImage = try XCTUnwrap(PageCompositor.shared.composite(request(cream)))
        let parchmentImage = try XCTUnwrap(PageCompositor.shared.composite(request(parchment)))
        XCTAssertNotEqual(pixels(creamImage), pixels(parchmentImage))
    }

    func testDegenerateSizesAreRejectedRatherThanCrashing() {
        XCTAssertNil(
            PageCompositor.shared.composite(
                request(.wellReadPaperback, size: CGSize(width: 2, height: 2))
            )
        )
    }

    // MARK: - Paper texture

    func testPaperTextureIsCachedAndCorrectlySized() throws {
        let factory = PaperTextureFactory.shared
        factory.purge()
        let first = try XCTUnwrap(factory.texture(material: .aged, pixelSize: CGSize(width: 300, height: 400), seed: 9))
        let second = try XCTUnwrap(factory.texture(material: .aged, pixelSize: CGSize(width: 300, height: 400), seed: 9))
        XCTAssertTrue(first === second, "The same request must hit the cache.")
        // Bucketed up to the next multiple of 64.
        XCTAssertEqual(first.width, 320)
        XCTAssertEqual(first.height, 448)
    }

    func testDifferentMaterialsProduceDifferentTextures() throws {
        let factory = PaperTextureFactory.shared
        let white = try XCTUnwrap(factory.texture(material: .white, pixelSize: CGSize(width: 128, height: 128), seed: 1))
        let dark = try XCTUnwrap(factory.texture(material: .dark, pixelSize: CGSize(width: 128, height: 128), seed: 1))
        XCTAssertNotEqual(pixels(white), pixels(dark))
    }

    /// A hole must open onto something darker. If a later change repaints the
    /// sheet base over the under-sheet, holes flatten into painted-on shapes
    /// and this is the assertion that notices.
    func testAHoleRevealsADarkerSheetBelow() throws {
        var environment = ReadingEnvironment.cleanPaper
        environment.presentation = .minimal      // no stack, no inset
        environment.lighting = .flat             // no vignette to confuse the reading

        let hole = Hole(center: NormalizedPoint(0.5, 0.5), radius: 0.13, irregularity: 0.15, seed: 5)
        let condition = PageConditionData(
            documentID: documentID,
            stablePageID: "pdf:0",
            seed: 1,
            intensity: 1,
            environmentIdentity: "test",
            damage: [.hole(hole)]
        )
        let composition = PageCompositionRequest(
            content: nil,
            pixelSize: CGSize(width: 600, height: 800),
            environment: environment,
            condition: condition,
            spine: .left,
            textureSeed: 7,
            spineShadowScale: 0
        )

        let image = try XCTUnwrap(PageCompositor.shared.composite(composition))
        let data = pixels(image)
        let width = image.width

        func brightness(x: Int, y: Int) -> Double {
            let offset = (y * width + x) * 4
            return (Double(data[offset]) + Double(data[offset + 1]) + Double(data[offset + 2])) / 3
        }

        let throughTheHole = brightness(x: 300, y: 400)
        let onThePaper = brightness(x: 300, y: 120)
        XCTAssertLessThan(
            throughTheHole,
            onThePaper - 15,
            "The sheet seen through a hole must be clearly darker than the page around it."
        )
    }

    // MARK: - Render scale

    func testRenderScalePassesThroughBelowTheCap() {
        let size = CGSize(width: 390, height: 585)
        XCTAssertEqual(PageRenderScale.scale(for: size, displayScale: 3), 3, accuracy: 0.0001)
        let pixels = PageRenderScale.pixelSize(for: size, displayScale: 3)
        XCTAssertEqual(pixels.width, 1170, accuracy: 0.5)
        XCTAssertEqual(pixels.height, 1755, accuracy: 0.5)
    }

    func testRenderScaleIsCappedForLargeSurfaces() {
        let size = CGSize(width: 1024, height: 1366)
        let scale = PageRenderScale.scale(for: size, displayScale: 3)
        XCTAssertLessThan(scale, 3)
        XCTAssertGreaterThanOrEqual(scale, 1)
        let pixels = PageRenderScale.pixelSize(for: size, displayScale: 3)
        XCTAssertLessThanOrEqual(pixels.width * pixels.height, PageRenderScale.maximumPixels + 1)
    }

    func testRenderScaleNeverDropsBelowOne() {
        let huge = CGSize(width: 4000, height: 4000)
        XCTAssertGreaterThanOrEqual(PageRenderScale.scale(for: huge, displayScale: 3), 1)
        XCTAssertEqual(PageRenderScale.scale(for: .zero, displayScale: 2), 2, accuracy: 0.0001)
    }

    // MARK: - Cache keys

    func testRenderKeyDistinguishesEnvironments() {
        let base = PageRenderKey(
            stablePageID: "pdf:1",
            renderIdentity: ReadingEnvironment.cleanPaper.renderIdentity,
            pixelWidth: 600,
            pixelHeight: 800,
            spineShadowBucket: 10,
            spine: .left
        )
        var other = base
        other.renderIdentity = ReadingEnvironment.oldJournal.renderIdentity
        XCTAssertNotEqual(base.stringValue, other.stringValue)
        XCTAssertEqual(base.stringValue, base.stringValue)
    }

    func testRenderKeyDistinguishesDuoReservedGeometry() {
        var first = PageRenderKey(
            stablePageID: "pdf:1",
            renderIdentity: "x",
            pixelWidth: 600,
            pixelHeight: 800,
            spineShadowBucket: 10,
            spine: .left,
            safeToken: "divider-left"
        )
        var second = first
        second.safeToken = "divider-right"
        XCTAssertNotEqual(first.stringValue, second.stringValue)
        first.safeToken = second.safeToken
        XCTAssertEqual(first.stringValue, second.stringValue)
    }

    func testCacheStoresAndReturnsImages() throws {
        let cache = PageRenderCache(costLimitBytes: 8 * 1024 * 1024)
        let key = PageRenderKey(
            stablePageID: "pdf:1",
            renderIdentity: "x",
            pixelWidth: 100,
            pixelHeight: 100,
            spineShadowBucket: 10,
            spine: .left
        )
        XCTAssertNil(cache.image(for: key))
        let image = try XCTUnwrap(PageCompositor.shared.composite(
            request(.cleanPaper, size: CGSize(width: 100, height: 100))
        ))
        cache.store(image, for: key)
        XCTAssertNotNil(cache.image(for: key))
        cache.removeAll()
        XCTAssertNil(cache.image(for: key))
    }

    func testCacheRetainsAllEnchantedImagesAndChargesThemAgainstItsLimit() throws {
        let image = try XCTUnwrap(PageCompositor.shared.composite(request(
            .cleanPaper,
            size: CGSize(width: 100, height: 100)
        )))
        let page = PageRenderResult(image: image, revealBackground: image, revealSeed: 7)
        let cache = PageRenderCache(costLimitBytes: page.memoryCost + 1)
        let key = PageRenderKey(
            stablePageID: "pdf:reveal",
            renderIdentity: "enchanted",
            pixelWidth: 100,
            pixelHeight: 100,
            spineShadowBucket: 10,
            spine: .left
        )

        cache.store(page, for: key)
        let cached = try XCTUnwrap(cache.page(for: key))
        XCTAssertNotNil(cached.revealBackground)
        XCTAssertEqual(cached.memoryCost, image.bytesPerRow * image.height * 2)
    }

    func testCacheEvictsSpeculationBeforeOlderVisitedPages() throws {
        let image = try XCTUnwrap(PageCompositor.shared.composite(request(.cleanPaper, size: CGSize(width: 64, height: 96))))
        let page = PageRenderResult(image: image, revealBackground: image, revealSeed: 7)
        let cache = PageRenderCache(costLimitBytes: page.memoryCost * 2)
        func key(_ id: String) -> PageRenderKey {
            PageRenderKey(stablePageID: id, renderIdentity: "ink", pixelWidth: 64,
                          pixelHeight: 96, spineShadowBucket: 10, spine: .left)
        }
        cache.store(page, for: key("visited"))
        cache.store(page, for: key("speculative"), speculative: true)
        cache.store(page, for: key("incoming"))
        XCTAssertNotNil(cache.page(for: key("visited")))
        XCTAssertNil(cache.page(for: key("speculative")))
        XCTAssertNotNil(cache.page(for: key("incoming")))
    }
}
