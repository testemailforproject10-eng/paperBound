//
//  SubstrateLegibilityTests.swift
//  PaperboundTests
//
//  A themed environment is allowed to look like anything. It is not allowed to
//  be unreadable.
//
//  The first render of the gilded plate was dark type on dark bronze, because
//  the substrate's luminance landed just above the ink-inversion threshold.
//  Nothing failed: the build was green and the tests passed. These assertions
//  exist so that the next one does fail.
//

import CoreGraphics
import XCTest
@testable import Paperbound

final class SubstrateLegibilityTests: XCTestCase {

    // MARK: - The contrast floor

    /// Every substrate, at every tone, either keeps enough luminance for dark
    /// type or flips to light type. There is no third option, and no gap.
    func testEverySubstrateAndToneIsOnOneSideOfTheInversionThreshold() {
        for substrate in Substrate.allCases {
            for material in PaperMaterial.allCases {
                let palette = substrate.palette(for: material)
                let luminance = palette.base.luminance
                let inverts = substrate.invertsInk(for: material)

                if inverts {
                    // Light type on a dark ground: the ground must actually be
                    // dark, or light type disappears into it.
                    XCTAssertLessThan(
                        luminance, 0.52,
                        "\(substrate.rawValue)/\(material.rawValue) inverts ink but its ground is too light"
                    )
                } else {
                    // Dark type on a light ground: roughly 4.5:1 against black
                    // is reached around 0.18 relative luminance. Below that,
                    // dark type on this ground cannot be read.
                    XCTAssertGreaterThan(
                        luminance, 0.18,
                        "\(substrate.rawValue)/\(material.rawValue) keeps dark ink on a ground too dark to read it"
                    )
                }
            }
        }
    }

    /// The themed presets specifically, since those are what ships.
    func testEveryThemedPresetResolvesToALegibleSurface() {
        for environment in ReadingEnvironment.themedPresets {
            let luminance = environment.palette.base.luminance
            if environment.invertsInk {
                XCTAssertLessThan(
                    luminance, 0.52,
                    "\(environment.name) inverts ink on a ground that is not dark"
                )
            } else {
                XCTAssertGreaterThan(
                    luminance, 0.18,
                    "\(environment.name) keeps dark ink on a ground too dark to read it"
                )
            }
        }
    }

    // MARK: - What actually reaches the screen

    /// Composites a leather page and checks the pixels: whichever way the ink
    /// went, type and ground must be far enough apart to read.
    ///
    /// The model answering correctly is not the same as the compositor doing
    /// what the model said, which is the gap this test covers.
    func testCompositedTypeSeparatesFromItsGroundOnADarkSubstrate() throws {
        let size = CGSize(width: 420, height: 630)
        let environment = ReadingEnvironment.watchingGrimoire

        let composed = try XCTUnwrap(
            PageCompositor.shared.composite(
                PageCompositionRequest(
                    content: blockOfType(in: size),
                    pixelSize: size,
                    environment: environment,
                    condition: .pristine(
                        documentID: UUID(),
                        stablePageID: "pdf:0",
                        environmentIdentity: environment.damageIdentity
                    ),
                    spine: .left,
                    textureSeed: 0xABCD_1234
                )
            )
        )

        let samples = luminances(of: composed)
        XCTAssertFalse(samples.isEmpty)

        let sorted = samples.sorted()
        let dark = sorted[sorted.count / 20]          // 5th percentile
        let light = sorted[sorted.count - 1 - sorted.count / 20]  // 95th

        // 0.16 of the 0…1 range is a low bar on purpose: this is catching
        // "type and paper are the same colour", not grading the design.
        XCTAssertGreaterThan(
            light - dark, 0.16,
            "type does not separate from its ground on \(environment.name)"
        )
    }

    // MARK: - Helpers

    /// An opaque black bar on a transparent ground, standing in for a page of
    /// type: the compositor only ever sees rasterized pixels anyway.
    private func blockOfType(in size: CGSize) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.clear(CGRect(origin: .zero, size: size))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        // Several bars, so the sample lands on type wherever it is taken.
        for row in 0..<14 {
            ctx.fill(CGRect(
                x: size.width * 0.12,
                y: size.height * (0.1 + Double(row) * 0.058),
                width: size.width * 0.76,
                height: size.height * 0.028
            ))
        }
        return ctx.makeImage()
    }

    private func luminances(of image: CGImage) -> [Double] {
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

        var result: [Double] = []
        result.reserveCapacity(width * height / 16)
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let index = (y * width + x) * 4
                let r = Double(buffer[index]) / 255
                let g = Double(buffer[index + 1]) / 255
                let b = Double(buffer[index + 2]) / 255
                result.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
            }
        }
        return result
    }
}
