//
//  SnapshotComparisonTests.swift
//  PaperboundTests
//
//  Produces the side-by-side comparison the brief asks for: the same page of
//  the same book, at the same size, under every page condition.
//
//  The files land in the test host's temporary directory and are also attached
//  to the test result. To pull them out of the simulator:
//
//      xcrun simctl get_app_container booted com.paperbound.reader data
//      open "<that path>/tmp/PaperboundSnapshots"
//
//  `make-snapshots.sh` in the repository root does both steps.
//

import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import Paperbound

@MainActor
final class SnapshotComparisonTests: XCTestCase {

    /// The page of the sample book used for every comparison: it carries body
    /// text, so a tear visibly removes letters.
    private let comparisonPageIndex = 2
    /// A second comparison on the artwork page, so damage can be seen cutting
    /// through a figure rather than through type.
    private let artworkPageOffset = 1

    private var sampleURL: URL!
    private var outputDirectory: URL!

    /// The shared output folder, emptied exactly once per run.
    ///
    /// A `static let` initialiser runs once and only once, which is the point:
    /// the condition set and the Duo set are written by two different tests
    /// into this one folder, and emptying it from `setUp` — which runs before
    /// *each* test — meant whichever test happened to run last was the only
    /// one whose images survived to be copied out.
    private static let sharedOutputDirectory: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperboundSnapshots", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    override func setUp() async throws {
        try await super.setUp()
        sampleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-source-\(UUID().uuidString).pdf")
        try SampleLibrary.write(to: sampleURL)

        outputDirectory = Self.sharedOutputDirectory
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sampleURL)
        try await super.tearDown()
    }

    // MARK: - The comparison

    func testWriteConditionComparisonAtOneFixedPageAndZoom() async throws {
        let documentID = UUID(uuidString: "5C0FFEE0-0000-4000-8000-00000000BEEF")!
        let bookSeed: UInt64 = 0x50AB_1E17_C0FF_EE01

        let engine = try PDFReadingEngine(
            documentID: documentID,
            fileURL: sampleURL,
            initialLocation: nil
        )
        try await engine.open()

        let pages = [
            ("text", comparisonPageIndex),
            ("figure", max(0, engine.pageCount - artworkPageOffset))
        ]

        // One surface size and one page size for every shot — the only thing
        // that changes between images is the condition.
        let surface = CGSize(width: 900, height: 1350)

        var written: [String] = []

        for (label, pageIndex) in pages {
            let location = ReadingLocation.pdfPage(index: pageIndex, yOffset: 0)

            for condition in PageCondition.allCases {
                var environment = ReadingEnvironment.wellReadPaperback
                environment.condition = condition
                environment.intensity = condition == .pristine ? 0 : 0.85

                let sheetRect = PageCompositor.sheetRect(
                    in: CGRect(origin: .zero, size: surface),
                    presentation: environment.presentation
                )
                let content = try await engine.renderPage(at: location, pixelSize: sheetRect.size)

                let damage = DamageGenerator.generate(
                    documentID: documentID,
                    bookSeed: bookSeed,
                    stablePageID: engine.stablePageID(for: location),
                    environment: environment,
                    spine: DamageGenerator.spineEdge(forPageIndex: pageIndex)
                )

                let composed = try XCTUnwrap(
                    PageCompositor.shared.composite(
                        PageCompositionRequest(
                            content: content,
                            pixelSize: surface,
                            environment: environment,
                            condition: damage,
                            spine: DamageGenerator.spineEdge(forPageIndex: pageIndex),
                            textureSeed: StableHash.combine(
                                StableHash.hash(documentID),
                                bookSeed,
                                StableHash.hash(engine.stablePageID(for: location))
                            ),
                            spineShadowScale: 0.85
                        )
                    ),
                    "Compositing failed for \(label)/\(condition.rawValue)"
                )

                let name = "\(label)-page\(pageIndex + 1)-\(condition.rawValue).png"
                try write(composed, named: name)
                written.append(name)

                XCTAssertEqual(composed.width, Int(surface.width))
                XCTAssertEqual(composed.height, Int(surface.height))
            }
        }

        // A material comparison too: same wear, four different stocks.
        let location = ReadingLocation.pdfPage(index: comparisonPageIndex, yOffset: 0)
        for material in PaperMaterial.allCases {
            var environment = ReadingEnvironment.wellReadPaperback
            environment.material = material
            environment.intensity = 0.85

            let sheetRect = PageCompositor.sheetRect(
                in: CGRect(origin: .zero, size: surface),
                presentation: environment.presentation
            )
            let content = try await engine.renderPage(at: location, pixelSize: sheetRect.size)
            let damage = DamageGenerator.generate(
                documentID: documentID,
                bookSeed: bookSeed,
                stablePageID: engine.stablePageID(for: location),
                environment: environment,
                spine: .left
            )
            let composed = try XCTUnwrap(
                PageCompositor.shared.composite(
                    PageCompositionRequest(
                        content: content,
                        pixelSize: surface,
                        environment: environment,
                        condition: damage,
                        spine: .left,
                        textureSeed: 0x1234_5678_9ABC_DEF0,
                        spineShadowScale: 0.85
                    )
                )
            )
            let name = "material-\(material.rawValue).png"
            try write(composed, named: name)
            written.append(name)
        }

        XCTAssertEqual(written.count, PageCondition.allCases.count * 2 + PaperMaterial.allCases.count)

        let index = written.sorted().joined(separator: "\n")
        try Data(index.utf8).write(to: outputDirectory.appendingPathComponent("index.txt"))

        print("Paperbound snapshots written to: \(outputDirectory.path)")
    }

    // MARK: - iPhone Duo

    /// Renders what the Duo shows on each of its displays, through the same
    /// layout coordinator and compositor the live app uses.
    ///
    /// The cover screen can be checked by running the app; the inner screen
    /// cannot, because the simulator here offers no fold control and there is
    /// no Simulator.app. This produces the artifact instead.
    func testWriteDuoSurfaceRenders() async throws {
        let documentID = UUID(uuidString: "D00D00D0-0000-4000-8000-0000000D0001")!
        let bookSeed: UInt64 = 0xD0D0_BEEF_1234_5678

        let engine = try PDFReadingEngine(documentID: documentID, fileURL: sampleURL, initialLocation: nil)
        try await engine.open()

        var environment = ReadingEnvironment.wellReadPaperback
        environment.intensity = 0.7

        // The surfaces the reader actually gets, controls showing. The cover
        // figures are measured from the device; the inner ones come from its
        // reported display size less the same control bars.
        let cases: [(name: String, surface: CGSize, snapshot: DisplaySnapshot)] = [
            (
                "duo-cover-folded",
                CGSize(width: 386, height: 522),
                duoSnapshot(screen: DuoDisplayReference.coverScreen, window: CGSize(width: 386, height: 678), onLargest: false)
            ),
            (
                "duo-inner-portrait",
                CGSize(width: 669, height: 860),
                duoSnapshot(screen: DuoDisplayReference.innerScreen, window: DuoDisplayReference.innerScreen, onLargest: true)
            ),
            (
                "duo-inner-landscape-spread",
                CGSize(width: 951, height: 590),
                duoSnapshot(screen: DuoDisplayReference.innerScreenLandscape, window: DuoDisplayReference.innerScreenLandscape, onLargest: true)
            )
        ]

        var modes: [String: ReadingSurfaceMode] = [:]

        for testCase in cases {
            let layout = DeviceLayoutCoordinator.layout(
                surfaceSize: testCase.surface,
                pageAspectRatio: engine.aspectRatio(at: .pdfPage(index: 2, yOffset: 0)),
                presentation: environment.presentation,
                preference: .automatic,
                provider: DisplayPostureProvider(snapshot: testCase.snapshot)
            )
            modes[testCase.name] = layout.mode

            // Page 2 alone when single; pages 2 and 3 as a spread.
            let pageIndices = layout.mode == .spread ? [2, 3] : [2]

            let image = try await renderReadingSurface(
                surfaceSize: testCase.surface,
                layout: layout,
                pageIndices: pageIndices,
                environment: environment,
                engine: engine,
                documentID: documentID,
                bookSeed: bookSeed,
                scale: 2
            )
            try write(image, named: "\(testCase.name).png")
        }

        // The point of the whole exercise: unfolding changes what you see.
        XCTAssertEqual(modes["duo-cover-folded"], .single)
        XCTAssertEqual(modes["duo-inner-portrait"], .single)
        XCTAssertEqual(modes["duo-inner-landscape-spread"], .spread)

        print("Paperbound snapshots written to: \(outputDirectory.path)")
    }

    private func duoSnapshot(screen: CGSize, window: CGSize, onLargest: Bool) -> DisplaySnapshot {
        DisplaySnapshot(
            screenSize: screen,
            windowSize: window,
            safeAreaInsets: UIEdgeInsets(top: 0, left: 0, bottom: 34, right: 0),
            scale: 3,
            distinctScreensSeen: 2,
            isOnLargestSeenScreen: onLargest,
            largestSeenScreenSize: DuoDisplayReference.innerScreen
        )
    }

    /// Mirrors what `PagedReaderView` puts on screen: the surround, then one
    /// composited sheet per visible page, at the rects the coordinator chose.
    private func renderReadingSurface(
        surfaceSize: CGSize,
        layout: ReadingSurfaceLayout,
        pageIndices: [Int],
        environment: ReadingEnvironment,
        engine: PDFReadingEngine,
        documentID: UUID,
        bookSeed: UInt64,
        scale: CGFloat
    ) async throws -> CGImage {

        let pixelSize = CGSize(width: surfaceSize.width * scale, height: surfaceSize.height * scale)
        let width = Int(pixelSize.width.rounded())
        let height = Int(pixelSize.height.rounded())

        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))

        // y-down, matching the compositor's convention.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(environment.presentation.surroundColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))

        let aspect = engine.aspectRatio(at: .pdfPage(index: pageIndices[0], yOffset: 0))
        let rects = DeviceLayoutCoordinator.surfaceRects(
            in: surfaceSize,
            layout: layout,
            pageAspectRatio: aspect
        )

        for (slot, pageIndex) in pageIndices.enumerated() {
            guard slot < rects.count else { break }
            let rect = rects[slot]
            let tilePixels = CGSize(width: rect.width * scale, height: rect.height * scale)
            let location = ReadingLocation.pdfPage(index: pageIndex, yOffset: 0)

            let sheetRect = PageCompositor.sheetRect(
                in: CGRect(origin: .zero, size: tilePixels),
                presentation: environment.presentation
            )
            let content = try await engine.renderPage(at: location, pixelSize: sheetRect.size)
            let spine = DamageGenerator.spineEdge(forPageIndex: pageIndex)
            let damage = DamageGenerator.generate(
                documentID: documentID,
                bookSeed: bookSeed,
                stablePageID: engine.stablePageID(for: location),
                environment: environment,
                spine: spine
            )
            let tile = try XCTUnwrap(PageCompositor.shared.composite(
                PageCompositionRequest(
                    content: content,
                    pixelSize: tilePixels,
                    environment: environment,
                    condition: damage,
                    spine: spine,
                    textureSeed: StableHash.combine(
                        StableHash.hash(documentID),
                        bookSeed,
                        StableHash.hash(engine.stablePageID(for: location))
                    ),
                    spineShadowScale: layout.spineShadowScale
                )
            ))

            let destination = CGRect(
                x: rect.minX * scale,
                y: rect.minY * scale,
                width: tilePixels.width,
                height: tilePixels.height
            )
            ctx.saveGState()
            ctx.translateBy(x: destination.minX, y: destination.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(tile, in: CGRect(origin: .zero, size: destination.size))
            ctx.restoreGState()
        }

        return try XCTUnwrap(ctx.makeImage())
    }

    /// The same page rendered twice, hours or launches apart, must be identical.
    func testRepeatVisitsToAPageAreByteIdentical() async throws {
        let documentID = UUID()
        let engine = try PDFReadingEngine(documentID: documentID, fileURL: sampleURL, initialLocation: nil)
        try await engine.open()

        let location = ReadingLocation.pdfPage(index: comparisonPageIndex, yOffset: 0)
        let surface = CGSize(width: 450, height: 675)
        let environment = ReadingEnvironment.oldJournal

        func render() async throws -> [UInt8] {
            let sheetRect = PageCompositor.sheetRect(
                in: CGRect(origin: .zero, size: surface),
                presentation: environment.presentation
            )
            let content = try await engine.renderPage(at: location, pixelSize: sheetRect.size)
            let damage = DamageGenerator.generate(
                documentID: documentID,
                bookSeed: 99,
                stablePageID: engine.stablePageID(for: location),
                environment: environment,
                spine: .left
            )
            let image = try XCTUnwrap(PageCompositor.shared.composite(
                PageCompositionRequest(
                    content: content,
                    pixelSize: surface,
                    environment: environment,
                    condition: damage,
                    spine: .left,
                    textureSeed: 4242,
                    spineShadowScale: 1.0
                )
            ))
            return bytes(of: image)
        }

        let first = try await render()
        PaperTextureFactory.shared.purge()   // force the texture to be rebuilt
        let second = try await render()
        XCTAssertEqual(first, second, "A page must not drift between visits.")
    }

    // MARK: - The themed set

    /// Renders every themed environment at one fixed page and size, so the
    /// eleven can be laid side by side and judged as a set rather than one at
    /// a time. This is the sheet; covers are a separate surface.
    func testWriteThemedEnvironmentSet() async throws {
        let documentID = UUID(uuidString: "5C0FFEE0-0000-4000-8000-00000000BEEF")!
        let bookSeed: UInt64 = 0x50AB_1E17_C0FF_EE01

        let engine = try PDFReadingEngine(
            documentID: documentID,
            fileURL: sampleURL,
            initialLocation: nil
        )
        try await engine.open()

        let surface = CGSize(width: 900, height: 1350)
        let location = ReadingLocation.pdfPage(index: comparisonPageIndex, yOffset: 0)
        let stablePageID = engine.stablePageID(for: location)
        let spine = DamageGenerator.spineEdge(forPageIndex: comparisonPageIndex)

        for environment in ReadingEnvironment.themedPresets {
            let sheetRect = PageCompositor.sheetRect(
                in: CGRect(origin: .zero, size: surface),
                presentation: environment.presentation
            )
            let contentRect = PageCompositor.contentRect(
                in: sheetRect,
                presentation: environment.presentation,
                pageAspectRatio: engine.aspectRatio(at: location),
                extraInset: environment.marginalia.marginWidth
            )
            let content = try await engine.renderPage(at: location, pixelSize: contentRect.size)

            let damage = DamageGenerator.generate(
                documentID: documentID,
                bookSeed: bookSeed,
                stablePageID: stablePageID,
                environment: environment,
                spine: spine
            )
            let marginalia = MarginaliaGenerator.generate(
                documentID: documentID,
                bookSeed: bookSeed,
                stablePageID: stablePageID,
                environment: environment,
                frame: MarginaliaGenerator.Frame(sheet: sheetRect, content: contentRect)
            )

            let composed = try XCTUnwrap(
                PageCompositor.shared.composite(
                    PageCompositionRequest(
                        content: content,
                        pixelSize: surface,
                        environment: environment,
                        condition: damage,
                        marginalia: marginalia,
                        spine: spine,
                        textureSeed: StableHash.combine(
                            StableHash.hash(documentID),
                            bookSeed,
                            StableHash.hash(stablePageID)
                        ),
                        pageAspectRatio: engine.aspectRatio(at: location),
                        spineShadowScale: 0.85
                    )
                ),
                "Compositing failed for \(environment.id)"
            )

            let slug = environment.id.replacingOccurrences(of: "theme.", with: "")
            try write(composed, named: "theme-\(slug).png")

            XCTAssertEqual(composed.width, Int(surface.width))
            XCTAssertEqual(composed.height, Int(surface.height))
        }
    }

    // MARK: - Helpers

    private func write(_ image: CGImage, named name: String) throws {
        let url = outputDirectory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw XCTSkip("No PNG encoder available")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            XCTFail("Could not write \(name)")
            return
        }

        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func bytes(of image: CGImage) -> [UInt8] {
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
}
