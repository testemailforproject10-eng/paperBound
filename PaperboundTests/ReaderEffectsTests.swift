import CoreGraphics
import Foundation
import XCTest
@testable import Paperbound

@MainActor
final class ReaderEffectsTests: XCTestCase {
    func testNewDefaultsHaveNoAppearanceOrEnabledEffects() {
        let environment = ReadingEnvironment.default
        XCTAssertEqual(environment, ReadingEnvironment.cleanPaper.effectsOnly)
        XCTAssertEqual(environment.ink, .instant)
        XCTAssertFalse(environment.footstepsEnabled)
        XCTAssertEqual(environment.intensity, 0)
        XCTAssertEqual(environment.condition, .pristine)
        XCTAssertEqual(environment.marginalia, .none)
        XCTAssertEqual(environment.motion, .still)
    }

    func testLegacyBookAppearanceIsIgnoredWithoutLosingEffectToggles() throws {
        let book = Book(title: "Old book", fileName: "old.pdf", format: .pdf,
                        contentFingerprint: "old")
        var old = ReadingEnvironment.watchingGrimoire
        old.ink = .enchanted
        old.footstepsEnabled = true
        book.environmentData = try JSONEncoder().encode(old)
        XCTAssertEqual(book.savedEnvironment, old.effectsOnly)
        book.savedEnvironment = old
        let saved = try JSONDecoder().decode(ReadingEnvironment.self,
                                            from: XCTUnwrap(book.environmentData))
        XCTAssertEqual(saved, old.effectsOnly)
        XCTAssertEqual(saved.ink, .enchanted)
        XCTAssertTrue(saved.footstepsEnabled)
    }

    func testLegacyGlobalDefaultIsMigratedAndCannotRestoreStyling() throws {
        let suite = "reader-effects-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var old = ReadingEnvironment.oldJournal
        old.ink = .enchanted
        old.footstepsEnabled = true
        defaults.set(try JSONEncoder().encode(old), forKey: "settings.defaultEnvironment")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.defaultEnvironment, old.effectsOnly)
        let persisted = try JSONDecoder().decode(
            ReadingEnvironment.self,
            from: XCTUnwrap(defaults.data(forKey: "settings.defaultEnvironment"))
        )
        XCTAssertEqual(persisted, old.effectsOnly)
        settings.defaultEnvironment = .nightPaper
        XCTAssertEqual(settings.defaultEnvironment, ReadingEnvironment.default)
    }

    func testReaderIgnoresLegacyStylingAndPreservesOriginalPixels() async throws {
        var legacy = ReadingEnvironment.watchingGrimoire
        legacy.ink = .enchanted
        let source = try sourceImage()
        let decorated = try await PageCompositor.shared.compositeReaderPage(
            request(legacy, content: source)
        )
        let neutral = try await PageCompositor.shared.compositeReaderPage(
            request(legacy.effectsOnly, content: source)
        )
        XCTAssertEqual(pixels(decorated.image), pixels(source),
                       "Original colored backgrounds, dark print and light print must stay unchanged")
        XCTAssertEqual(pixels(decorated.image), pixels(neutral.image))
        let paper = try XCTUnwrap(decorated.revealBackground)
        XCTAssertTrue(pixels(paper).allSatisfy { $0 == 255 },
                      "Waiting ink must show plain white without texture, cuts, marks or tint")
        var instant = legacy; instant.ink = .instant
        let staticPage = try await PageCompositor.shared.compositeReaderPage(
            request(instant, content: source)
        )
        XCTAssertNil(staticPage.revealBackground)
        XCTAssertEqual(pixels(staticPage.image), pixels(source))
    }

    func testUnstyledReaderStillRespectsDuoReservedRegions() async throws {
        var composition = request(.oldJournal, content: try sourceImage())
        composition.reservedRegions = [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)]
        let result = try await PageCompositor.shared.compositeReaderPage(composition)
        let bytes = pixels(result.image)
        let center = (48 * 64 + 32) * 4
        XCTAssertEqual(Array(bytes[center..<(center + 4)]), [255, 255, 255, 255])
    }

    private func request(_ environment: ReadingEnvironment, content: CGImage) -> PageCompositionRequest {
        PageCompositionRequest(
            content: content, pixelSize: CGSize(width: 64, height: 96),
            environment: environment,
            condition: DamageGenerator.generate(
                documentID: UUID(), bookSeed: 3, stablePageID: "pdf:0",
                environment: environment, spine: .left
            ),
            spine: .left, textureSeed: 9, pageAspectRatio: 1.5
        )
    }

    private func sourceImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 64, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.75, green: 0.25, blue: 0.125, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 8, y: 8, width: 48, height: 40))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 24, y: 24, width: 16, height: 8))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
